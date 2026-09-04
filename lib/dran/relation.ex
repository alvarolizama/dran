defmodule Dran.Relation do
  @moduledoc """
  Directed N:M relation between nodes. The graph is directed:
  `source` → `target`.

  Relations are **polymorphic**: `source_type` / `target_type` indicate which
  table the `source_id` / `target_id` point to — `"page"`, `"goal"`,
  `"project"`, or `"collection"`. App-level validation in `changeset/2`
  ensures each endpoint resolves to a real row of the declared type.

  ## Relation types (manual)
  - `related` — generic connection (default)
  - `contradicts` — source contradicts target
  - `supersedes` — source replaces/obsoletes target
  - `part_of` — source is part of target
  - `embeds` — source embeds target (e.g. a file page in a note body)
  - `mentions` — source mentions the target entity (entity linking)

  Additionally, `semantic` is created automatically by the augmenter and
  `works_in` / `has_tier` / `based_in` / `written_in` / `built_with` are
  materialized from `meta.props` — none of them are set manually.

  `depends_on` (task→task) is the workflow edge: target is a prerequisite of
  source. See `Dran.Contracts` for the ready/blocked semantics it enables.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :source_id,
             :source_type,
             :target_id,
             :target_type,
             :relation_type,
             :weight,
             :inserted_at
           ]}
  @relation_types ~w(related contradicts supersedes part_of embeds semantic mentions works_in has_tier based_in written_in built_with depends_on)
  @node_types ~w(page goal task collection step)

  schema "relations" do
    field :source_id, :binary_id
    field :source_type, :string, default: "page"
    field :target_id, :binary_id
    field :target_type, :string, default: "page"
    field :relation_type, :string, default: "related"
    field :weight, :float
    field :meta, :map, default: %{}

    has_one :source, Dran.Page, foreign_key: :id, references: :source_id
    has_one :target, Dran.Page, foreign_key: :id, references: :target_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating a relation"
  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [
      :source_id,
      :source_type,
      :target_id,
      :target_type,
      :relation_type,
      :weight,
      :meta
    ])
    |> validate_required([:source_id, :target_id])
    |> validate_inclusion(:source_type, @node_types)
    |> validate_inclusion(:target_type, @node_types)
    |> validate_inclusion(:relation_type, @relation_types)
    |> validate_polymorphic_source()
    |> validate_polymorphic_target()
    |> unique_constraint([:source_id, :target_id, :relation_type],
      name: :relations_source_id_target_id_relation_type_index
    )
  end

  @doc "List of valid relation types"
  def relation_types, do: @relation_types

  @doc "List of valid node types (polymorphic endpoints)"
  def node_types, do: @node_types

  # App-level polymorphic validation — the DB has no FK to enforce that
  # `(source_id, source_type)` resolves, so we check it here.
  defp validate_polymorphic_source(changeset) do
    with id when not is_nil(id) <- get_change(changeset, :source_id),
         type when not is_nil(type) <- get_change(changeset, :source_type),
         false <- endpoint_exists?(type, id) do
      add_error(changeset, :source_id, "does not exist for type #{type}")
    else
      _ -> changeset
    end
  end

  defp validate_polymorphic_target(changeset) do
    with id when not is_nil(id) <- get_change(changeset, :target_id),
         type when not is_nil(type) <- get_change(changeset, :target_type),
         false <- endpoint_exists?(type, id) do
      add_error(changeset, :target_id, "does not exist for type #{type}")
    else
      _ -> changeset
    end
  end

  # Relationship modules for polymorphic endpoint lookup. When a relation is
  # created via the context the ids are always present, so we query the repo
  # for the declared type to confirm the row exists. Uses on_conflict-safe
  # Repo.exists? checks that are cheap (single PK lookup per side).
  defp endpoint_exists?(type, id) do
    mod = endpoint_module(type)

    if mod do
      Dran.Repo.exists?(from e in mod, where: e.id == ^id)
    else
      false
    end
  end

  defp endpoint_module("page"), do: Dran.Page
  defp endpoint_module("goal"), do: Dran.Goal
  defp endpoint_module("task"), do: Dran.Task
  defp endpoint_module("collection"), do: Dran.Collection
  defp endpoint_module("step"), do: Dran.Step
  defp endpoint_module(_), do: nil
end
