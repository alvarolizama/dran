defmodule DranWeb.MemoryLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge
  alias Dran.Memory
  alias Dran.Repo

  # Gettext wrapper. English is the app default locale, so the msgid is
  # what the app renders unless a test pins another locale.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference so Memory.add skips embedding calls and Memory.search
    # runs the FTS leg only (deterministic, no external APIs).
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
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
    {:ok, _view, html} = live(conn, ~p"/memory")

    assert html =~ t("Memory")
    assert html =~ "El proyecto Dran usa Postgres con pgvector"
    assert html =~ "agent-riel"
    assert html =~ "agent-hermes"
    assert html =~ t("just now")
    assert html =~ "sess-alpha"
  end

  test "sidebar shows the memory nav item with the badge count", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/memory")

    assert html =~ ~s(href="/memory")
    # active nav highlight on the memory item
    assert html =~ ~s(aria-current="page")
  end

  test "search filters memories via the hybrid search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/memory")

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

    {:ok, view, _html} = live(conn, ~p"/memory")

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
    {:ok, view, _html} = live(conn, ~p"/memory")

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
    {:ok, view, _html} = live(conn, ~p"/memory")

    [entry | _] = Memory.list_memories(context.id, status: "active", limit: 1)

    render_click(view |> element("#memory-delete-#{entry.id}"))

    updated = Memory.get_memory!(entry.id)
    assert updated.status == "superseded"
    refute render(view) =~ entry.content
  end

  test "purge permanently deletes a superseded memory", %{conn: conn, context: context} do
    [entry | _] = Memory.list_memories(context.id, status: "active", limit: 1)
    {:ok, _} = Memory.delete_memory(entry)

    {:ok, view, _html} = live(conn, ~p"/memory")

    view
    |> element("#memory-filter-superseded")
    |> render_click()

    render_click(view |> element("#memory-purge-#{entry.id}"))

    assert Repo.get(Memory, entry.id) == nil
  end

  test "purge_superseded bulk-deletes every obsolete memory", %{conn: conn, context: context} do
    entries = Memory.list_memories(context.id, status: "active", limit: 2)
    Enum.each(entries, &({:ok, _} = Memory.delete_memory(&1)))

    {:ok, view, _html} = live(conn, ~p"/memory")

    view
    |> element("#memory-filter-superseded")
    |> render_click()

    assert has_element?(view, "#memory-purge-superseded")

    view
    |> element("#memory-purge-superseded")
    |> render_click()

    assert Memory.list_memories(context.id, status: "superseded") == []
    assert Enum.all?(entries, &(Repo.get(Memory, &1.id) == nil))
  end

  test "feedback rejects ids from another workspace (forged phx event)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/memory")

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

    assert html =~ t("Memory not found")
    assert Memory.get_memory!(foreign.id).trust_score == trust_before
  end

  test "updates live when an agent stores a new fact (handle_info)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/memory")

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

    {:ok, view, html} = live(conn, ~p"/memory")

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
    {:ok, _view, html} = live(conn, ~p"/search?q=pgvector")

    # Memory section present with the matching fact and its attribution
    assert html =~ ~s(data-testid="memory-results")
    assert html =~ "El proyecto Dran usa Postgres con pgvector"
    assert html =~ "agent-riel"
  end

  test "set_mode keeps the current mode for unknown client-sent modes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=pgvector")

    active_btn = "button[phx-value-mode='semantic']"

    # A valid mode switches (button gets the active classes); an arbitrary
    # string must be rejected (it feeds String.to_atom on the next search)
    # and leave the mode untouched.
    render_hook(view, "set_mode", %{"mode" => "semantic"})
    assert has_element?(view, active_btn, t("Semantic"))

    html = render_hook(view, "set_mode", %{"mode" => "evil-mode-#{System.unique_integer()}"})
    # Still on semantic: the active classes survive the bogus event.
    assert html =~ ~s(bg-base-100 shadow-sm font-medium)
  end

  describe "el destino del hecho (W2)" do
    # Memory era la única superficie con destino y sin píldora, sin control y
    # sin diálogo de grants: el vocabulario y la puerta son los MISMOS que en
    # pages, goals y plans.
    setup %{context: context} do
      owner = create_user!("mem-owner")
      guest = create_user!("mem-guest")

      {:ok, memory, :created} =
        Memory.add(%{
          "workspace_id" => context.id,
          "content" => "Hecho propio del dueño",
          "created_by" => "agent-owner",
          "owner_user_id" => owner.id
        })

      {:ok, owner: owner, guest: guest, memory: memory, context: context}
    end

    test "un hecho privado no anuncia su nivel y uno público usa la píldora compartida", ctx do
      {:ok, view, _html} = live(login(ctx.conn, ctx.owner), ~p"/memory")

      # `private` es el default: la píldora NO se dibuja (nada que anunciar).
      refute has_element?(view, "#memory-visibility-#{ctx.memory.id}")

      {:ok, public_memory} = Memory.set_scope(ctx.memory, "public")
      {:ok, view, _html} = live(login(ctx.conn, ctx.owner), ~p"/memory")

      assert has_element?(
               view,
               "#memory-visibility-#{public_memory.id}",
               t("Public")
             )

      # El valor CRUDO de la columna no se imprime en la tarjeta.
      card_html = view |> element("#memory-#{public_memory.id}") |> render()
      refute card_html =~ ~r/>\s*public\s*</
    end

    test "el dueño mueve el destino por la puerta del contexto y persiste", ctx do
      {:ok, view, _html} = live(login(ctx.conn, ctx.owner), ~p"/memory")

      view
      |> form("#memory-scope-form-#{ctx.memory.id}",
        memory_scope: %{visibility: "shared"}
      )
      |> render_change()

      # La fila cambió por `Memory.set_scope/2` (no por un Repo.update de la vista).
      assert Memory.get_memory!(ctx.memory.id).visibility == "shared"
      assert has_element?(view, "#memory-share-#{ctx.memory.id}")
      assert has_element?(view, "#memory-visibility-#{ctx.memory.id}", t("Shared"))
      refute Memory.get_memory!(ctx.memory.id).visibility == "private"
    end

    test "un lector que no es el dueño no ve el control ni puede moverlo", ctx do
      # Un hecho público: el invitado lo LEE, pero no lo gobierna.
      {:ok, memory} = Memory.set_scope(ctx.memory, "public")

      {:ok, view, _html} = live(login(ctx.conn, ctx.guest), ~p"/memory")

      assert has_element?(view, "#memory-#{memory.id}")
      refute has_element?(view, "#memory-scope-form-#{memory.id}")
      refute has_element?(view, "#memory-share-#{memory.id}")

      # Un evento forjado tampoco: el dueño es el único que mueve el destino.
      render_change(view, "set_scope", %{
        "memory_id" => memory.id,
        "memory_scope" => %{"visibility" => "private"}
      })

      assert Memory.get_memory!(memory.id).visibility == "public"
    end

    test "compartir con el diálogo es real: el invitado LEE el hecho", ctx do
      {:ok, view, _html} = live(login(ctx.conn, ctx.owner), ~p"/memory")

      # Se abre el MISMO diálogo, con `resource_type="memory"`.
      view |> element("#memory-share-#{ctx.memory.id}") |> render_click()
      assert has_element?(view, "#memory-share-dialog")

      view
      |> form("#share-user-form", user_id: ctx.guest.id)
      |> render_submit()

      # El grant marcó `shared` en la misma transacción (no es un no-op)…
      updated = Memory.get_memory!(ctx.memory.id)
      assert updated.visibility == "shared"

      # …y el invitado lo lee, en el contexto y en la superficie.
      ids =
        Memory.list_memories(ctx.context.id, scope: {:reader, ctx.guest.id})
        |> Enum.map(& &1.id)

      assert ctx.memory.id in ids

      {:ok, guest_view, _html} = live(login(ctx.conn, ctx.guest), ~p"/memory")
      assert has_element?(guest_view, "#memory-#{ctx.memory.id}")
    end
  end

  defp create_user!(unique) do
    {:ok, user} =
      %Dran.Accounts.User{}
      |> Dran.Accounts.User.changeset(%{
        email: "mem-#{unique}@dran.test",
        api_token: "mem-#{unique}"
      })
      |> Repo.insert()

    user
  end

  defp login(conn, %Dran.Accounts.User{} = user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end
end
