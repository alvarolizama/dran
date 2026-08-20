defmodule Dran.PageTypes do
  @moduledoc """
  Canonical page type registry — the single source of truth for the list of
  page types and what each type can do (its *capabilities*).

  ## Page types

  There are exactly **4** page types: `note`, `entity`, `concept`, and
  `reference`. They are the only values accepted by `Page.@page_types` and by
  the `dran_create_page` MCP tool.

  ## Capabilities

  | Capability    | Meaning                                                        |
  |---------------|----------------------------------------------------------------|
  | `graph`       | included in the global graph (GraphCache / graph views)        |
  | `journey`     | counted in the Journey timeline (`Dran.Journey`)               |
  | `embeddings`  | gets embeddings + semantic relations (`PageAugmenter`)         |
  | `mcp_create`  | can be created through the `dran_create_page` MCP tool         |

  All four types are full citizens (every capability `true`).

  ## What is NOT a page type

  Goals, collections, and reports are **first-class entities in
  their own tables** (`Dran.Goal`,
  `Dran.Collection`, `Dran.Report`) — they are not page types
  and are not created through `dran_create_page`. Todo-style action items
  are `note` pages with `meta.kind == "todo"` plus kanban columns
  (`kanban_status`, `priority`, `due_date`, `assignee`); use the
  `dran_create_note` MCP tool for those.

  `DranWeb.PageTypes` is only UI labels/icons/paths — THIS module decides
  what a type can do. `Dran.Page.@page_types` derives from `types/0`,
  so adding a type here propagates to changeset validation automatically.
  """

  @capabilities %{
    "note" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "entity" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "concept" => %{graph: true, journey: true, embeddings: true, mcp_create: true},
    "reference" => %{graph: true, journey: true, embeddings: true, mcp_create: true}
  }

  # Canonical ordering — preserves the historical `Page.all_types()` order so
  # UI surfaces that iterate the list (e.g. the Settings page-types modal)
  # keep their existing ordering.
  @types ~w(note entity concept reference)

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
