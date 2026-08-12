defmodule Dran.Accounts.ApiKey do
  @moduledoc """
  Context-scoped API key, not tied to any user.

  A key grants API/MCP access to exactly ONE context. Unlike per-user tokens
  (`users.api_token`), these keys are standalone — ideal for integrations,
  scripts, or MCP clients that should only ever touch a single brain context.

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
    field :write_access, :boolean, default: false

    # Virtual — present only in the create/regenerate result, never persisted
    field :token, :string, virtual: true

    belongs_to :context, Dran.Brain.Context

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating an API key"
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :token_hash, :token_prefix, :context_id, :write_access])
    |> validate_required([:name, :token_hash, :token_prefix, :context_id])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:context_id)
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
end
