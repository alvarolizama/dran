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
    if Plug.Conn.get_session(conn, "user") do
      conn
    else
      conn
      |> Plug.Conn.put_session(:return_to, conn.request_path)
      |> Phoenix.Controller.redirect(to: ~p"/login")
      |> Plug.Conn.halt()
    end
  end

  # ── Admin auth plug ──

  defp require_admin(conn, _opts) do
    user_email = Plug.Conn.get_session(conn, "user")

    if user_email do
      user = Dran.Accounts.get_user_by_email(user_email)

      if user && user.is_admin do
        conn
      else
        conn
        |> Phoenix.Controller.put_flash(:error, "Admin access required")
        |> Phoenix.Controller.redirect(to: ~p"/")
        |> Plug.Conn.halt()
      end
    else
      conn
      |> Phoenix.Controller.redirect(to: ~p"/login")
      |> Plug.Conn.halt()
    end
  end

  # ── API token auth plug ──

  defp require_api_token(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        if Dran.Auth.valid_token?(token) do
          conn
        else
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
    live "/login", LoginLive, :index

    # Google OAuth
    get "/auth/google", OAuthController, :request
    get "/auth/google/callback", OAuthController, :callback
  end

  # ── Public health check (no auth) ──

  scope "/", DranWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # ── Authenticated web UI ──

  scope "/", DranWeb do
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

    # Outputs
    live "/comparisons", ComparisonLive, :index
    live "/comparisons/new", PageNewLive, :new
    live "/comparisons/:slug", ComparisonLive, :show

    # Views
    live "/graph", GraphLive, :index
    live "/graph/:slug", GraphLive, :show

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

    live "/contexts", ContextLive, :index

    # Context switching
    post "/context", SessionController, :switch_context
  end

  # ── Admin-only web UI ──

  scope "/", DranWeb do
    pipe_through [:browser, :auth, :admin]

    live "/settings", SettingsLive, :index
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

    # MCP Streamable HTTP endpoint
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
end
