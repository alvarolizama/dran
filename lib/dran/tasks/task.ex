defmodule Dran.Tasks.Task do
  @moduledoc """
  La acción: una task que SIEMPRE pertenece a un goal.

  `goal_id` es `NOT NULL` con FK `on_delete: :delete_all` en el motor: una
  task no existe sin goal y borrar el goal borra sus tasks. La app no decide
  ese invariante (Constraint 11 / F37).

  ## Columnas del board

      backlog → todo → in_progress → done
                                    ↘ cancelled

  `position` ordena dentro de la columna (gap de 100). `lock_version` es el
  bloqueo optimista de `Dran.Tasks.move_task/2`.

  ## Visibilidad

  Una task NO declara `visibility` ni `owner_user_id`: hereda la del goal por
  join + `ContentVisibility.filter/3` (Constraint 12 / F2). Mover una task
  entre goals cambia quién la lee — es la visibilidad del destino.

  ## Checklist

  `checklist` es jsonb `[%{"text" => _, "done" => _}]`: texto que se tacha.
  No comparte ítem con el kanban (estado/asignado/fecha son columnas).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :goal_id,
             :title,
             :slug,
             :body,
             :status,
             :position,
             :priority,
             :due_date,
             :assignee_id,
             :checklist,
             :recurrence,
             :lock_version,
             :completed_at,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @statuses ~w(backlog todo in_progress done cancelled)
  @priorities ~w(low medium high urgent)
  @recurrences ~w(none daily weekly monthly)

  schema "tasks" do
    field :title, :string
    field :slug, :string
    field :body, :string, default: ""

    field :status, :string, default: "backlog"
    field :priority, :string
    field :position, :integer, default: 0
    field :due_date, :date

    field :checklist, {:array, :map}, default: []
    field :recurrence, :string, default: "none"

    field :lock_version, :integer, default: 1
    field :completed_at, :utc_datetime

    field :archived, :boolean, default: false

    # El contenedor: NOT NULL en la migración.
    belongs_to :goal, Dran.Goals.Goal

    # users usa PK serial, así que el tipo se sobreescribe.
    belongs_to :assignee, Dran.Accounts.User, foreign_key: :assignee_id, type: :id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de creación; coloca la task al final de su columna."
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> put_default_position()
  end

  @doc "Changeset de actualización."
  def update_changeset(%__MODULE__{} = task, attrs), do: changeset(task, attrs)

  @doc """
  Changeset de movimiento (estado, columna y/u goal) con bloqueo optimista.

  `optimistic_lock/2` convierte un `lock_version` desfasado en un error de
  changeset en `:lock_version`, que `Dran.Tasks.move_task/2` traduce a
  `{:error, :stale}`.
  """
  def move_changeset(%__MODULE__{} = task, attrs) do
    task
    |> cast(attrs, [:goal_id, :status, :position, :lock_version])
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end

  defp changeset(task, attrs) do
    task
    |> cast(attrs, [
      :goal_id,
      :title,
      :slug,
      :body,
      :status,
      :position,
      :priority,
      :due_date,
      :assignee_id,
      :checklist,
      :recurrence,
      :completed_at,
      :archived
    ])
    |> validate_required([:goal_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:recurrence, @recurrences)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:assignee_id)
    |> unique_constraint(:slug, name: :tasks_goal_id_slug_index)
  end

  # Si no llegó posición, va al final de su columna (max + 100). Solo en
  # creación (el caller aún no manda `position`).
  defp put_default_position(changeset) do
    case get_change(changeset, :position) do
      nil ->
        goal_id = get_field(changeset, :goal_id)
        status = get_field(changeset, :status, "backlog")

        if goal_id do
          put_change(changeset, :position, Dran.Tasks.max_position(goal_id, status) + 100)
        else
          changeset
        end

      _pos ->
        changeset
    end
  end

  @doc "Estados válidos (columnas del board)."
  def statuses, do: @statuses

  @doc "Prioridades válidas."
  def priorities, do: @priorities

  @doc "Opciones de recurrencia."
  def recurrences, do: @recurrences
end
