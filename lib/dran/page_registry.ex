defmodule Dran.PageRegistry do
  @moduledoc """
  Single source of truth for page type configuration.

  Consolidates what was previously spread across three modules:

  | What              | Old location        | Now               |
  |-------------------|---------------------|-------------------|
  | Capabilities      | `Dran.PageTypes`    | `PageRegistry`    |
  | Meta field defs   | `Dran.Knowledge.PageMeta`     | `PageRegistry`    |
  | UI attrs          | `DranWeb.PageTypes` | `PageRegistry`    |

  There are exactly four built-in page types (`note`, `entity`, `concept`,
  `reference`) and no sub-type vocabulary: a page is fully described by its
  type plus free-form `meta` fields and `meta.props`.

  ## Adding a meta field

  Add a tuple to the relevant `meta_fields/1` clause. Tuple shapes:

      {:text,  "key", "Label", opts}     # opts = keyword list
      {:date,  "key", "Label"}           # no opts
      {:props, "key", "Label"}

  ## What is NOT here

  The Ecto embedded schema (`Dran.Knowledge.PageMeta`) and its changeset stay in
  `PageMeta` — they are about validation, not configuration.

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
  #   :ui           — presentation attrs (path, label, icon, plural)

  @registry %{
    "note" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, agent_create: true},
      ui: %{
        path: "notes",
        label: "Note",
        icon: "hero-document-text",
        color: "#60A5FA",
        plural: "Notes"
      }
    },
    "entity" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, agent_create: true},
      ui: %{
        path: "entities",
        label: "Entity",
        icon: "hero-user",
        color: "#FB7185",
        plural: "Entities"
      }
    },
    "concept" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, agent_create: true},
      ui: %{
        path: "concepts",
        label: "Concept",
        icon: "hero-light-bulb",
        color: "#F59E0B",
        plural: "Concepts"
      }
    },
    "reference" => %{
      capabilities: %{graph: true, journey: true, embeddings: true, agent_create: true},
      ui: %{
        path: "references",
        label: "Reference",
        icon: "hero-bookmark",
        color: "#A3E635",
        plural: "References"
      }
    }
  }

  # Canonical ordering — sidebar/agent tools/docs iterate this list.
  @types ~w(note entity concept reference)

  # ── Type accessors ─────────────────────────────────────────────────

  @doc "Ordered list of all valid page types."
  def types, do: @types

  @doc "The full registry map."
  def all, do: @registry

  @doc "Config for a single type (capabilities, ui). Returns nil if unknown."
  def config(type), do: Map.get(@registry, type)

  # ── Capability accessors ───────────────────────────────────────────

  @doc "True if pages of this type appear in the global graph."
  def graph?(type), do: capability(type, :graph)

  @doc "True if pages of this type are counted in the Journey timeline."
  def journey?(type), do: capability(type, :journey)

  @doc "True if pages of this type get embeddings and semantic relations."
  def embeddings?(type), do: capability(type, :embeddings)

  @doc "True if pages of this type can be created via the `dran_create_page` plugin tool."
  def agent_create?(type), do: capability(type, :agent_create)

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

      {:text,  "key", "Label", [placeholder: "..."]}
      {:date,  "key", "Label"}
      {:props, "key", "Label"}
  """
  def meta_fields(type)

  def meta_fields("note") do
    [
      {:date, "date", gettext("Date")},
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
      {:text, "location", gettext("Location")},
      {:text, "external_url", gettext("External URL")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields("reference") do
    [
      {:text, "source_url", gettext("Source URL")},
      {:date, "published_at", gettext("Published at")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  def meta_fields(_), do: []

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
