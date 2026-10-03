defmodule DranWeb.API.AgentDestinationTest do
  @moduledoc """
  Gate W6 (contract-instance-visibility-20260919): el destino de escritura se
  declara POR ESCRITURA con `scope` y el servidor lo traduce a `visibility` +
  `content_shares`, validando membresía y fallando cerrado.

  - P4: `scope: %{"group" => slug}` deja la escritura ya compartida con ese
    grupo y un miembro del grupo la lee por REST.
  - P20: un `scope` de grupo ajeno (o inexistente) falla cerrado con 422; nunca
    cae a `private` en silencio (y no deja fila huérfana).
  - Rules#10 / F16: la memoria acepta `scope` por la MISMA puerta que páginas.
  - Rules#9: el cliente NUNCA declara lectura — `scope` es destino de escritura.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Memory, Sharing}

  setup do
    # Memoria: el alta genera embeddings — stub determinístico por contenido.
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

    ws = Dran.DataCase.ensure_workspace!()
    u = u()

    {:ok, owner} =
      Accounts.create_user(%{
        email: "dest-owner-#{u}@example.com",
        name: "Owner",
        api_token: "tok-owner-#{u}"
      })

    {:ok, member} =
      Accounts.create_user(%{
        email: "dest-member-#{u}@example.com",
        name: "Member",
        api_token: "tok-member-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "dest-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-stranger-#{u}"
      })

    %{ws: ws, owner: owner, member: member, stranger: stranger}
  end

  defp u, do: System.unique_integer([:positive])

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  # Grupo del que `owner` es miembro (la membresía del DUEÑO es lo que valida
  # el scope de escritura). Opcionalmente suma `member` como lector.
  defp group_with(owner, members) do
    {:ok, group} = Sharing.create_group(%{name: "Equipo #{u()}"})
    {:ok, _} = Sharing.add_group_member(group, owner.id)
    Enum.each(members, fn m -> {:ok, _} = Sharing.add_group_member(group, m.id) end)
    group
  end

  defp page_count, do: Dran.Repo.aggregate(Knowledge.Page, :count, :id)
  defp memory_count, do: Dran.Repo.aggregate(Memory, :count, :id)

  defp create_page(conn, attrs) do
    post(
      conn,
      "/api/knowledge-pages",
      Map.merge(%{"title" => "Destino #{u()}", "page_type" => "note"}, attrs)
    )
  end

  defp create_memory(conn, attrs) do
    post(conn, "/api/memory", Map.merge(%{"content" => "hecho destino #{u()}"}, attrs))
  end

  # ── Páginas ────────────────────────────────────────────────────────────────

  describe "páginas — el destino por escritura (P4/P20)" do
    test "(a) sin scope la página nace private y un tercero no la lee", ctx do
      conn = create_page(conn_for(ctx.owner), %{})
      assert %{"data" => page} = json_response(conn, 201)
      assert page["visibility"] == "private"

      denied = get(conn_for(ctx.stranger), "/api/knowledge-pages/#{page["slug"]}")
      assert json_response(denied, 404)
    end

    test "(b) scope public: un tercero la lee", ctx do
      conn = create_page(conn_for(ctx.owner), %{"scope" => "public"})
      assert %{"data" => page} = json_response(conn, 201)
      assert page["visibility"] == "public"

      ok = get(conn_for(ctx.stranger), "/api/knowledge-pages/#{page["slug"]}")
      assert %{"data" => _} = json_response(ok, 200)
    end

    test "(c) scope group + slug: queda shared con el share y el miembro la lee (P4)", ctx do
      group = group_with(ctx.owner, [ctx.member])

      conn = create_page(conn_for(ctx.owner), %{"scope" => %{"group" => group.slug}})
      assert %{"data" => page} = json_response(conn, 201)
      assert page["visibility"] == "shared"

      [share] = Sharing.list_shares("page", page["id"])
      assert share.user_group_id == group.id
      assert share.user_id == nil

      # El miembro del grupo la lee por REST…
      member_read = get(conn_for(ctx.member), "/api/knowledge-pages/#{page["slug"]}")
      assert %{"data" => _} = json_response(member_read, 200)

      # …y un tercero fuera del grupo no.
      stranger_read = get(conn_for(ctx.stranger), "/api/knowledge-pages/#{page["slug"]}")
      assert json_response(stranger_read, 404)
    end

    test "(d) grupo inexistente → 422 y no deja fila", ctx do
      before = page_count()

      conn = create_page(conn_for(ctx.owner), %{"scope" => %{"group" => "no-existe-#{u()}"}})
      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "unknown group"

      # Nada se insertó: ni public, ni shared, ni un `private` silencioso.
      assert page_count() == before
    end

    test "(e) grupo del que el dueño NO es miembro → 422 (nunca private en silencio)", ctx do
      # El grupo existe y tiene miembros, pero NO al dueño de la credencial.
      {:ok, group} = Sharing.create_group(%{name: "Ajeno #{u()}"})
      {:ok, _} = Sharing.add_group_member(group, ctx.stranger.id)

      before = page_count()

      conn = create_page(conn_for(ctx.owner), %{"scope" => %{"group" => group.slug}})
      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "not a member"

      # Fail-closed: la página NO quedó creada como private.
      assert page_count() == before
    end

    test "(f) un scope fuera del vocabulario → 422", ctx do
      before = page_count()

      for bad <- ["team", "shared", 123, %{"user" => "x"}] do
        conn = create_page(conn_for(ctx.owner), %{"scope" => bad})
        assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)
      end

      assert page_count() == before
    end
  end

  # ── Memoria (misma puerta, Rules#10 / F16) ─────────────────────────────────

  describe "memoria — la misma puerta (Rules#10/F16)" do
    test "sin scope nace private y un tercero no la ve", ctx do
      conn = create_memory(conn_for(ctx.owner), %{})
      assert %{"data" => memory} = json_response(conn, 201)
      assert memory["visibility"] == "private"

      listed = get(conn_for(ctx.stranger), "/api/memory")
      assert %{"data" => data} = json_response(listed, 200)
      refute memory["id"] in Enum.map(data, & &1["id"])
    end

    test "scope public: un tercero la lee", ctx do
      conn = create_memory(conn_for(ctx.owner), %{"scope" => "public"})
      assert %{"data" => memory} = json_response(conn, 201)
      assert memory["visibility"] == "public"

      listed = get(conn_for(ctx.stranger), "/api/memory")
      assert %{"data" => data} = json_response(listed, 200)
      assert memory["id"] in Enum.map(data, & &1["id"])
    end

    test "scope group + slug: el miembro la lee (P4)", ctx do
      group = group_with(ctx.owner, [ctx.member])

      conn = create_memory(conn_for(ctx.owner), %{"scope" => %{"group" => group.slug}})
      assert %{"data" => memory} = json_response(conn, 201)
      assert memory["visibility"] == "shared"

      [share] = Sharing.list_shares("memory", memory["id"])
      assert share.user_group_id == group.id

      member_listed = get(conn_for(ctx.member), "/api/memory")
      assert %{"data" => member_data} = json_response(member_listed, 200)
      assert memory["id"] in Enum.map(member_data, & &1["id"])

      stranger_listed = get(conn_for(ctx.stranger), "/api/memory")
      assert %{"data" => stranger_data} = json_response(stranger_listed, 200)
      refute memory["id"] in Enum.map(stranger_data, & &1["id"])
    end

    test "grupo ajeno → 422 y no deja hecho (P20)", ctx do
      {:ok, group} = Sharing.create_group(%{name: "Ajeno M #{u()}"})
      {:ok, _} = Sharing.add_group_member(group, ctx.stranger.id)

      before = memory_count()

      conn = create_memory(conn_for(ctx.owner), %{"scope" => %{"group" => group.slug}})
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)

      assert memory_count() == before
    end

    test "scope fuera del vocabulario → 422", ctx do
      before = memory_count()

      conn = create_memory(conn_for(ctx.owner), %{"scope" => "team"})
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)

      assert memory_count() == before
    end
  end

  # ── Stub de embeddings (mismo determinismo que memory_test) ────────────────

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
