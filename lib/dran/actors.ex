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

  @doc """
  List agent actors for the Agents management UI (users and system are
  automatic). Preloads api_keys + their workspaces so the Agents tab can
  render the access matrix without extra queries.
  """
  def list_managed_actors do
    Actor
    |> where([a], a.kind == "agent")
    |> order_by([a], asc: a.name)
    |> Repo.all()
    |> Repo.preload(api_keys: [api_key_workspaces: :workspace])
  end

  @doc """
  Resolve an actor by name. The attribution join key — server-side
  resolvers call this (cached by caller when hot).
  """
  def get_actor_by_name(name) when is_binary(name) do
    Repo.get_by(Actor, name: name)
  end

  @doc """
  Display labels for a batch of `created_by` values: TWO queries for the whole
  list, however long it is. One-by-one resolution inside a row component is the
  N+1 this exists to avoid.

  The stored attribution stays the IDENTIFIER — a user's email, an API key's
  name — because that is the join key and what the API returns. This is only
  what the SCREEN shows: the person's name when the identifier is a user's
  email, then the actor's `display_name`, and the identifier itself when there
  is nothing friendlier (key and system actors keep their name).
  """
  def creator_labels(names) when is_list(names) do
    names = names |> Enum.reject(&is_nil/1) |> Enum.uniq()

    labels =
      from(a in Actor, where: a.name in ^names, where: not is_nil(a.display_name))
      |> Repo.all()
      |> Map.new(&{&1.name, &1.display_name})

    # El nombre del usuario manda sobre el display_name del actor: es el campo
    # que la persona (o un admin) edita en la UI; el actor queda de respaldo.
    from(u in Dran.Accounts.User,
      where: u.email in ^names,
      where: not is_nil(u.name) and u.name != ""
    )
    |> Repo.all()
    |> Enum.reduce(labels, fn user, acc -> Map.put(acc, user.email, user.name) end)
  end

  def creator_labels(_names), do: %{}

  @doc "The label for one `created_by` value; the identifier itself if unknown."
  def creator_label(labels, name) when is_map(labels), do: Map.get(labels, name) || name
  def creator_label(_labels, name), do: name

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
  Count pages/memories attributed to this actor's name — the
  deletion-impact preview for the settings UI. One query per table,
  run concurrently.
  """
  def attribution_count(%Actor{name: name}) do
    pages_task =
      Task.async(fn ->
        from(p in "knowledge_pages", where: p.created_by == ^name)
        |> Repo.aggregate(:count, :id)
      end)

    memories =
      from(m in "memories", where: m.created_by == ^name)
      |> Repo.aggregate(:count, :id)

    %{pages: Task.await(pages_task), memories: memories}
  end

  # ── Internal ──

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
