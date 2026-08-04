defmodule DranWeb.DisabledTypes do
  @moduledoc """
  Helper for filtering UI elements based on a context's `disabled_page_types`.

  When a page type is disabled (e.g. "goals"), tabs and filters that reference
  that type should be hidden across Goal/Plan/Project/Kanban/Dashboard views.
  """

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
end
