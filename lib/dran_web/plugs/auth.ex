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
  @admin_key :is_admin
  @editor_key :is_editor
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
    # Cache `is_admin` in the session so router pipelines don't hit the DB on
    # every request. SEC-002: fail closed — a session user with no row in the
    # users table is NOT admin (previously nil -> true, which escalated deleted
    # users to full admin).
    is_admin =
      case Dran.Accounts.get_user_by_email(username) do
        nil -> false
        %{is_admin: admin?} -> admin?
      end

    is_editor =
      case Dran.Accounts.get_user_by_email(username) do
        nil -> false
        %{is_editor: editor?} -> editor?
      end

    conn
    |> put_session(@session_key, username)
    |> put_session(@admin_key, is_admin)
    |> put_session(@editor_key, is_editor)
    |> put_context(context_slug)
  end

  def logout(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(@admin_key)
    |> delete_session(@editor_key)
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

  # ── Post-login redirect helper ──

  @doc """
  Resolves where to redirect a user after a successful login.

  If there's a `return_to` in the session, honor it. Otherwise, if the user
  is admin or editor AND no wiki-enabled contexts exist, send them straight
  to `/panel` — the wiki would be an empty page anyway. Fall back to `/`
  (the wiki) in all other cases.
  """
  def resolve_login_redirect(conn) do
    case get_session(conn, :return_to) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        is_admin = get_session(conn, "is_admin") == true
        is_editor = get_session(conn, "is_editor") == true

        if (is_admin or is_editor) and Dran.Brain.list_wiki_contexts() == [] do
          ~p"/panel"
        else
          ~p"/"
        end
    end
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
    # assigned contexts. SEC-002: fail closed — a session user with no row in
    # the users table gets NO contexts and is NOT admin (previously nil ->
    # {all_contexts, true}, which escalated deleted users to full admin).
    {accessible_contexts, is_admin, is_editor} =
      case Dran.Accounts.get_user_by_email(current_user) do
        nil -> {[], false, false}
        %{is_admin: true} -> {contexts, true, false}
        %{is_editor: true} = user -> {Dran.Accounts.list_user_contexts(user), false, true}
        user -> {Dran.Accounts.list_user_contexts(user), false, false}
      end

    socket =
      socket
      |> Phoenix.Component.assign(:current_user, current_user)
      |> Phoenix.Component.assign(:is_admin, is_admin)
      |> Phoenix.Component.assign(:is_editor, is_editor)
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

  # Owner / created_by resolution lives in Dran.Auth (domain layer, no web deps).
  # See Dran.Auth.resolve_owner/1 and Dran.Auth.resolve_created_by/1.

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
          # No cookie either — fall back to the user's default context (if
          # their account has one set) before the global default.
          case user_default_context(conn) do
            nil -> conn
            slug -> put_session(conn, @context_key, slug)
          end
      end
    end
  end

  # The logged-in user's configured default context slug, or nil.
  defp user_default_context(conn) do
    case get_session(conn, @session_key) do
      nil ->
        nil

      email ->
        case Dran.Accounts.get_user_by_email(email) do
          %{default_context_slug: slug} when is_binary(slug) and slug != "" -> slug
          _ -> nil
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
