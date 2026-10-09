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
  descripción se valida al guardar (422), nunca se trunca al servir. El CUERPO
  tiene dos techos: el duro (90 K) rechaza al guardar y el suave (80 K) sólo
  avisa — es el borde del carril inline (`warnings/1`).
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
  # El techo del CUERPO, en dos escalones: el DURO rechaza (422) y el SUAVE
  # AVISA. La razón es del transporte, no del contenido: el cuerpo viaja dentro
  # del resultado de un tool (JSON) y el escape de los saltos de línea le suma
  # ~7%, así que un cuerpo grande empujaba el resultado arriba del tope del host
  # (100,000 chars): el agente recibía un preview de 1,500 y una ruta, o sea el
  # encabezado del skill, creyéndose que había leído los pasos.
  #
  # 80 K (suave) deja ~6 K de margen bajo el techo del plugin
  # (`SKILLS_INLINE_MAX_CHARS`, 90 K) — por debajo viaja inline en UNA llamada.
  # 90 K (duro) es donde partir deja de ser opcional: lo que pase de ahí o se
  # parte en dos skills que se agrupan por prefijo, o se sirve por puntero y el
  # agente lo lee con `read_file` sobre el archivo del espejo.
  @body_soft_max 80_000
  @body_max 90_000
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

    # Dueño server-side; NULL = contenido sin dueño (admin legacy).
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

  @doc "Largo máximo del identificador del wire (`name`/`slug`)."
  def name_max, do: @name_max

  @doc "Tamaño válido del cuerpo (mínimo, máximo DURO: arriba se rechaza)."
  def body_limits, do: {@body_min, @body_max}

  @doc """
  El techo SUAVE del cuerpo: arriba de esto el skill se guarda, pero AVISA.

  Es el número que garantiza el carril inline (una sola llamada, sin puntero):
  por eso el aviso no es decoración — dice que el skill salió del carril donde
  el agente lo recibe completo de una vez.
  """
  def body_soft_max, do: @body_soft_max

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
