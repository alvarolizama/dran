defmodule DranWeb.API.OwnershipTest do
  @moduledoc """
  Gate W4 (P2): la atribución de propiedad es SERVER-SIDE.

  Un cliente puede mandar `owner_user_id` y `agent_name` en el body; el
  servidor los resuelve por su cuenta y descarta lo que vino del cliente.
  Además, `owner_user_id` no cambia en un update (el snapshot pertenece al
  write original).
  """
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Memory, Repo}

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      chat_model: "Qwen3.5-9B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
      embedding_dimensions: 1024
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    stub_embeddings()

    unique = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{
        email: "own-owner-#{unique}@example.com",
        name: "Owner",
        is_owner: true
      })

    # W5: the API targets the instance workspace — reuse it.
    workspace = Dran.DataCase.ensure_workspace!()

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "own-agent-#{unique}",
        workspace_ids: [{workspace.id, "write"}],
        created_by_user_id: owner.id
      })

    # W3: la key ya no crea un actor. El propietario de lo escrito sale de
    # `api_keys.created_by_user_id` (el creador de la key), no de un
    # `actors.owner_user_id`.

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")

    %{conn: conn, owner: owner, workspace: workspace, key: key, unique: unique}
  end

  describe "POST /api/memory — atribución server-side" do
    test "el cliente NO puede setear owner_user_id ni agent_name", %{
      conn: conn,
      owner: owner,
      workspace: workspace,
      unique: unique
    } do
      body = %{
        "workspace" => workspace.slug,
        "content" => "Fact con campos de atribución inyectados #{unique}",
        # Intento de mass assignment:
        "owner_user_id" => 999_999,
        "agent_name" => "cliente-malicioso"
      }

      conn = post(conn, ~p"/api/memory", body)
      assert %{"data" => data} = json_response(conn, 201)

      # El dueño es el de la key (created_by_user_id), NO el del body.
      assert data["owner_user_id"] == owner.id
      refute data["owner_user_id"] == 999_999
      # agent_name no vino por header ⇒ nil (no el valor del cliente).
      refute data["agent_name"] == "cliente-malicioso"

      persisted = Memory.get_memory!(data["id"])
      assert persisted.owner_user_id == owner.id
    end

    test "X-Hermes-Agent llega al row como agent_name", %{
      conn: conn,
      workspace: workspace,
      unique: unique
    } do
      conn =
        conn
        |> Plug.Conn.put_req_header("x-hermes-agent", "coder")
        |> post(~p"/api/memory", %{
          "workspace" => workspace.slug,
          "content" => "Fact atribuido al perfil #{unique}"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["agent_name"] == "coder"
    end

    test "el listado funciona igual que antes (guard backwards-compat)", %{
      conn: conn,
      workspace: workspace,
      unique: unique
    } do
      conn =
        post(conn, ~p"/api/memory", %{
          "workspace" => workspace.slug,
          "content" => "Fact listable #{unique}"
        })

      assert json_response(conn, 201)

      listed = get(conn, ~p"/api/memory?workspace=#{workspace.slug}")
      assert %{"data" => data} = json_response(listed, 200)
      assert length(data) == 1
      assert hd(data)["content"] == "Fact listable #{unique}"
    end
  end

  describe "POST /api/knowledge-pages — atribución server-side" do
    test "created_by y owner_user_id salen del actor, no del body", %{
      conn: conn,
      owner: owner,
      workspace: workspace,
      unique: unique
    } do
      conn =
        post(conn, ~p"/api/knowledge-pages", %{
          "workspace" => workspace.slug,
          "title" => "Página con atribución #{unique}",
          "page_type" => "note",
          "body" => "cuerpo",
          "created_by" => "cliente-falso",
          "owner_user_id" => 999_999,
          "agent_name" => "cliente-falso"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["owner_user_id"] == owner.id
      assert data["created_by"] != "cliente-falso"
    end

    test "X-Hermes-Agent se persiste en la página", %{
      conn: conn,
      workspace: workspace,
      unique: unique
    } do
      conn =
        conn
        |> Plug.Conn.put_req_header("x-hermes-agent", "aluxe")
        |> post(~p"/api/knowledge-pages", %{
          "workspace" => workspace.slug,
          "title" => "Página atribuida #{unique}",
          "page_type" => "note"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["agent_name"] == "aluxe"
    end

    test "PUT no puede cambiar owner_user_id (whitelist SEC-006)", %{
      conn: conn,
      owner: owner,
      workspace: workspace,
      unique: unique
    } do
      created =
        post(conn, ~p"/api/knowledge-pages", %{
          "workspace" => workspace.slug,
          "title" => "Página a actualizar #{unique}",
          "page_type" => "note"
        })

      assert %{"data" => %{"slug" => slug}} = json_response(created, 201)

      updated =
        put(conn, ~p"/api/knowledge-pages/#{slug}?workspace=#{workspace.slug}", %{
          "title" => "Título nuevo #{unique}",
          "owner_user_id" => 999_999,
          "agent_name" => "cliente-falso"
        })

      assert %{"data" => data} = json_response(updated, 200)
      assert data["owner_user_id"] == owner.id
      refute data["owner_user_id"] == 999_999
    end
  end

  describe "GET /api/memory — filtro de lectura (P5 REST)" do
    test "en workspace aislado el usuario no ve facts de otro dueño", %{
      conn: conn,
      owner: owner,
      workspace: workspace,
      unique: unique
    } do
      # Aísla el workspace
      {:ok, _} =
        workspace
        |> Dran.Workspace.settings_changeset(%{share_memory: false})
        |> Repo.update()

      # Fact del owner (la key pertenece a su actor)
      post(conn, ~p"/api/memory", %{
        "workspace" => workspace.slug,
        "content" => "Fact del owner #{unique}"
      })

      # Fact de OTRO dueño, insertado directo
      {:ok, other} =
        Accounts.create_user(%{
          email: "other-#{unique}@example.com",
          api_token: "other-token-#{unique}"
        })

      {:ok, _, _} =
        Memory.add(%{
          "workspace_id" => workspace.id,
          "content" => "Fact de otro dueño #{unique}",
          "owner_user_id" => other.id
        })

      conn = get(conn, ~p"/api/memory?workspace=#{workspace.slug}")
      assert %{"data" => data} = json_response(conn, 200)

      contents = Enum.map(data, & &1["content"])
      assert "Fact del owner #{unique}" in contents
      refute "Fact de otro dueño #{unique}" in contents
      assert owner.id != other.id
    end
  end

  # Mismo stub determinístico que memory_test.exs: vectores distintos por
  # contenido, para que el dedupe semántico no colapse todo en un duplicado.
  defp stub_embeddings do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      input = extract_embed_input(body)
      Req.Test.json(conn, embeddings_response(embedding_for(input)))
    end)
  end

  defp extract_embed_input(body) do
    case Jason.decode(body) do
      {:ok, %{"input" => [input | _]}} when is_binary(input) -> input
      {:ok, %{"input" => input}} when is_binary(input) -> input
      _ -> ""
    end
  end

  defp embedding_for(input) do
    idx = rem(:erlang.phash2(input), 1024)
    List.duplicate(0.0, idx) ++ [1.0] ++ List.duplicate(0.0, 1023 - idx)
  end

  defp embeddings_response(vec) do
    %{
      "object" => "list",
      "data" => [%{"object" => "embedding", "index" => 0, "embedding" => vec}],
      "model" => "Qwen3-Embedding",
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }
  end
end
