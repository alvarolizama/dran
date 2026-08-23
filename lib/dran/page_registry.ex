defmodule Dran.PageRegistry do
  @moduledoc """
  Single source of truth for page type configuration.

  Consolidates what was previously spread across three modules:

  | What              | Old location        | Now               |
  |-------------------|---------------------|-------------------|
  | Capabilities      | `Dran.PageTypes`    | `PageRegistry`    |
  | Kinds             | `Dran.PageMeta`     | `PageRegistry`    |
  | Meta field defs   | `Dran.PageMeta`     | `PageRegistry`    |
  | Kind labels       | `Dran.PageMeta`     | `PageRegistry`    |
  | UI attrs          | `DranWeb.PageTypes` | `PageRegistry`    |

  ## Adding a kind

  1. Add the slug to the type's `:kinds` list in `@registry`.
  2. Add `"slug" => gettext("Label")` to `kind_labels/0`.
  3. Done — changeset validation, the editor UI, and `mcp_description/0`
     all read from here.

  ## Adding a meta field

  Add a tuple to the relevant `meta_fields/1` clause. Tuple shapes:

      {:select, "key", "Label", options}        # options = [{label, value}, ...]
      {:text,   "key", "Label", opts}           # opts = keyword list
      {:date,   "key", "Label"}                 # no opts
      {:date,   "key", "Label", condition: {:kind, "reminder"}}
      {:props,  "key", "Label"}

  ## What is NOT here

  The Ecto embedded schema (`Dran.PageMeta`) and its changeset stay in
  `PageMeta` — they are about validation, not configuration. `PageMeta`
  delegates to this registry for kinds and field definitions.

  Goals, Reports, and Collections are first-class entities in their own
  tables — they are not page types and are not configured here.
  """

  use Gettext, backend: DranWeb.Gettext

  # ── Master registry ────────────────────────────────────────────────
  #
  # One map, one place. Every consumer reads from here.
  #
  # Fields per type:
  #   :capabilities — what pages of this type can do
  #   :kinds        — valid meta.kind sub-types (nil = no kind validation)
  #   :ui           — presentation attrs (path, label, icon, plural)

  @registry %{
    "note" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds:
        ~w(thought journal idea meeting question quote reminder fleeting permanent moc comparison code recipe debug checklist summary decision draft template brainstorm todo plan project),
      ui: %{path: "notes", label: "Note", icon: "hero-document-text", plural: "Notes"}
    },
    "entity" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds:
        ~w(person company product tool place event language framework service hardware protocol course cluster asset),
      ui: %{path: "entities", label: "Entity", icon: "hero-user", plural: "Entities"}
    },
    "concept" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds:
        ~w(technique pattern discipline theory principle method model law heuristic strategy convention),
      ui: %{path: "concepts", label: "Concept", icon: "hero-light-bulb", plural: "Concepts"}
    },
    "reference" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds:
        ~w(article paper video podcast book document code design deliverable tweet course newsletter forum spec release website repo api guide interview),
      ui: %{path: "references", label: "Reference", icon: "hero-bookmark", plural: "References"}
    }
  }

  # Canonical ordering — preserves the historical `Page.all_types()` order
  # so UI surfaces that iterate the list keep their existing ordering.
  @types ~w(note entity concept reference)

  # ── Type accessors ─────────────────────────────────────────────────

  @doc "Ordered list of all valid page types."
  def types, do: @types

  @doc "The full registry map."
  def all, do: @registry

  @doc "Config for a single type (capabilities, kinds, ui). Returns nil if unknown."
  def config(type), do: Map.get(@registry, type)

  # ── Capability accessors ───────────────────────────────────────────

  @doc "True if pages of this type appear in the global graph."
  def graph?(type), do: capability(type, :graph)

  @doc "True if pages of this type are counted in the Journey timeline."
  def journey?(type), do: capability(type, :journey)

  @doc "True if pages of this type get embeddings and semantic relations."
  def embeddings?(type), do: capability(type, :embeddings)

  @doc "True if pages of this type can be created via the MCP `dran_create_page` tool."
  def mcp_create?(type), do: capability(type, :mcp_create)

  @doc "List of page types excluded from the global graph by default."
  def hidden_from_graph do
    for {type, %{capabilities: %{graph: false}}} <- @registry, do: type
  end

  @doc "List of page types excluded from the Journey timeline."
  def excluded_from_journey do
    for {type, %{capabilities: %{journey: false}}} <- @registry, do: type
  end

  # Unknown types default to `true` (permissive) — every type that exists
  # is in this registry by construction (`Page.@page_types` derives from
  # `types/0`), so the default only guards hypothetical future callers.
  defp capability(type, key) do
    case Map.get(@registry, type) do
      nil -> true
      %{capabilities: caps} -> Map.get(caps, key, true)
    end
  end

  # ── Kind accessors ─────────────────────────────────────────────────

  @doc "Valid kinds for a type, or nil if the type has no kind validation."
  def kinds(type) do
    case Map.get(@registry, type) do
      %{kinds: kinds} -> kinds
      _ -> nil
    end
  end

  # ── UI accessors ───────────────────────────────────────────────────

  @doc "UI attrs for a type (%{path, label, icon, plural}), or nil."
  def ui(type) do
    case Map.get(@registry, type) do
      %{ui: ui} -> ui
      _ -> nil
    end
  end

  @doc "URL path segment for a type (e.g. \"notes\")."
  def path(type) when is_binary(type) do
    case ui(type) do
      %{path: p} -> p
      nil -> to_string(type) <> "s"
    end
  end

  def path(_), do: "notes"

  @doc "Singular display label for a type, localized."
  def label(type) when is_binary(type) do
    case ui(type) do
      %{label: l} -> Gettext.gettext(DranWeb.Gettext, l)
      nil -> type |> to_string() |> String.capitalize()
    end
  end

  def label(other), do: other |> to_string() |> String.capitalize()

  @doc "Icon name for a type."
  def icon(type) when is_binary(type) do
    case ui(type) do
      %{icon: i} -> i
      nil -> "hero-document"
    end
  end

  def icon(_), do: "hero-document"

  @doc "Plural display label for a type, localized."
  def plural(type) when is_binary(type) do
    case ui(type) do
      %{plural: p} -> Gettext.gettext(DranWeb.Gettext, p)
      nil -> label(type) <> "s"
    end
  end

  def plural(other), do: label(other) <> "s"

  @doc "Resolves a URL path segment back to a page type (e.g. \"notes\" → \"note\")."
  def type_from_path(path_segment) when is_binary(path_segment) do
    Enum.find_value(@registry, fn {type, %{ui: %{path: p}}} ->
      if p == path_segment, do: type
    end)
  end

  # ── Meta field definitions ─────────────────────────────────────────
  #
  # What the editor renders per page type. Tuple shapes are identical to
  # what `Dran.PageMeta.meta_fields_for/1` returned — the normaliser in
  # `markdown_editor_components.ex` handles them unchanged.

  @doc """
  Returns the metadata field definitions for a given page type.

  ## Tuple shapes

      {:select, "key", "Label", [{label, value}, ...]}
      {:text,   "key", "Label", [placeholder: "...", condition: {:kind, "code"}]}
      {:date,   "key", "Label"}
      {:date,   "key", "Label", [condition: {:kind, "reminder"}]}
      {:props,  "key", "Label"}

  The `:condition` opt is a `{field, expected_value}` tuple that hides
  the field unless `meta[field]` equals `expected_value`.
  """
  def meta_fields(type)

  def meta_fields("note") do
    [
      {:select, "kind", gettext("Kind"), kind_options("note")},
      {:text, "language", gettext("Language"),
       placeholder: "elixir, python, typescript…", condition: {:kind, "code"}},
      {:date, "date", gettext("Date")},
      {:text, "author", gettext("Author")},
      {:date, "due_date", gettext("Due date"), condition: {:kind, "reminder"}},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("concept") do
    [
      {:select, "kind", gettext("Kind"), kind_options("concept")},
      {:text, "domain", gettext("Domain")},
      {:text, "parent_concept", gettext("Parent concept")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("entity") do
    [
      {:select, "kind", gettext("Kind"), kind_options("entity")},
      {:text, "location", gettext("Location")},
      {:text, "external_url", gettext("External URL")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("reference") do
    [
      {:select, "kind", gettext("Kind"), kind_options("reference")},
      {:text, "source_url", gettext("Source URL")},
      {:date, "published_at", gettext("Published at")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields(_), do: []

  defp kind_options(type) do
    kinds(type)
    |> Enum.map(&{kind_label(&1), &1})
  end

  # ── MCP description ────────────────────────────────────────────────
  #
  # Builds the page-type section of the `dran_create_page` MCP tool
  # description dynamically, so it never drifts from the registry.

  @doc """
  Returns a human-readable summary of page types and their kinds,
  suitable for embedding in MCP tool descriptions.
  """
  def mcp_description do
    for type <- @types, reduce: [] do
      acc ->
        kind_list = kinds(type) || []
        # Show first 7 kinds as a sample (matching the old hardcoded format)
        sample = Enum.take(kind_list, 7)
        acc ++ ["- #{type}: #{Enum.join(sample, ", ")}"]
    end
    |> Enum.join("\n")
  end

  @doc """
  Returns the enum list of page types for MCP JSON schema.
  """
  def mcp_enum, do: @types

  @doc """
  Returns the meta description string for MCP, keyed by type.
  """
  def mcp_meta_description do
    parts =
      for type <- @types do
        fields = meta_fields(type) |> extract_field_keys()
        "#{type}→{#{Enum.join(fields, ", ")}}"
      end

    "Type-specific metadata. Key fields by type: #{Enum.join(parts, ", ")}. " <>
      "**Custom properties**: use `meta.props` as a namespaced key-value bag " <>
      "for free-form metadata (e.g. `props: %{\\\"role\\\" => \\\"sales\\\", \\\"tier\\\" => \\\"vip\\\"}`). " <>
      "Props survive round-trips and are indexed by the existing meta GIN index."
  end

  defp extract_field_keys(fields) do
    fields
    |> Enum.map(fn
      {_type, key, _label} -> key
      {_type, key, _label, _opts} -> key
    end)
    |> Enum.reject(&(&1 == "props"))
  end

  # ── Kind labels (gettext extraction source) ───────────────────────
  #
  # Slugs → gettext'd display labels. Only the *display label* is
  # translated; the slug (DB value) is never passed to gettext.
  # This map is the single source of truth for display names.

  @doc "Returns the display label for a kind slug."
  def kind_label(slug) when is_binary(slug) do
    Map.fetch!(kind_labels(), slug)
  end

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
      "fleeting" => gettext("Fleeting"),
      "permanent" => gettext("Permanent"),
      "moc" => gettext("Map of Content"),
      "comparison" => gettext("Comparison"),
      "code" => gettext("Code"),
      "recipe" => gettext("Recipe"),
      "debug" => gettext("Debug"),
      "checklist" => gettext("Checklist"),
      "summary" => gettext("Summary"),
      "decision" => gettext("Decision"),
      "draft" => gettext("Draft"),
      "template" => gettext("Template"),
      "brainstorm" => gettext("Brainstorm"),
      "todo" => gettext("Todo"),
      "plan" => gettext("Plan"),
      "project" => gettext("Project"),
      # ── entity kinds ───────────────────────────────────────────────────
      "person" => gettext("Person"),
      "company" => gettext("Company"),
      "product" => gettext("Product"),
      "tool" => gettext("Tool"),
      "place" => gettext("Place"),
      "event" => gettext("Event"),
      "language" => gettext("Language"),
      "framework" => gettext("Framework"),
      "service" => gettext("Service"),
      "hardware" => gettext("Hardware"),
      "protocol" => gettext("Protocol"),
      "course" => gettext("Course"),
      "cluster" => gettext("Cluster"),
      "asset" => gettext("Asset"),
      # ── concept kinds ──────────────────────────────────────────────────
      "technique" => gettext("Technique"),
      "pattern" => gettext("Pattern"),
      "discipline" => gettext("Discipline"),
      "theory" => gettext("Theory"),
      "principle" => gettext("Principle"),
      "method" => gettext("Method"),
      "model" => gettext("Model"),
      "law" => gettext("Law"),
      "heuristic" => gettext("Heuristic"),
      "strategy" => gettext("Strategy"),
      "convention" => gettext("Convention"),
      # ── reference kinds ────────────────────────────────────────────────
      "article" => gettext("Article"),
      "paper" => gettext("Paper"),
      "video" => gettext("Video"),
      "podcast" => gettext("Podcast"),
      "book" => gettext("Book"),
      "document" => gettext("Document"),
      "design" => gettext("Design"),
      "deliverable" => gettext("Deliverable"),
      "tweet" => gettext("Tweet"),
      "newsletter" => gettext("Newsletter"),
      "forum" => gettext("Forum"),
      "spec" => gettext("Spec"),
      "release" => gettext("Release"),
      "website" => gettext("Website"),
      "repo" => gettext("Repository"),
      "api" => gettext("API"),
      "guide" => gettext("Guide"),
      "interview" => gettext("Interview")
    }
  end

  # ── Gettext extraction markers ─────────────────────────────────────
  #
  # UI labels are stored as English strings in @registry and translated
  # at runtime via Gettext.gettext/2, so the extractor never sees them.
  # Listing them here keeps them in the .pot/.po so translations survive
  # re-extraction. (Same pattern the old DranWeb.PageTypes used.)
  if false do
    # UI type labels + plurals
    gettext("Note")
    gettext("Concept")
    gettext("Entity")
    gettext("Reference")
    gettext("Notes")
    gettext("Concepts")
    gettext("Entities")
    gettext("References")
  end
end
