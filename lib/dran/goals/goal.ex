defmodule Dran.Goals.Goal do
  @moduledoc """
  El PARA QUÉ: un contenedor de trabajo con horizonte, fechas y jerarquía.

  Un goal es una entidad propia (`goals`), no una página. Las tasks cuelgan
  de él con `goal_id NOT NULL` (el invariante del motor), y su progreso se
  DERIVA de esas tasks (done/total) — no hay columna de progreso guardada.
  `progress_manual` existe para el goal sin tasks y cubre ese caso.

  ## Visibilidad

  Igual que páginas, memoria, colecciones y reports: `visibility` (`private`
  por default) + `owner_user_id`. La lectura pasa por
  `Dran.ContentVisibility.filter/3`. Las tasks NO declaran visibilidad: la
  heredan de este goal por join.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :title,
             :slug,
             :summary,
             :body,
             :horizon,
             :starts_on,
             :due_on,
             :status,
             :parent_goal_id,
             :progress_manual,
             :pinned,
             :visibility,
             :owner_user_id,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @statuses ~w(draft active on_hold done archived)
  @horizons ~w(someday day week month quarter year)

  schema "goals" do
    field :title, :string
    field :slug, :string
    field :summary, :string
    field :body, :string, default: ""

    # El tiempo como campo, no como fila por período.
    field :horizon, :string
    field :starts_on, :date
    field :due_on, :date

    field :status, :string, default: "active"

    # NULL = derivado de las tasks; entero = override manual.
    field :progress_manual, :integer

    field :pinned, :boolean, default: false

    # Visibilidad por ítem, default privado (Constraint 2).
    field :visibility, :string, default: "private"

    # Dueño server-side; NULL = contenido de sistema (workspace-wide).
    field :owner_user_id, :integer

    field :archived, :boolean, default: false

    belongs_to :parent_goal, __MODULE__, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de creación/actualización de un goal."
  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [
      :title,
      :slug,
      :summary,
      :body,
      :horizon,
      :starts_on,
      :due_on,
      :status,
      :parent_goal_id,
      :progress_manual,
      :pinned,
      :visibility,
      :owner_user_id,
      :archived
    ])
    |> validate_required([:title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:horizon, @horizons)
    |> validate_inclusion(:visibility, ~w(private public shared))
    |> validate_number(:progress_manual,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> foreign_key_constraint(:parent_goal_id)
    |> unique_constraint(:slug, name: :goals_owner_user_id_slug_index)
  end

  @doc "Estados válidos de un goal."
  def statuses, do: @statuses

  @doc "Horizontes válidos."
  def horizons, do: @horizons
end
