defmodule Dran.PageRegistry do
  @moduledoc """
  Single source of truth for page type configuration.

  Consolidates what was previously spread across three modules:

  | What              | Old location        | Now               |
  |-------------------|---------------------|-------------------|
  | Capabilities      | `Dran.PageTypes`    | `PageRegistry`    |
  | Kinds             | `Dran.Knowledge.PageMeta`     | `PageRegistry`    |
  | Meta field defs   | `Dran.Knowledge.PageMeta`     | `PageRegistry`    |
  | Kind labels       | `Dran.Knowledge.PageMeta`     | `PageRegistry`    |
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

  The Ecto embedded schema (`Dran.Knowledge.PageMeta`) and its changeset stay in
  `PageMeta` — they are about validation, not configuration. `PageMeta`
  delegates to this registry for kinds and field definitions.

  Reports, and Collections are first-class entities in their own
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
      kinds: nil,
      ui: %{
        path: "notes",
        label: "Note",
        icon: "hero-document-text",
        color: "#60A5FA",
        plural: "Notes"
      }
    },
    "idea" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds: ~w(idea question hypothesis spark),
      ui: %{
        path: "ideas",
        label: "Idea",
        icon: "hero-light-bulb",
        color: "#F472B6",
        plural: "Ideas"
      }
    },
    "project" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds: ~w(project plan goal milestone),
      ui: %{
        path: "projects",
        label: "Project",
        icon: "hero-rocket-launch",
        color: "#34D399",
        plural: "Projects"
      }
    },
    "knowledge" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds: ~w(quote summary highlight excerpt),
      ui: %{
        path: "knowledge",
        label: "Knowledge",
        icon: "hero-book-open",
        color: "#FBBF24",
        plural: "Knowledge"
      }
    },
    "technical" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds: ~w(code snippet debug recipe config command template pattern method),
      ui: %{
        path: "technical",
        label: "Technical",
        icon: "hero-code-bracket",
        color: "#22D3EE",
        plural: "Technical"
      }
    },
    "entity" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds: ~w(person company product tool place event language framework hardware protocol),
      ui: %{
        path: "entities",
        label: "Entity",
        icon: "hero-user",
        color: "#FB7185",
        plural: "Entities"
      }
    },
    "concept" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds: nil,
      ui: %{
        path: "concepts",
        label: "Concept",
        icon: "hero-light-bulb",
        color: "#F59E0B",
        plural: "Concepts"
      }
    },
    "reference" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, mcp_create: true},
      kinds: ~w(article paper video podcast book newsletter spec code release website repo api),
      ui: %{
        path: "references",
        label: "Reference",
        icon: "hero-bookmark",
        color: "#A3E635",
        plural: "References"
      }
    }
  }

  # Canonical ordering — sidebar/MCP/docs iterate this list.
  @types ~w(note idea project knowledge technical entity concept reference)

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

  @doc "UI attrs for a type (%{path, label, icon, color, plural}), or nil."
  def ui(type) do
    case Map.get(@registry, type) do
      %{ui: ui} -> ui
      _ -> nil
    end
  end

  @doc """
  Node color per page type (graph views), plus the non-page `"memory"`
  pseudo-type. Map form — for lookups.
  """
  def type_colors do
    Map.new(ordered_type_colors())
  end

  @doc """
  Same colors as `type_colors/0` but as an ordered keyword list: registry
  canonical order with `"memory"` last — graph legends use this so their
  order matches the sidebar.
  """
  def ordered_type_colors do
    colors =
      for type <- @types,
          %{ui: %{color: c}} <- [Map.get(@registry, type, %{})] do
        {type, c}
      end

    colors ++ [{"memory", "#A78BFA"}]
  end

  @doc "Node color for a single type (or nil for unknown types)."
  def type_color(type), do: Map.get(type_colors(), type)

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
  # what `Dran.Knowledge.PageMeta.meta_fields_for/1` returned — the normaliser in
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
      {:date, "date", gettext("Date")},
      {:date, "due_date", gettext("Due date"), condition: {:kind, "reminder"}},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("idea") do
    [
      {:select, "kind", gettext("Kind"), kind_options("idea")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("project") do
    [
      {:select, "kind", gettext("Kind"), kind_options("project")},
      {:select, "horizon", gettext("Horizon"),
       [
         {gettext("Weekly"), "weekly"},
         {gettext("Monthly"), "monthly"},
         {gettext("Quarterly"), "quarterly"},
         {gettext("Yearly"), "yearly"}
       ]},
      {:select, "status", gettext("Status"),
       [
         {gettext("Draft"), "draft"},
         {gettext("Active"), "active"},
         {gettext("On hold"), "on_hold"},
         {gettext("Done"), "done"}
       ]},
      {:date, "due_date", gettext("Due date")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("knowledge") do
    [
      {:select, "kind", gettext("Kind"), kind_options("knowledge")},
      {:text, "source_url", gettext("Source URL")},
      {:date, "date", gettext("Date")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("technical") do
    [
      {:select, "kind", gettext("Kind"), kind_options("technical")},
      {:text, "language", gettext("Language"),
       placeholder: "elixir, python, typescript…", condition: {:kind, "code"}},
      {:text, "version", gettext("Version")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("concept") do
    [
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
      # ── note kinds (free — kept for display of legacy data) ────────────
      "journal" => gettext("Journal"),
      "meeting" => gettext("Meeting"),
      "reminder" => gettext("Reminder"),
      "decision" => gettext("Decision"),
      "technical" => gettext("Technical"),
      # ── idea kinds ──────────────────────────────────────────────────────
      "idea" => gettext("Idea"),
      "question" => gettext("Question"),
      "hypothesis" => gettext("Hypothesis"),
      "spark" => gettext("Spark"),
      # ── project kinds ───────────────────────────────────────────────────
      "project" => gettext("Project"),
      "plan" => gettext("Plan"),
      "goal" => gettext("Goal"),
      "milestone" => gettext("Milestone"),
      # ── knowledge kinds ─────────────────────────────────────────────────
      "quote" => gettext("Quote"),
      "summary" => gettext("Summary"),
      "highlight" => gettext("Highlight"),
      "excerpt" => gettext("Excerpt"),
      # ── technical kinds ─────────────────────────────────────────────────
      "code" => gettext("Code"),
      "snippet" => gettext("Snippet"),
      "debug" => gettext("Debug"),
      "recipe" => gettext("Recipe"),
      "config" => gettext("Config"),
      "command" => gettext("Command"),
      "template" => gettext("Template"),
      "pattern" => gettext("Pattern"),
      "method" => gettext("Method"),
      # ── entity kinds ───────────────────────────────────────────────────
      "person" => gettext("Person"),
      "company" => gettext("Company"),
      "product" => gettext("Product"),
      "tool" => gettext("Tool"),
      "place" => gettext("Place"),
      "event" => gettext("Event"),
      "language" => gettext("Language"),
      "framework" => gettext("Framework"),
      "hardware" => gettext("Hardware"),
      "protocol" => gettext("Protocol"),
      # ── concept kinds (free — kept for display of legacy data) ─────────
      "technique" => gettext("Technique"),
      "discipline" => gettext("Discipline"),
      "theory" => gettext("Theory"),
      "principle" => gettext("Principle"),
      "model" => gettext("Model"),
      "law" => gettext("Law"),
      # ── reference kinds ────────────────────────────────────────────────
      "article" => gettext("Article"),
      "paper" => gettext("Paper"),
      "video" => gettext("Video"),
      "podcast" => gettext("Podcast"),
      "book" => gettext("Book"),
      "newsletter" => gettext("Newsletter"),
      "spec" => gettext("Spec"),
      "release" => gettext("Release"),
      "website" => gettext("Website"),
      "repo" => gettext("Repository"),
      "api" => gettext("API")
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
    gettext("Idea")
    gettext("Project")
    gettext("Knowledge")
    gettext("Technical")
    gettext("Concept")
    gettext("Entity")
    gettext("Reference")
    gettext("Notes")
    gettext("Ideas")
    gettext("Projects")
    gettext("Knowledge Plural")
    gettext("Technical Plural")
    gettext("Concepts")
    gettext("Entities")
    gettext("References")
  end
end
