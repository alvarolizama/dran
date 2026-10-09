defmodule Dran.Skills do
  @moduledoc """
  El contexto de skills — el catálogo de instrucciones que un agente conectado
  por API descubre y carga por tool.

  Un skill es una ENTIDAD con `owner_user_id` + `visibility` propios (default
  `private`), como un goal o un plan: no es un tipo de página y no vive en
  `knowledge_pages`. Las lecturas con `scope:` pasan por
  `Dran.ContentVisibility.filter/3` (el punto único); las escrituras reciben el
  dueño YA resuelto server-side.

  ## La suite no vive acá

  El router y los ocho flows (`loader`, `knowledge-flow`, …) son las
  instrucciones de la SUITE: viajan CON el plugin de Hermes
  (`hermes_plugin/dran/skills/<slug>/SKILL.md`, filas locales `dran:<slug>`) y no
  son filas del catálogo de ninguna instancia — Dran no sirve ningún built-in.
  Sus slugs quedan RESERVADOS (`reserved_slug?/1`) para que un skill de usuario no
  ocupe la misma dirección.

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

  # Los slugs de la SUITE (el router y los ocho flows) están RESERVADOS: la suite
  # son las instrucciones que viajan CON el plugin de Hermes
  # (`hermes_plugin/dran/skills/<slug>/SKILL.md`, filas locales `dran:<slug>`), no
  # contenido del catálogo de la instancia. Un skill de usuario con uno de esos
  # slugs sería una dirección con dos dueños en el detalle (`/api/skills/:slug`,
  # `dran_skill`), así que el alta lo rechaza con el error en el campo que el
  # cliente escribió. El conjunto es ESTÁTICO: la lista es la única verdad y no
  # depende de filas (antes eran filas `system: true`, que ya no existen: Dran no
  # sirve ningún built-in).
  @reserved_slugs ~w(loader knowledge-flow relations-flow workers-flow memory-flow
                     goal-flow plan-flow services-flow skills-flow)

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
  `orders/0`, default `:name`), `:query` (filtro de texto sobre slug, name y
  description), `:limit`.
  """
  def list_skills(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    owner_user_id = Keyword.get(opts, :owner_user_id)
    visibility = Keyword.get(opts, :visibility)
    order = Keyword.get(opts, :order)
    query_text = Keyword.get(opts, :query)
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

    query = filter_by_query(query, query_text)

    query
    |> Dran.ContentVisibility.filter(scope, :skill)
    |> Repo.all()
  end

  # El filtro de texto del listado: busca en slug, name y description sin
  # distinguir mayúsculas. Los comodines de LIKE que vengan en el texto se
  # ESCAPAN para que se busquen como caracteres — un `%` del usuario no puede
  # convertirse en «todo el catálogo»: un filtro que devuelve de más es peor que
  # uno que devuelve de menos, porque el agente lo reporta como filtrado.
  defp filter_by_query(query, text) when is_binary(text) do
    case escape_like(text) do
      "" ->
        query

      escaped ->
        pattern = "%#{escaped}%"

        where(
          query,
          [s],
          fragment("? ILIKE ? ESCAPE '\\'", s.slug, ^pattern) or
            fragment("? ILIKE ? ESCAPE '\\'", s.name, ^pattern) or
            fragment("? ILIKE ? ESCAPE '\\'", s.description, ^pattern)
        )
    end
  end

  defp filter_by_query(query, _text), do: query

  # El backslash que agrega sólo vale con el `ESCAPE` explícito del fragment:
  # sin él, `\%` busca un backslash seguido de cualquier cosa.
  defp escape_like(text) do
    text
    |> String.trim()
    |> String.replace(~r/[\\%_]/, fn char -> "\\" <> char end)
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

  @doc """
  Los AVISOS de un skill guardado: cumple la regla, pero está en el borde.

  Lista vacía es lo normal. Hoy hay uno: el cuerpo arriba del techo SUAVE
  (80 K) — el skill sirve y se guarda, pero salió del carril donde el agente lo
  recibe COMPLETO en una sola llamada, así que el autor tiene que saberlo (el
  siguiente escalón, 90 K, ya rechaza).

  Se calcula al servir, no se guarda: el número sale del cuerpo que hay, así que
  no puede quedar desfasado con lo que el lector vería.
  """
  def warnings(%Skill{} = skill) do
    soft = Skill.body_soft_max()
    {_min, hard} = Skill.body_limits()
    chars = body_length(skill.body)

    if chars > soft do
      [
        %{
          field: "body",
          code: "body_over_soft_max",
          chars: chars,
          soft_max: soft,
          hard_max: hard,
          detail:
            "the body is over the #{soft} soft max: it still saves, but it leaves " <>
              "the inline lane — the agent gets a pointer to the mirror file and reads " <>
              "it with read_file instead of receiving the whole body in one call. " <>
              "Split it into two skills grouped by prefix before #{hard}."
        }
      ]
    else
      []
    end
  end

  # El MISMO conteo que usa `validate_length/3` (grafemas, no bytes): si los dos
  # números discreparan, un cuerpo con acentos pasaría el aviso y fallaría el
  # rechazo (o al revés).
  defp body_length(body) when is_binary(body), do: String.length(body)
  defp body_length(_body), do: 0

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
  # Slugs reservados (la suite vive en el plugin, no en la tabla)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  ¿Ese slug está RESERVADO por la suite?

  El detalle resuelve por slug, así que un skill de usuario homónimo sería una
  dirección con dos dueños: el alta lo rechaza (`{:error, changeset}`) en vez de
  dejar una fila inalcanzable. La lista es ESTÁTICA (`@reserved_slugs`): la suite
  no tiene filas — sus instrucciones viajan con el plugin de Hermes.
  """
  def reserved_slug?(slug) when is_binary(slug), do: slug in @reserved_slugs
  def reserved_slug?(_slug), do: false

  @doc "Los slugs que la suite reserva (el router y los ocho flows)."
  def reserved_slugs, do: @reserved_slugs

  # ──────────────────────────────────────────────────────────────────────────
  # Escritura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea un skill. El `owner_user_id` llega resuelto server-side (la credencial),
  NUNCA del body.

  El slug es la dirección del wire y se escribe UNA vez: no hay rename — lo
  único que se edita es el cuerpo, la descripción y el destino. Un slug de la
  SUITE está RESERVADO (`{:error, changeset}` con el error en el campo que el
  cliente mandó): la dirección del wire tiene un solo dueño.
  """
  def create_skill(attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)
    # Quién mandó la dirección: el error del slug reservado va al campo que el
    # cliente ESCRIBIÓ — un error en un campo que su form no muestra no se ve.
    sent_slug? = is_binary(attrs["slug"] || attrs[:slug])
    # La reserva se comprueba sobre la dirección EFECTIVA: sin `slug` en el
    # body, es la que se deriva del `name`.
    attrs = put_slug_from_name(attrs)

    changeset =
      attrs
      |> put_owner(opts[:owner_user_id])
      |> then(&Skill.changeset(%Skill{}, &1))

    if reserved_slug?(attrs["slug"] || attrs[:slug]) do
      {:error, reserved_slug_error(changeset, sent_slug?)}
    else
      Repo.insert(changeset)
    end
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
      update_readable_skill(skill, attrs)
    end
  end

  defp update_readable_skill(skill, attrs) do
    skill
    |> Skill.changeset(drop_rename(attrs))
    |> bump_version(skill)
    |> Repo.update()
  end

  @doc """
  Borra un skill.

  Los grants de `content_shares` no tienen FK polimórfica y quedan inertes (la
  misma postura que pages, goals y planes): sin la fila, el `EXISTS` no puede
  alcanzarlos.
  """
  def delete_skill(%Skill{} = skill), do: Repo.delete(skill)

  # El mensaje del slug reservado: una sola frase para el API y la web.
  @reserved_slug_message "is reserved by the Dran suite (served by the plugin)"

  # La web pinta los errores de un changeset sólo si trae `action` (lo que setea
  # `Repo.insert/1` al fallar): `apply_action/2` presenta este changeset como el
  # insert fallido que es, sin tocar el struct a mano.
  defp reserved_slug_error(changeset, sent_slug?) do
    {:error, changeset} =
      changeset
      |> add_reserved_slug_errors(sent_slug?)
      |> Ecto.Changeset.apply_action(:insert)

    changeset
  end

  defp add_reserved_slug_errors(changeset, true) do
    Ecto.Changeset.add_error(changeset, :slug, @reserved_slug_message)
  end

  # Sin slug en el body, la dirección se DERIVÓ del `name`: el error va también
  # ahí, que es el campo que el operador escribió.
  defp add_reserved_slug_errors(changeset, false) do
    changeset
    |> Ecto.Changeset.add_error(:name, @reserved_slug_message)
    |> Ecto.Changeset.add_error(:slug, @reserved_slug_message)
  end

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
