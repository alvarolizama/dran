defmodule Dran.Workspace do
  @moduledoc """
  A workspace is an isolated silo of knowledge (personal, work, projects).
  All pages and relations belong to a workspace.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :disabled_page_types,
             :workspace_page_types,
             :is_default,
             :visibility,
             :enabled_features,
             :share_memory,
             :share_pages,
             :inserted_at
           ]}
  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :disabled_page_types, {:array, :string}, default: []
    # Ordered list of workspace-declared custom page types (jsonb).
    # Shape: %{"slug" => _, "label" => _, "plural" => _, "path" => _,
    # "icon" => _, "color" => _, "meta_fields" => [...]}. `slug` and `path`
    # are explicit and unique within the workspace (see normalize_page_types/1).
    field :workspace_page_types, {:array, :map}, default: []
    field :is_default, :boolean, default: false
    field :visibility, :string, default: "public"
    field :enabled_features, :map, default: %{}
    field :semantic_threshold_short, :float
    field :semantic_threshold_mid, :float
    field :semantic_threshold_long, :float
    field :entity_linker_enabled, :boolean
    field :worker_max_pages, :integer
    field :summary_language, :string
    field :share_memory, :boolean, default: true
    field :share_pages, :boolean, default: true
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating a workspace"
  def changeset(context, attrs) do
    context
    |> cast(attrs, [:name, :slug, :is_default, :visibility])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 100)
    |> validate_length(:slug, max: 100)
    |> validate_inclusion(:visibility, ~w(public private))
    |> force_public_when_default()
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> unique_constraint(:is_default)
  end

  @doc "Changeset for updating settings like disabled page types, enabled features, and brain tuning"
  def settings_changeset(context, attrs) do
    context
    |> cast(attrs, [
      :disabled_page_types,
      :workspace_page_types,
      :enabled_features,
      :is_default,
      :visibility,
      :semantic_threshold_short,
      :semantic_threshold_mid,
      :semantic_threshold_long,
      :entity_linker_enabled,
      :worker_max_pages,
      :summary_language,
      :share_memory,
      :share_pages
    ])
    |> validate_page_types()
    |> validate_disabled_page_types()
    |> validate_inclusion(:visibility, ~w(public private))
    |> force_public_when_default()
    |> validate_number(:worker_max_pages, greater_than: 0)
    |> validate_inclusion(:summary_language, ~w(auto es en))
    |> validate_threshold(:semantic_threshold_short)
    |> validate_threshold(:semantic_threshold_mid)
    |> validate_threshold(:semantic_threshold_long)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Custom page types (workspace-declared)
  # ──────────────────────────────────────────────────────────────────────────
  #
  # `workspace_page_types` is an ORDERED jsonb list; each entry declares one
  # custom page type with an explicit `slug` and `path` (never a blind
  # pluralization). Both are unique within the workspace: a duplicate is a
  # validation error, not a silent dedupe. A slug that repeats one of the four
  # built-in types is rejected too — built-ins cannot be redefined.

  @custom_page_type_keys ~w(slug label plural path icon color meta_fields)
  @builtin_paths_map %{
    "note" => "notes",
    "entity" => "entities",
    "concept" => "concepts",
    "reference" => "references"
  }
  @default_custom_icon "hero-document-text"
  @default_custom_color "#94A3B8"
  @slug_format ~r/^[a-z0-9][a-z0-9_-]*$/

  @doc """
  The workspace's declared custom page types, normalized.

  Returns an ordered list of string-keyed maps with exactly the keys
  `slug`, `label`, `plural`, `path`, `icon`, `color`, `meta_fields`.
  Accepts a `%Workspace{}`, any map carrying the column, or `nil`.
  """
  def custom_page_types(nil), do: []

  def custom_page_types(ws) when is_map(ws) do
    ws
    |> Map.get(:workspace_page_types)
    |> normalize_page_types()
  end

  @doc "Slugs of the workspace's custom page types, in declaration order."
  def custom_page_type_slugs(ws) do
    ws |> custom_page_types() |> Enum.map(& &1["slug"])
  end

  @doc """
  Normalizes a raw `workspace_page_types` value into the canonical shape
  (string keys, JSON-safe values, defaults for the presentation fields).

  Not a validator: duplicates and malformed entries pass through untouched so
  `validate_page_types/1` can report them with a precise message instead of
  silently dropping data.
  """
  def normalize_page_types(nil), do: []

  def normalize_page_types(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn entry ->
      entry = stringify_keys(entry)

      %{
        "slug" => blank_to_nil(entry["slug"]),
        "label" => blank_to_nil(entry["label"]),
        "plural" => blank_to_nil(entry["plural"]),
        "path" => blank_to_nil(entry["path"]),
        "icon" => blank_to_nil(entry["icon"]) || @default_custom_icon,
        "color" => blank_to_nil(entry["color"]) || @default_custom_color,
        "meta_fields" => normalize_meta_fields(entry["meta_fields"])
      }
    end)
  end

  def normalize_page_types(_), do: []

  @doc "Ordered full definition of the workspace's custom types (only declared keys)."
  def page_type_defs(ws) do
    ws
    |> custom_page_types()
    |> Enum.map(fn entry ->
      Map.take(entry, @custom_page_type_keys)
      |> Map.put("builtin", false)
    end)
  end

  # meta_fields arrives either as Elixir tuples ({:text, "key", "Label", opts})
  # or as JSON arrays (["text", "key", "Label", opts]); jsonb stores arrays, so
  # tuples are converted and the editor side converts back. opts maps get
  # string keys — Jason cannot encode atoms or tuples.

  @doc """
  JSON-safe meta field definitions for a page type: the registry tuples
  converted to arrays plus string-keyed opts, ready for a JSON response.
  """
  def meta_fields_json(type) when is_binary(type) do
    type |> Dran.PageRegistry.meta_fields() |> normalize_meta_fields()
  end

  def meta_fields_json(_type), do: []

  defp normalize_meta_fields(list) when is_list(list) do
    list
    |> Enum.map(fn
      tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> Enum.map(&meta_field_part/1)
      list when is_list(list) -> Enum.map(list, &meta_field_part/1)
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_meta_fields(_other), do: []

  defp meta_field_part(part) when is_map(part), do: stringify_keys(part)
  defp meta_field_part(part) when is_atom(part) and not is_boolean(part), do: to_string(part)
  defp meta_field_part(part), do: part

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # `disabled_page_types` keeps working, but validates against the workspace's
  # EFFECTIVE types (4 built-in ∪ its own custom types) instead of the built-in
  # list alone — disabling a custom type must not break the saved list. The
  # subset check takes the union of the new custom types (if the changeset is
  # changing them) and the ones already persisted on the workspace.
  defp validate_disabled_page_types(changeset) do
    disabled = get_change(changeset, :disabled_page_types)

    if is_list(disabled) do
      validate_subset(changeset, :disabled_page_types, effective_types_for(changeset))
    else
      changeset
    end
  end

  defp effective_types_for(changeset) do
    custom =
      case get_change(changeset, :workspace_page_types) do
        nil -> get_field(changeset, :workspace_page_types) || []
        changed -> changed
      end

    builtin = Dran.Knowledge.Page.all_types()

    custom_slugs =
      custom
      |> normalize_page_types()
      |> Enum.map(& &1["slug"])

    builtin ++ (custom_slugs -- builtin)
  end

  # Validates the custom types: required slug/path, no duplicates (slug or
  # path), no collision with a built-in slug, and a slug that is a safe
  # identifier. All messages land on :workspace_page_types.
  defp validate_page_types(changeset) do
    entries = get_field(changeset, :workspace_page_types) || []

    if Enum.all?(entries, &is_map/1) do
      normalized = normalize_page_types(entries)

      changeset
      |> validate_custom_types_required(normalized)
      |> validate_custom_types_unique_slugs(normalized)
      |> validate_custom_types_unique_paths(normalized)
      |> validate_custom_types_slug_format(normalized)
      |> validate_custom_types_not_builtin(normalized)
    else
      add_error(
        changeset,
        :workspace_page_types,
        "must be a list of page type objects"
      )
    end
  end

  defp validate_custom_types_required(changeset, entries) do
    missing =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _i} -> is_nil(entry["slug"]) or is_nil(entry["path"]) end)
      |> Enum.map(fn {entry, i} ->
        "entry ##{i + 1} (#{entry["slug"] || entry["path"] || "?"}) requires both slug and path"
      end)

    if missing == [] do
      changeset
    else
      add_error(changeset, :workspace_page_types, Enum.join(missing, "; "))
    end
  end

  defp validate_custom_types_unique_slugs(changeset, entries) do
    duplicates =
      entries
      |> Enum.map(& &1["slug"])
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_slug, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [] do
      changeset
    else
      add_error(
        changeset,
        :workspace_page_types,
        "duplicate slug: #{Enum.join(duplicates, ", ")}"
      )
    end
  end

  defp validate_custom_types_unique_paths(changeset, entries) do
    duplicates =
      entries
      |> Enum.map(& &1["path"])
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_path, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [] do
      changeset
    else
      add_error(
        changeset,
        :workspace_page_types,
        "duplicate path: #{Enum.join(duplicates, ", ")}"
      )
    end
  end

  defp validate_custom_types_slug_format(changeset, entries) do
    bad =
      entries
      |> Enum.map(& &1["slug"])
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&Regex.match?(@slug_format, &1))

    if bad == [] do
      changeset
    else
      add_error(
        changeset,
        :workspace_page_types,
        "invalid slug (use lowercase letters, digits, _ or -): #{Enum.join(bad, ", ")}"
      )
    end
  end

  defp validate_custom_types_not_builtin(changeset, entries) do
    builtin = Map.keys(@builtin_paths_map)

    collisions =
      entries
      |> Enum.map(& &1["slug"])
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1 in builtin))
      |> Enum.uniq()

    if collisions == [] do
      changeset
    else
      add_error(
        changeset,
        :workspace_page_types,
        "cannot redefine built-in page type: #{Enum.join(collisions, ", ")}"
      )
    end
  end

  @doc """
  UI attributes for a page type in this workspace: `%{path, label, plural,
  icon, color}`. Custom types win over the built-in registry (they cannot
  collide by construction), so this is the workspace-aware replacement for
  `Dran.PageRegistry.ui/1` in surfaces that render a workspace's navigation.
  """
  def page_type_ui(ws, type) when is_binary(type) do
    case Enum.find(custom_page_types(ws), &(&1["slug"] == type)) do
      nil ->
        case Dran.PageRegistry.ui(type) do
          nil ->
            %{
              path: Map.get(@builtin_paths_map, type, type <> "s"),
              label: String.capitalize(type),
              plural: String.capitalize(type) <> "s",
              icon: @default_custom_icon,
              color: @default_custom_color
            }

          ui ->
            ui
        end

      custom ->
        %{
          path: custom["path"],
          label: custom["label"] || String.capitalize(type),
          plural: custom["plural"] || (custom["label"] || String.capitalize(type)) <> "s",
          icon: custom["icon"],
          color: custom["color"]
        }
    end
  end

  def page_type_ui(_ws, type), do: %{
    path: "pages",
    label: to_string(type),
    plural: to_string(type),
    icon: @default_custom_icon,
    color: @default_custom_color
  }

  @doc "URL path segment for a page type in this workspace."
  def page_type_path(ws, type), do: page_type_ui(ws, type).path

  @doc "Singular label for a page type in this workspace."
  def page_type_label(ws, type), do: page_type_ui(ws, type).label

  @doc "Plural label for a page type in this workspace."
  def page_type_plural(ws, type), do: page_type_ui(ws, type).plural

  @doc "Icon name for a page type in this workspace."
  def page_type_icon(ws, type), do: page_type_ui(ws, type).icon

  @doc "Node/legend color for a page type in this workspace."
  def page_type_color(ws, type), do: page_type_ui(ws, type).color

  @doc """
  Resolves a URL path segment back to a page type within a workspace —
  built-in paths first, then the workspace's custom `path` values.
  Returns `nil` for an unknown path (the caller 404s).
  """
  def page_type_by_path(ws, path_segment) when is_binary(path_segment) do
    case Dran.PageRegistry.type_from_path(path_segment) do
      nil -> Enum.find_value(custom_page_types(ws), fn e ->
               if e["path"] == path_segment, do: e["slug"]
             end)

      type ->
        type
    end
  end

  def page_type_by_path(_ws, _path), do: nil

  @doc "slug → path map for every effective type (server → graph hook handoff)."
  def type_paths(ws) do
    Map.new(Dran.Knowledge.effective_page_types(ws), fn type ->
      {type, page_type_path(ws, type)}
    end)
  end

  @doc """
  Ordered `{type, color}` pairs for every effective type (custom types use
  their declared color), with the non-page `"memory"` pseudo-type last.
  """
  def ordered_type_colors(ws) do
    colors =
      for type <- Dran.Knowledge.effective_page_types(ws) do
        {type, page_type_color(ws, type)}
      end

    colors ++ [{"memory", "#A78BFA"}]
  end

  @doc "Metadata field tuples for a custom type (built-ins fall back to the registry)."
  def page_type_meta_fields(ws, type) when is_binary(type) do
    case Enum.find(custom_page_types(ws), &(&1["slug"] == type)) do
      %{"meta_fields" => fields} when fields != [] ->
        Enum.map(fields, &to_meta_field_tuple/1)

      _ ->
        Dran.PageRegistry.meta_fields(type)
    end
  end

  def page_type_meta_fields(_ws, type), do: Dran.PageRegistry.meta_fields(type)

  # JSON array → the tuple shape the editor's normaliser expects.
  defp to_meta_field_tuple(list) when is_list(list), do: List.to_tuple(list)
  defp to_meta_field_tuple(other), do: other

  @doc """
  True when `page_type` is a declared custom type of this workspace.
  """
  def custom_page_type?(ws, page_type) when is_binary(page_type) do
    page_type in custom_page_type_slugs(ws)
  end

  def custom_page_type?(_ws, _page_type), do: false

  # Invariant (decided): a default workspace is ALWAYS public. Setting
  # is_default=true forces visibility to "public" so the unique partial
  # index (workspaces_is_default_index) can never hold a private default.
  defp force_public_when_default(changeset) do
    if get_field(changeset, :is_default) == true do
      put_change(changeset, :visibility, "public")
    else
      changeset
    end
  end

  # Semantic thresholds are cosine-distances in [0, 1]. Only validated when
  # present (nil = use the global default).
  defp validate_threshold(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      if is_number(value) and value >= 0 and value <= 1 do
        []
      else
        [{field, "must be between 0 and 1"}]
      end
    end)
  end

  @doc """
  Returns true if the feature is enabled.
  If enabled_features is empty (default), all features are ON.
  If the key exists and is false, the feature is OFF.

  Accepts a Workspace struct or any map with :enabled_features/:features key
  (defensive: LiveView assigns can carry a pre-rename struct across a hot
  code reload, which pattern-matches as a plain map).
  """
  def feature_enabled?(ws, feature)
      when is_map(ws) and (is_atom(feature) or is_binary(feature)) do
    feature_key = to_string(feature)
    features = ws.enabled_features || %{}

    case Map.get(features, feature_key) do
      nil -> true
      value -> value
    end
  end

  @doc """
  Returns the workspace tuning value if set, otherwise falls back to the global default.
  """
  def get_tuning(%__MODULE__{} = ws, key) do
    case Map.get(ws, key) do
      nil -> Dran.Settings.get(to_string(key))
      value -> value
    end
  end

  @doc """
  Language pin for LLM-generated summaries (page summaries, cluster
  summaries, agent memories) in this workspace.

  Returns `"es"` / `"en"` when pinned, or `nil` for `"auto"` (and for the
  default): the model then follows the language of the page/transcript it is
  summarizing, which is the historical behavior.
  """
  @spec summary_language(ws :: map() | nil) :: String.t() | nil
  def summary_language(nil), do: nil

  def summary_language(ws) when is_map(ws) do
    case ws.summary_language || Dran.Settings.get("summary_language") do
      lang when lang in ["es", "en"] -> lang
      _other -> nil
    end
  end

  @doc """
  Prompt suffix pinning the summary language, or `""` when auto.
  """
  @spec summary_language_instruction(ws :: map() | nil) :: String.t()
  def summary_language_instruction(ws) do
    case summary_language(ws) do
      nil -> ""
      "es" -> "Respond in Spanish. "
      "en" -> "Respond in English. "
    end
  end
end
