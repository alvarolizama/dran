defmodule Dran.PageTypes do
  @moduledoc """
  Canonical page type registry — delegates to `Dran.PageRegistry`.

  This module preserves the public API that consumers call directly
  (`types/0`, `graph?/1`, `journey?/1`, etc.). The data now lives in
  `Dran.PageRegistry`, which is the single source of truth for all page
  type configuration (capabilities, kinds, meta fields, UI attrs).

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

  @doc "Ordered list of all valid page types."
  defdelegate types, to: Dran.PageRegistry

  @doc "True if pages of this type appear in the global graph."
  defdelegate graph?(type), to: Dran.PageRegistry

  @doc "True if pages of this type are counted in the Journey timeline."
  defdelegate journey?(type), to: Dran.PageRegistry

  @doc "True if pages of this type get embeddings and semantic relations."
  defdelegate embeddings?(type), to: Dran.PageRegistry

  @doc "True if pages of this type can be created via the MCP `dran_create_page` tool."
  defdelegate mcp_create?(type), to: Dran.PageRegistry

  @doc "List of page types excluded from the global graph by default."
  defdelegate hidden_from_graph, to: Dran.PageRegistry

  @doc "List of page types excluded from the Journey timeline."
  defdelegate excluded_from_journey, to: Dran.PageRegistry
end
