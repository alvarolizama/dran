defmodule DranWeb.Plugs.Auth do
  @moduledoc """
  Session helpers for authentication.

  The actual plug pipelines are defined in `DranWeb.Router` as function plugs.
  This module provides helpers for controllers and LiveViews to manage the
  session, context selection, and extracting auth data from LiveView sessions.

  ## Single-workspace model (W1)

  The instance IS one workspace: the active workspace is always the instance
  workspace (`Dran.Knowledge.instance_workspace/0`), resolved from the URL
  or the session slug only to keep old links landing somewhere sane. The
  `dran_last_workspace` cookie and workspace switching died with the
  multi-workspace router.
  """

  import Plug.Conn

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: DranWeb.Router,
    statics: DranWeb.static_paths()

  alias Dran.Auth

  @session_key :user
  @owner_key :is_owner
  @workspace_key :workspace_slug
  @impersonator_key :impersonator

  # ── Plug callbacks (for use in router pipelines) ──

  @doc """
  Plug init — stores the function name to call.
  """
  def init(opts), do: opts

  @doc """
  Plug call — dispatches to the named function.
  """
  def call(conn, _opts), do: conn

  # ── Session management (for controllers) ──

  @doc """
  Opens a session for `username`.

  Single-workspace model: the landing workspace is always the instance
  workspace. The `workspace_slug` param stays for caller compatibility.
  """
  def login(conn, username, workspace_slug \\ nil) do
    # Cache `is_owner` in the session so router pipelines don't hit the DB on
    # every request. SEC-002: fail closed — a session user with no row in the
    # users table is NOT owner (previously nil -> true, which escalated deleted
    # users to full admin).
    user = Dran.Accounts.get_user_by_email(username)

    is_owner =
      case user do
        nil -> false
        %{is_owner: owner?} -> owner?
      end

    # Single workspace: the landing workspace is always the instance
    # workspace. The param stays for caller compatibility.
    workspace_slug = workspace_slug || Dran.Auth.default_workspace_slug()

    conn
    # A fresh login RENEWS the session id: without it a session id fixed before
    # the login (an attacker-supplied cookie) survives the authentication and
    # becomes an authenticated session (fixation). See the family standard,
    # SPEC-auth.md §Hard rules #3.
    |> configure_session(renew: true)
    # A fresh login must always drop any stale impersonation session (F6): the
    # impersonated user logging out and back in, or logging in under another
    # account, must not keep riding on the admin's impersonation.
    |> delete_session(@impersonator_key)
    |> put_session(@session_key, username)
    |> put_session(@owner_key, is_owner)
    |> put_session(@workspace_key, workspace_slug)
  end

  def logout(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(@owner_key)
    |> delete_session(@workspace_key)
    |> delete_session(@impersonator_key)
  end

  # ── Post-login redirect helper ──

  @doc """
  Resolves where to redirect a user after a successful login.

  If there's a `return_to` in the session, honor it. Otherwise send the
  user to `/` — the dashboard (workspace/instance overview). When the
  instance has no workspaces yet, the dashboard shows the empty state with
  the create-workspace action straight from there.
  """
  def resolve_login_redirect(conn) do
    case get_session(conn, :return_to) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        ~p"/"
    end
  end

  def current_user(conn), do: get_session(conn, @session_key)

  # ── LiveView helpers ──

  @doc """
  Assigns auth-related fields to a LiveView socket from the session map.

  The `session` map here is the LiveView connect_info session, which is a
  plain map (not a `Plug.Conn`). Cookie restoration for LiveViews is handled
  at the controller/router level: when a request arrives, the browser sends
  the `dran_last_workspace` cookie, and the `fetch_workspace_cookie/2` plug
  merges it into the session before LiveView connects.

  Returns `{socket, context}` where `context` is the loaded Knowledge.Context.
  """
  def assign_to_socket(socket, session, params \\ nil) when is_map(session) do
    %{current_user: current_user} = from_session(session)

    # Per-user scoping: a DB user (created via Dran.Accounts) sees the
    # workspaces they are a member of (their personal one first). Every
    # workspace is private, so there is no public tier to add on top (F2).
    # SEC-002: fail closed — a session user with no row in the users table gets
    # NO workspaces and is NOT owner (previously nil -> {all_workspaces, true},
    # which escalated deleted users to full admin).
    #
    # Loaded BEFORE the workspace: with no slug in the session, where the mount
    # lands depends on the user (their own default, the instance default, or the
    # only workspace they can reach).
    {user, user_workspaces, is_owner} =
      case Dran.Accounts.get_user_by_email(current_user) do
        nil -> {nil, [], false}
        %{is_owner: true} = user -> {user, Dran.Accounts.accessible_workspaces(user), true}
        user -> {user, Dran.Accounts.accessible_workspaces(user), false}
      end

    # The URL wins over the session: a LiveView mounted at
    # /:workspace_slug/... must always show THAT workspace, even when the
    # session still points elsewhere (e.g. login defaulted to "personal").
    # With no session slug either, resolve per-user (the bare instance default
    # would drop a user on a workspace they cannot reach).
    workspace_slug =
      case params do
        %{"workspace_slug" => url_slug} when is_binary(url_slug) and url_slug != "" ->
          url_slug

        _ ->
          session["workspace_slug"] || session_workspace_slug(user)
      end

    context = Dran.Knowledge.get_workspace_by_slug(workspace_slug)
    page_counts = Dran.Knowledge.page_counts_by_workspace()

    # F2: the user's role in the CURRENT workspace (from the session slug).
    # The instance owner is owner everywhere; every other logged-in user uses
    # their workspace membership role (public non-members fall back to
    # "viewer"). A nil user (no DB row) gets nil — fail-closed.
    workspace_role =
      case {user, context} do
        {nil, _} -> nil
        {%{is_owner: true}, _} -> "owner"
        {_, nil} -> nil
        {logged_in, ws} -> Dran.Accounts.user_role_in_workspace(logged_in, ws)
      end

    # Each LiveView runs in its own process, so the request-level locale set by
    # `DranWeb.Plugs.Locale` does not reach it. Pin it here: explicit session
    # override first, then the user's durable preference, then the app default.
    locale =
      DranWeb.Gettext.resolve_locale([
        session["locale"],
        user && user.locale
      ])

    Gettext.put_locale(DranWeb.Gettext, locale)

    socket =
      socket
      |> Phoenix.Component.assign(:user, user)
      |> Phoenix.Component.assign(:current_user, current_user)
      |> Phoenix.Component.assign(:is_owner, is_owner)
      |> Phoenix.Component.assign(:workspace_slug, workspace_slug)
      |> Phoenix.Component.assign(:workspaces, user_workspaces)
      |> Phoenix.Component.assign(:workspace_role, workspace_role)
      |> Phoenix.Component.assign(:page_counts, page_counts)
      |> Phoenix.Component.assign(:current_scope, current_user)
      |> Phoenix.Component.assign(:workspace, context)
      |> Phoenix.Component.assign(:locale, locale)
      |> Phoenix.Component.assign(:impersonator, session["impersonator"])

    {socket, context}
  end

  @doc """
  Extracts user and workspace_slug from a LiveView session map.
  """
  def from_session(session) when is_map(session) do
    %{
      current_user: session["user"],
      workspace_slug: session["workspace_slug"] || Auth.default_workspace_slug()
    }
  end

  # The landing workspace for a mount with no slug in the session: the user's
  # own resolution when they have a row, else the instance default.
  defp session_workspace_slug(%Dran.Accounts.User{} = user),
    do: Dran.Accounts.session_workspace_slug(user)

  defp session_workspace_slug(_user), do: Auth.default_workspace_slug()

  # Owner / created_by resolution lives in Dran.Auth (domain layer, no web deps).
  # See Dran.Auth.resolve_owner/1 and Dran.Auth.resolve_created_by/1.

  # ── URL-based context resolution ──

  @doc """
  Resolves the context from query params, falling back to the socket's
  current context.

  If `params["workspace"]` is present and matches a known context slug,
  returns that context and updates the socket assigns. Otherwise returns
  the socket's existing context.

  ## Usage in LiveView handle_params

      def handle_params(%{"slug" => slug} = params, _url, socket) do
        {socket, context} = Auth.resolve_workspace(socket, params)
        page = Knowledge.get_page_by_slug(slug, context.id)
        ...
      end

  This enables URLs like `/notes/my-slug?context=work` to open a page
  in a specific context regardless of the session's active context.
  """
  def resolve_workspace(socket, params) do
    # Routes deliver the slug under "workspace_slug" (/:workspace_slug/...).
    # "workspace" is kept as a legacy alias (PagesLive used to set it).
    slug =
      params["workspace_slug"] || params["workspace"]

    case slug do
      slug when is_binary(slug) and slug != "" ->
        case Dran.Knowledge.get_workspace_by_slug(slug) do
          nil ->
            {socket, socket.assigns[:workspace]}

          context ->
            socket =
              socket
              |> Phoenix.Component.assign(:workspace, context)
              |> Phoenix.Component.assign(:workspace_slug, slug)

            {socket, context}
        end

      _ ->
        {socket, socket.assigns[:workspace]}
    end
  end
end
