defmodule Dran.Repo.Migrations.StepsContractsPromotion do
  use Ecto.Migration

  # Wave "step = contrato" (2026-09): el contrato deja de vivir como
  # `steps.meta["contract"]` (jsonb opaco) y sube a columnas/embeds propios
  # del schema. `meta` se elimina en la misma pasada — su único otro
  # contenido era `meta["pos"]` (posición de canvas) y `meta["checklist"]`
  # NO existía en steps.
  #
  # Backfill:
  #   intent/status/version/fingerprint/model/generated_by ← meta.contract
  #   history                                         ← meta.contract.history
  #   claims/gates/context_snapshot                   ← meta.contract.* (jsonb → embeds)
  #   graph                                           ← meta.contract.graph (jsonb → embeds, mismo shape)
  #   pos_x/pos_y                                     ← meta.pos.x / meta.pos.y
  #
  # Columnas nulas == ausencia (intent NULL = step sin contrato legacy;
  # el changeset nuevo exige intent, pero el backfill no inventa datos).
  def change do
    alter table(:steps) do
      add :intent, :string
      add :status, :string, default: "draft"
      add :version, :integer, default: 1
      add :history, :map, default: fragment("'[]'::jsonb")
      add :fingerprint, :string
      add :model, :string
      add :generated_by, :string
      add :claims, :map, default: fragment("'[]'::jsonb")
      add :gates, :map, default: fragment("'[]'::jsonb")
      add :graph, :map
      add :context_snapshot, :map, default: fragment("'[]'::jsonb")
      add :pos_x, :integer
      add :pos_y, :integer
    end

    execute(
      """
      UPDATE steps SET
        intent          = meta->'contract'->>'intent',
        status          = COALESCE(meta->'contract'->>'status', 'draft'),
        version         = COALESCE((meta->'contract'->>'version')::int, 1),
        history         = COALESCE(meta->'contract'->'history', '[]'::jsonb),
        fingerprint     = meta->'contract'->>'fingerprint',
        model           = meta->'contract'->>'model',
        generated_by    = meta->'contract'->>'generated_by',
        claims          = COALESCE(meta->'contract'->'claims', '[]'::jsonb),
        gates           = COALESCE(meta->'contract'->'gates', '[]'::jsonb),
        graph           = meta->'contract'->'graph',
        context_snapshot= COALESCE(meta->'contract'->'context_snapshot', '[]'::jsonb),
        pos_x           = (meta->'pos'->>'x')::int,
        pos_y           = (meta->'pos'->>'y')::int
      WHERE meta IS NOT NULL
      """,
      """
      UPDATE steps SET
        meta = jsonb_strip_nulls(jsonb_build_object(
          'contract',
          jsonb_build_object(
            'intent', intent,
            'status', status,
            'version', version,
            'history', history,
            'fingerprint', fingerprint,
            'model', model,
            'generated_by', generated_by,
            'claims', claims,
            'gates', gates,
            'graph', graph,
            'context_snapshot', context_snapshot
          ),
          'pos', CASE WHEN pos_x IS NOT NULL AND pos_y IS NOT NULL
                      THEN jsonb_build_object('x', pos_x, 'y', pos_y)
                      ELSE NULL END
        ))
      WHERE intent IS NOT NULL OR pos_x IS NOT NULL OR pos_y IS NOT NULL
      """
    )

    alter table(:steps) do
      remove :meta
    end
  end
end
