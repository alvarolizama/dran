defmodule Dran.Sharing do
  @moduledoc """
  The sharing context (W2, contract-instance-visibility-20260919).

  Two jobs:

  - **Groups** — CRUD over `Dran.Accounts.UserGroup` (+ membership).
  - **Shares** — read grants over any content row (`page` | `memory` |
    `collection` | `report`) to a user or a group.

  Visibility VALUES (`private` | `public` | `shared`) are a column on each
  content table; a share row is only meaningful when the owner marks the
  item `shared`. The read filter that combines both lives in
  `Dran.ContentVisibility` (W3).

  Shares never grant write: only the owner (and instance admins) write.
  """

  import Ecto.Query
  alias Dran.Accounts.UserGroup
  alias Dran.Accounts.UserGroupMember
  alias Dran.ContentShare
  alias Dran.Repo

  # ── Groups ─────────────────────────────────────────────────────────────────

  def list_groups do
    Repo.all(from g in UserGroup, order_by: [asc: g.name])
  end

  def get_group!(id), do: Repo.get!(UserGroup, id)

  def create_group(attrs) do
    %UserGroup{}
    |> UserGroup.changeset(attrs)
    |> Repo.insert()
  end

  def update_group(%UserGroup{} = group, attrs) do
    group
    |> UserGroup.changeset(attrs)
    |> Repo.update()
  end

  def delete_group(%UserGroup{} = group), do: Repo.delete(group)

  def add_group_member(%UserGroup{} = group, user_id) do
    %UserGroupMember{}
    |> UserGroupMember.changeset(%{user_group_id: group.id, user_id: user_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_group_id, :user_id])
  end

  def remove_group_member(%UserGroup{} = group, user_id) do
    Repo.delete_all(
      from(m in UserGroupMember,
        where: m.user_group_id == ^group.id and m.user_id == ^user_id
      )
    )

    :ok
  end

  @doc "The users belonging to `group_id` (for the members panel)."
  def list_group_members(group_id) do
    Repo.all(
      from(m in UserGroupMember,
        join: u in assoc(m, :user),
        where: m.user_group_id == ^group_id,
        order_by: [asc: u.email],
        select: %{id: u.id, email: u.email, name: u.name}
      )
    )
  end

  @doc "The ids of every group `user_id` belongs to."
  def group_ids_for(user_id) when is_integer(user_id) do
    Repo.all(from(m in UserGroupMember, where: m.user_id == ^user_id, select: m.user_group_id))
  end

  @doc "Groups with their member count, for the admin UI."
  def list_groups_with_counts do
    Repo.all(
      from g in UserGroup,
        left_join: m in UserGroupMember,
        on: m.user_group_id == g.id,
        group_by: g.id,
        order_by: [asc: g.name],
        select: {g, count(m.id)}
    )
  end

  # ── Shares ─────────────────────────────────────────────────────────────────

  @doc """
  Share `resource` (type + uuid) with a user. Idempotent: sharing twice
  returns the existing row.
  """
  def share_with_user(resource_type, resource_id, user_id)
      when resource_type in ~w(page memory collection report) and is_integer(user_id) do
    %ContentShare{}
    |> ContentShare.changeset(%{
      resource_type: resource_type,
      resource_id: resource_id,
      user_id: user_id
    })
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _} -> {:ok, :shared}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Share `resource` with every member of a group (one share row)."
  def share_with_group(resource_type, resource_id, group_id)
      when resource_type in ~w(page memory collection report) and is_integer(group_id) do
    %ContentShare{}
    |> ContentShare.changeset(%{
      resource_type: resource_type,
      resource_id: resource_id,
      user_group_id: group_id
    })
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _} -> {:ok, :shared}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Remove one share row (by id)."
  def unshare(share_id) when is_binary(share_id) do
    Repo.delete_all(from(s in ContentShare, where: s.id == ^share_id))
    :ok
  end

  @doc "Every share on one resource, user and group targets preloaded as maps."
  def list_shares(resource_type, resource_id) do
    Repo.all(
      from(s in ContentShare,
        where: s.resource_type == ^resource_type and s.resource_id == ^resource_id,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  @doc """
  The subquery fragment every visibility read composes: true when `reader_id`
  holds a share on `resource_type`/`resource_id` (directly or via a group).
  Used by `Dran.ContentVisibility.filter/3` (W3).
  """
  def shared_with?(resource_type, resource_id, reader_id) when is_integer(reader_id) do
    reader_group_ids = group_ids_for(reader_id)

    Repo.exists?(
      from(s in ContentShare,
        where:
          s.resource_type == ^resource_type and
            s.resource_id == ^resource_id and
            (s.user_id == ^reader_id or s.user_group_id in ^reader_group_ids)
      )
    )
  end
end
