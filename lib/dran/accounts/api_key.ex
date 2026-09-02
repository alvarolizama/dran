defmodule Dran.Accounts.ApiKey do
  @moduledoc """
  Context-scoped API key.

  An API key grants API/MCP access to N workspaces, each with a specific access
  level ('read' or 'write'). The key also inherits the role of its creator
  (stored as `created_by_user_id`).

  ## Security model

  * The plaintext token is shown ONCE at creation/regeneration time and
    never stored. Only the SHA-256 hash (`token_hash`) and a short display
    prefix (`token_prefix`, first 8 chars) are persisted.
  * Lookup by token hashes the presented token and matches `token_hash`.
  * Revoking sets `revoked_at`; revoked keys fail validation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :name, :string
    field :token_hash, :string
    field :token_prefix, :string
    field :revoked_at, :utc_datetime

    # Virtual — present only in the create/regenerate result, never persisted
    field :token, :string, virtual: true

    belongs_to :created_by_user, Dran.Accounts.User,
      type: :integer,
      foreign_key: :created_by_user_id

    # The actor this key is a credential FOR (kind: agent, normally).
    # Attribution (owner/created_by) resolves server-side from this actor.
    belongs_to :actor, Dran.Actors.Actor, type: :binary_id

    has_many :api_key_workspaces, Dran.Accounts.ApiKeyWorkspace

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating an API key"
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :token_hash, :token_prefix, :created_by_user_id, :actor_id])
    |> validate_required([:name, :token_hash, :token_prefix])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:actor_id)
  end

  @doc """
  Resolve the actor for a key name, creating a kind=agent actor on first
  sight (the old convention: key name IS the agent identity). Idempotent.
  """
  def ensure_actor_for_key_name(name) when is_binary(name) and name != "" do
    case Dran.Actors.get_actor_by_name(name) do
      nil ->
        case Dran.Actors.create_actor(%{name: name, kind: "agent"}) do
          {:ok, actor} -> actor
          {:error, _} -> Dran.Actors.get_actor_by_name(name)
        end

      %Dran.Actors.Actor{} = actor ->
        actor
    end
  end

  @doc "Generate a new random token (URL-safe, 43 chars)."
  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc "SHA-256 hex of a token — what gets stored and matched."
  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @doc "Short display prefix (first 8 chars) for UI listing."
  def prefix_of(token) when is_binary(token), do: String.slice(token, 0, 8)

  @doc "True when the key is active (not revoked)."
  def active?(%__MODULE__{revoked_at: nil}), do: true
  def active?(_), do: false

  @doc """
  Returns the access level for a given workspace_id, or nil.
  """
  def access_level_for(%__MODULE__{api_key_workspaces: workspaces}, workspace_id)
      when is_list(workspaces) do
    case Enum.find(workspaces, &(&1.workspace_id == workspace_id)) do
      nil -> nil
      akw -> akw.access_level
    end
  end

  @doc """
  Convenience: true if ANY of the key's workspaces has write access.
  """
  def write_access?(%__MODULE__{api_key_workspaces: %Ecto.Association.NotLoaded{}} = key) do
    key |> Dran.Repo.preload(api_key_workspaces: []) |> write_access?()
  end

  def write_access?(%__MODULE__{api_key_workspaces: workspaces}) when is_list(workspaces) do
    Enum.any?(workspaces, &(&1.access_level == "write"))
  end

  @doc """
  Convenience: true if the key has access to the given workspace.
  """
  def has_workspace?(%__MODULE__{api_key_workspaces: workspaces}, workspace_id)
      when is_list(workspaces) do
    Enum.any?(workspaces, &(&1.workspace_id == workspace_id))
  end
end
