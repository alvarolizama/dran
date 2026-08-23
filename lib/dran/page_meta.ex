defmodule Dran.PageMeta do
  @moduledoc """
  Embedded schema for validating the `meta` JSONB of a page.

  The kind lists and meta-field definitions have been consolidated into
  `Dran.PageRegistry` (single source of truth). This module keeps the
  Ecto embedded schema and changeset — it delegates kind validation and
  field definitions to the registry.

  ## Usage

      changeset = PageMeta.changeset(%PageMeta{}, attrs, "note")
      if changeset.valid?, do: ...
  """

  use Ecto.Schema
  use Gettext, backend: DranWeb.Gettext
  import Ecto.Changeset

  alias Dran.PageRegistry

  @primary_key false

  embedded_schema do
    # Common
    field :kind, :string

    # graph signals (computed by Dran.Graph)
    field :pagerank, :float
    field :cluster_id, :integer

    # note sub-types
    field :date, :date
    field :feasibility, :string
    field :impact, :string
    field :attendees, {:array, :string}
    field :resolved, :boolean
    field :source_ref, :string
    field :author, :string
    field :language, :string

    # entity
    field :aliases, {:array, :string}
    field :external_url, :string
    field :location, :string

    # concept
    field :domain, :string
    field :parent_concept, :string

    # reference
    field :source_url, :string
    field :published_at, :date
    field :content_hash, :string
    field :fetched_at, :utc_datetime

    # custom properties — namespaced free-form key-value bag for user metadata
    # (e.g. %{"role" => "sales", "tier" => "vip"}). Kept under :props so it
    # never collides with reserved top-level meta keys.
    field :props, :map
  end

  def changeset(meta, attrs, page_type) do
    meta
    |> cast(attrs, all_fields())
    |> validate_kind(page_type)
    |> validate_meta_for_type(page_type)
  end

  defp all_fields do
    [
      :kind,
      :pagerank,
      :cluster_id,
      :date,
      :feasibility,
      :impact,
      :attendees,
      :resolved,
      :source_ref,
      :author,
      :language,
      :aliases,
      :external_url,
      :location,
      :domain,
      :parent_concept,
      :source_url,
      :published_at,
      :content_hash,
      :fetched_at,
      :props
    ]
  end

  defp validate_kind(cs, type) do
    kinds = PageRegistry.kinds(type)

    if kinds do
      validate_inclusion(cs, :kind, kinds)
    else
      cs
    end
  end

  defp validate_meta_for_type(cs, _type), do: cs

  # ── Delegation to PageRegistry ──────────────────────────────────────
  #
  # These functions preserve the public API that consumers call directly.
  # The data lives in Dran.PageRegistry.

  @doc "Valid kinds for a type (delegates to PageRegistry)."
  def kinds_for(type), do: PageRegistry.kinds(type)

  def note_kinds, do: PageRegistry.kinds("note")
  def entity_kinds, do: PageRegistry.kinds("entity")
  def concept_kinds, do: PageRegistry.kinds("concept")
  def reference_kinds, do: PageRegistry.kinds("reference")

  @doc """
  Returns the metadata fields and their select options for a given page type.

  Delegates to `Dran.PageRegistry.meta_fields/1`. The tuple shapes are
  identical to what this module returned previously — the normaliser in
  `markdown_editor_components.ex` handles them unchanged.
  """
  def meta_fields_for(type, mode \\ :edit)

  def meta_fields_for(type, :edit), do: PageRegistry.meta_fields(type)
  def meta_fields_for(type, :new), do: PageRegistry.meta_fields(type)
end
