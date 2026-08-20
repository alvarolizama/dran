defmodule Dran.PageMeta do
  @moduledoc """
  Embedded schema for validating the `meta` JSONB of a page.

  Each page type has a different set of meaningful meta fields. This module
  defines all of them in a single embedded schema and dispatches validation
  based on the page type.

  ## Usage

      changeset = PageMeta.changeset(%PageMeta{}, attrs, "note")
      if changeset.valid?, do: ...
  """

  use Ecto.Schema
  use Gettext, backend: DranWeb.Gettext
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # Common
    field :kind, :string

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
    field :language, :string

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

    # custom properties — namespaced free-form key-value bag for user metadata
    # (e.g. %{"role" => "sales", "tier" => "vip"}). Kept under :props so it
    # never collides with reserved top-level meta keys.
    field :props, :map
  end

  @note_kinds ~w(thought journal idea meeting question quote reminder fleeting permanent moc comparison code snippet recipe debug checklist outline summary decision draft template log brainstorm todo plan project)
  @entity_kinds ~w(person company product tool place event language framework service hardware protocol course community asset brand)
  @concept_kinds ~w(technique pattern discipline theory principle framework method model law heuristic strategy convention)
  @reference_kinds ~w(article paper video podcast book document code design deliverable file tweet docs course newsletter forum spec release website repo api guide interview talk)

  def changeset(meta, attrs, page_type) do
    meta
    |> cast(attrs, all_fields())
    |> validate_kind(page_type)
    |> validate_meta_for_type(page_type)
  end

  defp all_fields do
    [
      :kind,
      :pagerank,
      :community_id,
      :date,
      :feasibility,
      :impact,
      :attendees,
      :resolved,
      :source_ref,
      :author,
      :language,
      :aliases,
      :external_url,
      :location,
      :domain,
      :parent_concept,
      :source_url,
      :published_at,
      :content_hash,
      :fetched_at,
      :props
    ]
  end

  defp validate_kind(cs, type)
       when type in ~w(note entity concept reference) do
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
  defp kinds_for(_), do: nil

  defp validate_meta_for_type(cs, _type), do: cs

  def note_kinds, do: @note_kinds
  def entity_kinds, do: @entity_kinds
  def concept_kinds, do: @concept_kinds
  def reference_kinds, do: @reference_kinds

  @doc """
  Returns the metadata fields and their select options for a given page type.

  ## Modes

    * `:edit` (default) — the full field list used when editing an existing
      page. This is what the `<.meta_fields>` component renders today.
    * `:new` — same as `:edit` for the remaining page types.

  The arity-1 form `meta_fields_for(type)` delegates to
  `meta_fields_for(type, :edit)` so existing callers (notably the
  `<.meta_fields>` component in `markdown_editor_components.ex`) keep
  working unchanged.
  """
  def meta_fields_for(type, mode \\ :edit)

  def meta_fields_for(type, :edit), do: meta_fields_edit(type)

  def meta_fields_for(type, :new), do: meta_fields_edit(type)

  defp meta_fields_edit("note") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@note_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "language", gettext("Language"),
       placeholder: "elixir, python, typescript…", condition: {:kind, "code"}},
      {:date, "date", gettext("Date")},
      {:text, "author", gettext("Author")},
      {:date, "due_date", gettext("Due date"), condition: {:kind, "reminder"}},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  defp meta_fields_edit("concept") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@concept_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "domain", gettext("Domain")},
      {:text, "parent_concept", gettext("Parent concept")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  defp meta_fields_edit("entity") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@entity_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "location", gettext("Location")},
      {:text, "external_url", gettext("External URL")},
      {:props, "props", gettext("Custom properties")}
    ]
  end

  defp meta_fields_edit("reference") do
    [
      {:select, "kind", gettext("Kind"),
       Enum.map(@reference_kinds, &{Gettext.gettext(DranWeb.Gettext, humanize_kind(&1)), &1})},
      {:text, "source_url", gettext("Source URL")},
      {:date, "published_at", gettext("Published at")},
      {:props, "props", gettext("Custom properties")}
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
      "fleeting" => gettext("Fleeting"),
      "permanent" => gettext("Permanent"),
      "moc" => gettext("Map of Content"),
      "comparison" => gettext("Comparison"),
      "code" => gettext("Code"),
      "snippet" => gettext("Snippet"),
      "recipe" => gettext("Recipe"),
      "debug" => gettext("Debug"),
      "checklist" => gettext("Checklist"),
      "outline" => gettext("Outline"),
      "summary" => gettext("Summary"),
      "decision" => gettext("Decision"),
      "draft" => gettext("Draft"),
      "template" => gettext("Template"),
      "log" => gettext("Log"),
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
      "community" => gettext("Community"),
      "asset" => gettext("Asset"),
      "brand" => gettext("Brand"),
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
      "file" => gettext("File"),
      "tweet" => gettext("Tweet"),
      "docs" => gettext("Docs"),
      "newsletter" => gettext("Newsletter"),
      "forum" => gettext("Forum"),
      "spec" => gettext("Spec"),
      "release" => gettext("Release"),
      "website" => gettext("Website"),
      "repo" => gettext("Repository"),
      "api" => gettext("API"),
      "guide" => gettext("Guide"),
      "interview" => gettext("Interview"),
      "talk" => gettext("Talk")
    }
  end
end
