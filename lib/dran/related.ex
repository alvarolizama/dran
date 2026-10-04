defmodule Dran.Related do
  @moduledoc """
  Las páginas relacionadas con un contenedor de trabajo (un goal o un plan).

  Dos fuentes, en este orden y nunca mezcladas:

    1. las RELACIONES REALES del grafo — filas de `relations` con el goal/plan
       como extremo y un tipo LEGIBLE (`related`, `contradicts`, `supersedes`,
       `part_of`, `embeds`, `mentions`). Es la verdad declarada;
    2. SÓLO si no hay ninguna, el FALLBACK SEMÁNTICO
       (`Knowledge.semantic_search/2` sobre título + summary, con umbral y
       `limit`).

  Las dos leen con la puerta PERSONAL del lector (`ContentVisibility.
  personal_scope/1`): una página que no puede leer no aparece por ninguna de
  las dos vías, y una que sí puede aparece sin que su relación revele nada de
  otro. La fuente viaja en el resultado (`:relations | :semantic | :none`) para
  que la UI diga CUÁL está mostrando — el sidebar no es una caja negra.

  El alta de una relación es EXPLÍCITA y pasa por `link/5`: el fallback nunca
  escribe, y la arista queda atribuida a quien la creó.
  """

  import Ecto.Query, warn: false

  alias Dran.Knowledge
  alias Dran.Knowledge.Page
  alias Dran.Relation
  alias Dran.Repo

  @entity_types ~w(goal plan)

  # Tipos de relación LEGIBLES: los manuales del grafo. Los derivados por la
  # máquina (`semantic`, `informs`, los materializados de `meta.props`) no son
  # «relacionadas» para el lector — son inferencia, y viven en su propia vista.
  @readable_relation_types ~w(related contradicts supersedes part_of embeds mentions)

  @default_limit 5

  # Umbral del fallback: la distancia del vecino más lejano que todavía cuenta
  # como relacionado. Sin umbral, un goal que no se parece a nada listaría las
  # cinco páginas más cercanas del workspace — que es exactamente lo que el
  # umbral evita.
  @max_distance 0.6

  @type source :: :relations | :semantic | :none
  @type page :: %{id: binary(), title: binary(), slug: binary(), page_type: binary()}

  def entity_types, do: @entity_types

  @doc """
  Las páginas relacionadas con `entity`, con la fuente declarada.

  Devuelve `%{source: :relations | :semantic | :none, pages: [page]}`.

  Opts: `:scope` (la puerta del lector, default `:all`), `:limit`,
  `:workspace_id` (default: el workspace de la instancia — un goal no tiene
  columna de workspace) y `:searcher` (el buscador del fallback; el default es
  `Knowledge.semantic_search/2`, y los tests inyectan uno para probar que con
  relaciones reales NO se consulta).
  """
  @spec for_entity(binary(), map(), keyword()) :: %{source: source(), pages: [page()]}
  def for_entity(entity_type, entity, opts \\ [])

  def for_entity(entity_type, %{id: entity_id} = entity, opts)
      when entity_type in @entity_types do
    scope = Keyword.get(opts, :scope, :all)
    limit = Keyword.get(opts, :limit, @default_limit)
    workspace_id = workspace_id(opts)

    case related_pages(entity_type, entity_id, workspace_id, scope, limit) do
      [] -> semantic_pages(entity, workspace_id, scope, limit, opts)
      pages -> %{source: :relations, pages: pages}
    end
  end

  def for_entity(_entity_type, _entity, _opts), do: %{source: :none, pages: []}

  @doc """
  Da de alta una relación EXPLÍCITA entre la entidad y una página LEGIBLE para
  el lector, atribuida a quien la creó.

  La arista la crea el picker, nunca el sidebar solo, y la página sale del scope
  del lector: no se puede «relacionar» —ni siquiera ciegamente— algo que no se
  puede leer (el id forjado devuelve `{:error, :page_not_found}`).
  """
  @spec link(binary(), map(), binary(), map() | nil, keyword()) ::
          {:ok, %Relation{}} | {:error, :page_not_found | Ecto.Changeset.t()}
  def link(entity_type, entity, page_id, user, opts \\ []) when entity_type in @entity_types do
    scope = Keyword.get(opts, :scope, :all)

    case readable_page(page_id, workspace_id(opts), scope) do
      nil ->
        {:error, :page_not_found}

      page ->
        Knowledge.create_relation(%{
          source_id: entity.id,
          source_type: entity_type,
          target_id: page.id,
          target_type: "page",
          relation_type: "related",
          meta: %{
            "source" => "related_sidebar",
            "created_by_user_id" => user_id(user)
          }
        })
    end
  end

  @doc """
  Las páginas que el lector puede leer y que todavía NO están relacionadas con
  la entidad — las opciones del picker.

  Opts: `:scope`, `:limit`, `:workspace_id`.
  """
  @spec linkable_pages(binary(), map(), keyword()) :: [page()]
  def linkable_pages(entity_type, entity, opts \\ [])

  def linkable_pages(entity_type, entity, opts) when entity_type in @entity_types do
    scope = Keyword.get(opts, :scope, :all)
    limit = Keyword.get(opts, :limit, 100)
    workspace_id = workspace_id(opts)

    taken =
      related_pages(entity_type, entity.id, workspace_id, scope, @default_limit)
      |> Enum.map(& &1.id)

    from(p in Page,
      where: p.archived == false and p.id not in ^taken,
      order_by: [desc: p.updated_at],
      limit: ^limit,
      select: %{id: p.id, title: p.title, slug: p.slug, page_type: p.page_type}
    )
    |> maybe_filter_workspace(workspace_id)
    |> Dran.ContentVisibility.filter(scope, :page)
    |> Repo.all()
  end

  def linkable_pages(_entity_type, _entity, _opts), do: []

  # ── Fuente 1: las relaciones reales ────────────────────────────────────────

  defp related_pages(entity_type, entity_id, workspace_id, scope, limit) do
    ids =
      from(r in Relation,
        where:
          r.relation_type in ^@readable_relation_types and
            ((r.source_id == ^entity_id and r.source_type == ^entity_type and
                r.target_type == "page") or
               (r.target_id == ^entity_id and r.target_type == ^entity_type and
                  r.source_type == "page")),
        order_by: [desc: r.inserted_at],
        limit: ^limit,
        select: {r.source_id, r.source_type, r.target_id, r.target_type}
      )
      |> Repo.all()
      |> Enum.flat_map(fn {source_id, source_type, target_id, target_type} ->
        cond do
          target_type == "page" -> [target_id]
          source_type == "page" -> [source_id]
          true -> []
        end
      end)
      |> Enum.uniq()

    by_id = load_pages(ids, workspace_id, scope) |> Map.new(&{&1.id, &1})

    ids
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  # ── Fuente 2: el fallback semántico ────────────────────────────────────────

  defp semantic_pages(entity, workspace_id, scope, limit, opts) do
    searcher = Keyword.get(opts, :searcher, &Knowledge.semantic_search/2)

    case searcher.(semantic_query(entity), workspace_id: workspace_id, limit: limit * 4) do
      {:ok, results} when is_list(results) ->
        ranked =
          results
          |> Enum.filter(&(distance_of(&1) <= @max_distance))
          |> Enum.take(limit)

        by_id =
          load_pages(Enum.map(ranked, & &1.id), workspace_id, scope) |> Map.new(&{&1.id, &1})

        pages =
          ranked
          |> Enum.map(&Map.get(by_id, &1.id))
          |> Enum.reject(&is_nil/1)

        %{source: if(pages == [], do: :none, else: :semantic), pages: pages}

      _ ->
        %{source: :none, pages: []}
    end
  end

  # El texto del fallback: título + summary de la entidad. Nunca el cuerpo
  # (kilómetros de markdown no buscaron nunca un vecino mejor).
  defp semantic_query(entity) do
    [entity.title, Map.get(entity, :summary)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  defp distance_of(%{distance: distance}) when is_number(distance), do: distance

  defp distance_of(result) when is_map(result) do
    value = Map.get(result, "distance") || Map.get(result, :distance)
    if is_number(value), do: value, else: @max_distance
  end

  defp distance_of(_), do: @max_distance

  # ── Lectura de páginas, siempre por la política única ──────────────────────

  defp readable_page(page_id, workspace_id, scope) do
    from(p in Page,
      where: p.id == ^page_id and p.archived == false,
      select: %{id: p.id, title: p.title, slug: p.slug, page_type: p.page_type}
    )
    |> maybe_filter_workspace(workspace_id)
    |> Dran.ContentVisibility.filter(scope, :page)
    |> Repo.one()
  end

  defp load_pages([], _workspace_id, _scope), do: []

  defp load_pages(ids, workspace_id, scope) do
    from(p in Page,
      where: p.id in ^ids and p.archived == false,
      select: %{id: p.id, title: p.title, slug: p.slug, page_type: p.page_type}
    )
    |> maybe_filter_workspace(workspace_id)
    |> Dran.ContentVisibility.filter(scope, :page)
    |> Repo.all()
  end

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, workspace_id) do
    where(query, [p], p.workspace_id == ^workspace_id)
  end

  defp workspace_id(opts) do
    case Keyword.get(opts, :workspace_id) do
      nil -> instance_workspace_id()
      id -> id
    end
  end

  # Un goal/plan no tiene columna `workspace_id`: en el modelo de una sola
  # instancia, el contenedor es el workspace de la instancia.
  defp instance_workspace_id do
    case Dran.Auth.instance_workspace() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp user_id(%{id: id}) when is_integer(id), do: id
  defp user_id(id) when is_integer(id), do: id
  defp user_id(_), do: nil
end
