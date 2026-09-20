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

  A reader sees: **own ∪ public ∪ shared-with-me**. An API key reads with
  exactly the reach of its owner (the user behind the actor).

  ## The vocabulary: the scope

      {:reader, user_id}   a concrete user (or API-key owner) — the normal case
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
  @type scope :: :all | {:reader, integer() | nil}
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

  # Instance owner keeps the full view.
  def scope(_workspace, %{is_owner: true}, _kind), do: :all

  # Instance admins (the new instance_role) read everything.
  def scope(_workspace, %User{instance_role: role}, _kind) when role in @roles_full_view,
    do: :all

  # API-key / agent identity: reads with the reach of its owner.
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

  def visible?(row, {:reader, reader_id}, resource) when is_map(row) do
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

  def visible?(_row, _scope, _resource), do: false

  @doc """
  True when `identity` is a privileged reader (instance owner or an
  admin/owner instance role) — the readers that always keep the full view.
  """
  @spec privileged?(map() | struct() | nil, map() | struct() | nil) :: boolean()
  def privileged?(nil, _workspace), do: false
  def privileged?(%{is_owner: true}, _workspace), do: true

  def privileged?(%User{instance_role: role}, _workspace), do: role in @roles_full_view

  def privileged?(_identity, _workspace), do: false

  @doc """
  The personal content preference of `user_id` (`"all"` | `"own"`), kept for
  the memory LiveView toggle. With per-item visibility the default is
  `"all"` — the filter already narrows to what the reader may see.
  """
  @spec content_scope_for(integer() | nil, binary() | nil) :: String.t()
  def content_scope_for(_user_id, _workspace_id), do: "all"

  # ── Internals ─────────────────────────────────────────────────────────────

  defp privileged_identity?(identity), do: Map.get(identity, :is_owner) == true
end
