defmodule DranWeb.DisabledTypes do
  @moduledoc """
  Helper for filtering UI elements based on a context's `disabled_page_types`.

  When a page type is disabled (e.g. "goals"), tabs and filters that reference
  that type should be hidden across Goal/Plan/Project/Kanban/Dashboard views.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: DranWeb.Router,
    statics: DranWeb.static_paths()

  alias Dran.Workspace

  @doc """
  Given a context and a page_type string, returns `true` if the type is
  enabled (not in disabled_page_types). Convenience wrapper around
  `Brain.page_type_enabled?/2` for use in templates without aliasing Brain.
  """
  def type_enabled?(%Workspace{} = context, page_type) do
    Dran.Brain.page_type_enabled?(context, page_type)
  end

  @doc """
  Given a socket with `:workspace` in assigns and a `page_type` string,
  returns `{:cont, socket}` if the type is enabled, or
  `{:halt, {:push_navigate, ~p"/"}}` if disabled — use in `handle_params`
  to block direct URL access to disabled page types.
  """
  def guard_page_type(socket, page_type) do
    context = socket.assigns[:workspace]

    if context && Dran.Brain.page_type_enabled?(context, page_type) do
      {:cont, socket}
    else
      {:halt, {:push_navigate, ~p"/"}}
    end
  end

  @doc """
  on_mount hook that blocks access to disabled page types.

  Receives the page_type string as the first arg (on_mount {Module, "note"}).
  Resolves the context from the session itself (before mount runs) and
  redirects to the dashboard if the page type is disabled.
  """
  def on_mount(page_type, _params, session, socket) when is_binary(page_type) do
    workspace_slug = session["workspace_slug"]
    context = workspace_slug && Dran.Brain.get_workspace_by_slug(workspace_slug)

    if context do
      if Dran.Brain.page_type_enabled?(context, page_type) do
        {:cont, socket}
      else
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
      end
    else
      {:cont, socket}
    end
  end

  def on_mount(_arg, _params, _session, socket), do: {:cont, socket}
end
