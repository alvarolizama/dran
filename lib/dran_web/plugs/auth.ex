defmodule DranWeb.Plugs.Auth do
  @moduledoc """
  Session helpers for authentication.

  The actual plug pipelines are defined in `DranWeb.Router` as function plugs.
  This module provides helpers for controllers and LiveViews to manage the
  session, context selection, and extracting auth data from LiveView sessions.

  ## Context persistence

  The active context is stored in two places:

  1. **Session** (`:context_slug`) — the source of truth for the current tab.
  2. **Signed cookie** (`dran_last_context`) — persists across browser restarts
     and new tabs. When a LiveView mounts without a `context_slug` in the
     session (e.g. a fresh login or a new tab that hasn't switched yet), the
     cookie is read and the context is restored.

  The cookie is signed via `Plug.Conn.put_resp_cookie/4` with `:signed` using
  the endpoint's signing salt, and verified with `Plug.Conn.fetch_cookies/2`.
  """

  import Plug.Conn

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: DranWeb.Router,
    statics: DranWeb.static_paths()

  alias Dran.Auth

  @session_key :user
  @context_key :context_slug
  @context_cookie "dran_last_context"
  # 30 days in seconds
  @context_cookie_max_age 30 * 24 * 60 * 60

  # ── Plug callbacks (for use in router pipelines) ──

  @doc """
  Plug init — stores the function name to call.
  """
  def init(opts), do: opts

  @doc """
  Plug call — dispatches to the named function.
  Used as `plug DranWeb.Plugs.Auth, :fetch_context_cookie`.
  """
  def call(conn, :fetch_context_cookie), do: fetch_context_cookie(conn, [])
  def call(conn, _opts), do: conn

  # ── Session management (for controllers) ──

  def login(conn, username, context_slug \\ Auth.default_context_slug()) do
    conn
    |> put_session(@session_key, username)
    |> put_context(context_slug)
  end

  def logout(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(@context_key)
    |> delete_resp_cookie(@context_cookie)
  end

  @doc """
  Switches the active context in the session and persists it to a signed
  cookie so it survives browser restarts and new tabs.
  """
  def put_context(conn, context_slug) do
    conn
    |> put_session(@context_key, context_slug)
    |> put_resp_cookie(@context_cookie, context_slug,
      max_age: @context_cookie_max_age,
      sign: true
    )
  end

  def current_user(conn), do: get_session(conn, @session_key)

  def current_context(conn), do: get_session(conn, @context_key) || Auth.default_context_slug()

  # ── LiveView helpers ──

  @doc """
  Assigns auth-related fields to a LiveView socket from the session map.

  The `session` map here is the LiveView connect_info session, which is a
  plain map (not a `Plug.Conn`). Cookie restoration for LiveViews is handled
  at the controller/router level: when a request arrives, the browser sends
  the `dran_last_context` cookie, and the `fetch_context_cookie/2` plug
  merges it into the session before LiveView connects.

  Returns `{socket, context}` where `context` is the loaded Brain.Context.
  """
  def assign_to_socket(socket, session) when is_map(session) do
    %{
      current_user: current_user,
      context_slug: context_slug
    } = from_session(session)

    context = Dran.Brain.get_context_by_slug(context_slug)
    contexts = Dran.Brain.list_contexts()
    page_counts = Dran.Brain.page_counts_by_context()

    # Per-user scoping: a DB user (created via Dran.Accounts) only sees their
    # assigned contexts. A session user with no row in the users table (e.g.
    # created before multi-user auth) is treated as a full admin.
    {accessible_contexts, is_admin} =
      case Dran.Accounts.get_user_by_email(current_user) do
        nil -> {contexts, true}
        %{is_admin: true} -> {contexts, true}
        user -> {Dran.Accounts.list_user_contexts(user), false}
      end

    socket =
      socket
      |> Phoenix.Component.assign(:current_user, current_user)
      |> Phoenix.Component.assign(:is_admin, is_admin)
      |> Phoenix.Component.assign(:context_slug, context_slug)
      |> Phoenix.Component.assign(:contexts, accessible_contexts)
      |> Phoenix.Component.assign(:page_counts, page_counts)
      |> Phoenix.Component.assign(:current_scope, current_user)

    {socket, context}
  end

  @doc """
  Extracts user and context_slug from a LiveView session map.
  """
  def from_session(session) when is_map(session) do
    %{
      current_user: session["user"],
      context_slug: session["context_slug"] || Auth.default_context_slug()
    }
  end

  # ── Cookie-based context restoration plug ──

  @doc """
  Plug that restores the context from the signed `dran_last_context` cookie
  when the session doesn't already carry a `context_slug`.

  This runs in the `:browser` pipeline (or `:auth` pipeline) so that by the
  time a LiveView connects, the session already has the right context.
  """
  def fetch_context_cookie(conn, _opts) do
    if get_session(conn, @context_key) do
      conn
    else
      conn = fetch_cookies(conn, signed: [@context_cookie])

      case conn.cookies[@context_cookie] do
        slug when is_binary(slug) and slug != "" ->
          put_session(conn, @context_key, slug)

        _ ->
          conn
      end
    end
  end

  # ── URL-based context resolution ──

  @doc """
  Resolves the context from query params, falling back to the socket's
  current context.

  If `params["context"]` is present and matches a known context slug,
  returns that context and updates the socket assigns. Otherwise returns
  the socket's existing context.

  ## Usage in LiveView handle_params

      def handle_params(%{"slug" => slug} = params, _url, socket) do
        {socket, context} = Auth.resolve_context(socket, params)
        page = Brain.get_page_by_slug(slug, context.id)
        ...
      end

  This enables URLs like `/notes/my-slug?context=work` to open a page
  in a specific context regardless of the session's active context.
  """
  def resolve_context(socket, params) do
    case params["context"] do
      slug when is_binary(slug) and slug != "" ->
        case Dran.Brain.get_context_by_slug(slug) do
          nil ->
            {socket, socket.assigns[:context]}

          context ->
            socket =
              socket
              |> Phoenix.Component.assign(:context, context)
              |> Phoenix.Component.assign(:context_slug, slug)

            {socket, context}
        end

      _ ->
        {socket, socket.assigns[:context]}
    end
  end
end
