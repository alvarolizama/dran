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
  # scopes it to the identity), /agent/config (authenticated-only by
  # construction) and /groups (W7: the payload is scoped to the reader's own
  # memberships — there is no workspace to authorize against; without the
  # exemption `require_read_access` fails closed and answers 403).
  pipeline :api_read_access do
    plug :require_read_access, exempt_index: ["workspaces", "agent", "groups"]
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

          # Account token — the ONE credential. Resolves to the user, but the
          # identity is a map (not the struct) because the agent identity is
          # resolved here and nowhere else.
          match?({:ok, _}, Dran.Accounts.valid_token?(token)) ->
            {:ok, user} = Dran.Accounts.valid_token?(token)

            agent_name = Dran.Auth.agent_name_from_headers(conn.req_headers)

            assign(conn, :user, %{
              id: user.id,
              email: user.email,
              is_owner: user.is_owner,
              instance_role: user.instance_role,
              # Attribution, resolved in this SINGLE point: created_by = header,
              # else the email; owner_user_id = the credential's owner.
              agent_name: agent_name,
              created_by_user_id: user.id,
              owner_user_id: user.id,
              # The agent IS its owner's credential (no `actors` row).
              actor: %{
                id: "account:#{user.id}",
                name: agent_name || user.email,
                display_name: user.name
              }
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

    # One identity shape at the API surface now: authorize via the shared
    # matrix, failing closed when the request names no resolvable workspace.
    if DranWeb.ResourceAuthorization.authorize(user, :write, get_requested_workspace_id(conn)) ==
         :ok do
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        403,
        Jason.encode!(%{errors: %{detail: "Token does not have write access to this workspace"}})
      )
      |> Plug.Conn.halt()
    end
  end

  # ── API read-access plug (SEC: row-level read authorization) ──
  #
  # The read pipeline authenticates the identity but the controllers resolve
  # workspaces by slug themselves — without this plug any valid token could
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
          Jason.encode!(%{errors: %{detail: "Token does not have read access to this workspace"}})
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

  # ── Settings: account (any logged-in user) ─────────────────────────────────
  #
  # The account page carries the user's ONE credential (users.api_token).
  # Defined BEFORE the admin scope so the static segment wins over the
  # admin-only wildcard.

  scope "/settings", DranWeb do
    pipe_through [:browser, :auth]

    live "/account", SettingsLive, :account

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
    # the calling account (returns the instance it reaches), so there is no
    # workspace to authorize against.
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

    # Groups (read) — W7/P19: los grupos donde el lector es MIEMBRO, el mismo
    # conjunto al que puede apuntar con un `scope` de grupo (W6). El payload
    # está acotado al lector, así que no hay workspace que autorizar.
    get "/groups", GroupController, :index

    # Worker sessions (read: poll a running session by id)
    get "/workers/:id", WorkerController, :show
  end

  # ── REST API — write routes (requires write access) ────────────

  scope "/api", DranWeb.API do
    pipe_through [:api, :api_auth, :require_write_access]

    # Contexts (READ ONLY)
    #
    # W5 (F11/P6): the instance does not admit extra containers through the
    # API. `POST /workspaces` left orphan containers behind; `PUT`/`DELETE`
    # were the same class one step further (`DELETE` removed the ONLY
    # instance). The container set is instance policy, not an agent
    # capability — the operations stay in the admin UI. Reads below.

    # Pages (write)
    #
    # W4a (F31): `:slug` is an OPAQUE id-or-slug segment. The controller casts
    # it as a uuid FIRST and falls back to a slug lookup; a forged binary is a
    # clean 404, never a Postgres uuid-cast crash.
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

  # ── REST API — memory write routes (requires write access) ─────
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

    # El contenedor de trabajo: goals + board. First-class, ANTES de la ruta
    # genérica /:type, que si no los traga. `/tasks/:id` es el board de UN goal
    # (:id es el goal, uuid primero y slug de respaldo); `/tasks` es el board
    # global filtrable por goal.
    live "/goals", GoalLive, :index
    live "/goals/:id", GoalLive, :show
    live "/tasks", TaskBoardLive, :index
    live "/tasks/:id", TaskBoardLive, :show

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
    #
    # W4a (F31): `:slug` is id-or-slug. A uuid is canonical; the slug is a
    # fallback that PageDetail resolves in place (no redirect hop).
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
