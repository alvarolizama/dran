defmodule DranWeb.Router do
  use DranWeb, :router

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: __MODULE__,
    statics: DranWeb.static_paths()

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DranWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug DranWeb.Plugs.Auth, :fetch_context_cookie
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug :require_login
  end

  pipeline :api_auth do
    plug :require_api_token
  end

  pipeline :admin do
    plug :require_admin
  end

  # ── Browser auth plug ──

  defp require_login(conn, _opts) do
    cond do
      Plug.Conn.get_session(conn, "user") ->
        conn

      not Dran.Accounts.any_users?() ->
        conn
        |> Phoenix.Controller.redirect(to: ~p"/setup")
        |> Plug.Conn.halt()

      true ->
        conn
        |> Plug.Conn.put_session(:return_to, conn.request_path)
        |> Phoenix.Controller.redirect(to: ~p"/login")
        |> Plug.Conn.halt()
    end
  end

  # ── Admin auth plug ──

  defp require_admin(conn, _opts) do
    # `is_admin` is cached in the session at login (see DranWeb.Plugs.Auth.login/3),
    # so we don't hit the users table on every admin request. A session without
    # the flag (e.g. an old pre-multi-user session) is treated as full admin.
    cond do
      is_nil(Plug.Conn.get_session(conn, "user")) ->
        conn
        |> Phoenix.Controller.redirect(to: ~p"/login")
        |> Plug.Conn.halt()

      Plug.Conn.get_session(conn, "is_admin") == false ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Admin access required")
        |> Phoenix.Controller.redirect(to: ~p"/")
        |> Plug.Conn.halt()

      true ->
        conn
    end
  end

  # ── API token auth plug ──

  defp require_api_token(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        cond do
          # Legacy admin token (backward compat) — full admin, no user row
          token == Dran.Auth.api_token() ->
            assign(conn, :user, %{is_admin: true, email: "admin", contexts: :all})

          # Per-user token — look up the user and assign it
          match?({:ok, _}, Dran.Accounts.valid_token?(token)) ->
            {:ok, user} = Dran.Accounts.valid_token?(token)
            assign(conn, :user, user)

          # Context-scoped API key — synthetic user with single context
          match?({:ok, _}, Dran.Accounts.valid_api_key?(token)) ->
            {:ok, key} = Dran.Accounts.valid_api_key?(token)

            assign(conn, :user, %{
              is_admin: false,
              email: "api-key:#{key.name}",
              contexts: [key.context]
            })

          true ->
            unauthorized(conn, "invalid token")
        end

      :error ->
        unauthorized(conn, "missing or malformed Authorization header")
    end
  end

  defp extract_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(401, Jason.encode!(%{errors: %{detail: message}}))
    |> Plug.Conn.halt()
  end

  # ── Public routes (login page, session, health) ──

  scope "/", DranWeb do
    pipe_through :browser

    post "/session", SessionController, :create
    delete "/session", SessionController, :delete
    post "/setup", SessionController, :setup
    live "/login", LoginLive, :index
    live "/setup", SetupLive, :index

    # Google OAuth
    get "/auth/google", OAuthController, :request
    get "/auth/google/callback", OAuthController, :callback
  end

  # ── Public health check (no auth) ──

  scope "/", DranWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # ── Admin panel UI (data administration) ──────────────────────────────────

  scope "/panel", DranWeb do
    pipe_through [:browser, :auth]

    live "/", DashboardLive, :index

    # ── LiveView pages (second brain UI) ────────────────────────────────────

    # Knowledge
    live "/notes", NoteLive, :index
    live "/notes/new", PageNewLive, :new
    live "/notes/:slug", NoteLive, :show

    live "/concepts", ConceptLive, :index
    live "/concepts/new", PageNewLive, :new
    live "/concepts/:slug", ConceptLive, :show

    live "/entities", EntityLive, :index
    live "/entities/new", PageNewLive, :new
    live "/entities/:slug", EntityLive, :show

    live "/references", ReferenceLive, :index
    live "/references/new", PageNewLive, :new
    live "/references/:slug", ReferenceLive, :show

    live "/queries", QueryLive, :index
    live "/queries/new", PageNewLive, :new
    live "/queries/:slug", QueryLive, :show

    live "/goals", GoalLive, :index
    live "/goals/new", PageNewLive, :new
    live "/goals/:slug", GoalLive, :show

    live "/kanban", KanbanLive, :index

    live "/projects", ProjectLive, :index
    live "/projects/new", PageNewLive, :new
    live "/projects/:slug", ProjectLive, :show

    live "/plans", PlanLive, :index
    live "/plans/new", PageNewLive, :new
    live "/plans/:slug", PlanLive, :show

    live "/todos", TodoLive, :index
    live "/todos/new", PageNewLive, :new
    live "/todos/:slug", TodoLive, :show

    # System reports (second-citizen pages): detail only — reports are
    # system-created, so there is no index or new form.
    live "/reports/:slug", ReportLive, :show

    # Views
    live "/graph", GraphLive, :index
    live "/graph/:slug", GraphLive, :show

    # JSON endpoint for progressive graph loading (session-authenticated)
    get "/graph-json", GraphJSONController, :show

    live "/activity", ActivityLive, :index

    live "/journey", JourneyLive, :index

    live "/search", SearchLive, :index

    live "/tags/:tag", TagLive, :index

    # Smart Collections (saved live queries)
    live "/collections", SmartCollectionLive, :index
    live "/collections/new", SmartCollectionLive, :new
    live "/collections/:slug", SmartCollectionLive, :show

    # Docs
    live "/docs", DocsLive, :index

    # Context switching
    post "/context", SessionController, :switch_context
  end

  # ── Admin-only web UI ──

  scope "/panel", DranWeb do
    pipe_through [:browser, :auth, :admin]

    live "/settings", SettingsLive, :index
    live "/settings/:tab", SettingsLive, :index
  end

  # ── REST API (token-protected) ─────────────────────────────────────────────

  scope "/api", DranWeb.API do
    pipe_through [:api, :api_auth]

    # Contexts
    get "/contexts", ContextController, :index
    post "/contexts", ContextController, :create
    get "/contexts/:slug", ContextController, :show
    put "/contexts/:slug", ContextController, :update
    delete "/contexts/:slug", ContextController, :delete
    get "/contexts/:slug/export", ExportController, :show

    # Full export (by context id)
    get "/export/:context/full", ExportController, :full

    # Pages
    get "/pages", PageController, :index
    post "/pages", PageController, :create
    get "/pages/:slug", PageController, :show
    put "/pages/:slug", PageController, :update
    delete "/pages/:slug", PageController, :delete
    get "/pages/:slug/links", PageController, :links
    get "/pages/:slug/graph", PageController, :graph

    # Relations
    post "/relations", RelationController, :create
    delete "/relations/:id", RelationController, :delete

    # Search
    get "/search", SearchController, :search
    get "/search/fuzzy", SearchController, :fuzzy
    get "/search/semantic", SearchController, :semantic

    # Goals
    get "/goals", GoalController, :index
    get "/goals/:slug", GoalController, :show

    # Todos
    get "/todos", TodoController, :index
    post "/todos", TodoController, :create
    put "/todos/:id", TodoController, :update

    # Quality / maintenance
    get "/lint", LintController, :lint

    # Wiki index + graph + log
    get "/index", IndexController, :index
    get "/graph", GraphController, :graph
    get "/log", LogController, :index
  end

  # ── MCP Streamable HTTP endpoint (self-authenticating) ────────────────────
  #
  # The MCP controller performs its own dual auth — legacy DRAN_API_TOKEN
  # (admin) OR each user's per-user api_token — and then enforces per-user
  # context access. It must therefore NOT go through the :api_auth pipeline,
  # which only validates the legacy admin token and would reject user tokens.
  scope "/api", DranWeb.API do
    pipe_through [:api]

    post "/mcp", MCPController, :handle_post
    get "/mcp", MCPController, :handle_get
    delete "/mcp", MCPController, :handle_delete
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dran, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DranWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # ── Wiki (read-only knowledge browser) at the ROOT ─────────────────────────
  #
  # The wiki is the app's home — the first thing a logged-in user sees.
  # This scope MUST stay last: `/:context_slug` is a wildcard and would swallow
  # any static route defined after it (e.g. /dev/dashboard). Static segments
  # (/login, /panel, /api, /health, /dev…) win because they are defined above.
  # Consequently, context slugs named like a reserved segment (panel, api,
  # login, setup, session, auth, health, context, dev) are unreachable by URL.
  scope "/", DranWeb do
    pipe_through [:browser, :auth]

    live "/", WikiLive, :index
    live "/:context_slug", WikiLive, :context_home
    live "/:context_slug/type/:page_type", WikiLive, :type_list
    live "/:context_slug/type/:page_type/:slug", WikiLive, :page_show
    live "/:context_slug/collection/:slug", WikiLive, :collection
    live "/:context_slug/graph", WikiLive, :graph
  end
end
