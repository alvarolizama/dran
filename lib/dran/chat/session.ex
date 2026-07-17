defmodule Dran.Chat.Session do
  @moduledoc """
  Schema for a persisted chat conversation.

  A chat session is scoped by (context_id, user) and stores the message
  history as a JSONB map `%{"items" => [...]}`. Each item is a map with
  `:role` (`"user"` | `"assistant"`), `:content`, and optional `:sources`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dran.Brain.Context

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  schema "chat_sessions" do
    field :user, :string, default: "anonymous"
    field :messages, :map, default: %{"items" => []}
    field :page_slug, :string

    belongs_to :context, Context

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/updating a chat session"
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:context_id, :user, :messages, :page_slug])
    |> validate_required([:context_id, :user])
  end
end
