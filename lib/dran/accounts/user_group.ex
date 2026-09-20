defmodule Dran.Accounts.UserGroup do
  @moduledoc """
  A named group of users — the share-with-group target (W2).

  Groups are instance-wide and flat (no nesting). Membership is
  `Dran.Accounts.UserGroupMember`. Deleting a group cascades its memberships
  (and with them the group-targeted shares).
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "user_groups" do
    field :name, :string
    field :slug, :string

    many_to_many :users, Dran.Accounts.User,
      join_through: "user_group_members",
      join_keys: [user_group_id: :id, user_id: :id]

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(group, attrs) do
    import Ecto.Changeset

    group
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> validate_length(:slug, max: 100)
    |> put_slug()
    |> unique_constraint(:slug)
  end

  # Slug derives from the name when absent (same policy as workspaces: the
  # name is a label, the slug is the identity).
  defp put_slug(%Ecto.Changeset{changes: %{name: name}} = changeset)
       when is_binary(name) do
    case Ecto.Changeset.get_field(changeset, :slug) do
      nil ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.replace(~r/^-+|-+$/, "")

        if slug == "",
          do: changeset,
          else: Ecto.Changeset.put_change(changeset, :slug, slug)

      _ ->
        changeset
    end
  end

  defp put_slug(changeset), do: changeset
end
