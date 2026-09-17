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
  the `dran_create_page` plugin tool.

  ## Capabilities

  | Capability    | Meaning                                                        |
  |---------------|----------------------------------------------------------------|
  | `graph`       | included in the global graph (GraphCache / graph views)        |
  | `journey`     | counted in the Journey timeline (`Dran.Journey`)              |
  | `embeddings`  | gets embeddings + semantic relations (`PageAugmenter`)         |
  | `agent_create`| can be created through the `dran_create_page` plugin tool      |

  All four types are full citizens (every capability `true`).

  ## What is NOT a page type

  Collections and reports are **first-class entities in
  their own tables** (`Dran.Collections.Collection`, `Dran.Reports.Report`) — they are not page types
  and are not created through `dran_create_page`. Pages carry no sub-type
  vocabulary: classification beyond the type lives in `meta.props` and tags,
  never in a reserved `meta.kind` key.

  `DranWeb.PageTypes` is only UI labels/icons/paths — THIS module decides
  what a type can do. `Dran.Knowledge.Page.@page_types` derives from `types/0`,
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

  @doc "True if pages of this type can be created via the `dran_create_page` plugin tool."
  defdelegate agent_create?(type), to: Dran.PageRegistry

  @doc "List of page types excluded from the global graph by default."
  defdelegate hidden_from_graph, to: Dran.PageRegistry

  @doc "List of page types excluded from the Journey timeline."
  defdelegate excluded_from_journey, to: Dran.PageRegistry
end
