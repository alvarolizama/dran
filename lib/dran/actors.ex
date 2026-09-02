defmodule Dran.Actors do
  @moduledoc """
  The actor context: global identities (user | agent | system).

  System actors are code-managed: `ensure_system_actors!/0` upserts them
  idempotently (migration + boot). User/agent actors are created via the
  settings CRUD; every API key is attached to exactly one actor.
  """

  import Ecto.Query
  alias Dran.Actors.Actor
  alias Dran.Repo

  @system_actors [
    %{name: "system", display_name: "System"},
    %{name: "entity_linker", display_name: "Entity Linker"},
    %{name: "jobs", display_name: "Scheduled Jobs"},
    %{name: "automation", display_name: "Task Automation"}
  ]

  @doc "The canonical system actor definitions (source of truth = code)."
  def system_actor_defs, do: @system_actors

  @doc """
  Upsert all system actors. Idempotent — safe to call on every boot.
  Called from the migration and from `Dran.Application`.
  """
  def ensure_system_actors! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(@system_actors, fn defn ->
        %{
          id: Ecto.UUID.generate(),
          name: defn.name,
          kind: "system",
          display_name: defn.display_name,
          inserted_at: now
        }
      end)

    {_, _} =
      Repo.insert_all(Actor, rows, on_conflict: :nothing, conflict_target: :name)

    :ok
  end

  @doc "List actors, optionally filtered by kind. System actors included."
  def list_actors(opts \\ []) do
    kind = Keyword.get(opts, :kind)

    Actor
    |> maybe_where_kind(kind)
    |> order_by([a], asc: a.kind, asc: a.name)
    |> Repo.all()
  end

  @doc "List actors excluding code-managed system ones (for CRUD UIs)."
  def list_managed_actors do
    Actor
    |> where([a], a.kind != "system")
    |> order_by([a], asc: a.kind, asc: a.name)
    |> Repo.all()
  end

  @doc """
  Resolve an actor by name. The attribution join key — server-side
  resolvers call this (cached by caller when hot).
  """
  def get_actor_by_name(name) when is_binary(name) do
    Repo.get_by(Actor, name: name)
  end

  @doc "Get the actor for an API key (preloads-safe: plain FK lookup)."
  def get_actor!(id), do: Repo.get!(Actor, id)

  @doc """
  Create a user/agent actor. Refuses system kind — system actors are
  code-managed only (see `ensure_system_actors!/0`).
  """
  def create_actor(attrs) do
    %Actor{}
    |> Actor.changeset(attrs)
    |> validate_not_system()
    |> Repo.insert()
  end

  @doc """
  Update a managed actor (kind user/agent only). System actors are frozen.
  """
  def update_actor(%Actor{} = actor, attrs) do
    cond do
      Actor.system?(actor) ->
        {:error, :system_actor}

      true ->
        # name/kind are immutable — only display_name/host are castable
        actor
        |> Ecto.Changeset.cast(attrs, [:display_name, :host])
        |> Ecto.Changeset.validate_length(:display_name, max: 255)
        |> Ecto.Changeset.validate_length(:host, max: 255)
        |> Repo.update()
    end
  end

  @doc """
  Delete a managed actor. Refuses when the actor still has API keys
  (revoke/delete those first), when it is a code-managed system actor, or
  when it is the identity actor of a user row (deleting it would silently
  nilify users.actor_id and break web attribution).
  """
  def delete_actor(%Actor{} = actor) do
    cond do
      Actor.system?(actor) ->
        {:error, :system_actor}

      Repo.exists?(from k in Dran.Accounts.ApiKey, where: k.actor_id == ^actor.id) ->
        {:error, :actor_has_api_keys}

      Repo.exists?(from u in Dran.Accounts.User, where: u.actor_id == ^actor.id) ->
        {:error, :actor_is_user_identity}

      true ->
        Repo.delete(actor)
    end
  end

  @doc """
  Count pages/tasks/memories attributed to this actor's name — the
  deletion-impact preview for the settings UI.
  """
  def attribution_count(%Actor{name: name}) do
    pages =
      from(p in "pages", where: p.created_by == ^name)
      |> Repo.aggregate(:count, :id)

    tasks =
      from(t in "tasks", where: t.created_by == ^name)
      |> Repo.aggregate(:count, :id)

    memories =
      from(m in "memories", where: m.created_by == ^name)
      |> Repo.aggregate(:count, :id)

    %{pages: pages, tasks: tasks, memories: memories}
  end

  # ── Internal ──

  defp maybe_where_kind(query, nil), do: query
  defp maybe_where_kind(query, kind), do: where(query, [a], a.kind == ^kind)

  # Override the action: system kind is never creatable via CRUD
  defp validate_not_system(changeset) do
    case Ecto.Changeset.get_field(changeset, :kind) do
      "system" ->
        Ecto.Changeset.add_error(changeset, :kind, "system actors are code-managed")

      _ ->
        changeset
    end
  end
end
