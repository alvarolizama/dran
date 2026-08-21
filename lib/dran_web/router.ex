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
    plug :require_instance_owner
  end

  pipeline :admin_or_editor do
    plug :require_workspace_role
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

  # ── Instance owner auth plug ──

  defp require_instance_owner(conn, _opts) do
    # `is_owner` is cached in the session at login (see DranWeb.Plugs.Auth.login/3),
    # so we don't hit the users table on every request. A session without
    # the flag (e.g. an old pre-multi-user session) is NOT treated as owner.
    cond do
      is_nil(Plug.Conn.get_session(conn, "user")) ->
        conn
        |> Phoenix.Controller.redirect(to: ~p"/login")
        |> Plug.Conn.halt()

      Plug.Conn.get_session(conn, "is_owner") == false ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Instance owner access required")
        |> Phoenix.Controller.redirect(to: ~p"/")
        |> Plug.Conn.halt()

      true ->
        conn
    end
  end

  # ── Workspace role auth plug ──
  # Grants access if the user is the instance owner OR has at least one
  # workspace membership with a role in ["owner", "admin", "editor"].
  defp require_workspace_role(conn, _opts) do
    cond do
      is_nil(Plug.Conn.get_session(conn, "user")) ->
        conn
        |> Phoenix.Controller.redirect(to: ~p"/login")
        |> Plug.Conn.halt()

      Plug.Conn.get_session(conn, "is_owner") == true ->
        conn

      true ->
        user_email = Plug.Conn.get_session(conn, "user")
        user = user_email && Dran.Accounts.get_user_by_email(user_email)

        has_role? =
          case user do
            # No DB row: pre-multi-user session, treat as owner (matches the
            # legacy require_admin behavior of nil -> admin).
            nil ->
              true

            # Instance owner has full access to every workspace.
            %{is_owner: true} ->
              true

            user ->
              Dran.Accounts.list_user_workspaces(user)
              |> Enum.any?(fn ws -> Map.get(ws, :role) in ~w(owner admin editor) end)
          end

        if has_role? do
          conn
        else
          conn
          |> Phoenix.Controller.put_flash(:error, "Insufficient permissions")
          |> Phoenix.Controller.redirect(to: ~p"/")
          |> Plug.Conn.halt()
        end
    end
  end

  # ── API token auth plug ──

  defp require_api_token(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        cond do
          # Legacy admin token (backward compat) — full owner, no user row
          token == Dran.Auth.api_token() ->
            assign(conn, :user, %{is_owner: true, email: "admin", contexts: :all})

          # Per-user token — look up the user and assign it
          match?({:ok, _}, Dran.Accounts.valid_token?(token)) ->
            {:ok, user} = Dran.Accounts.valid_token?(token)
            assign(conn, :user, user)

          # Context-scoped API key — synthetic user with multi-workspace access
          match?({:ok, _}, Dran.Accounts.valid_api_key?(token)) ->
            {:ok, key} = Dran.Accounts.valid_api_key?(token)

            workspaces =
              key.api_key_workspaces
              |> Enum.map(& &1.workspace)

            access_levels =
              key.api_key_workspaces
              |> Enum.into(%{}, fn akw -> {akw.workspace_id, akw.access_level} end)

            assign(conn, :user, %{
              role: "viewer",
              email: "api-key:***",
              key_name: key.name,
              workspaces: workspaces,
              access_levels: access_levels,
              created_by_user_id: key.created_by_user_id
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

  # ── API write-access plug (SEC-002) ──

  defp require_write_access(conn, _opts) do
    user = conn.assigns[:user]

    # Check per-workspace access_level for API keys
    if user && Map.has_key?(user, :access_levels) do
      # API key user - check if they have write access to the requested workspace
      workspace_id = get_requested_workspace_id(conn)
      access_level = Map.get(user.access_levels, workspace_id)

      if access_level == "write" do
        conn
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            errors: %{detail: "API key does not have write access to this workspace"}
          })
        )
        |> Plug.Conn.halt()
      end
    else
      # Normal user or admin - always pass
      conn
    end
  end

  defp get_requested_workspace_id(conn) do
    # Extract workspace_id from params or path
    cond do
      conn.params["workspace_id"] -> conn.params["workspace_id"]
      # slug lookup would need extra query
      conn.params["workspace"] -> conn.params["workspace"]
      true -> nil
    end
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

  # ── Global routes (instance-level, no workspace) ──────────────────────────

  scope "/", DranWeb do
    pipe_through [:browser, :auth, :admin_or_editor]

    # Dashboard — overview of the entire instance + all workspaces
    live "/", DashboardLive, :index

    # Docs (global, not workspace-scoped)
    live "/docs", DocsLive, :index

    # Workspace switching
    post "/workspace", SessionController, :switch_workspace
  end

  # ── Settings (instance-level, admin-only) ────────────────────────────────

  scope "/settings", DranWeb do
    pipe_through [:browser, :auth, :admin]

    live "/", SettingsLive, :index
    live "/:tab", SettingsLive, :index
  end

  # ── REST API (token-protected) ─────────────────────────────────────────────

  scope "/api", DranWeb.API do
    pipe_through [:api, :api_auth]

    # Contexts (read + export)
    get "/workspaces", WorkspaceController, :index
    get "/workspaces/:slug", WorkspaceController, :show
    get "/workspaces/:slug/export", ExportController, :show

    # Full export (by context id)
    get "/export/:workspace/full", ExportController, :full

    # Pages (read + graph)
    get "/pages", PageController, :index
    get "/pages/:slug", PageController, :show
    get "/pages/:slug/links", PageController, :links
    get "/pages/:slug/graph", PageController, :graph

    # Search (read-only)
    get "/search", SearchController, :search
    get "/search/fuzzy", SearchController, :fuzzy
    get "/search/semantic", SearchController, :semantic

    # Goals (read-only)
    get "/goals", GoalController, :index
    get "/goals/:slug", GoalController, :show

    # Todos (read)
    get "/todos", TodoController, :index

    # Quality / maintenance (read-only)
    get "/lint", LintController, :lint

    # Home index + graph + log (read-only)
    get "/index", IndexController, :index
    get "/graph", GraphController, :graph
    get "/log", LogController, :index
  end

  # ── REST API — write routes (requires write_access on API keys) ────────────

  scope "/api", DranWeb.API do
    pipe_through [:api, :api_auth, :require_write_access]

    # Contexts (write)
    post "/workspaces", WorkspaceController, :create
    put "/workspaces/:slug", WorkspaceController, :update
    delete "/workspaces/:slug", WorkspaceController, :delete

    # Pages (write)
    post "/pages", PageController, :create
    put "/pages/:slug", PageController, :update
    delete "/pages/:slug", PageController, :delete

    # Relations (write)
    post "/relations", RelationController, :create
    delete "/relations/:id", RelationController, :delete

    # Todos (write)
    post "/todos", TodoController, :create
    put "/todos/:id", TodoController, :update
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

      live_dashboard "/", metrics: DranWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # ── Workspace-scoped routes ────────────────────────────────────────────────
  #
  # Everything below /:workspace_slug is workspace-scoped. This scope MUST
  # stay last: /:workspace_slug is a wildcard and would swallow any static
  # route defined after it. Reserved segments (settings, api, dev, login,
  # session, auth, health, docs) are unreachable as workspace slugs because
  # they are defined above.
  scope "/", DranWeb do
    pipe_through [:browser, :auth, :admin_or_editor]

    # Workspace home
    live "/:workspace_slug", HomeLive, :workspace_home

    # First-class entities (their own schemas, not page types) — MUST be
    # defined BEFORE the generic /:workspace_slug/:type route, otherwise
    # /:workspace_slug/:type would swallow /:workspace_slug/goals etc.
    live "/:workspace_slug/goals", GoalLive, :index
    live "/:workspace_slug/goals/new", GoalLive, :new
    live "/:workspace_slug/goals/:slug", GoalLive, :show

    live "/:workspace_slug/collections", SmartCollectionLive, :index
    live "/:workspace_slug/collections/new", SmartCollectionLive, :new
    live "/:workspace_slug/collections/:slug", SmartCollectionLive, :show

    live "/:workspace_slug/communities", CommunityLive, :index
    live "/:workspace_slug/communities/:id", CommunityLive, :show

    live "/:workspace_slug/reports/:slug", ReportLive, :show

    # Views — also before the generic /:type route
    live "/:workspace_slug/search", SearchLive, :index
    live "/:workspace_slug/activity", ActivityLive, :index
    live "/:workspace_slug/journey", JourneyLive, :index
    live "/:workspace_slug/graph", HomeLive, :graph
    get "/:workspace_slug/graph/json", HomeGraphController, :show
    live "/:workspace_slug/kanban", HomeLive, :kanban
    live "/:workspace_slug/collection/:slug", HomeLive, :collection
    live "/:workspace_slug/letter/:letter", HomeLive, :letter

    # Generic page type routes — PagesLive handles note/concept/entity/reference.
    # MUST be defined LAST so first-class entity routes above win.
    live "/:workspace_slug/:type", PagesLive, :index
    live "/:workspace_slug/:type/new", PagesLive, :new
    live "/:workspace_slug/:type/:slug", PagesLive, :show
  end
end
