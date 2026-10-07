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

  # Los built-ins (`system: true`) los sirve Dran a TODA credencial por default:
  # índice, detalle y conteo los incluyen con cualquier scope — incluido el de
  # grupo, que por la Constraint 3 lee exactamente lo compartido a su grupo.
  @system_field [system_field: :system]

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
    |> Dran.ContentVisibility.filter(scope, :skill, @system_field)
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
    |> Dran.ContentVisibility.filter(scope, :skill, @system_field)
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
    |> Dran.ContentVisibility.filter(scope, :skill, @system_field)
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
      system: skill.system,
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
  # Built-ins (los skills de SISTEMA)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Los built-ins, ordenados por slug.

  Es el conjunto que ship el CÓDIGO (`Dran.Skills.Builtin`), no una lectura de
  lector: por eso NO pasa por el scope — el sincronizador necesita su conjunto
  completo para reconciliarlo, y la lectura de un lector pasa por
  `list_skills/1`.
  """
  def list_system_skills do
    Skill
    |> where([s], s.system)
    |> order_by([s], asc: s.slug)
    |> Repo.all()
  end

  @doc "El built-in con ese slug (`system: true`), sin scope."
  def get_system_skill(slug) when is_binary(slug) do
    Repo.one(from s in Skill, where: s.system and s.slug == ^slug)
  end

  def get_system_skill(_slug), do: nil

  @doc """
  ¿Ese slug está RESERVADO por un built-in?

  El detalle resuelve por slug, así que un skill de usuario homónimo sería una
  dirección con dos dueños: el alta lo rechaza (`{:error, :reserved_slug}`) en
  vez de dejar una fila inalcanzable.
  """
  def system_slug?(slug) when is_binary(slug) do
    Repo.exists?(from s in Skill, where: s.system and s.slug == ^slug)
  end

  def system_slug?(_slug), do: false

  @doc """
  Poda los built-ins que el código YA NO sirve.

  Son contenido de código, no datos de nadie: un flow que se retira del repo
  tiene que dejar de servirse, o quedaría para siempre en el catálogo de todos
  los consumidores. Devuelve cuántas filas se borraron.
  """
  def prune_system_skills(slugs) when is_list(slugs) do
    {count, _} = Repo.delete_all(from s in Skill, where: s.system and s.slug not in ^slugs)
    count
  end

  @doc """
  Reconcilia la tabla con las definiciones embebidas (los `SKILL.md` del repo).

  Idempotente y sin sorpresas:

  * slug nuevo → alta con `system: true`, sin dueño y `visibility: "public"`;
  * slug conocido con el MISMO cuerpo y descripción → no escribe nada (ni
    `updated_at` ni versión: reescribir el mismo cuerpo deja el hash igual);
  * cuerpo o descripción distintos → el MISMO changeset del wire, con
    `version + 1`;
  * slug que ya no se sirve → poda.

  Devuelve `%{created:, updated:, pruned:, total:}`.
  """
  def sync_system_skills(definitions) when is_list(definitions) do
    slugs = Enum.map(definitions, & &1.slug)

    {created, updated} =
      Enum.reduce(definitions, {0, 0}, fn definition, {created, updated} ->
        case upsert_system_skill(definition) do
          :created -> {created + 1, updated}
          :updated -> {created, updated + 1}
          :unchanged -> {created, updated}
        end
      end)

    %{
      created: created,
      updated: updated,
      pruned: prune_system_skills(slugs),
      total: length(definitions)
    }
  end

  # El insert/update va con `!` a propósito: un built-in que no se puede
  # sincronizar es un despliegue roto (nombre inválido, base sin migrar), no un
  # caso de negocio — el error tiene que verse, no degradarse en silencio.
  defp upsert_system_skill(%{slug: slug, name: name, description: description, body: body}) do
    case get_system_skill(slug) do
      nil ->
        %Skill{}
        |> Skill.system_changeset(%{
          "slug" => slug,
          "name" => name,
          "description" => description,
          "body" => body,
          "visibility" => "public"
        })
        |> Repo.insert!()

        :created

      %Skill{} = skill ->
        if skill.content_hash == Skill.content_hash(body) and skill.description == description do
          :unchanged
        else
          skill
          |> Skill.system_changeset(%{"description" => description, "body" => body})
          |> bump_version(skill)
          |> Repo.update!()

          :updated
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Escritura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea un skill. El `owner_user_id` llega resuelto server-side (la credencial),
  NUNCA del body.

  El slug es la dirección del wire y se escribe UNA vez: no hay rename — lo
  único que se edita es el cuerpo, la descripción y el destino. Un slug que ya
  sirve un built-in está RESERVADO (`{:error, changeset}` con el error en el
  campo que el cliente mandó): la dirección del wire tiene un solo dueño.
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

    if system_slug?(attrs["slug"] || attrs[:slug]) do
      {:error, reserved_slug_error(changeset, sent_slug?)}
    else
      Repo.insert(changeset)
    end
  end

  @doc """
  Actualiza un skill: el cuerpo versionado y el destino.

  * Un skill de SISTEMA no se escribe por acá (`{:error, :system_readonly}`): su
    contenido es el archivo del repo y su ciclo es un redeploy. Sin esta guarda,
    la credencial de la instancia podría dejar a todos los consumidores con una
    versión que el código ya no sirve.
  * Una escritura que CAMBIA el cuerpo bumpea `version` y recalcula
    `content_hash`; reescribir el MISMO cuerpo deja hash y versión iguales — es
    lo que sostiene el `unchanged` del agente.
  * `slug`/`name` NO se renombran: pedirlo devuelve `{:error, :rename}` (explícito,
    no un descarte en silencio), porque el slug es la dirección del wire.
  """
  def update_skill(%Skill{} = skill, attrs) do
    cond do
      Skill.system?(skill) -> {:error, :system_readonly}
      rename_attempted?(skill, attrs) -> {:error, :rename}
      true -> update_readable_skill(skill, attrs)
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

  Un built-in NO se borra (`{:error, :system_readonly}`): es contenido de código
  y su ciclo es el repo, no una credencial. Los grants de `content_shares` no
  tienen FK polimórfica y quedan inertes (la misma postura que pages, goals y
  planes): sin la fila, el `EXISTS` no puede alcanzarlos.
  """
  def delete_skill(%Skill{} = skill) do
    if Skill.system?(skill), do: {:error, :system_readonly}, else: Repo.delete(skill)
  end

  # El mensaje del slug reservado: una sola frase para el API y la web.
  @reserved_slug_message "is reserved by a built-in skill"

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
