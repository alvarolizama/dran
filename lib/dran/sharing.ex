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

  @doc "Busca un grupo por su slug — la identidad que el cliente usa en `scope` (W6)."
  def get_group_by_slug(slug) when is_binary(slug), do: Repo.get_by(UserGroup, slug: slug)

  @doc "¿`user_id` pertenece a `group_id`? La membresía que valida el scope por escritura."
  def group_member?(group_id, user_id) when is_integer(group_id) and is_integer(user_id) do
    Repo.exists?(
      from(m in UserGroupMember, where: m.user_group_id == ^group_id and m.user_id == ^user_id)
    )
  end

  def group_member?(_group_id, _user_id), do: false

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

  @doc """
  Agrega al grupo la cuenta con ese `email` — la puerta "agregar por correo"
  del panel de miembros.

  Igual que invitar a un workspace: la persona ya debe tener cuenta (no hay
  correo de invitación ni estado pendiente), así que un email desconocido es
  `{:error, :user_not_found}` y no crea nada. Un miembro existente devuelve
  `{:error, :already_member}` en vez de duplicar o de fallar en silencio.
  """
  def add_group_member_by_email(%UserGroup{} = group, email) when is_binary(email) do
    case email |> String.trim() |> Dran.Accounts.get_user_by_email() do
      nil ->
        {:error, :user_not_found}

      user ->
        if group_member?(group.id, user.id) do
          {:error, :already_member}
        else
          add_group_member(group, user.id)
        end
    end
  end

  def add_group_member_by_email(_group, _email), do: {:error, :user_not_found}

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

  @doc """
  Los grupos donde `user_id` es MIEMBRO, ordenados por nombre (W7/P19).

  Es el MISMO conjunto con el que `apply_scope/3` autoriza un `scope` de grupo
  (W6 valida la membresía del dueño del recurso): la lista que el cliente ve y
  los slugs a los que puede escribir no pueden divergir — si divergieran, el
  agente elegiría un slug que la lista dejaba prever y comería un 422.

  Sin identidad (o sin membresías) devuelve `[]`: la lectura es membresía, no
  visibilidad (un grupo no es contenido con `visibility`/`owner_user_id`).
  """
  def list_groups_for_user(user_id) when is_integer(user_id) do
    group_ids = group_ids_for(user_id)

    Repo.all(from(g in UserGroup, where: g.id in ^group_ids, order_by: [asc: g.name]))
  end

  def list_groups_for_user(_user_id), do: []

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
      when is_binary(resource_type) and is_integer(user_id) do
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
      when is_binary(resource_type) and is_integer(group_id) do
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

  # ── Scope por escritura (W6) ───────────────────────────────────────────────

  # S32 (backfill): NO se crea migración. Medición sobre `dran_dev` — las
  # cuatro tablas ya tienen `visibility` desde W2 y con 0 filas NULL:
  # knowledge_pages 8 (todas `private`), memories 0, collections 0, reports 0.
  # No queda nada que backfillear; una migración inventada sería peor que
  # ninguna.

  @doc """
  Agrega un grant Y fija `visibility = "shared"` en la MISMA transacción.

  Un grant con la fila en `private` es INERTE para la política de lectura
  (`ContentVisibility.filter/3` exige `visibility == "shared"` Y el `EXISTS` del
  share), así que agregarlo suelto —lo que hacían `share_with_user/3` y
  `share_with_group/3` por separado— es una mentira silenciosa: el invitado no
  lee y nadie se entera. Acá las dos cosas viajan juntas.

  `target` es `{:user, id}` o `{:group, id}`; `resource_type` sale del
  vocabulario de `resource_types/0`.
  """
  @spec grant(struct(), atom() | binary(), tuple()) ::
          {:ok, :shared, struct()} | {:error, term()}
  def grant(resource, resource_type, {:user, user_id}) when is_integer(user_id) do
    grant_with(resource, resource_type, fn type, id -> share_with_user(type, id, user_id) end)
  end

  def grant(resource, resource_type, {:group, group_id}) when is_integer(group_id) do
    grant_with(resource, resource_type, fn type, id -> share_with_group(type, id, group_id) end)
  end

  def grant(_resource, _resource_type, target),
    do: {:error, "invalid grant target #{inspect(target)}: expected {:user, id} or {:group, id}"}

  defp grant_with(resource, resource_type, share) do
    Repo.transaction(fn ->
      case share.(to_string(resource_type), resource.id) do
        {:ok, :shared} -> put_visibility(resource, "shared")
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, :shared, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Traduce el destino de UNA escritura (`scope`) a la `visibility` de la fila
  más la fila de `content_shares` que corresponda, validando la membresía
  server-side y fallando cerrado (contract Rules#5, W6).

  `scope` es el vocabulario de la INTENCIÓN — destino de escritura, nunca de
  lectura (constraint 9):

    * `"private"` — `visibility: "private"`, sin share (el DEFAULT del schema).
    * `"public"`  — `visibility: "public"`, sin share.
    * `%{"group" => slug}` — `visibility: "shared"` + un share para ESE grupo.

  El grupo debe existir y el DUEÑO de la fila (`resource.owner_user_id`) debe
  ser miembro. Si el grupo no existe, el dueño no es miembro, o el `scope` no
  es del vocabulario, devuelve `{:error, mensaje}` — NUNCA un fallback
  silencioso a `private` (P20): un destino que no se puede honrar es un error,
  no una degradación.

  Recibe el recurso YA insertado (necesita su id para el share); el
  controlador la envuelve junto con el insert en UN `Repo.transaction`, así un
  destino inválido revierte la fila y no deja huérfanos.
  """
  @spec apply_scope(struct(), term(), atom()) :: {:ok, struct()} | {:error, binary()}
  def apply_scope(resource, "private", _resource_type) do
    {:ok, put_visibility(resource, "private")}
  end

  def apply_scope(resource, "public", _resource_type) do
    {:ok, put_visibility(resource, "public")}
  end

  def apply_scope(resource, %{"group" => slug}, resource_type) when is_binary(slug) do
    apply_group_scope(resource, slug, resource_type)
  end

  # Forma con átomo — para callers internos y tests.
  def apply_scope(resource, %{group: slug}, resource_type) when is_binary(slug) do
    apply_group_scope(resource, slug, resource_type)
  end

  def apply_scope(_resource, scope, _resource_type) do
    {:error,
     "invalid scope #{inspect(scope)}: expected \"private\", \"public\" or %{\"group\" => \"<slug>\"}"}
  end

  defp apply_group_scope(resource, slug, resource_type) do
    owner_id = Map.get(resource, :owner_user_id)

    with %UserGroup{} = group <- get_group_by_slug(slug),
         :ok <- ensure_group_member(group, owner_id),
         {:ok, :shared} <- share_with_group(to_string(resource_type), resource.id, group.id) do
      {:ok, put_visibility(resource, "shared")}
    else
      nil ->
        {:error, "unknown group #{inspect(slug)}"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "could not share: #{inspect(format_share_errors(changeset))}"}
    end
  end

  # Membresía fail-closed: sin identidad dueña no se puede validar el grupo, así
  # que la escritura no se honra (nunca `private` en silencio).
  defp ensure_group_member(_group, nil) do
    {:error, "scope %{\"group\" => ...} requires an owned identity to validate membership"}
  end

  defp ensure_group_member(%UserGroup{} = group, owner_id) do
    if group_member?(group.id, owner_id) do
      :ok
    else
      {:error, "the owner is not a member of group #{group.slug}"}
    end
  end

  defp put_visibility(resource, visibility) do
    resource
    |> Ecto.Changeset.change(visibility: visibility)
    |> Repo.update!()
  end

  defp format_share_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
