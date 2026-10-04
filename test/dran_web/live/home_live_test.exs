defmodule DranWeb.HomeLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge
  alias Dran.{Goals, Memory, Plans, Repo}
  alias Dran.Accounts.User

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't call external APIs
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

    # W1 single-workspace: the flat home renders the instance workspace.
    wiki_ctx = Dran.DataCase.ensure_workspace!()

    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: wiki_ctx.id,
        title: "Wiki Test Note",
        body: "A note visible through the wiki",
        page_type: "note"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, wiki_ctx: wiki_ctx, page: page}
  end

  describe "workspace home" do
    test "GET /:workspace_slug renders the workspace home", %{conn: conn, wiki_ctx: wiki_ctx} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ wiki_ctx.name
    end

    # TODO: PagesLive resolves workspace from session, not URL — needs fix in PageDetail.mount_page_viewer
    @tag :skip
    test "GET /:workspace_slug/:type/:slug renders the page read-only", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      page: page
    } do
      {:ok, _view, html} = live(conn, ~p"/notes/#{page.slug}")

      assert html =~ "Wiki Test Note"
      assert html =~ "A note visible through the wiki"
    end

    test "GET /:unknown_slug redirects to / for an unknown workspace", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/no-such-workspace")
    end
  end

  describe "graph node_click" do
    # Regression: the hook sends the singular page_type ("note") but routes
    # are plural workspace-scoped (/:ws/notes/:slug). With the raw type the
    # wildcard matched page_type="note", PagesLive couldn't resolve it and
    # redirected to the index — clicking a node landed on home.
    test "navigates to the plural workspace-scoped page route", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      page: page
    } do
      {:ok, view, _html} = live(conn, ~p"/graph")

      render_click(view, "node_click", %{"slug" => page.slug, "type" => "note"})

      assert_redirect(view, "/notes/#{page.slug}")
    end
  end

  describe "el estado del home es PERSONAL (W1)" do
    # La regla del contrato: un owner o un admin NO ensanchan esta sección —
    # el scope sale de `ContentVisibility.personal_scope/1`, no de `scope/3`.
    setup %{wiki_ctx: workspace} do
      reader = create_user!("status-reader")
      admin = create_user!("status-admin", "admin")
      {:ok, reader: reader, admin: admin, workspace: workspace}
    end

    test "un admin ve lo suyo, no el goal privado de otro usuario", %{
      conn: conn,
      workspace: workspace,
      reader: reader,
      admin: admin
    } do
      {:ok, _} = create_goal!(workspace, reader, "Reader private goal", "private")
      {:ok, _} = create_goal!(workspace, admin, "Admin private goal", "private")

      {:ok, reader_view, _} = live(login(conn, reader), ~p"/")
      {:ok, admin_view, _} = live(login(conn, admin), ~p"/")

      # Cada uno cuenta SU goal privado — y ninguno cuenta el del otro.
      assert has_element?(reader_view, "#home-status-goals-total", "1")
      assert has_element?(admin_view, "#home-status-goals-total", "1")
      refute has_element?(admin_view, "#home-status-goals-total", "2")
    end

    test "lo PÚBLICO de otro sí se cuenta: el contador no es «sólo lo mío»", %{
      conn: conn,
      workspace: workspace,
      reader: reader,
      admin: admin
    } do
      {:ok, _} = create_goal!(workspace, reader, "Reader private goal", "private")
      {:ok, _} = create_goal!(workspace, admin, "Admin public goal", "public")

      {:ok, reader_view, _} = live(login(conn, reader), ~p"/")
      {:ok, admin_view, _} = live(login(conn, admin), ~p"/")

      assert has_element?(reader_view, "#home-status-goals-total", "2")
      assert has_element?(admin_view, "#home-status-goals-total", "1")
    end

    test "un goal ajeno privado no asoma ni por un chip de estado", %{
      conn: conn,
      workspace: workspace,
      reader: reader,
      admin: admin
    } do
      # El admin tiene un goal en `on_hold`; el lector no tiene ninguno.
      {:ok, _} = create_goal!(workspace, admin, "Admin on hold", "private", "on_hold")

      {:ok, reader_view, _} = live(login(conn, reader), ~p"/")

      refute has_element?(reader_view, "#home-status-goals-on_hold")
      assert has_element?(reader_view, "#home-status-goals-total", "0")
      refute has_element?(reader_view, "#home-status-goals-active")
    end

    test "planes activos con su progreso, memoria y páginas, todo scopeado", %{
      conn: conn,
      workspace: workspace,
      reader: reader,
      admin: admin
    } do
      # Plan propio del lector: 1 de 2 pasos hechos.
      {:ok, plan} = create_plan!(workspace, reader, "Reader plan", "active")

      # Plan ajeno y memoria ajena: no entran en los números del lector.
      {:ok, _} = create_plan!(workspace, admin, "Admin plan", "active")
      {:ok, _} = create_memory!(workspace, admin, "un hecho privado del admin")

      # Una página propia y una ajena privada.
      {:ok, _} = create_page!(workspace, reader, "Reader page", "private")
      {:ok, _} = create_page!(workspace, admin, "Admin page", "private")

      {:ok, view, _} = live(login(conn, reader), ~p"/")

      assert has_element?(view, "#home-status-plan-#{plan.id}", "Reader plan")
      assert has_element?(view, "#home-status-plan-#{plan.id}", "1/2")
      assert has_element?(view, "#home-status-plans-total", "1")
      assert has_element?(view, "#home-status-memory-total", "0")
      assert has_element?(view, "#home-status-pages-total", "1")
    end

    test "una sesión sin fila en `users` no dibuja el estado", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, "status-ghost-user-does-not-exist")

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#home-status")
    end
  end

  defp create_user!(unique, instance_role \\ nil) do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        email: "status-#{unique}@dran.test",
        api_token: "status-#{unique}"
      })
      |> Repo.insert()

    if instance_role do
      user |> Ecto.Changeset.change(instance_role: instance_role) |> Repo.update!()
    else
      user
    end
  end

  defp login(conn, %User{} = user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, user.is_owner)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  defp create_goal!(_workspace, owner, title, visibility, status \\ "active") do
    Goals.create_goal(%{
      "title" => title,
      "status" => status,
      "visibility" => visibility,
      "owner_user_id" => owner.id
    })
  end

  defp create_plan!(_workspace, owner, title, status, visibility \\ "private") do
    Plans.create_plan(%{
      "title" => title,
      "status" => status,
      "visibility" => visibility,
      "owner_user_id" => owner.id,
      "checklist" => [
        %{"text" => "hecho", "done" => true},
        %{"text" => "pendiente", "done" => false}
      ]
    })
  end

  defp create_memory!(workspace, owner, content) do
    %Memory{}
    |> Memory.changeset(%{
      workspace_id: workspace.id,
      content: content,
      status: "active",
      visibility: "private",
      owner_user_id: owner.id,
      created_by: "status-test"
    })
    |> Repo.insert()
  end

  defp create_page!(workspace, owner, title, visibility) do
    Knowledge.create_page(%{
      workspace_id: workspace.id,
      title: title,
      body: "cuerpo de #{title}",
      page_type: "note",
      visibility: visibility,
      owner_user_id: owner.id
    })
  end

  describe "el grafo dibuja goals y plans (W4)" do
    test "la leyenda incluye goal y plan, con el conteo que trae el payload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      # Las entidades de trabajo entran a la leyenda y al filtro por tipo: su
      # color sale del registro de tipos, no de una tabla por superficie.
      assert has_element?(view, "button[phx-value-type='goal']")
      assert has_element?(view, "button[phx-value-type='plan']")

      # El hook carga el payload por HTTP y avisa al servidor: los números de la
      # leyenda salen del payload (el JS no inventa colores ni conteos).
      render_hook(view, "graph_loaded", %{
        "total_nodes" => 12,
        "total_edges" => 9,
        "type_counts" => %{"goal" => 2, "plan" => 3}
      })

      assert has_element?(view, "button[phx-value-type='goal']", "2")
      assert has_element?(view, "button[phx-value-type='plan']", "3")
    end

    test "un nodo de goal navega a SU superficie, no a la ruta de páginas", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      goal_id = Ecto.UUID.generate()
      render_click(view, "node_click", %{"slug" => goal_id, "type" => "goal"})

      assert_redirect(view, "/goals/#{goal_id}")
    end

    test "un nodo de plan navega a la suya", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      plan_id = Ecto.UUID.generate()
      render_click(view, "node_click", %{"slug" => plan_id, "type" => "plan"})

      assert_redirect(view, "/plans/#{plan_id}")
    end

    test "el tipo de página sigue navegando por su ruta plural", %{conn: conn, page: page} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      render_click(view, "node_click", %{"slug" => page.slug, "type" => "note"})

      assert_redirect(view, "/notes/#{page.slug}")
    end
  end

  describe "authentication" do
    test "GET / redirects to /login without a session" do
      conn = build_conn() |> get(~p"/")
      assert redirected_to(conn) == ~p"/login"
    end

    test "GET /admin/instance redirects to /login without a session" do
      conn = build_conn() |> get(~p"/admin/instance")
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
