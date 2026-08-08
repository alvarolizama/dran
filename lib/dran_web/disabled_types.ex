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

  alias Dran.Brain.Context

  # Maps tab keys (used in Goal/Plan/Project detail views) to page types.
  @tab_key_page_types %{
    "todos" => "todo",
    "goals" => "goal",
    "plans" => "plan",
    "projects" => "project"
  }

  @doc """
  Given a list of `{tab_key, label}` tuples and a context, returns only the
  tabs whose page type is NOT in the context's disabled_page_types.

  The "graph" tab is never filtered out.
  """
  def visible_tabs(tabs, %Context{} = context) do
    disabled = context.disabled_page_types || []

    Enum.reject(tabs, fn {key, _label} ->
      page_type = Map.get(@tab_key_page_types, key)
      page_type && page_type in disabled
    end)
  end

  @doc """
  True if the given tab key's page type is enabled for the context.
  """
  def tab_enabled?(key, %Context{} = context) do
    page_type = Map.get(@tab_key_page_types, key)
    is_nil(page_type) or page_type not in (context.disabled_page_types || [])
  end

  @doc """
  Given a context and a page_type string, returns `true` if the type is
  enabled (not in disabled_page_types). Convenience wrapper around
  `Brain.page_type_enabled?/2` for use in templates without aliasing Brain.
  """
  def type_enabled?(%Context{} = context, page_type) do
    Dran.Brain.page_type_enabled?(context, page_type)
  end

  @doc """
  Given a socket with `:context` in assigns and a `page_type` string,
  returns `{:cont, socket}` if the type is enabled, or
  `{:halt, {:redirect, %{to: "/"}}}` if disabled — use in `handle_params`
  to block direct URL access to disabled page types.
  """
  def guard_page_type(socket, page_type) do
    context = socket.assigns[:context]

    if context && Dran.Brain.page_type_enabled?(context, page_type) do
      {:cont, socket}
    else
      {:halt, {:push_navigate, ~p"/"}}
    end
  end

  @doc """
  on_mount hook that blocks access to disabled page types.

  Reads `page_type` from the socket assigns (set by the LiveView's mount)
  or from the module attribute `@page_type`. Redirects to the dashboard
  if the type is disabled in the current context.
  """
  def on_mount(:guard_disabled_type, _params, _session, socket) do
    context = socket.assigns[:context]
    page_type = socket.assigns[:page_type]

    if context && page_type do
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
