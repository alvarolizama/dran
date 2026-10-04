defmodule Dran.Plans.Plan do
  @moduledoc """
  El CÓMO: un plan con sus pasos, como ENTIDAD propia.

  Un plan es una fila de `plans` — no una página de un tipo declarado: tiene
  `owner_user_id` + `visibility` (default `private`) y se lee por
  `Dran.ContentVisibility.filter/3` como goals, memoria, colecciones y reports.
  No cuelga de un goal (`goal_id` no existe): el vínculo, si lo hay, es una
  arista de `relations` (`plan` es un node type).

  ## Checklist

  `checklist` es jsonb ORDENADO `[%{"text" => _, "done" => _}]` — la MISMA forma
  y el mismo `Dran.Checklist.cast/1` que la task. No hay tabla `steps` ni
  `checklist_items`: tachar un ítem reescribe el array y no crea ni mueve tasks
  (Constraint 8). Cualquier entrada (lista de mapas, lista de binarios, el JSON
  serializado del editor) se normaliza en el changeset.

  ## Bloqueo optimista

  `lock_version` es del RMW del checklist (`Dran.Plans.toggle_checklist/3` y
  `set_checklist/3`): la reescritura del array es un read-modify-write, así que
  dos manos escribiendo a la vez no pueden pisarse en silencio. El changeset
  general (título, estado, fechas) NO toca `lock_version`, igual que en la task.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :title,
             :slug,
             :summary,
             :body,
             :status,
             :starts_on,
             :due_on,
             :checklist,
             :lock_version,
             :visibility,
             :owner_user_id,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @statuses ~w(draft active on_hold done archived)
  @visibilities ~w(private public shared)

  schema "plans" do
    field :title, :string
    field :slug, :string
    field :summary, :string
    field :body, :string, default: ""

    field :status, :string, default: "draft"
    field :starts_on, :date
    field :due_on, :date

    field :checklist, {:array, :map}, default: []

    field :lock_version, :integer, default: 1

    # Visibilidad por ítem, default privado (Constraint 2).
    field :visibility, :string, default: "private"

    # Dueño server-side; NULL = contenido de sistema.
    field :owner_user_id, :integer

    field :archived, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de creación/actualización del plan (sin tocar `lock_version`)."
  def changeset(plan, attrs) do
    plan
    |> cast(prepare_attrs(attrs), [
      :title,
      :slug,
      :summary,
      :body,
      :status,
      :starts_on,
      :due_on,
      :checklist,
      :visibility,
      :owner_user_id,
      :archived
    ])
    |> validate_required([:title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:visibility, @visibilities)
    |> unique_constraint(:slug, name: :plans_owner_user_id_slug_index)
  end

  @doc """
  Changeset del checklist: reescribe el array con bloqueo optimista.

  `optimistic_lock/2` convierte un `lock_version` desfasado en un error de
  changeset en ese campo, que `Dran.Plans` traduce a `{:error, :stale}`.
  """
  def checklist_changeset(plan, attrs) do
    plan
    |> cast(prepare_attrs(attrs), [:checklist, :lock_version])
    |> optimistic_lock(:lock_version)
  end

  @doc "Estados válidos de un plan."
  def statuses, do: @statuses

  @doc "Visibilidades válidas (la política única del contenido)."
  def visibilities, do: @visibilities

  # El checklist se NORMALIZA ANTES del cast: `{:array, :map}` no sabe castear
  # textos sueltos (`["uno", "dos"]`) ni el JSON que manda el editor, así que la
  # forma canónica se resuelve primero y el cast sólo ve `[%{text, done}]`. Una
  # sola forma para el plan y para la task.
  defp prepare_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, "checklist") || Map.get(attrs, :checklist) do
      nil -> attrs
      value -> Map.put(attrs, "checklist", Dran.Checklist.cast(value))
    end
  end

  defp prepare_attrs(attrs), do: attrs
end
