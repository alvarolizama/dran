defmodule Dran.Repo.Migrations.DropGoalOkrCosmeticFields do
  @moduledoc """
  Drop the never-wired OKR-cosmetic fields from goals: `kind`, `health`,
  `metric`, `target_value`, `current_value`, `unit`, `start_date`,
  `target_date`.

  Context (2026-09, decisión de Álvaro): ningún cálculo ni query los leía.
  `health` y `kind` eran badges manuales; `metric`/`target_value`/
  `current_value`/`unit` un sistema de medición que nunca se conectó a
  nada (el progreso real es derivado de tasks, `recompute_progress/1`);
  `start_date` no se mostraba y `target_date` era solo display. Los datos
  se pierden (asumido — son clasificación manual no consultada).

  Reversible: recrea las columnas (sin datos — la limpieza es destructiva
  por diseño). `kind`/`health`/`metric`/`unit` eran varchar, values/fechas
  sus tipos originales (migración 20260820070328).
  """

  use Ecto.Migration

  @columns [
    {:kind, "varchar(255)"},
    {:health, "varchar(255)"},
    {:metric, "varchar(255)"},
    {:target_value, "double precision"},
    {:current_value, "double precision"},
    {:unit, "varchar(255)"},
    {:start_date, "date"},
    {:target_date, "date"}
  ]

  def up do
    for {col, _type} <- @columns do
      execute("ALTER TABLE goals DROP COLUMN IF EXISTS #{col}")
    end
  end

  def down do
    for {col, type} <- @columns do
      execute("ALTER TABLE goals ADD COLUMN IF NOT EXISTS #{col} #{type}")
    end
  end
end
