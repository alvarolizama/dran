defmodule Dran.Brain.Page do
  @moduledoc """
  The core entity of the second brain. Every piece of knowledge is a page.

  ## Page types

  - `note` — ephemeral thought, quick note, journal entry, meeting, idea
  - `comparison` — compare two or more entities against criteria
  - `plan` — a plan with a horizon (weekly, monthly, quarterly, yearly)
  - `todo` — action with kanban status (backlog → done)
  - `goal` — a goal with target date, team, and health
  - `entity` — something concrete (person, company, product, tool, place, event)
  - `concept` — abstract idea, technique, pattern, discipline, theory
  - `reference` — immutable external source (article, paper, video, podcast, book)
  - `artifact` — attached file (document, code, design, deliverable)

  ## Meta JSONB

  The `meta` field stores type-specific data, validated via `Dran.Brain.PageMeta`:
  - `todo`: `%{kanban_status: "backlog", goal_slug: "dran"}`
  - `note`: `%{kind: "journal", date: ~D[2026-06-19]}`
  - `reference`: `%{source_url: "https://...", kind: "article"}`

  ## Owner tracking

  Every page tracks who owns it and who created/updated it:
  - `owner` — the identity that owns this page (default: "system")
  - `created_by` — which agent/user created it (default: "system")
  - `updated_by` — which agent/user last updated it (nullable)
  - `on_behalf_of` — for whom an agent is acting (nullable)

  ## Search

  The `search_vector` column is a Postgres generated tsvector that
  combines `immutable_unaccent(title) + immutable_unaccent(body)` with
  Spanish stemming. It's maintained automatically by Postgres.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :context_id,
             :title,
             :slug,
             :body,
             :page_type,
             :summary,
             :tags,
             :meta,
             :kb_confidence,
             :kb_source_url,
             :kb_contested,
             :body_hash,
             :version,
             :owner,
             :created_by,
             :updated_by,
             :on_behalf_of,
             :inserted_at,
             :updated_at
           ]}

  @page_types ~w(note comparison plan todo goal entity concept reference artifact)
  @confidence_levels ~w(low medium high verified)

  schema "pages" do
    field :title, :string
    field :slug, :string
    field :body, :string, default: ""
    field :page_type, :string
    field :summary, :string
    field :tags, {:array, :string}, default: []
    field :meta, :map, default: %{}
    field :kb_confidence, :string
    field :kb_source_url, :string
    field :kb_contested, :boolean, default: false
    field :body_hash, :string
    field :version, :integer, default: 1

    # Embeddings
    field :embedding_hash, :string
    field :embedding, Pgvector.Ecto.Vector

    # Owner tracking
    field :owner, :string, default: "system"
    field :created_by, :string, default: "system"
    field :updated_by, :string
    field :on_behalf_of, :string

    # search_vector is a Postgres generated column — not mapped in Ecto.
    # It's maintained automatically by Postgres and used only in raw SQL queries.

    belongs_to :context, Dran.Brain.Context

    timestamps(type: :utc_datetime)
  end

  @doc "Base changeset for creating/updating a page"
  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :context_id,
      :title,
      :slug,
      :body,
      :page_type,
      :summary,
      :tags,
      :meta,
      :kb_confidence,
      :kb_source_url,
      :kb_contested,
      :owner,
      :created_by,
      :updated_by,
      :on_behalf_of
    ])
    |> validate_required([:context_id, :title, :slug, :page_type])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:page_type, @page_types)
    |> validate_inclusion(:kb_confidence, @confidence_levels)
    |> put_body_hash()
    |> unique_constraint([:context_id, :slug], name: :pages_context_id_slug_index)
  end

  @doc "Changeset for creating a new page"
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  @doc "Changeset for updating a page (increments version)"
  def update_changeset(page, attrs) do
    page
    |> changeset(attrs)
    |> put_version_bump(page)
  end

  @doc "List of all valid page types"
  def all_types, do: @page_types

  defp put_body_hash(%Ecto.Changeset{changes: %{body: body}} = changeset) when is_binary(body) do
    put_change(changeset, :body_hash, :crypto.hash(:sha256, body) |> Base.encode16(case: :lower))
  end

  defp put_body_hash(changeset), do: changeset

  defp put_version_bump(changeset, %{version: current}) do
    case get_change(changeset, :body) do
      nil -> changeset
      _ -> put_change(changeset, :version, current + 1)
    end
  end
end
