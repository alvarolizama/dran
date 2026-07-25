defmodule DranWeb.PageTypes do
  @moduledoc """
  Centralized page type mappings.

  A single source of truth for the 11 page types, each with its
  URL path segment, display label, icon, and plural label.
  """

  use Gettext, backend: DranWeb.Gettext

  @types %{
    "note" => %{path: "notes", label: "Note", icon: "hero-document-text", plural: "Notes"},
    "concept" => %{
      path: "concepts",
      label: "Concept",
      icon: "hero-light-bulb",
      plural: "Concepts"
    },
    "entity" => %{path: "entities", label: "Entity", icon: "hero-user", plural: "Entities"},
    "project" => %{
      path: "projects",
      label: "Project",
      icon: "hero-rocket-launch",
      plural: "Projects"
    },
    "reference" => %{
      path: "references",
      label: "Reference",
      icon: "hero-bookmark",
      plural: "References"
    },
    "goal" => %{path: "goals", label: "Goal", icon: "hero-flag", plural: "Goals"},
    "plan" => %{path: "plans", label: "Plan", icon: "hero-calendar-days", plural: "Plans"},
    "todo" => %{path: "todos", label: "Todo", icon: "hero-check-circle", plural: "Todos"},
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

  @doc "Returns the singular display label for a page type, localized (e.g. `\"Nota\"`)."
  def label(type) when is_binary(type) do
    case Map.get(@types, type) do
      %{label: l} -> Gettext.gettext(DranWeb.Gettext, l)
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

  @doc "Returns the plural display label for a page type, localized (e.g. `\"Notas\"`)."
  def plural(type) when is_binary(type) do
    case Map.get(@types, type) do
      %{plural: p} -> Gettext.gettext(DranWeb.Gettext, p)
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

  # Extraction markers — these msgids are looked up dynamically in label/1 and
  # plural/1 via Gettext.gettext/2, so the extractor never sees them. Listing
  # them here keeps them in the .pot/.po so translations survive re-extraction.
  if false do
    gettext("Note")
    gettext("Concept")
    gettext("Entity")
    gettext("Project")
    gettext("Reference")
    gettext("Goal")
    gettext("Plan")
    gettext("Todo")
gettext("Comparison")
    gettext("Query")
    gettext("Notes")
    gettext("Concepts")
    gettext("Entities")
    gettext("Projects")
    gettext("References")
    gettext("Goals")
    gettext("Plans")
    gettext("Todos")
gettext("Comparisons")
    gettext("Queries")
  end
end
