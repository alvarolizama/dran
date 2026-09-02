defmodule Dran.Actors.Actor do
  @moduledoc """
  A global identity in the Dran instance.

  One row per human (`kind: "user"`), agent (`kind: "agent"`), or internal
  system producer (`kind: "system"`). NOT workspace-scoped — an actor is who
  someone *is*; permissions live in `api_key_workspaces` (for keys) and
  user-workspace roles (for users).

  Attribution (owner/created_by strings on pages/tasks/memories) resolves to
  an actor's `name` server-side; the `name` is the join key with historical
  data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @kinds ~w(user agent system)
  @system_names ~w(system entity_linker jobs automation)

  schema "actors" do
    field :name, :string
    field :kind, :string, default: "agent"
    field :display_name, :string
    field :host, :string

    has_many :api_keys, Dran.Accounts.ApiKey
    # users.actor_id is a plain FK column (no belongs_to needed here)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name, :kind, :display_name, :host])
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:name)
  end

  @doc "Valid kinds."
  def kinds, do: @kinds

  @doc "Names reserved for code-managed system actors (no CRUD, no keys)."
  def system_names, do: @system_names

  @doc "True when this actor is code-managed (cannot be edited or deleted)."
  def system?(%__MODULE__{kind: "system"}), do: true
  def system?(_), do: false

  @doc "Display label: display_name if set, else name."
  def label(%__MODULE__{display_name: dn, name: name}) do
    if is_binary(dn) and dn != "", do: dn, else: name
  end
end
