defmodule Dran.Accounts.UserGroup do
  @moduledoc """
  A named group of users — the share-with-group target (W2), and since W2 of
  `grupo-credencial` a PRINCIPAL in its own right: `api_token` is the group's
  own credential (a client that presents it writes ONLY into this group) and
  `owner_user_id` is the account that answers for it.

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

    # La credencial del grupo. NO viaja en el changeset: la emite y la rota
    # `issue_group_token/1` (server-side), nunca el cliente.
    field :api_token, :string

    # El humano que responde por el grupo (nace del owner de la instancia).
    field :owner_user_id, :id

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

  @doc """
  El changeset del TOKEN: emite (o rota) la credencial del grupo.

  Mismo alfabeto que la credencial de cuenta (`User.generate_api_token/0`) — una
  sola forma de token en la casa. Se llama server-side; `api_token` no es campo
  de escritura del cliente en ningún changeset.
  """
  def token_changeset(%__MODULE__{} = group) do
    import Ecto.Changeset

    change(group, api_token: Dran.Accounts.User.generate_api_token())
  end
end
