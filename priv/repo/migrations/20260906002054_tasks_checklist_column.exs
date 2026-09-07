defmodule Dran.Repo.Migrations.TasksChecklistColumn do
  use Ecto.Migration

  # Wave "step = contrato" (2026-09): el único contenido vivo de `tasks.meta`
  # es el checklist (subtareas kanban). Se promueve a columna jsonb propia y
  # `meta` se elimina — el cajón de sastre ya no tiene lectores.
  #
  # Shape: [%{"text" => "...", "done" => false}] — mismo JSON que vivía en
  # meta["checklist"] (escrito por MCP y el board).
  def change do
    alter table(:tasks) do
      add :checklist, :map, default: fragment("'[]'::jsonb")
    end

    # Backfill: meta["checklist"] → checklist (solo si existe y es lista);
    # el resto de meta no tiene lectores → se descarta con el drop.
    execute(
      """
      UPDATE tasks
      SET checklist = meta->'checklist'
      WHERE meta IS NOT NULL AND jsonb_typeof(meta->'checklist') = 'array'
      """,
      """
      UPDATE tasks
      SET meta = jsonb_build_object('checklist', checklist)
      WHERE checklist IS NOT NULL AND jsonb_typeof(checklist::jsonb) = 'array'
      """
    )

    alter table(:tasks) do
      remove :meta
    end
  end
end
