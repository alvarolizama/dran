defmodule Dran.Knowledge.PageMeta do
  @moduledoc """
  Embedded schema for validating the `meta` JSONB of a page.

  The meta-field definitions have been consolidated into `Dran.PageRegistry`
  (single source of truth). This module keeps the Ecto embedded schema and
  changeset — it delegates field definitions to the registry.

  Pages carry no sub-type vocabulary: there is no `kind` field. Classification
  beyond the page type lives in `:props`, the namespaced free-form bag.

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
    # graph signals (computed by Dran.Graph)
    field :pagerank, :float
    field :cluster_id, :integer

    # note
    field :date, :date

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
    |> validate_meta_for_type(page_type)
  end

  # Per-type validation hook — the only cross-field rules that ever existed
  # were the retired kind rules, so today every type is accepted as-is. Kept
  # as a named step so a future per-type rule has an obvious home.

  defp all_fields do
    [
      :pagerank,
      :cluster_id,
      :date,
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

  defp validate_meta_for_type(cs, _type), do: cs

  # ── Delegation to PageRegistry ──────────────────────────────────────
  #
  # These functions preserve the public API that consumers call directly.
  # The data lives in Dran.PageRegistry.

  @doc """
  Returns the metadata fields for a given page type.

  Delegates to `Dran.PageRegistry.meta_fields/1`. The tuple shapes are
  identical to what this module returned previously — the normaliser in
  `markdown_editor_components.ex` handles them unchanged.
  """
  def meta_fields_for(type, mode \\ :edit)

  def meta_fields_for(type, :edit), do: PageRegistry.meta_fields(type)
  def meta_fields_for(type, :new), do: PageRegistry.meta_fields(type)
end
