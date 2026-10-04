defmodule Dran.Skills.Skill do
  @moduledoc """
  El skill: INSTRUCCIONES que un agente conectado por API descubre y carga por
  tool.

  No es contenido de lectura: vive en su propia tabla (`skills`), no entra al
  grafo, a la búsqueda semántica ni a los workers, y su identificador **no es
  renombrable** — el `slug` es la dirección del wire y renombrarlo deja en
  contexto a quien lo tenga cargado.

  ## Visibilidad

  Igual que páginas, memoria, goals y planes: `visibility` (`private` por
  default) + `owner_user_id`. La lectura pasa por
  `Dran.ContentVisibility.filter(scope, :skill)` en el punto único; el dueño se
  resuelve server-side y NUNCA sale del body.

  ## El contrato de wire

  `name` + `description` (≤ 60) + `body` + `version` + `content_hash`. El
  changeset es la ÚNICA puerta de validación: la web y `dran_skill_save` pasan
  por acá, así que la regla no se puede implementar dos veces distinto. La
  descripción se valida al guardar (422), nunca se trunca al servir.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}

  @derive {Jason.Encoder,
           only: [
             :id,
             :slug,
             :name,
             :description,
             :body,
             :version,
             :content_hash,
             :visibility,
             :owner_user_id,
             :inserted_at,
             :updated_at
           ]}

  # El identificador del wire: minúsculas, con dígitos, `_` y `-`.
  @name_format ~r/^[a-z][a-z0-9_-]*$/
  @name_max 64
  @description_max 60
  @body_min 1
  @body_max 100_000
  @visibilities ~w(private public shared)

  schema "skills" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :body, :string, default: ""
    field :version, :integer, default: 1
    field :content_hash, :string

    # Visibilidad por ítem, default privado.
    field :visibility, :string, default: "private"

    # Dueño server-side; NULL = contenido de sistema (workspace-wide).
    field :owner_user_id, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset de creación/actualización de un skill.

  `owner_user_id` y `visibility` son datos server-side: el dueño lo resuelve el
  caller (nunca el body) y el destino lo traduce `Dran.Sharing.apply_scope/3`.
  El `content_hash` se recalcula sólo cuando el CUERPO cambió — es la señal de
  la que cuelga el `unchanged` del agente.
  """
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:slug, :name, :description, :body, :visibility, :owner_user_id])
    |> validate_required([:slug, :name, :description, :body])
    |> validate_format(:slug, @name_format, message: name_format_message())
    |> validate_format(:name, @name_format, message: name_format_message())
    |> validate_length(:slug, max: @name_max)
    |> validate_length(:name, max: @name_max)
    |> validate_length(:description, max: @description_max)
    |> validate_length(:body, min: @body_min, max: @body_max)
    |> validate_inclusion(:visibility, @visibilities)
    |> put_content_hash()
    |> unique_constraint(:slug, name: :skills_owner_user_id_slug_index)
  end

  @doc "El hash del CUERPO de un skill: sha256 en hex minúsculas."
  def content_hash(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  @doc "Descripciones válidas: el tope que el índice del prompt respeta."
  def description_max, do: @description_max

  @doc "Tamaño válido del cuerpo (mínimo, máximo)."
  def body_limits, do: {@body_min, @body_max}

  @doc "Niveles de visibilidad válidos (`private` | `public` | `shared`)."
  def visibilities, do: @visibilities

  defp put_content_hash(changeset) do
    case get_change(changeset, :body) do
      body when is_binary(body) -> put_change(changeset, :content_hash, content_hash(body))
      _ -> changeset
    end
  end

  defp name_format_message do
    "must start with a letter and use only a-z, 0-9, _ and -"
  end
end
