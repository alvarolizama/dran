defmodule DranWeb.PageTypes do
  @moduledoc """
  Centralized page type mappings.

  A single source of truth for the 10 page types, each with its
  URL path segment, display label, icon, and plural label.
  """

  @types %{
    "note" => %{path: "notes", label: "Note", icon: "hero-document-text", plural: "Notes"},
    "concept" => %{
      path: "concepts",
      label: "Concept",
      icon: "hero-light-bulb",
      plural: "Concepts"
    },
    "entity" => %{path: "entities", label: "Entity", icon: "hero-user", plural: "Entities"},
    "reference" => %{
      path: "references",
      label: "Reference",
      icon: "hero-bookmark",
      plural: "References"
    },
    "goal" => %{path: "goals", label: "Goal", icon: "hero-flag", plural: "Goals"},
    "plan" => %{path: "plans", label: "Plan", icon: "hero-calendar-days", plural: "Plans"},
    "todo" => %{path: "todos", label: "Todo", icon: "hero-check-circle", plural: "Todos"},
    "artifact" => %{
      path: "artifacts",
      label: "Artifact",
      icon: "hero-paper-clip",
      plural: "Artifacts"
    },
    "comparison" => %{
      path: "comparisons",
      label: "Comparison",
      icon: "hero-scale",
      plural: "Comparisons"
    },
    "query" => %{
      path: "queries",
      label: "Query",
      icon: "hero-question-mark-circle",
      plural: "Queries"
    }
  }

  @doc "Returns the full types map."
  def all, do: @types

  @doc "Returns the URL path segment for a page type (e.g. `\"notes\"`)."
  def path(type) when is_binary(type) do
    case Map.get(@types, type) do
      %{path: p} -> p
      nil -> to_string(type) <> "s"
    end
  end

  def path(_), do: "notes"

  @doc "Returns the singular display label for a page type (e.g. `\"Note\"`)."
  def label(type) when is_binary(type) do
    case Map.get(@types, type) do
      %{label: l} -> l
      nil -> type |> to_string() |> String.capitalize()
    end
  end

  def label(other), do: other |> to_string() |> String.capitalize()

  @doc "Returns the icon name for a page type."
  def icon(type) when is_binary(type) do
    case Map.get(@types, type) do
      %{icon: i} -> i
      nil -> "hero-document"
    end
  end

  def icon(_), do: "hero-document"

  @doc "Returns the plural display label for a page type (e.g. `\"Notes\"`)."
  def plural(type) when is_binary(type) do
    case Map.get(@types, type) do
      %{plural: p} -> p
      nil -> label(type) <> "s"
    end
  end

  def plural(other), do: label(other) <> "s"

  @doc """
  Returns the show path for a page struct or map.

  ## Examples

      iex> DranWeb.PageTypes.page_show_path(%Page{page_type: "note", slug: "my-note"})
      "/notes/my-note"
  """
  def page_show_path(%Dran.Brain.Page{page_type: type, slug: slug})
      when is_binary(type) and is_binary(slug) do
    "/#{path(type)}/#{slug}"
  end

  def page_show_path(%{page_type: type, slug: slug})
      when is_binary(type) and is_binary(slug) do
    "/#{path(type)}/#{slug}"
  end

  def page_show_path(_), do: "#"
end
