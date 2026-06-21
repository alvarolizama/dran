defmodule DranWeb.Plugs.Auth do
  @moduledoc """
  Session helpers for authentication.

  The actual plug pipelines are defined in `DranWeb.Router` as function plugs.
  This module provides helpers for controllers and LiveViews to manage the
  session, context selection, and extracting auth data from LiveView sessions.
  """

  import Plug.Conn

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: DranWeb.Router,
    statics: DranWeb.static_paths()

  alias Dran.Auth

  @session_key :user
  @context_key :context_slug

  # ── Session management (for controllers) ──

  def login(conn, username, context_slug \\ Auth.default_context_slug()) do
    conn
    |> put_session(@session_key, username)
    |> put_session(@context_key, context_slug)
  end

  def logout(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(@context_key)
  end

  def put_context(conn, context_slug) do
    put_session(conn, @context_key, context_slug)
  end

  def current_user(conn), do: get_session(conn, @session_key)
  def current_context(conn), do: get_session(conn, @context_key) || Auth.default_context_slug()

  # ── LiveView helpers ──

  @doc """
  Assigns auth-related fields to a LiveView socket from the session map.

  Returns `{socket, context}` where `context` is the loaded Brain.Context.
  """
  def assign_to_socket(socket, session) when is_map(session) do
    %{
      current_user: current_user,
      context_slug: context_slug
    } = from_session(session)

    context = Dran.Brain.get_context_by_slug(context_slug)
    contexts = Dran.Brain.list_contexts()

    socket =
      socket
      |> Phoenix.Component.assign(:current_user, current_user)
      |> Phoenix.Component.assign(:context_slug, context_slug)
      |> Phoenix.Component.assign(:contexts, contexts)
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
end
