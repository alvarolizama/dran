defmodule Dran.Brain.PageTypes do
  @moduledoc """
  Canonical page type registry — the single source of truth for the list of
  page types and what each type can do (its *capabilities*).

  ## Capabilities

  | Capability    | Meaning                                                        |
  |---------------|----------------------------------------------------------------|
  | `graph`       | included in the global graph (GraphCache / graph views)        |
  | `journey`     | counted in the Journey timeline (`Dran.Journey`)               |
  | `embeddings`  | gets embeddings + semantic relations (`PageAugmenter`)         |
  | `mcp_create`  | can be created through the `dran_create_page` MCP tool         |

  Most types are full citizens (all `true`). Exceptions:

  - `todo` and `plan` are hidden from the graph by default (they are
    operational, not knowledge) but keep every other capability.
  - `report` is a second-citizen page: system-created reports (jobs, system
    output) that live outside the graph, the journey, embeddings and
    MCP-create. They are still pages: they appear in the activity log
    (brain_log) and have a detail view at `/reports/:slug`.

  `DranWeb.PageTypes` is only UI labels/icons/paths — THIS module decides
  what a type can do. `Dran.Brain.Page.@page_types` derives from `types/0`,
  so adding a type here propagates to changeset validation automatically.
  """

  @capabilities %{
    "note" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "plan" => %{graph: false, journey: true, embeddings: true, mcp_create: true},
    "todo" => %{graph: false, journey: true, embeddings: true, mcp_create: true},
    "goal" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "entity" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "concept" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "reference" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "query" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "project" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "report" => %{graph: false, journey: false, embeddings: false, mcp_create: false}
  }

  # Canonical ordering — preserves the historical `Page.all_types()` order so
  # UI surfaces that iterate the list (e.g. the Settings page-types modal)
  # keep their existing ordering, with the new type appended at the end.
  @types ~w(note plan todo goal entity concept reference query project report)

  @doc "Ordered list of all valid page types."
  def types, do: @types

  @doc "True if pages of this type appear in the global graph."
  def graph?(type), do: capability(type, :graph)

  @doc "True if pages of this type are counted in the Journey timeline."
  def journey?(type), do: capability(type, :journey)

  @doc "True if pages of this type get embeddings and semantic relations."
  def embeddings?(type), do: capability(type, :embeddings)

  @doc "True if pages of this type can be created via the MCP `dran_create_page` tool."
  def mcp_create?(type), do: capability(type, :mcp_create)

  @doc "List of page types excluded from the global graph by default."
  def hidden_from_graph do
    for {type, %{graph: false}} <- @capabilities, do: type
  end

  @doc "List of page types excluded from the Journey timeline."
  def excluded_from_journey do
    for {type, %{journey: false}} <- @capabilities, do: type
  end

  # Unknown types default to `true` (permissive) — every type that exists is
  # in this registry by construction (`Page.@page_types` derives from it), so
  # the default only guards hypothetical future callers.
  defp capability(type, key) do
    case Map.get(@capabilities, type) do
      nil -> true
      caps -> Map.fetch!(caps, key)
    end
  end
end
