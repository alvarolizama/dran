defmodule Dran.Skills do
  @moduledoc """
  El contexto de skills — el catálogo de instrucciones que un agente conectado
  por API descubre y carga por tool.

  Un skill es una ENTIDAD con `owner_user_id` + `visibility` propios (default
  `private`), como un goal o un plan: no es un tipo de página y no vive en
  `knowledge_pages`. Las lecturas con `scope:` pasan por
  `Dran.ContentVisibility.filter/3` (el punto único); las escrituras reciben el
  dueño YA resuelto server-side.

  ## El contrato de wire

  `name` + `description` (≤ 60) + `body` + `version` + `content_hash`. Se sirve
  en dos formas: el ÍNDICE (sin cuerpos) y el skill montado como `SKILL.md`
  (frontmatter + body), para que un cliente que no sea Hermes lo escriba o lo
  pase tal cual.

  `version` y `content_hash` son monotónicos: una escritura que cambia el cuerpo
  bumpea la versión y recalcula el hash; reescribir el MISMO cuerpo deja el hash
  igual. Eso es lo que sostiene el `unchanged` del agente — sin él habría que
  re-inyectar el skill completo en cada turno.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Skills.Skill

  @orders ~w(name updated)

  # ──────────────────────────────────────────────────────────────────────────
  # Lectura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Órdenes válidos del listado, en el orden en que la UI los ofrece.

  Vocabulario propio: el de `Dran.ListOrder` ordena por `title` y `due_on`, y un
  skill no tiene ninguna de las dos — reusarlo sería una query inválida.
  """
  def orders, do: @orders

  @doc "Clause de `order_by` para un orden del vocabulario (default `name`)."
  def order_clause(order) when order in [:updated, "updated"],
    do: [desc: :updated_at, asc: :name]

  def order_clause(_order), do: [asc: :name]

  @doc """
  Lista skills con scope de lectura.

  Opts: `:scope` (default `:all` para callers internos), `:owner_user_id`,
  `:visibility` (el filtro de destino de la lista), `:order` (vocabulario de
  `orders/0`, default `:name`), `:limit`.
  """
  def list_skills(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    owner_user_id = Keyword.get(opts, :owner_user_id)
    visibility = Keyword.get(opts, :visibility)
    order = Keyword.get(opts, :order)
    limit = Keyword.get(opts, :limit, 500)

    query =
      from(s in Skill,
        order_by: ^order_clause(order),
        limit: ^limit
      )

    query =
      if is_integer(owner_user_id),
        do: where(query, [s], s.owner_user_id == ^owner_user_id),
        else: query

    query = if visibility, do: where(query, [s], s.visibility == ^visibility), else: query

    query
    |> Dran.ContentVisibility.filter(scope, :skill)
    |> Repo.all()
  end

  @doc """
  Trae un skill por slug con scope de lectura.

  El slug ES la dirección del wire, así que no hay id-or-slug: un slug fuera del
  scope del lector se lee como inexistente (sin fuga de existencia) y un slug
  forjado devuelve `nil` sin reventar (la columna es texto, no hay cast que
  falle).
  """
  def get_skill(slug, opts \\ [])

  def get_skill(slug, opts) when is_binary(slug) do
    scope = Keyword.get(opts, :scope, :all)

    Skill
    |> where([s], s.slug == ^slug)
    |> order_by([s], asc: s.inserted_at)
    |> Dran.ContentVisibility.filter(scope, :skill)
    |> Repo.all()
    |> List.first()
  end

  def get_skill(_slug, _opts), do: nil

  @doc "Changeset para formularios (la validación vive en el schema)."
  def change_skill(%Skill{} = skill, attrs \\ %{}), do: Skill.changeset(skill, attrs)

  @doc """
  Conteo de skills legibles — UNA query agregada.

  Existe para el badge del nav: un contador no trae filas para contarlas en
  memoria, y el nav se pinta en TODAS las páginas. El scope es el del lector
  (la misma puerta que `list_skills/1`): contar todo anunciaría los privados
  ajenos y el nav es una superficie personal.
  """
  def count_skills(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)

    Skill
    |> Dran.ContentVisibility.filter(scope, :skill)
    |> Repo.aggregate(:count, :id)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # El contrato de wire servido
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  El hash del CUERPO de un skill (sha256 en hex).

  Se calcula sobre el body y nada más: incluir `updated_at` o cualquier campo
  del struct haría que el hash cambiara sin que el contenido cambie y el
  `unchanged` del agente nunca se dispararía.
  """
  defdelegate content_hash(body), to: Skill

  @doc """
  Monta el `SKILL.md` de un skill: frontmatter (`name` + `description`) y el
  cuerpo.

  Es la forma en que un cliente que no sea Hermes (o el propio agente, si quiere
  pasárselo tal cual a otro) escribe el archivo, sin que Dran dependa de que
  alguien lo baje a disco.
  """
  def to_skill_md(%Skill{} = skill) do
    [
      "---",
      "name: #{skill.name}",
      "description: #{frontmatter_value(skill.description)}",
      "---",
      "",
      skill.body || ""
    ]
    |> Enum.join("\n")
  end

  @doc """
  El payload del ÍNDICE: el catálogo sin cuerpos.

  `mine` es del LECTOR, no de la fila: el mismo skill es propio para su dueño y
  ajeno para quien lo lee compartido. Sale del id resuelto en el punto único de
  la credencial (`:api_auth`), nunca del body.
  """
  def index_payload(skills, reader_id) when is_list(skills) do
    Enum.map(skills, &index_entry(&1, reader_id))
  end

  @doc "El payload del DETALLE: el `SKILL.md` montado más el `body` crudo."
  def show_payload(%Skill{} = skill, reader_id) do
    skill
    |> index_entry(reader_id)
    |> Map.merge(%{body: skill.body, skill_md: to_skill_md(skill)})
  end

  defp index_entry(%Skill{} = skill, reader_id) do
    %{
      id: skill.id,
      slug: skill.slug,
      name: skill.name,
      description: skill.description,
      version: skill.version,
      content_hash: skill.content_hash,
      visibility: skill.visibility,
      updated_at: skill.updated_at,
      mine: is_integer(reader_id) and skill.owner_user_id == reader_id
    }
  end

  # El frontmatter es YAML: una descripción con `:` o comillas la rompería, así
  # que se cita siempre (escapando la comilla doble y la barra).
  defp frontmatter_value(value) when is_binary(value) do
    ~s(") <> String.replace(value, ~r/["\\]/, fn char -> "\\" <> char end) <> ~s(")
  end

  defp frontmatter_value(_value), do: ~s("")

  # ──────────────────────────────────────────────────────────────────────────
  # Escritura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea un skill. El `owner_user_id` llega resuelto server-side (la credencial),
  NUNCA del body.

  El slug es la dirección del wire y se escribe UNA vez: no hay rename — lo
  único que se edita es el cuerpo, la descripción y el destino.
  """
  def create_skill(attrs, opts \\ []) do
    attrs
    |> normalize_attrs()
    |> put_slug_from_name()
    |> put_owner(opts[:owner_user_id])
    |> then(&(%Skill{} |> Skill.changeset(&1) |> Repo.insert()))
  end

  @doc """
  Actualiza un skill: el cuerpo versionado y el destino.

  * Una escritura que CAMBIA el cuerpo bumpea `version` y recalcula
    `content_hash`; reescribir el MISMO cuerpo deja hash y versión iguales — es
    lo que sostiene el `unchanged` del agente.
  * `slug`/`name` NO se renombran: pedirlo devuelve `{:error, :rename}` (explícito,
    no un descarte en silencio), porque el slug es la dirección del wire.
  """
  def update_skill(%Skill{} = skill, attrs) do
    if rename_attempted?(skill, attrs) do
      {:error, :rename}
    else
      skill
      |> Skill.changeset(drop_rename(attrs))
      |> bump_version(skill)
      |> Repo.update()
    end
  end

  @doc """
  Borra un skill.

  Los grants de `content_shares` no tienen FK polimórfica y quedan inertes (la
  misma postura que pages, goals y planes): sin la fila, el `EXISTS` no puede
  alcanzarlos.
  """
  def delete_skill(%Skill{} = skill), do: Repo.delete(skill)

  # El `content_hash` sólo cambia cuando el cuerpo cambió (lo decide el
  # changeset), así que esa es la señal de la versión: dos textos distintos no
  # pueden producir el mismo hash.
  defp bump_version(changeset, skill) do
    if Ecto.Changeset.get_change(changeset, :content_hash) do
      Ecto.Changeset.put_change(changeset, :version, (skill.version || 1) + 1)
    else
      changeset
    end
  end

  defp put_owner(attrs, owner_user_id) when is_integer(owner_user_id),
    do: Map.put(attrs, "owner_user_id", owner_user_id)

  defp put_owner(attrs, _owner_user_id), do: attrs

  # El `slug` (la dirección del wire) se DERIVA del `name` cuando no viene: son
  # el MISMO espacio de nombres — el identificador es uno, se escribe una vez y
  # no se renombra (renombrarlo rompe a quien lo tenga cargado). El form del
  # alta sólo pide el nombre, y el API puede mandar uno de los dos.
  defp put_slug_from_name(attrs) do
    cond do
      Map.has_key?(attrs, "slug") or Map.has_key?(attrs, :slug) -> attrs
      name = attrs["name"] || attrs[:name] -> Map.put(attrs, "slug", name)
      true -> attrs
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_attrs(_attrs), do: %{}

  defp drop_rename(attrs) when is_map(attrs), do: Map.drop(attrs, ["slug", "name", :slug, :name])
  defp drop_rename(_attrs), do: %{}

  defp rename_attempted?(%Skill{} = skill, attrs) when is_map(attrs) do
    renamed?(Map.get(attrs, "slug", Map.get(attrs, :slug)), skill.slug) or
      renamed?(Map.get(attrs, "name", Map.get(attrs, :name)), skill.name)
  end

  defp rename_attempted?(_skill, _attrs), do: false

  defp renamed?(nil, _current), do: false
  defp renamed?(value, current), do: to_string(value) != current
end
