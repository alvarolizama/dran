defmodule Dran.Brain.Relation do
  @moduledoc """
  Directed N:M relation between pages. The graph is directed:
  `source` → `target`.

  ## Relation types
  - `related` — generic connection (default)
  - `contradicts` — source contradicts target
  - `supersedes` — source replaces/obsoletes target
  - `part_of` — source is part of target
  - `embeds` — source embeds target (e.g. an artifact page in a note body)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder, only: [:id, :source_id, :target_id, :relation_type, :inserted_at]}
  @relation_types ~w(related contradicts supersedes part_of embeds)

  schema "relations" do
    field :relation_type, :string, default: "related"
    field :meta, :map, default: %{}

    belongs_to :source, Dran.Brain.Page
    belongs_to :target, Dran.Brain.Page

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating a relation"
  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [:source_id, :target_id, :relation_type, :meta])
    |> validate_required([:source_id, :target_id])
    |> validate_inclusion(:relation_type, @relation_types)
    |> unique_constraint([:source_id, :target_id, :relation_type],
      name: :relations_source_id_target_id_relation_type_index
    )
  end

  @doc "List of valid relation types"
  def relation_types, do: @relation_types
end
