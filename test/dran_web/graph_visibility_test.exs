defmodule DranWeb.GraphVisibilityTest do
  @moduledoc """
  Gate W5 (P7): el grafo pinta solo nodos visibles y sus aristas.

  Regla dura del contrato: intersección estricta — nunca una arista con un
  extremo oculto.
  """
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Repo}

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

    unique = System.unique_integer([:positive])

    {:ok, workspace} =
      Knowledge.create_workspace(%{
        name: "Graph vis #{unique}",
        slug: "graph-vis-#{unique}"
      })

    {:ok, owner} =
      Accounts.create_user(%{
        email: "graph-owner-#{unique}@example.com",
        name: "Graph Owner",
        is_owner: true
      })

    {:ok, _} =
      %Accounts.UserWorkspace{}
      |> Accounts.UserWorkspace.changeset(%{
        user_id: owner.id,
        workspace_id: workspace.id,
        role: "owner"
      })
      |> Repo.insert()

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "graph-key-#{unique}",
        workspace_ids: [{workspace.id, "write"}],
        created_by_user_id: owner.id
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")

    %{conn: conn, owner: owner, workspace: workspace, unique: unique}
  end

  describe "GET /api/graph (P7)" do
    test "las aristas solo unen nodos visibles; una página de otro dueño no aparece",
         %{conn: conn, owner: owner, workspace: workspace, unique: unique} do
      # Workspace aislado: cada lector ve solo lo suyo.
      # Página del owner (visible para él)
      {:ok, own_page} =
        Knowledge.create_page(%{
          "workspace_id" => workspace.id,
          "title" => "Página del owner #{unique}",
          "slug" => "own-page-#{unique}",
          "page_type" => "note",
          "body" => "cuerpo",
          "owner_user_id" => owner.id
        })

      # Otra página + otro usuario
      {:ok, other} =
        Accounts.create_user(%{
          email: "graph-other-#{unique}@example.com",
          api_token: "graph-other-#{unique}"
        })

      {:ok, hidden_page} =
        Knowledge.create_page(%{
          "workspace_id" => workspace.id,
          "title" => "Página oculta #{unique}",
          "slug" => "hidden-page-#{unique}",
          "page_type" => "note",
          "body" => "cuerpo",
          "owner_user_id" => other.id
        })

      # Arista entre ambas páginas (cruzada: una visible, una oculta)
      {:ok, _rel} =
        %Dran.Relation{}
        |> Dran.Relation.changeset(%{
          workspace_id: workspace.id,
          source_id: own_page.id,
          target_id: hidden_page.id,
          source_type: "page",
          target_type: "page",
          relation_type: "related"
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/graph?workspace=#{workspace.slug}")
      assert %{"data" => %{"nodes" => nodes, "edges" => edges}} = json_response(conn, 200)

      node_ids = Enum.map(nodes, & &1["id"])
      assert own_page.id in node_ids, "la página del lector debe aparecer"
      refute hidden_page.id in node_ids, "la página de otro dueño NO debe aparecer"

      # Intersección estricta: ninguna arista con un extremo oculto.
      for edge <- edges do
        assert edge["source"] in node_ids
        assert edge["target"] in node_ids
      end
    end

    # W3: "shared workspace" is gone — the equivalent guarantee is PUBLIC
    # items: an edge between two visible (public) pages must render.
    test "con items públicos todo visible sigue apareciendo (guard)", %{
      conn: conn,
      owner: owner,
      workspace: workspace,
      unique: unique
    } do
      {:ok, page_a} =
        Knowledge.create_page(%{
          "workspace_id" => workspace.id,
          "title" => "Compartida A #{unique}",
          "slug" => "shared-a-#{unique}",
          "page_type" => "note",
          "body" => "cuerpo",
          "owner_user_id" => owner.id,
          "visibility" => "public"
        })

      {:ok, page_b} =
        Knowledge.create_page(%{
          "workspace_id" => workspace.id,
          "title" => "Compartida B #{unique}",
          "slug" => "shared-b-#{unique}",
          "page_type" => "note",
          "body" => "cuerpo",
          "visibility" => "public"
        })

      # Arista entre dos páginas visibles (una sin dueño = del workspace)
      {:ok, _rel} =
        %Dran.Relation{}
        |> Dran.Relation.changeset(%{
          workspace_id: workspace.id,
          source_id: page_a.id,
          target_id: page_b.id,
          source_type: "page",
          target_type: "page",
          relation_type: "related"
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/graph?workspace=#{workspace.slug}")
      assert %{"data" => %{"nodes" => nodes, "edges" => edges}} = json_response(conn, 200)

      node_ids = Enum.map(nodes, & &1["id"])
      assert page_a.id in node_ids
      assert page_b.id in node_ids

      assert Enum.any?(edges, fn e ->
               e["source"] == page_a.id and e["target"] == page_b.id
             end),
             "la arista entre dos nodos visibles debe pintarse"
    end

    test "el cache del grafo está particionado por scope (no filtra entre lectores)", %{
      workspace: workspace,
      owner: owner,
      unique: unique
    } do
      {:ok, mine} =
        Knowledge.create_page(%{
          "workspace_id" => workspace.id,
          "title" => "Mía #{unique}",
          "slug" => "cache-mine-#{unique}",
          "page_type" => "note",
          "owner_user_id" => owner.id
        })

      {:ok, other} =
        Accounts.create_user(%{
          email: "cache-other-#{unique}@example.com",
          api_token: "cache-other-#{unique}"
        })

      {:ok, theirs} =
        Knowledge.create_page(%{
          "workspace_id" => workspace.id,
          "title" => "Ajena #{unique}",
          "slug" => "cache-theirs-#{unique}",
          "page_type" => "note",
          "owner_user_id" => other.id
        })

      # W3: scopes are {:reader, id} now. An "all" reader (instance owner)
      # caches their view ...
      all_view = Dran.GraphCache.get(workspace.id, :all)
      assert all_view.json =~ theirs.slug
      assert all_view.json =~ mine.slug

      # ... and the per-reader view does NOT get that cached payload.
      reader_view = Dran.GraphCache.get(workspace.id, {:reader, owner.id})
      assert reader_view.json =~ mine.slug

      refute reader_view.json =~ theirs.slug,
             "el payload de otro scope no debe servirse a este lector"
    end
  end
end
