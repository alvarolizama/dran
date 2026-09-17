defmodule Dran.Repo.Migrations.DropMetaKindFromKnowledgePages do
  use Ecto.Migration

  @moduledoc """
  M9 paso 2/2 — borrado IRREVERSIBLE del vocabulario muerto de clasificación.

  Después del colapso (paso 1) el tipo original de las filas colapsadas
  quedaba en `meta.kind` como valor de display. Ese vocabulario ya no existe:
  el modelo de página tiene cuatro tipos (`note`, `entity`, `concept`,
  `reference`) y la clasificación libre vive en `meta.props` y en los tags.
  Este paso elimina:

  * `knowledge_pages.meta.kind` — de TODAS las filas (incluidas las 11 que
    nunca fueron colapsadas y las legacy `journal`/`plan`/`project`).
  * `collections.filters->'type'` — cuando apunta a un tipo de página retirado
    (`idea`, `knowledge`, `technical`, `food`); una colección guardada con un
    tipo que el registry ya no conoce filtraría a cero filas en silencio.
  * `collections.filters->'kind'` — la clave `kind[]` desapareció del modelo:
    el editor ya no la ofrece y el query de colecciones ya no la lee, así que
    dejarla guardada sería un filtro fantasma.
  * `workspaces.disabled_page_types` — las entradas de tipos retirados: un
    workspace con `disabled_page_types = ["food"]` quedaría con un valor que
    `Workspace.changeset/2` ya rechaza (`validate_subset`) y que ya no
    corresponde a ningún tipo.

  ## `down` — IRREVERSIBLE por diseño

  El `down` es un no-op deliberado: los valores borrados NO son reconstruibles
  desde los datos que quedan (todas las filas son de los cuatro tipos vigentes
  y el tipo original de las colapsadas solo existía en `meta.kind`; de las
  colecciones no queda rastro del filtro retirado). Por eso la reversibilidad
  del colapso se verifica ANTES de aplicar este paso — el `down` del paso 1
  restaura por `meta->>'kind'` solo mientras la clave existe. Recuperar el
  vocabulario requeriría restaurar desde un backup.

  `meta.props` no se toca: es ortogonal y lo consumen `PropsMaterializer` y los
  filtros `meta->'props'`.
  """

  @removed_types ~w(idea knowledge technical food)

  def up do
    execute("""
    UPDATE knowledge_pages
    SET meta = meta - 'kind'
    WHERE meta ? 'kind'
    """)

    types = Enum.map_join(@removed_types, ",", &"'#{&1}'")

    # Dead page type in a saved collection filter — drop the key, keep the rest.
    execute("""
    UPDATE collections
    SET filters = filters - 'type'
    WHERE filters->>'type' IN (#{types})
    """)

    # Dead kind filter (the kind vocabulary is gone from the page model).
    execute("""
    UPDATE collections
    SET filters = filters - 'kind'
    WHERE filters ? 'kind'
    """)

    # Dead disabled page types: a workspace that disabled `food` (or any other
    # retired type) would keep a value the changeset now rejects and that no
    # longer names a page type. Drop just those entries, keep the rest.
    execute("""
    UPDATE workspaces
    SET disabled_page_types = ARRAY(
      SELECT t FROM unnest(disabled_page_types) AS t WHERE t NOT IN (#{types})
    )
    WHERE disabled_page_types && ARRAY[#{types}]::varchar[]
    """)
  end

  def down do
    # Irreversible — ver el moduledoc. No-op a propósito: no inventamos datos.
    :ok
  end
end
