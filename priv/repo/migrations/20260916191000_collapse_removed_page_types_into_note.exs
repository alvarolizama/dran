defmodule Dran.Repo.Migrations.CollapseRemovedPageTypesIntoNote do
  use Ecto.Migration

  @moduledoc """
  M9 paso 1/2 — colapso REVERSIBLE de los tipos de página retirados.

  El registry (`Dran.PageRegistry`) queda con exactamente cuatro tipos
  (`note`, `entity`, `concept`, `reference`). Las filas que hoy tienen un tipo
  que el registry ya no conoce (`idea`, `knowledge`, `technical`, `food`) pasan
  a `note` — el tipo libre — conservando su tipo original en `meta.kind`, que
  sobrevive como valor de display y como dato recuperable.

  Sin cambio de esquema: `page_type` es texto validado en la capa de app.

  `down` es simétrico: restaura `page_type` desde `meta->>'kind'` y elimina la
  clave `kind` que este paso introdujo. Solo aplica a filas que quedaron en
  `note` con un `kind` del conjunto retirado — es decir, solo mientras la clave
  existe: el paso 2 (borrado irreversible de `meta.kind`) debe revertirse antes
  para que este `down` tenga de dónde restaurar.
  """

  @removed_types ~w(idea knowledge technical food)

  def up do
    types = Enum.map_join(@removed_types, ",", &"'#{&1}'")

    # Las expresiones del SET leen la fila VIEJA, así que `to_jsonb(page_type)`
    # captura el tipo original antes del colapso.
    execute("""
    UPDATE knowledge_pages
    SET page_type = 'note',
        meta = jsonb_set(coalesce(meta, '{}'::jsonb), '{kind}', to_jsonb(page_type))
    WHERE page_type IN (#{types})
    """)
  end

  def down do
    types = Enum.map_join(@removed_types, ",", &"'#{&1}'")

    execute("""
    UPDATE knowledge_pages
    SET page_type = meta->>'kind',
        meta = meta - 'kind'
    WHERE page_type = 'note'
      AND meta->>'kind' IN (#{types})
    """)
  end
end
