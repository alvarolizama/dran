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
  use Gettext, backend: DranWeb.Gettext
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # Common
    field :kind, :string
    field :project_slug, :string
    field :goal_slug, :string
    field :plan_slug, :string

    # graph signals (computed by Dran.Graph)
    field :pagerank, :float
    field :community_id, :integer

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
  @plan_kinds ~w(personal coding business learning health finance other)
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
      :pagerank,
      :community_id,
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

  defp validate_kind(cs, type)
       when type in ~w(note entity concept reference artifact query plan) do
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
  defp kinds_for("plan"), do: @plan_kinds
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
  def plan_kinds, do: @plan_kinds
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
      [] ->
        nil

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
      [] ->
        nil

      list ->
        done = Enum.count(list, &(&1 == "done"))
        done / length(list)
    end
  end

  defp score_to_health(3), do: "green"
  defp score_to_health(2), do: "yellow"
  defp score_to_health(_), do: "red"

  @doc """
  Returns the metadata fields and their select options for a given page type.

  ## Modes

    * `:edit` (default) — the full field list used when editing an existing
      page. This is what the `<.meta_fields>` component renders today.
    * `:new` — a reduced field list for the creation form. Only `("goal",
      :new)` is filtered today: health and current_value/progress are
      excluded (they are derived/progress-tracking fields, not capture
      fields). All other types return their full `:edit` list in `:new`
      mode.

  The arity-1 form `meta_fields_for(type)` delegates to
  `meta_fields_for(type, :edit)` so existing callers (notably the
  `<.meta_fields>` component in `markdown_editor_components.ex`) keep
  working unchanged. The `:new` filtering for goals activates once that
  component gains a `:mode` attr in a later wave.
  """
  def meta_fields_for(type, mode \\ :edit)

  def meta_fields_for(type, :edit), do: meta_fields_edit(type)

  def meta_fields_for("goal", :new) do
    # Capture-only fields for goal creation: health, current_value and
    # progress are derived/tracking fields, so they are hidden on the
    # new-goal form.
    [
      {:text, "metric", gettext("Metric"), placeholder: "e.g. MRR, users, uptime"},
      {:number, "target_value", gettext("Target value"), step: "0.01"},
      {:text, "unit", gettext("Unit"), placeholder: "e.g. %, USD, users"},
      {:date, "start_date", gettext("Start date")},
      {:date, "target_date", gettext("Target date")},
      {:slug_select, "project_slug", gettext("Project"), type: "project"}
    ]
  end

  def meta_fields_for(type, :new), do: meta_fields_edit(type)

  defp meta_fields_edit("note") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@note_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:date, "date", gettext("Date")},
      {:text, "author", gettext("Author")},
      {:date, "due_date", gettext("Due date"), condition: {:kind, "reminder"}}
    ]
  end

  defp meta_fields_edit("concept") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@concept_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "domain", gettext("Domain")},
      {:text, "parent_concept", gettext("Parent concept")}
    ]
  end

  defp meta_fields_edit("entity") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@entity_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "location", gettext("Location")},
      {:text, "external_url", gettext("External URL")}
    ]
  end

  defp meta_fields_edit("reference") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@reference_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "source_url", gettext("Source URL")},
      {:date, "published_at", gettext("Published at")}
    ]
  end

  defp meta_fields_edit("artifact") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@artifact_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})}
    ]
  end

  defp meta_fields_edit("plan") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@plan_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:select, "horizon", gettext("Horizon"),
       Enum.map(@horizons, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:select, "status", gettext("Status"),
       Enum.map(@plan_statuses, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "period", gettext("Period")},
      {:date, "due_date", gettext("Due date")},
      {:slug_select, "goal_slug", gettext("Goal"), type: "goal"},
      {:slug_select, "project_slug", gettext("Project"), type: "project"}
    ]
  end

  defp meta_fields_edit("project") do
    # NOTE: health_source is intentionally omitted — it is an internal
    # detail defaulting to "derived" everywhere. Health itself stays
    # editable as a manual override.
    [
      {:select, "status", gettext("Status"),
       Enum.map(@project_statuses, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:select, "health", gettext("Health"),
       [{gettext("Green"), "green"}, {gettext("Yellow"), "yellow"}, {gettext("Red"), "red"}]},
      {:select, "priority", gettext("Priority"),
       [
         {gettext("Low"), "low"},
         {gettext("Medium"), "medium"},
         {gettext("High"), "high"},
         {gettext("Urgent"), "urgent"}
       ]},
      {:date, "start_date", gettext("Start date")},
      {:date, "target_date", gettext("Target date")}
    ]
  end

  defp meta_fields_edit("goal") do
    [
      {:select, "health", gettext("Health"),
       [{gettext("Green"), "green"}, {gettext("Yellow"), "yellow"}, {gettext("Red"), "red"}]},
      {:text, "metric", gettext("Metric"), placeholder: "e.g. MRR, users, uptime"},
      {:number, "target_value", gettext("Target value"), step: "0.01"},
      {:number, "current_value", gettext("Current value"), step: "0.01"},
      {:text, "unit", gettext("Unit"), placeholder: "e.g. %, USD, users"},
      {:number, "progress", gettext("Progress (0.0-1.0)"), step: "0.01", min: "0", max: "1"},
      {:date, "start_date", gettext("Start date")},
      {:date, "target_date", gettext("Target date")},
      {:slug_select, "project_slug", gettext("Project"), type: "project"}
    ]
  end

  defp meta_fields_edit("todo") do
    [
      {:select, "kanban_status", gettext("Status"),
       [
         {gettext("Backlog"), "backlog"},
         {gettext("This Week"), "this_week"},
         {gettext("Today"), "today"},
         {gettext("In Progress"), "in_progress"},
         {gettext("Done"), "done"},
         {gettext("Cancelled"), "cancelled"}
       ]},
      {:select, "priority", gettext("Priority"),
       [
         {gettext("Low"), "low"},
         {gettext("Medium"), "medium"},
         {gettext("High"), "high"},
         {gettext("Urgent"), "urgent"}
       ]},
      {:date, "due_date", gettext("Due date")},
      {:text, "assignee", gettext("Assignee"), placeholder: "alvaro, hermes, claude-code..."},
      {:slug_select, "project_slug", gettext("Project"), type: "project"},
      {:slug_select, "goal_slug", gettext("Goal"), type: "goal"},
      {:slug_select, "plan_slug", gettext("Plan"), type: "plan"}
    ]
  end

  defp meta_fields_edit("comparison"), do: []

  defp meta_fields_edit("query") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@query_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:select, "difficulty", gettext("Difficulty"),
       Enum.map(@query_difficulties, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:select, "answer_status", gettext("Status"),
       Enum.map(@query_statuses, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "answered_by", gettext("Answered by")}
    ]
  end

  defp meta_fields_edit(_), do: []

  # Humanize a kind/status/horizon slug for display. We keep this logic out of
  # the tuples above so the gettext extractor sees the *display* string (the
  # result of `humanize_kind/1` is not a literal, so `gettext/1` cannot be
  # applied to it inside a comprehension at compile time). Instead we list the
  # human-readable labels below and look them up by slug — that way every label
  # is a literal `gettext("...")` call the extractor can see.
  #
  # NOTE: The label lists in `kind_labels/0` below are the single source of
  # truth for display names. Slugs (`thought`, `backlog`, `low`, …) are NEVER
  # translated — they are DB values.
  defp humanize_kind(slug) when is_binary(slug) do
    Map.fetch!(kind_labels(), slug)
  end

  # Slugs → gettext'd display labels. Keep alphabetised by slug within each
  # group for easy scanning. Only the *display label* is translated; the slug
  # (DB value) stays as the second tuple element in the field definitions
  # above and is never passed to gettext.
  defp kind_labels do
    %{
      # ── note kinds ──────────────────────────────────────────────────────
      "thought" => gettext("Thought"),
      "journal" => gettext("Journal"),
      "idea" => gettext("Idea"),
      "meeting" => gettext("Meeting"),
      "question" => gettext("Question"),
      "quote" => gettext("Quote"),
      "reminder" => gettext("Reminder"),
      # ── entity kinds ───────────────────────────────────────────────────
      "person" => gettext("Person"),
      "company" => gettext("Company"),
      "product" => gettext("Product"),
      "tool" => gettext("Tool"),
      "place" => gettext("Place"),
      "event" => gettext("Event"),
      # ── concept kinds ──────────────────────────────────────────────────
      "technique" => gettext("Technique"),
      "pattern" => gettext("Pattern"),
      "discipline" => gettext("Discipline"),
      "theory" => gettext("Theory"),
      # ── reference kinds ────────────────────────────────────────────────
      "article" => gettext("Article"),
      "paper" => gettext("Paper"),
      "video" => gettext("Video"),
      "podcast" => gettext("Podcast"),
      "book" => gettext("Book"),
      # ── artifact kinds ─────────────────────────────────────────────────
      "document" => gettext("Document"),
      "code" => gettext("Code"),
      "design" => gettext("Design"),
      "deliverable" => gettext("Deliverable"),
      "file" => gettext("File"),
      # ── query kinds ─────────────────────────────────────────────────────
      "factual" => gettext("Factual"),
      "conceptual" => gettext("Conceptual"),
      "how_to" => gettext("How to"),
      "opinion" => gettext("Opinion"),
      # ── query difficulties ─────────────────────────────────────────────
      "simple" => gettext("Simple"),
      "intermediate" => gettext("Intermediate"),
      "advanced" => gettext("Advanced"),
      # ── query statuses ──────────────────────────────────────────────────
      "open" => gettext("Open"),
      "answered" => gettext("Answered"),
      "verified" => gettext("Verified"),
      # ── project statuses ────────────────────────────────────────────────
      "draft" => gettext("Draft"),
      "active" => gettext("Active"),
      "on_hold" => gettext("On hold"),
      "archived" => gettext("Archived"),
      # ── plan statuses (subset of project) ───────────────────────────────
      # 'done' is shared with kanban_statuses — defined there to avoid dupes.
      # ── kanban statuses ─────────────────────────────────────────────────
      "backlog" => gettext("Backlog"),
      "this_week" => gettext("This Week"),
      "today" => gettext("Today"),
      "in_progress" => gettext("In Progress"),
      "done" => gettext("Done"),
      "cancelled" => gettext("Cancelled"),
      # ── horizons ────────────────────────────────────────────────────────
      "weekly" => gettext("Weekly"),
      "monthly" => gettext("Monthly"),
      "quarterly" => gettext("Quarterly"),
      "yearly" => gettext("Yearly"),
      # ── plan kinds ──────────────────────────────────────────────────────
      "personal" => gettext("Personal"),
      "coding" => gettext("Coding"),
      "business" => gettext("Business"),
      "learning" => gettext("Learning"),
      "health" => gettext("Health"),
      "finance" => gettext("Finance"),
      "other" => gettext("Other")
    }
  end
end
