defmodule Dran.ContentShare do
  @moduledoc """
  A read grant on one content row (W2).

  `resource_type` is one of `page`, `memory`, `collection` or `report` and
  `resource_id` is the row's UUID. Exactly one of `user_id` / `user_group_id`
  is set (CHECK constraint in the DB). Shares grant READ access only —
  writing stays with the owner (contract ?03, default applied read-only).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @resource_types ~w(page memory collection report)
  @visibility ~w(private public shared)

  schema "content_shares" do
    field :resource_type, :string
    field :resource_id, :binary_id
    field :user_id, :integer
    field :user_group_id, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def resource_types, do: @resource_types
  def visibility_levels, do: @visibility

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:resource_type, :resource_id, :user_id, :user_group_id])
    |> validate_required([:resource_type, :resource_id])
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_exactly_one_target()
    |> unique_constraint(:user_id,
      name: :content_shares_resource_type_resource_id_user_id_index
    )
    |> unique_constraint(:user_group_id,
      name: :content_shares_resource_type_resource_id_user_group_id_index
    )
  end

  defp validate_exactly_one_target(changeset) do
    user_id = get_field(changeset, :user_id)
    group_id = get_field(changeset, :user_group_id)

    case {user_id, group_id} do
      {nil, nil} ->
        add_error(changeset, :user_id, "a share targets exactly one user or group")

      {_, nil} ->
        changeset

      {nil, _} ->
        changeset

      _ ->
        add_error(changeset, :user_group_id, "a share targets exactly one user or group")
    end
  end
end
