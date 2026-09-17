defmodule Dran.Accounts.ApiKey do
  @moduledoc """
  Context-scoped API key.

  An API key grants agent (plugin tool / REST) access to N workspaces, each with a specific access
  level ('read' or 'write'). The key also inherits the role of its creator
  (stored as `created_by_user_id`).

  ## Identity and attribution (W3)

  A key IS the agent identity: its `name` is the agent name. Creating a key
  no longer creates (or links) a row in `actors` — `kind: "agent"` actors are
  not created for keys anymore, and the `actor_id` column is a **legacy,
  nullable, read-only** leftover kept until the M3 drop (see
  `MakeApiKeyActorIdNullableAndBackfillOwner`). No application path writes or
  reads it.

  Server-side attribution for content written through a key:

    * `created_by` — the `X-Hermes-Agent` request header when present,
      otherwise the key `name` (resolved once, in
      `DranWeb.Router.require_api_token/2`, and consumed by
      `Dran.Auth.resolve_created_by/1`).
    * `owner_user_id` — `api_keys.created_by_user_id` (the user that created
      the key), consumed by `Dran.Auth.resolve_owner_user_id/1`.

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

    # LEGACY (W3, tiempo M1): the column stays nullable until the M3 drop
    # (?03) but the key no longer carries an agent actor. Kept in the schema
    # only so historical rows remain loadable; nothing in the application
    # writes or preloads it.
    belongs_to :actor, Dran.Actors.Actor, type: :binary_id

    has_many :api_key_workspaces, Dran.Accounts.ApiKeyWorkspace

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for creating an API key.

  `actor_id` is deliberately NOT cast: a key is its own agent identity (its
  `name`), and creating one never touches `actors`.
  """
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :token_hash, :token_prefix, :created_by_user_id])
    |> validate_required([:name, :token_hash, :token_prefix])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:created_by_user_id)
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
  Convenience: true if ANY of the key's workspaces has write access.
  """
  def write_access?(%__MODULE__{api_key_workspaces: %Ecto.Association.NotLoaded{}} = key) do
    key |> Dran.Repo.preload(api_key_workspaces: []) |> write_access?()
  end

  def write_access?(%__MODULE__{api_key_workspaces: workspaces}) when is_list(workspaces) do
    Enum.any?(workspaces, &(&1.access_level == "write"))
  end
end
