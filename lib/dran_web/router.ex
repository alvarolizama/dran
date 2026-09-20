defmodule DranWeb.Router do
  use DranWeb, :router

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: __MODULE__,
    statics: DranWeb.static_paths()

  pipeline :browser do
    plug :accepts, ["html"]
    # Rewrite conn.remote_ip from x-forwarded-for BEFORE any IP-keyed control
    # runs (the login throttle). Without it, every request behind the reverse
    # proxy shares the proxy's address. See DranWeb.Plugs.ClientIp.
    plug DranWeb.Plugs.ClientIp
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DranWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Pin the request language for Gettext (user preference → Accept-Language →
    # English). LiveViews re-pin it in their own process, see the plug docs.
    plug DranWeb.Plugs.Locale
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

  # Row-level read authorization for the REST read surface. Exempts the
  # workspace *listing* (no single workspace to authorize — the controller
  # scopes it to the identity) and /agent/config (key-scoped by construction).
  pipeline :api_read_access do
    plug :require_read_access, exempt_index: ["workspaces", "agent"]
  end

  pipeline :admin do
    plug :require_instance_owner
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

  # ── API token auth plug ──

  defp require_api_token(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        cond do
          # Legacy admin token (backward compat) — full owner, no user row
          Plug.Crypto.secure_compare(token, Dran.Auth.api_token() || "") ->
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
              email: "api-key:#{key.id}",
              key_name: key.name,
              # Agent identity DERIVED FROM THE KEY (W3): a key is its own
              # agent — no actor row is created for it. Exposed as `:actor`
              # (id = key id, name = key name) so consumers written before the
              # change (e.g. /api/agent/config) keep working; the ownership
              # clauses of ContentVisibility are served by `:owner_user_id`
              # below, not by this map.
              actor: %{id: key.id, name: key.name, display_name: nil},
              workspaces: workspaces,
              access_levels: access_levels,
              # Attribution, resolved in this SINGLE point (P13/M7):
              # created_by = X-Hermes-Agent header, else the key name;
              # owner_user_id = api_keys.created_by_user_id.
              agent_name: Dran.Auth.agent_name_from_headers(conn.req_headers),
              created_by_user_id: key.created_by_user_id,
              owner_user_id: key.created_by_user_id
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

      if DranWeb.ResourceAuthorization.authorize(user, :write, workspace_id) == :ok do
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
      # Other identity shapes (per-user tokens) — authorize via the shared
      # matrix instead of passing through. Fails closed when the request
      # names no resolvable workspace.
      if DranWeb.ResourceAuthorization.authorize(user, :write, get_requested_workspace_id(conn)) ==
           :ok do
        conn
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            errors: %{detail: "Token does not have write access to this workspace"}
          })
        )
        |> Plug.Conn.halt()
      end
    end
  end

  # ── API read-access plug (SEC: row-level read authorization) ──
  #
  # The read pipeline authenticates the identity but the controllers resolve
  # workspaces by slug themselves — without this plug any valid key could
  # read any workspace (IDOR). Authorize against the same matrix the write
  # plug uses, failing closed when the request names no resolvable workspace.

  defp require_read_access(conn, opts) do
    user = conn.assigns[:user]

    exempt =
      case conn.path_info do
        ["api", section] -> Enum.any?(opts[:exempt_index] || [], &(&1 == section))
        _ -> false
      end

    cond do
      exempt ->
        conn

      DranWeb.ResourceAuthorization.authorize(user, :read, get_requested_workspace_id(conn)) ==
          :ok ->
        conn

      true ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            errors: %{detail: "API key does not have read access to this workspace"}
          })
        )
        |> Plug.Conn.halt()
    end
  end

  defp get_requested_workspace_id(_conn) do
    # W5: the instance IS the workspace — there is exactly one container and
    # no request-side id to resolve.
    case Dran.Auth.instance_workspace() do
      %{id: id} -> id
      nil -> nil
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

  # ── Global routes (instance-level, single workspace) ─────────────────────
  # (No routes: the workspace home below serves "/". Kept as a placeholder
  # for future instance-level routes.)

  # ── Settings: API keys (per-user, any logged-in user) ──────────────────────
  #
  # API keys are personal: every user manages their own keys. Defined BEFORE
  # the admin scope so the static segment wins over the admin-only wildcard.

  scope "/settings", DranWeb do
    pipe_through [:browser, :auth]

    live "/account", SettingsLive, :account
    live "/api-keys", SettingsLive, :api_keys

    # Instance settings (page types, features, tuning) — instance admins
    # (owner ∪ instance_role admin/owner), the old workspace_admin guard.
    live "/instance", WorkspaceSettingsLive, :index
  end

  # ── Admin (instance-level, owner-only) ────────────────────────────────────
  #
  # Administration is instance policy (F3): users, workspaces, models, system
  # info, and global jobs. Defined BEFORE the /:workspace_slug wildcard so
  # 'admin' stays a reserved segment.

  scope "/admin", DranWeb do
    pipe_through [:browser, :auth, :admin]

    # Impersonation (F6) — owner-only, defense-in-depth in the controller.
    post "/impersonate/:id", ImpersonationController, :create
    delete "/impersonate", ImpersonationController, :delete

    # live_session wraps the privileged LiveViews with an on_mount twin of the
    # :admin pipeline: the plug runs on the HTTP request only, so without this
    # the guard would not re-run when the LiveView mounts over the socket.
    live_session :admin, on_mount: {DranWeb.LiveAuth, :require_admin} do
      live "/", AdminLive, :index
      live "/users", AdminUsersLive, :index
      live "/groups", AdminGroupsLive, :index
      live "/models", AdminModelsLive, :index
      live "/system", AdminSystemLive, :index
      live "/jobs", AdminJobsLive, :index
    end
  end

  # ── REST API (token-protected) ─────────────────────────────────────────────

  scope "/api", DranWeb.API do
    # Agent self-description — authenticated only: the payload is scoped to
    # the key itself (returns ONLY the workspaces the key reaches), so there
    # is no workspace to authorize against.
    pipe_through [:api, :api_auth]

    get "/agent/config", AgentConfigController, :show
  end

  scope "/api", DranWeb.API do
    pipe_through [:api, :api_auth, :api_read_access]

    # W5: flat instance routes. The legacy /workspaces/:slug/* paths keep
    # answering (any segment resolves the instance) so old plugin builds
    # survive an upgrade.
    get "/instance", WorkspaceController, :index
    get "/workspaces", WorkspaceController, :index
    get "/workspaces/:slug", WorkspaceController, :show
    get "/workspaces/:slug/page-types", PageTypeController, :index
    get "/workspaces/:slug/export", ExportController, :show

    # Full export (by context id)
    get "/export/:workspace/full", ExportController, :full

    # Pages (read + graph)
    get "/knowledge-pages", PageController, :index
    get "/knowledge-pages/:slug", PageController, :show
    get "/knowledge-pages/:slug/links", PageController, :links
    get "/knowledge-pages/:slug/graph", PageController, :graph

    # Search (read-only)
    get "/search", SearchController, :search
    get "/search/fuzzy", SearchController, :fuzzy
    get "/search/semantic", SearchController, :semantic

    # Quality / maintenance (read-only)
    get "/lint", LintController, :lint

    # Home index + graph + log (read-only)
    get "/index", IndexController, :index
    get "/graph", GraphController, :graph
    get "/log", LogController, :index

    # Shared multi-agent memory (read)
    get "/memory", MemoryController, :index
    get "/memory/search", MemoryController, :search

    # Worker sessions (read: poll a running session by id)
    get "/workers/:id", WorkerController, :show
  end

  # ── REST API — write routes (requires write_access on API keys) ────────────

  scope "/api", DranWeb.API do
    pipe_through [:api, :api_auth, :require_write_access]

    # Contexts (write)
    post "/workspaces", WorkspaceController, :create
    put "/workspaces/:slug", WorkspaceController, :update
    delete "/workspaces/:slug", WorkspaceController, :delete

    # Pages (write)
    post "/knowledge-pages", PageController, :create
    put "/knowledge-pages/:slug", PageController, :update
    delete "/knowledge-pages/:slug", PageController, :delete
    post "/knowledge-pages/:slug/rename", PageController, :rename
    post "/knowledge-pages/:slug/reaugment", PageController, :reaugment

    # Cluster summaries (write: regenerates stored summaries)
    post "/cluster-summaries", PageController, :cluster_summaries

    # Relations (write)
    post "/relations", RelationController, :create
    delete "/relations", RelationController, :delete_by_slugs
    delete "/relations/:id", RelationController, :delete

    # Workers (write: starting a worker writes pages)
    post "/workers", WorkerController, :create
  end

  # ── REST API — memory write routes (requires write_access on API keys) ─────
  # Agents store facts, rate them, ingest transcripts and soft-delete via the
  # same write-scoped gate as pages/relations (DranWeb.API.MemoryController).
  scope "/api/memory", DranWeb.API do
    pipe_through [:api, :api_auth, :require_write_access]

    post "/", MemoryController, :create
    patch "/:id", MemoryController, :update
    post "/feedback", MemoryController, :feedback
    post "/ingest", MemoryController, :ingest
    delete "/:id", MemoryController, :delete
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

  # ── Instance routes (single-workspace model, W1) ─────────────────────────
  #
  # The instance IS the workspace: no /:workspace_slug prefix, no per-slug
  # access plugs. Old URLs redirect 301 to their flat equivalent (D2) so
  # bookmarks, browser history and plugin-built links survive.
  scope "/", DranWeb do
    pipe_through [:browser, :auth]

    # Workspace home
    live "/", HomeLive, :workspace_home

    # First-class entities (their own schemas, not page types) — MUST be
    # defined BEFORE the generic /:type route, otherwise /:type would
    # swallow them.
    live "/collections", SmartCollectionLive, :index
    live "/collections/new", SmartCollectionLive, :new
    live "/collections/:slug", SmartCollectionLive, :show

    live "/clusters", ClusterLive, :index
    live "/clusters/:id", ClusterLive, :show

    live "/reports/:slug", ReportLive, :show

    # Views — also before the generic /:type route
    live "/search", SearchLive, :index
    live "/activity", ActivityLive, :index
    live "/journey", JourneyLive, :index
    live "/graph", HomeLive, :graph
    get "/graph/json", HomeGraphController, :show

    # Shared multi-agent memory (first-class, own table — not page types).
    live "/memory", MemoryLive, :index

    live "/collection/:slug", HomeLive, :collection
    live "/letter/:letter", HomeLive, :letter

    # Generic page type routes — PagesLive handles note/concept/entity/reference
    # and the instance's custom types. MUST be defined LAST so first-class
    # entity routes above win.
    live "/:type", PagesLive, :index
    live "/:type/:slug", PagesLive, :show
  end

  # ── Legacy /:workspace_slug URLs → 301 to the flat routes (D2) ───────────
  # Single-segment and 2-segment GETs are shadowed by `live /:type(/:slug)`
  # above — PagesLive performs that hop (unknown type → flat redirect). These
  # routes only catch what the live routes cannot: 3+ segment paths.
  scope "/", DranWeb do
    pipe_through [:browser, :auth]

    get "/:workspace_slug/graph/json", RedirectController, :graph_json
    get "/:workspace_slug/*rest", RedirectController, :rest
  end
end
