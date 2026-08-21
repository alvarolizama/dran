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
             :is_default,
             :visibility,
             :enabled_features,
             :inserted_at
           ]}
  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :disabled_page_types, {:array, :string}, default: []
    field :is_default, :boolean, default: false
    field :visibility, :string, default: "public"
    field :enabled_features, :map, default: %{}
    field :semantic_threshold_short, :float
    field :semantic_threshold_mid, :float
    field :semantic_threshold_long, :float
    field :entity_linker_enabled, :boolean
    field :agent_max_pages, :integer
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
      :enabled_features,
      :is_default,
      :visibility,
      :semantic_threshold_short,
      :semantic_threshold_mid,
      :semantic_threshold_long,
      :entity_linker_enabled,
      :agent_max_pages
    ])
    |> validate_subset(:disabled_page_types, Dran.Page.all_types())
    |> validate_inclusion(:visibility, ~w(public private))
    |> force_public_when_default()
    |> validate_number(:agent_max_pages, greater_than: 0)
    |> validate_threshold(:semantic_threshold_short)
    |> validate_threshold(:semantic_threshold_mid)
    |> validate_threshold(:semantic_threshold_long)
  end

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
  """
  def feature_enabled?(%__MODULE__{} = ws, feature) when is_atom(feature) or is_binary(feature) do
    feature_key = to_string(feature)

    case Map.get(ws.enabled_features, feature_key) do
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
end
