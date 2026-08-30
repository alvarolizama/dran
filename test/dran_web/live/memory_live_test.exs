defmodule DranWeb.MemoryLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge
  alias Dran.Memory

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference so Memory.add skips embedding calls and Memory.search
    # runs the FTS leg only (deterministic, no external APIs).
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    context = Knowledge.get_workspace_by_slug("personal")

    {:ok, _m1, :created} =
      Memory.add(%{
        "workspace_id" => context.id,
        "content" => "El proyecto Dran usa Postgres con pgvector para búsqueda semántica",
        "source_session" => "sess-alpha",
        "created_by" => "agent-riel"
      })

    {:ok, _m2, :created} =
      Memory.add(%{
        "workspace_id" => context.id,
        "content" => "A Álvaro le gusta Tailwind para el frontend de Dran",
        "source_session" => "sess-beta",
        "created_by" => "agent-hermes"
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, context: context}
  end

  test "renders memories with attribution (who, when, what)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/personal/memory")

    assert html =~ t("Memory")
    assert html =~ "El proyecto Dran usa Postgres con pgvector"
    assert html =~ "agent-riel"
    assert html =~ "agent-hermes"
    assert html =~ t("just now")
    assert html =~ "sess-alpha"
  end

  test "sidebar shows the memory nav item with the badge count", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/personal/memory")

    assert html =~ ~s(href="/personal/memory")
    # active nav highlight on the memory item
    assert html =~ ~s(border-l-2 border-primary)
  end

  test "search filters memories via the hybrid search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/memory")

    html =
      view
      |> form("#memory-search-form", q: "pgvector")
      |> render_change()

    assert html =~ "El proyecto Dran usa Postgres con pgvector"
    refute html =~ "A Álvaro le gusta Tailwind"
  end

  test "status filter shows superseded memories", %{conn: conn, context: context} do
    {:ok, m3, :created} =
      Memory.add(%{
        "workspace_id" => context.id,
        "content" => "Fact obsoleto que fue reemplazado por otro",
        "created_by" => "agent-old"
      })

    {:ok, _} = Memory.delete_memory(m3)

    {:ok, view, _html} = live(conn, ~p"/personal/memory")

    # Active by default — the superseded fact is hidden
    refute render(view) =~ "Fact obsoleto"

    html =
      view
      |> element("#memory-filter-superseded")
      |> render_click()

    assert html =~ "Fact obsoleto"
    refute html =~ "El proyecto Dran usa Postgres"
  end

  test "feedback updates the trust score in place", %{conn: conn, context: context} do
    {:ok, view, _html} = live(conn, ~p"/personal/memory")

    [entry | _] = Memory.list_memories(context.id, status: "active", limit: 1)

    html =
      view
      |> element("#memory-helpful-#{entry.id}")
      |> render_click()

    assert html =~ "0.55"
  end

  test "delete marks the memory superseded and removes it from the active list", %{
    conn: conn,
    context: context
  } do
    {:ok, view, _html} = live(conn, ~p"/personal/memory")

    [entry | _] = Memory.list_memories(context.id, status: "active", limit: 1)

    render_click(view |> element("#memory-delete-#{entry.id}"))

    updated = Memory.get_memory!(entry.id)
    assert updated.status == "superseded"
    refute render(view) =~ entry.content
  end

  test "feedback rejects ids from another workspace (forged phx event)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/memory")

    # A memory in a DIFFERENT workspace (not visible in this view's socket)
    {:ok, other} = Knowledge.create_workspace(%{name: "Otro WS", slug: "otro-ws-feedback"})

    {:ok, foreign, :created} =
      Memory.add(%{
        "workspace_id" => other.id,
        "content" => "Fact de otro workspace",
        "created_by" => "agent-foreign"
      })

    trust_before = foreign.trust_score

    # Simulates a forged phx-click carrying the foreign id
    html = render_click(view, "feedback", %{"id" => foreign.id, "helpful" => "true"})

    assert html =~ t("Memory no encontrada")
    assert Memory.get_memory!(foreign.id).trust_score == trust_before
  end

  test "updates live when an agent stores a new fact (handle_info)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/memory")

    context = Knowledge.get_workspace_by_slug("personal")

    # Simulates an agent writing through the REST API: Memory.add broadcasts
    # {:memory_changed, ...} on the brain topic the view subscribes to.
    {:ok, _m, :created} =
      Memory.add(%{
        "workspace_id" => context.id,
        "content" => "Fact en vivo desde el broadcast de un agente",
        "created_by" => "agent-late"
      })

    # Give the PubSub message a moment to be processed (repo test pattern).
    Process.sleep(50)

    assert render(view) =~ "Fact en vivo desde el broadcast de un agente"
  end

  test "load_more appends the next page and keeps the first one", %{conn: conn, context: context} do
    # 31 facts total (2 from setup + 29 here) > @page_size (30) so has_more
    # is true on the first page; the second page holds the remainder.
    for i <- 1..29 do
      {:ok, _m, :created} =
        Memory.add(%{
          "workspace_id" => context.id,
          "content" => "Fact de relleno número #{i} para paginación",
          "created_by" => "agent-bulk"
        })
    end

    {:ok, view, html} = live(conn, ~p"/personal/memory")

    assert html =~ ~s(id="memory-load-more")

    html = view |> element("#memory-load-more") |> render_click()

    # First page content still present + the oldest facts (page 2) appended
    assert html =~ "Fact de relleno"
    assert html =~ "El proyecto Dran usa Postgres con pgvector"
    # 31 facts, one page consumed → no more pages
    refute html =~ ~s(id="memory-load-more")
  end

  describe "workspace graph integration" do
    test "active memories appear as additive graph nodes", %{context: context} do
      %{nodes: nodes} = Knowledge.graph_data(context.id)

      memory_nodes = Enum.filter(nodes, &(&1.type == "memory"))

      assert length(memory_nodes) >= 2
      assert Enum.any?(memory_nodes, &(&1.title =~ "Postgres"))
      # Memory nodes are hover-only: no slug, so the JS hook won't navigate.
      assert Enum.all?(memory_nodes, &is_nil(&1.slug))
    end

    test "graph_type_counts includes the memory count", %{context: context} do
      counts = Knowledge.graph_type_counts(context.id)
      assert counts["memory"] >= 2
    end

    test "superseded memories are excluded from the graph", %{context: context} do
      {:ok, m, :created} =
        Memory.add(%{
          "workspace_id" => context.id,
          "content" => "Fact para el grafo que será obsoleto",
          "created_by" => "agent-graph"
        })

      {:ok, _} = Memory.delete_memory(m)

      %{nodes: nodes} = Knowledge.graph_data(context.id)
      refute Enum.any?(nodes, &(&1.title =~ "será obsoleto"))
    end
  end

  test "global search surfaces memory facts", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/personal/search?q=pgvector")

    # Memory section present with the matching fact and its attribution
    assert html =~ ~s(data-testid="memory-results")
    assert html =~ "El proyecto Dran usa Postgres con pgvector"
    assert html =~ "agent-riel"
  end
end
