defmodule Dran.Task do
  @moduledoc """
  First-class task entity — the action item of the second brain.

  Tasks live in their own table (`tasks`), independent of pages. They exist
  standalone by default; linking a task to a goal or a page is opt-in via
  polymorphic `relations` (`Dran.Relation`, relation_type `part_of`,
  source_type `"task"`).

  ## Board columns (status)

      backlog → todo → in_progress → done
                                    ↘ cancelled

  Time scoping lives in `due_date` ("today" / "this week" are views over it,
  not columns).

  `position` orders tasks within a column (gap-based, default 100).

  ## Subtasks

  Subtasks are a checklist inside `meta`:

      %{checklist: [%{text: "Write outline", done: false}, ...]}

  Lightweight by design — not individually queried or linked.

  ## Recurrence

  When `recurrence != "none"`, completing a task (status → "done") triggers
  the automation context to clone it with the next due date (W5).

  ## Owner tracking

  Same convention as pages and goals: `owner`, `created_by`, `updated_by`,
  `on_behalf_of`.

  ## Optimistic locking

  `lock_version` is used by `Dran.Tasks.move_task/3` to prevent lost updates
  when two clients drag the same task concurrently.
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
             :summary,
             :status,
             :priority,
             :position,
             :due_date,
             :assignee_id,
             :assignee_actor_id,
             :meta,
             :recurrence,
             :completed_at,
             :archived,
             :created_by,
             :updated_by,
             :on_behalf_of,
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
    field :summary, :string

    field :status, :string, default: "backlog"
    field :priority, :string
    field :position, :integer, default: 0
    field :due_date, :date

    # assignee FK to users — users uses serial PK, so we override the FK type
    belongs_to :assignee, Dran.Accounts.User, foreign_key: :assignee_id, type: :id

    # Actor assignee — humans AND agents (the actor model); new writes go here.
    belongs_to :assignee_actor, Dran.Actors.Actor,
      foreign_key: :assignee_actor_id,
      type: :binary_id

    field :meta, :map, default: %{}
    field :recurrence, :string, default: "none"

    field :lock_version, :integer, default: 1
    field :completed_at, :utc_datetime

    field :archived, :boolean, default: false

    # Attribution — resolves server-side from the actor (Dran.Actors).
    # `owner` was dropped in the phase-2 migration. `creator_actor_id` is
    # the id-based attribution of the acting actor (F6); `created_by` is the
    # human-readable mirror (actor name / email) kept for display and API.
    field :created_by, :string, default: "system"
    field :updated_by, :string
    field :on_behalf_of, :string

    belongs_to :workspace, Dran.Workspace

    belongs_to :creator_actor, Dran.Actors.Actor,
      foreign_key: :creator_actor_id,
      type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new task"
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> put_default_position()
  end

  @doc "Changeset for updating a task (does NOT bump lock_version — Ecto does that via optimistic_lock)"
  def update_changeset(%__MODULE__{} = task, attrs) do
    task
    |> changeset(attrs)
  end

  @doc "Changeset for moving a task between columns / positions (used by move_task)"
  def move_changeset(%__MODULE__{} = task, attrs) do
    task
    |> cast(attrs, [:status, :position, :lock_version])
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end

  defp changeset(task, attrs) do
    task
    |> cast(attrs, [
      :workspace_id,
      :title,
      :slug,
      :body,
      :summary,
      :status,
      :priority,
      :position,
      :due_date,
      :assignee_id,
      :assignee_actor_id,
      :meta,
      :recurrence,
      :completed_at,
      :archived,
      :created_by,
      :creator_actor_id,
      :updated_by,
      :on_behalf_of
    ])
    |> validate_required([:workspace_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:recurrence, @recurrences)
    |> foreign_key_constraint(:assignee_actor_id)
    |> unique_constraint([:workspace_id, :slug], name: :tasks_workspace_id_slug_index)
  end

  # If no position was set, place it at the end of its column (max + 100).
  # Runs only on create (the caller does not pass a position yet).
  defp put_default_position(changeset) do
    case get_change(changeset, :position) do
      nil ->
        workspace_id = get_field(changeset, :workspace_id)
        status = get_field(changeset, :status, "backlog")

        if workspace_id do
          max_pos = Dran.Tasks.max_position(workspace_id, status)
          put_change(changeset, :position, max_pos + 100)
        else
          put_change(changeset, :position, 100)
        end

      _pos ->
        changeset
    end
  end

  @doc "List of valid statuses (board columns)"
  def statuses, do: @statuses

  @doc "List of valid priorities"
  def priorities, do: @priorities

  @doc "List of valid recurrence options"
  def recurrences, do: @recurrences
end
