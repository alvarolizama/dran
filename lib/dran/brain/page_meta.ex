defmodule Dran.Brain.PageMeta do
  @moduledoc """
  Embedded schema for validating the `meta` JSONB of a page.

  Each page type has a different set of meaningful meta fields. This module
  defines all of them in a single embedded schema and dispatches validation
  based on the page type.

  ## Usage

      changeset = PageMeta.changeset(%PageMeta{}, attrs, "todo")
      if changeset.valid?, do: ...
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # Common
    field :kind, :string
    field :goal_slug, :string

    # note sub-types
    field :date, :date
    field :feasibility, :string
    field :impact, :string
    field :attendees, {:array, :string}
    field :resolved, :boolean
    field :source_ref, :string
    field :author, :string

    # comparison
    field :entities, {:array, :string}
    field :criteria, {:array, :string}
    field :verdict, :string

    # plan
    field :horizon, :string
    field :period, :string
    field :status, :string

    # todo
    field :kanban_status, :string
    field :priority, :string
    field :due_date, :date
    field :remind_at, :utc_datetime
    field :acknowledged, :boolean
    field :completed_at, :utc_datetime
    field :assignee, :string

    # goal
    field :start_date, :date
    field :target_date, :date
    field :team, {:array, :string}
    field :health, :string

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

    # artifact
    field :filename, :string
    field :mime_type, :string
    field :size, :integer
    field :storage_path, :string
    field :sha256, :string
    field :version, :string
  end

  @note_kinds ~w(thought journal idea meeting question quote)
  @entity_kinds ~w(person company product tool place event)
  @concept_kinds ~w(technique pattern discipline theory)
  @reference_kinds ~w(article paper video podcast book)
  @artifact_kinds ~w(document code design deliverable file)
  @kanban_statuses ~w(backlog this_week today in_progress done cancelled)
  @priorities ~w(low medium high urgent)
  @healths ~w(green yellow red)
  @horizons ~w(weekly monthly quarterly yearly)

  def changeset(meta, attrs, page_type) do
    meta
    |> cast(attrs, all_fields())
    |> validate_kind(page_type)
    |> validate_meta_for_type(page_type)
  end

  defp all_fields do
    [
      :kind,
      :goal_slug,
      :date,
      :feasibility,
      :impact,
      :attendees,
      :resolved,
      :source_ref,
      :author,
      :entities,
      :criteria,
      :verdict,
      :horizon,
      :period,
      :status,
      :kanban_status,
      :priority,
      :due_date,
      :remind_at,
      :acknowledged,
      :completed_at,
      :assignee,
      :start_date,
      :target_date,
      :team,
      :health,
      :aliases,
      :external_url,
      :location,
      :domain,
      :parent_concept,
      :source_url,
      :published_at,
      :content_hash,
      :fetched_at,
      :filename,
      :mime_type,
      :size,
      :storage_path,
      :sha256,
      :version
    ]
  end

  defp validate_kind(cs, type) when type in ~w(note entity concept reference artifact) do
    kinds = kinds_for(type)

    if kinds do
      validate_inclusion(cs, :kind, kinds)
    else
      cs
    end
  end

  defp validate_kind(cs, _type), do: cs

  defp kinds_for("note"), do: @note_kinds
  defp kinds_for("entity"), do: @entity_kinds
  defp kinds_for("concept"), do: @concept_kinds
  defp kinds_for("reference"), do: @reference_kinds
  defp kinds_for("artifact"), do: @artifact_kinds
  defp kinds_for(_), do: nil

  defp validate_meta_for_type(cs, "todo") do
    cs
    |> validate_inclusion(:kanban_status, @kanban_statuses)
    |> validate_inclusion(:priority, @priorities)
  end

  defp validate_meta_for_type(cs, "goal") do
    validate_inclusion(cs, :health, @healths)
  end

  defp validate_meta_for_type(cs, "plan") do
    validate_inclusion(cs, :horizon, @horizons)
  end

  defp validate_meta_for_type(cs, _type), do: cs

  def note_kinds, do: @note_kinds
  def entity_kinds, do: @entity_kinds
  def concept_kinds, do: @concept_kinds
  def reference_kinds, do: @reference_kinds
  def artifact_kinds, do: @artifact_kinds
  def kanban_statuses, do: @kanban_statuses
  def priorities, do: @priorities
end
