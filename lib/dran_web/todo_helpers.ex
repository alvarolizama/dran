defmodule DranWeb.TodoHelpers do
  @moduledoc """
  Shared meta accessors and formatting helpers for todo/kanban pages.

  All functions take a `%Page{}` struct (or any map with a `meta` field).
  `meta` is a JSONB map with string keys, e.g. `%{"kanban_status" => "today"}`.
  """

  @doc "Returns the kanban status, defaulting to `\"backlog\"`."
  def kanban_status(page) do
    case (page.meta || %{})["kanban_status"] do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  @doc "Returns the priority, defaulting to `\"medium\"`."
  def priority(page) do
    case (page.meta || %{})["priority"] do
      s when is_binary(s) and s != "" -> s
      _ -> "medium"
    end
  end

  @doc "Human-readable priority label."
  def priority_label(page) do
    case priority(page) do
      "urgent" -> "Urgent"
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      other -> other |> to_string() |> String.capitalize()
    end
  end

  @doc "Tailwind class string for a priority badge."
  def priority_class(page) do
    case priority(page) do
      "urgent" -> "bg-red-100 text-red-700"
      "high" -> "bg-orange-100 text-orange-700"
      "medium" -> "bg-blue-100 text-blue-700"
      "low" -> "bg-gray-100 text-gray-600"
      _ -> "bg-gray-100 text-gray-600"
    end
  end

  @doc "Returns the goal_slug stored in page meta (if any)."
  def goal_slug(page), do: (page.meta || %{})["goal_slug"]

  @doc "Returns the due_date stored in page meta (if any)."
  def due_date(page), do: (page.meta || %{})["due_date"]

  @doc "Returns true when the due_date has passed."
  def overdue?(page) do
    case due_date(page) do
      s when is_binary(s) and s != "" ->
        case Date.from_iso8601(s) do
          {:ok, d} -> Date.compare(d, Date.utc_today()) == :lt
          _ -> false
        end

      %Date{} = d ->
        Date.compare(d, Date.utc_today()) == :lt

      _ ->
        false
    end
  end

  @doc "Formats a due date value for display as `\"Mon DD\"`."
  def format_due(nil), do: ""
  def format_due(""), do: ""

  def format_due(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> Calendar.strftime(d, "%b %d")
      _ -> s
    end
  end

  def format_due(%Date{} = d), do: Calendar.strftime(d, "%b %d")
  def format_due(other), do: to_string(other)

  @doc "Tailwind class string for the due-date element, given an overdue? boolean."
  def due_date_class(true),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-red-600 font-medium"

  def due_date_class(false),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-base-content/60"

  @doc "Tailwind class for a kanban status button, highlighting the active status."
  def status_button_class(current, status, badge_class) when current == status,
    do:
      "px-2.5 py-1 text-xs rounded-full border transition #{badge_class} border-transparent font-semibold"

  def status_button_class(_current, _status, _badge_class),
    do:
      "px-2.5 py-1 text-xs rounded-full border transition border-base-300 text-base-content/60 hover:bg-base-200"

  @doc "Count items whose kanban status matches `status`."
  def column_count(items, status) do
    Enum.count(items, fn item -> kanban_status(item) == status end)
  end

  @doc "Filter items whose kanban status matches `status`."
  def column_items(items, status) do
    Enum.filter(items, fn item -> kanban_status(item) == status end)
  end
end
