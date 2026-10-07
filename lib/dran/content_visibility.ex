defmodule Dran.ContentVisibility do
  @moduledoc """
  The single read-visibility policy for content (memories + knowledge pages
  + collections + reports).

  Read visibility is decided in exactly ONE place. `Memory`, `Knowledge`,
  `Collections`, `Reports`, the graph, REST and the LiveViews all funnel
  through `scope/3` and `filter/3` — there are no ad-hoc checks per
  controller or per template.

  ## v2 — per-item visibility (W3, contract-instance-visibility-20260919)

  The instance is one workspace; isolation moved from the container to the
  ITEM. Every content row carries `visibility`:

    * `"private"` — readable by its owner and instance admins
    * `"public"`  — readable by every user of the instance
    * `"shared"`  — readable by the owner, instance admins, and the users /
      groups holding a `content_shares` row for it

  A reader sees: **own ∪ public ∪ shared-with-me**. An API identity (the
  account's `api_token`) reads with exactly the reach of its owner.

  ## The vocabulary: the scope

      {:reader, user_id}   a concrete user (or API-key owner) — the normal case
      {:group, group_id}   a GROUP credential: EXACTAMENTE lo compartido a ese
                           grupo, y nada más — ni lo público de la instancia, ni
                           lo privado ajeno, ni lo de otro grupo (W2/W3)
      :all                 a privileged reader (instance owner/admin): everything

  `nil` identity (unknown shapes, legacy surfaces) resolves to `:all` only
  on surfaces the authorization layer already authenticated; the callers
  pass the resolved user. The pre-v2 fail-open posture is kept for shapes
  this module does not understand (documented, tested).

  ## Write vs read

  Shares and visibility only move READ access. Writing stays with the owner
  and instance admins (contract ?03, default applied read-only).
  """

  import Ecto.Query, only: [from: 2]

  alias Dran.Accounts.User

  @type kind :: :memory | :pages
  @type scope :: :all | {:reader, integer() | nil} | {:group, integer()}
  @type identity :: struct() | map() | nil

  @roles_full_view ~w(owner admin)

  # ── Resolution ────────────────────────────────────────────────────────────

  @doc """
  Resolve the read scope of `identity` for `kind`.

  The `workspace` argument is kept for call-site compatibility (v1 resolved
  the sharing policy from it) and is IGNORED in the single-workspace model.
  """
  @spec scope(map() | struct() | nil, identity(), kind()) :: scope()
  def scope(_workspace, nil, _kind), do: :all

  # Una credencial de GRUPO lee EXACTAMENTE lo compartido a su grupo (W2/W3,
  # contract grupo-credencial). La cláusula va ARRIBA de las de privilegio por
  # una razón medida: la identidad de grupo lleva los TRES campos —su
  # `group_id`, un `is_owner` que nunca es true y el `owner_user_id` del humano
  # dueño del grupo—, así que el ORDEN es lo único que impide que un grupo cuyo
  # dueño es el owner de la instancia herede el `:all` de la cláusula siguiente.
  def scope(_workspace, %{group_id: group_id}, _kind) when is_integer(group_id),
    do: {:group, group_id}

  # Instance owner keeps the full view.
  def scope(_workspace, %{is_owner: true}, _kind), do: :all

  # Instance admins (the new instance_role) read everything.
  def scope(_workspace, %User{instance_role: role}, _kind) when role in @roles_full_view,
    do: :all

  # API identity (a map, not a struct): the instance role travels explicitly.
  def scope(_workspace, %{instance_role: role}, _kind) when role in @roles_full_view, do: :all

  # API account / agent identity: reads with the reach of its owner.
  def scope(_workspace, %{owner_user_id: owner_id} = identity, _kind)
      when not is_nil(owner_id) do
    if privileged_identity?(identity), do: :all, else: {:reader, owner_id}
  end

  # A plain user: the per-reader view.
  def scope(_workspace, %User{id: id}, _kind), do: {:reader, id}

  # Authenticated map without ownership information — same behaviour the
  # read path had before per-item visibility (documented fail-open).
  def scope(_workspace, _identity, _kind), do: :all

  @doc """
  Convenience resolver: like `scope/3` but accepting a workspace id, slug or
  struct (ignored in the single-workspace model).
  """
  @spec resolve(binary() | map() | struct() | nil, identity(), kind()) :: scope()
  def resolve(_workspace, identity, kind), do: scope(nil, identity, kind)

  # ── The personal gate ─────────────────────────────────────────────────────

  @doc """
  The PERSONAL read scope of `identity`: the reader's own reach, with NO
  privilege widening.

  `{:reader, id}` for every identity that resolves to a user id — an instance
  owner and an instance admin included. `:all` comes back ONLY when there is no
  identity at all (the nil-identity fail-open this module documents).

  `scope/3` answers *what may this reader read* and keeps the privileged view;
  this one answers *what is this reader's own*. It is the gate for the surfaces
  that must never list what the reader cannot read — the home status block, the
  goal/plan nodes of the graph and the related-pages sidebar. Being an admin is
  not a reason for a personal surface to reveal a foreign private item.
  """
  @spec personal_scope(identity()) :: scope()
  def personal_scope(nil), do: :all

  # La credencial de un grupo no tiene "lo propio" más allá del grupo: su
  # alcance personal ES el grupo. Arriba de `owner_user_id` por la misma razón
  # de orden que `scope/3` — la identidad de grupo lleva ese campo.
  def personal_scope(%{group_id: group_id}) when is_integer(group_id), do: {:group, group_id}

  def personal_scope(%User{id: id}) when is_integer(id), do: {:reader, id}
  def personal_scope(%{is_owner: true, id: id}) when is_integer(id), do: {:reader, id}

  def personal_scope(%{owner_user_id: owner_id}) when is_integer(owner_id),
    do: {:reader, owner_id}

  def personal_scope(%{id: id}) when is_integer(id), do: {:reader, id}
  def personal_scope(_identity), do: :all

  # ── Query helpers ─────────────────────────────────────────────────────────

  @doc """
  Narrow an Ecto query of CONTENT ROWS (pages, memories, collections,
  reports — tables with `visibility` + `owner_user_id`) to a reader's scope.

      from(p in Page) |> ContentVisibility.filter(scope, :page)

  The second argument is the resource type used to look up shares
  (default `:page`).
  """
  @spec filter(Ecto.Queryable.t(), scope(), atom()) :: Ecto.Queryable.t()
  def filter(queryable, :all, _resource), do: queryable

  # La lectura de un grupo es EXACTAMENTE su grupo (Constraint 3): `shared` Y un
  # share con ESE `user_group_id`. Sin `public` y sin `owner_user_id`, que es lo
  # que la vuelve un modo de lectura y no una variante del lector personal.
  def filter(queryable, {:group, group_id}, resource) when is_integer(group_id) do
    from(q in queryable,
      where:
        q.visibility == "shared" and
          fragment(
            "EXISTS (SELECT 1 FROM content_shares s WHERE s.resource_type = ? AND s.resource_id = ? AND s.user_group_id = ?)",
            ^to_string(resource),
            q.id,
            ^group_id
          )
    )
  end

  def filter(queryable, {:reader, reader_id}, resource) do
    group_ids = Dran.Sharing.group_ids_for(reader_id)

    from(q in queryable,
      where:
        q.visibility == "public" or
          q.owner_user_id == ^reader_id or
          (q.visibility == "shared" and
             fragment(
               "EXISTS (SELECT 1 FROM content_shares s WHERE s.resource_type = ? AND s.resource_id = ? AND (s.user_id = ? OR s.user_group_id = ANY(?)))",
               ^to_string(resource),
               q.id,
               ^reader_id,
               ^group_ids
             ))
    )
  end

  @doc """
  Post-fetch check for a single row (graph nodes, cached entries): true when
  a row owned by `owner_user_id` with `visibility` is readable under `scope`.
  """
  @spec visible?(map() | struct() | nil, scope(), atom()) :: boolean()
  def visible?(_row, :all, _resource), do: true

  # La fila de un grupo: `shared` Y un share con ese grupo (el mismo juicio que
  # `filter/3`, para las superficies que comprueban una fila ya cargada).
  def visible?(row, {:group, group_id}, resource)
      when is_map(row) and is_integer(group_id) do
    Map.get(row, :visibility) == "shared" and is_binary(Map.get(row, :id)) and
      Dran.Sharing.shared_with_group?(to_string(resource), Map.get(row, :id), group_id)
  end

  def visible?(row, {:reader, reader_id}, resource) when is_map(row) do
    visible_to_reader?(row, reader_id, resource)
  end

  def visible?(_row, _scope, _resource), do: false

  defp visible_to_reader?(row, reader_id, resource) do
    owner = Map.get(row, :owner_user_id)
    visibility = Map.get(row, :visibility)

    cond do
      owner == reader_id ->
        true

      visibility == "public" ->
        true

      visibility == "shared" and is_binary(Map.get(row, :id)) ->
        Dran.Sharing.shared_with?(to_string(resource), Map.get(row, :id), reader_id)

      true ->
        false
    end
  end

  @doc """
  True when `identity` is a privileged reader (instance owner or an
  admin/owner instance role) — the readers that always keep the full view.
  """
  @spec privileged?(map() | struct() | nil, map() | struct() | nil) :: boolean()
  def privileged?(nil, _workspace), do: false
  def privileged?(%{is_owner: true}, _workspace), do: true

  def privileged?(%User{instance_role: role}, _workspace), do: role in @roles_full_view

  def privileged?(_identity, _workspace), do: false

  # ── Internals ─────────────────────────────────────────────────────────────

  defp privileged_identity?(identity), do: Map.get(identity, :is_owner) == true
end
