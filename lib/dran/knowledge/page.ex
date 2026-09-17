defmodule Dran.Knowledge.Page do
  @moduledoc """
  The core entity of the second brain. Every piece of knowledge is a page.

  ## Page types

  - `note` — free-form capture (journals, meeting notes, decisions, snippets)
  - `entity` — something concrete (person, company, product, tool, place)
  - `concept` — abstract idea (a technique, a discipline, a theory)
  - `reference` — immutable external source (article, paper, video, book)

  The registry (`Dran.PageRegistry`) is the single source of truth — this
  list is descriptive. See `Dran.PageTypes` for capabilities.

  Classification beyond the type lives in `meta.props` and tags; there is no
  reserved `meta.kind` key.

  ## Meta JSONB

  The `meta` field stores type-specific data, validated via `Dran.Knowledge.PageMeta`:
  - `reference`: `%{source_url: "https://...", published_at: ~D[2026-01-01]}`


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
             :workspace_id,
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
             :archived,
             :pinned,
             :created_by,
             :updated_by,
             :on_behalf_of,
             :owner_user_id,
             :agent_name,
             :inserted_at,
             :updated_at
           ]}

  # The canonical list of page types lives in Dran.PageTypes (single
  # source of truth, including per-type capabilities). This module-level list
  # is the BUILT-IN set only: it is descriptive for the type registry and for
  # `all_types/0`, never the write-path validator (see `changeset/2`).
  @page_types Dran.PageTypes.types()
  @confidence_levels ~w(low medium high verified)

  schema "knowledge_pages" do
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
    field :archived, :boolean, default: false
    field :pinned, :boolean, default: false

    # Embeddings
    field :embedding_hash, :string
    field :embedding, Pgvector.Ecto.Vector

    # Owner tracking — attribution resolves server-side from the actor
    # (see Dran.Actors). `owner` was dropped in the phase-2 migration:
    # it duplicated created_by with weaker guarantees.
    field :created_by, :string, default: "system"
    field :updated_by, :string
    field :on_behalf_of, :string

    # Ownership snapshot, injected server-side on every write (never
    # client-settable). NULL = workspace-wide content (system producers).
    field :owner_user_id, :integer
    # The Hermes profile that produced the write (`X-Hermes-Agent`).
    field :agent_name, :string

    # search_vector is a Postgres generated column — not mapped in Ecto.
    # It's maintained automatically by Postgres and used only in raw SQL queries.

    belongs_to :workspace, Dran.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc "Base changeset for creating/updating a page"
  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :workspace_id,
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
      :created_by,
      :updated_by,
      :on_behalf_of,
      :owner_user_id,
      :agent_name,
      :archived,
      :pinned
    ])
    |> validate_required([:workspace_id, :title, :slug, :page_type])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    # `page_type` is NOT validated here anymore (M4): the workspace's
    # effective types (4 built-in ∪ custom) are only known at the context
    # level, so the fail-closed check lives in `Knowledge.create_page/1` /
    # `Knowledge.update_page/2`. `@confidence_levels` stays static.
    |> validate_inclusion(:kb_confidence, @confidence_levels)
    |> put_body_hash()
    |> unique_constraint([:workspace_id, :slug], name: :knowledge_pages_workspace_id_slug_index)
  end

  @doc "Changeset for creating a new page"
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  @doc "Changeset for updating a page (increments version when body changes)"
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
