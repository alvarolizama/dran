defmodule Dran.Brain.PageMeta do
  @moduledoc """
  Embedded schema for validating the `meta` JSONB of a page.

  Each page type has a different set of meaningful meta fields. This module
  defines all of them in a single embedded schema and dispatches validation
  based on the page type.

  ## Usage

      changeset = PageMeta.changeset(%PageMeta{}, attrs, "todo")
      if changeset.valid?, do: ...
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # Common
    field :kind, :string
    field :project_slug, :string
    field :goal_slug, :string
    field :plan_slug, :string

    # note sub-types
    field :date, :date
    field :feasibility, :string
    field :impact, :string
    field :attendees, {:array, :string}
    field :resolved, :boolean
    field :source_ref, :string
    field :author, :string

    # comparison
    field :entities, {:array, :string}
    field :criteria, {:array, :string}
    field :verdict, :string

    # plan
    field :horizon, :string
    field :period, :string
    field :status, :string

    field :kanban_status, :string
    field :priority, :string
    field :due_date, :date
    field :remind_at, :utc_datetime
    field :acknowledged, :boolean
    field :completed_at, :utc_datetime
    field :assignee, :string

    # goal
    field :start_date, :date
    field :target_date, :date
    field :team, {:array, :string}
    field :health, :string
    field :metric, :string
    field :target_value, :float
    field :current_value, :float
    field :unit, :string
    field :progress, :float

    # project
    field :health_source, :string

    # entity
    field :aliases, {:array, :string}
    field :external_url, :string
    field :location, :string

    # concept
    field :domain, :string
    field :parent_concept, :string

    # reference
    field :source_url, :string
    field :published_at, :date
    field :content_hash, :string
    field :fetched_at, :utc_datetime

    # artifact
    field :filename, :string
    field :mime_type, :string
    field :size, :integer
    field :storage_path, :string
    field :sha256, :string
    field :version, :string

    # query
    field :difficulty, :string
    field :answer_status, :string
    field :answered_by, :string
  end

  @note_kinds ~w(thought journal idea meeting question quote reminder)
  @entity_kinds ~w(person company product tool place event)
  @concept_kinds ~w(technique pattern discipline theory)
  @reference_kinds ~w(article paper video podcast book)
  @artifact_kinds ~w(document code design deliverable file)
  @query_kinds ~w(factual conceptual how_to opinion)
  @kanban_statuses ~w(backlog this_week today in_progress done cancelled)
  @priorities ~w(low medium high urgent)
  @healths ~w(green yellow red)
  @horizons ~w(weekly monthly quarterly yearly)
  @query_difficulties ~w(simple intermediate advanced)
  @query_statuses ~w(open answered verified)
  @project_statuses ~w(draft active on_hold done archived)
  @plan_statuses ~w(draft active done archived)
  @health_sources ~w(manual derived)
  @health_scores %{"green" => 3, "yellow" => 2, "red" => 1}

  def changeset(meta, attrs, page_type) do
    meta
    |> cast(attrs, all_fields())
    |> validate_kind(page_type)
    |> validate_meta_for_type(page_type)
  end

  defp all_fields do
    [
      :kind,
      :project_slug,
      :goal_slug,
      :plan_slug,
      :date,
      :feasibility,
      :impact,
      :attendees,
      :resolved,
      :source_ref,
      :author,
      :entities,
      :criteria,
      :verdict,
      :horizon,
      :period,
      :status,
      :kanban_status,
      :priority,
      :due_date,
      :remind_at,
      :acknowledged,
      :completed_at,
      :assignee,
      :start_date,
      :target_date,
      :team,
      :health,
      :health_source,
      :metric,
      :target_value,
      :current_value,
      :unit,
      :progress,
      :aliases,
      :external_url,
      :location,
      :domain,
      :parent_concept,
      :source_url,
      :published_at,
      :content_hash,
      :fetched_at,
      :filename,
      :mime_type,
      :size,
      :storage_path,
      :sha256,
      :version,
      :difficulty,
      :answer_status,
      :answered_by
    ]
  end

  defp validate_kind(cs, type) when type in ~w(note entity concept reference artifact query) do
    kinds = kinds_for(type)

    if kinds do
      validate_inclusion(cs, :kind, kinds)
    else
      cs
    end
  end

  defp validate_kind(cs, _type), do: cs

  defp kinds_for("note"), do: @note_kinds
  defp kinds_for("entity"), do: @entity_kinds
  defp kinds_for("concept"), do: @concept_kinds
  defp kinds_for("reference"), do: @reference_kinds
  defp kinds_for("artifact"), do: @artifact_kinds
  defp kinds_for("query"), do: @query_kinds
  defp kinds_for(_), do: nil

  defp validate_meta_for_type(cs, "todo") do
    cs
    |> validate_inclusion(:kanban_status, @kanban_statuses)
    |> validate_inclusion(:priority, @priorities)
  end

  defp validate_meta_for_type(cs, "project") do
    cs
    |> validate_inclusion(:status, @project_statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:health, @healths)
    |> validate_inclusion(:health_source, @health_sources)
  end

  defp validate_meta_for_type(cs, "goal") do
    cs
    |> validate_inclusion(:health, @healths)
    |> validate_progress_range()
  end

  defp validate_meta_for_type(cs, "plan") do
    cs
    |> validate_inclusion(:horizon, @horizons)
    |> validate_inclusion(:status, @plan_statuses)
  end

  defp validate_meta_for_type(cs, "query") do
    cs
    |> validate_inclusion(:difficulty, @query_difficulties)
    |> validate_inclusion(:answer_status, @query_statuses)
  end

  defp validate_meta_for_type(cs, _type), do: cs

  defp validate_progress_range(cs) do
    case get_change(cs, :progress) do
      nil -> cs
      val when is_number(val) and val >= 0.0 and val <= 1.0 -> cs
      _ -> add_error(cs, :progress, "must be between 0.0 and 1.0")
    end
  end

  def note_kinds, do: @note_kinds
  def entity_kinds, do: @entity_kinds
  def concept_kinds, do: @concept_kinds
  def reference_kinds, do: @reference_kinds
  def artifact_kinds, do: @artifact_kinds
  def query_kinds, do: @query_kinds
  def kanban_statuses, do: @kanban_statuses
  def priorities, do: @priorities
  def healths, do: @healths
  def horizons, do: @horizons
  def plan_statuses, do: @plan_statuses
  def project_statuses, do: @project_statuses
  def health_sources, do: @health_sources
  def query_difficulties, do: @query_difficulties
  def query_statuses, do: @query_statuses

  @doc """
  Deriva el health de un project a partir del health de sus goals.
  Regla: promedio de scores (green=3, yellow=2, red=1) con floor.
  Devuelve nil si no hay goals (no se recalcula).
  """
  def derive_project_health([]), do: nil

  def derive_project_health(goal_healths) when is_list(goal_healths) do
    scores =
      goal_healths
      |> Enum.map(&Map.get(@health_scores, &1))
      |> Enum.reject(&is_nil/1)

    case scores do
      [] -> nil
      list ->
        avg = Enum.sum(list) / length(list)
        score_to_health(floor(avg))
    end
  end

  @doc """
  Calcula el progreso de un goal a partir de sus todos vinculados.
  Regla: (todos done) / (todos totales no cancelados).
  Devuelve nil si no hay todos (o si todos están cancelados).
  """
  def derive_goal_progress([]), do: nil

  def derive_goal_progress(todo_statuses) when is_list(todo_statuses) do
    relevant = Enum.reject(todo_statuses, &(&1 == "cancelled"))

    case relevant do
      [] -> nil
      list ->
        done = Enum.count(list, &(&1 == "done"))
        done / length(list)
    end
  end

  defp score_to_health(3), do: "green"
  defp score_to_health(2), do: "yellow"
  defp score_to_health(_), do: "red"

  @doc "Returns the metadata fields and their select options for a given page type."
  def meta_fields_for("note") do
    [
      {:select, "kind", "Kind", Enum.map(@note_kinds, &{String.capitalize(&1), &1})},
      {:date, "date", "Date"},
      {:text, "author", "Author"},
      {:date, "due_date", "Due date", condition: {:kind, "reminder"}}
    ]
  end

  def meta_fields_for("concept") do
    [
      {:select, "kind", "Kind", Enum.map(@concept_kinds, &{String.capitalize(&1), &1})},
      {:text, "domain", "Domain"},
      {:text, "parent_concept", "Parent concept"}
    ]
  end

  def meta_fields_for("entity") do
    [
      {:select, "kind", "Kind", Enum.map(@entity_kinds, &{String.capitalize(&1), &1})},
      {:text, "location", "Location"},
      {:text, "external_url", "External URL"}
    ]
  end

  def meta_fields_for("reference") do
    [
      {:select, "kind", "Kind", Enum.map(@reference_kinds, &{String.capitalize(&1), &1})},
      {:text, "source_url", "Source URL"},
      {:date, "published_at", "Published at"}
    ]
  end

  def meta_fields_for("artifact") do
    [
      {:select, "kind", "Kind", Enum.map(@artifact_kinds, &{String.capitalize(&1), &1})}
    ]
  end

  def meta_fields_for("plan") do
    [
      {:select, "horizon", "Horizon", Enum.map(@horizons, &{String.capitalize(&1), &1})},
      {:select, "status", "Status", Enum.map(@plan_statuses, &{String.capitalize(&1), &1})},
      {:text, "period", "Period"},
      {:date, "due_date", "Due date"},
      {:text, "goal_slug", "Goal slug"},
      {:text, "project_slug", "Project slug"}
    ]
  end

  def meta_fields_for("project") do
    [
      {:select, "status", "Status",
       Enum.map(@project_statuses, &{String.capitalize(&1), &1})},
      {:select, "health", "Health",
       [{"Green", "green"}, {"Yellow", "yellow"}, {"Red", "red"}]},
      {:select, "health_source", "Health source",
       [{"Manual (override)", "manual"}, {"Derived from goals", "derived"}]},
      {:select, "priority", "Priority",
       [{"Low", "low"}, {"Medium", "medium"}, {"High", "high"}, {"Urgent", "urgent"}]},
      {:date, "start_date", "Start date"},
      {:date, "target_date", "Target date"}
    ]
  end

  def meta_fields_for("goal") do
    [
      {:select, "health", "Health",
       [{"Green", "green"}, {"Yellow", "yellow"}, {"Red", "red"}]},
      {:text, "metric", "Metric", placeholder: "e.g. MRR, users, uptime"},
      {:number, "target_value", "Target value", step: "0.01"},
      {:number, "current_value", "Current value", step: "0.01"},
      {:text, "unit", "Unit", placeholder: "e.g. %, USD, users"},
      {:number, "progress", "Progress (0.0-1.0)", step: "0.01", min: "0", max: "1"},
      {:date, "start_date", "Start date"},
      {:date, "target_date", "Target date"},
      {:text, "project_slug", "Project slug"}
    ]
  end

  def meta_fields_for("todo") do
    [
      {:select, "kanban_status", "Status",
       [
         {"Backlog", "backlog"},
         {"This Week", "this_week"},
         {"Today", "today"},
         {"In Progress", "in_progress"},
         {"Done", "done"},
         {"Cancelled", "cancelled"}
       ]},
      {:select, "priority", "Priority",
       [{"Low", "low"}, {"Medium", "medium"}, {"High", "high"}, {"Urgent", "urgent"}]},
      {:date, "due_date", "Due date"},
      {:text, "project_slug", "Project slug"},
      {:text, "goal_slug", "Goal slug"},
      {:text, "plan_slug", "Plan slug"}
    ]
  end

  def meta_fields_for("comparison") do
    []
  end

  def meta_fields_for("query") do
    [
      {:select, "kind", "Kind", Enum.map(@query_kinds, &{String.capitalize(&1), &1})},
      {:select, "difficulty", "Difficulty",
       Enum.map(@query_difficulties, &{String.capitalize(&1), &1})},
      {:select, "answer_status", "Status",
       Enum.map(@query_statuses, &{String.capitalize(&1), &1})},
      {:text, "answered_by", "Answered by"}
    ]
  end

  def meta_fields_for(_), do: []
end
