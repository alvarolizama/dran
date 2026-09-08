defmodule Dran.Repo.Migrations.DropGoalTeamAndMeta do
  @moduledoc """
  Drop the never-consumed `team` and `meta` fields from goals.

  Context (2026-09, decisión de Álvaro): `team` solo se escribía desde
  `dran_create_goal` y jamás se leía; `meta` quedaba en `%{}` en todos los
  seeds y ningún código leía claves. Ambos eran campos de reserva sin
  consumidores (misma limpieza que los OKR cosméticos en
  20260904013000_drop_goal_okr_cosmetic_fields). Los datos se pierden
  (asumido — no se consultaban).

  Reversible: recrea las columnas con sus tipos originales
  (migración 20260820070328), sin datos.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE goals DROP COLUMN IF EXISTS team")
    execute("ALTER TABLE goals DROP COLUMN IF EXISTS meta")
  end

  def down do
    execute("ALTER TABLE goals ADD COLUMN IF NOT EXISTS team varchar(255)[] DEFAULT '{}'")
    execute("ALTER TABLE goals ADD COLUMN IF NOT EXISTS meta jsonb DEFAULT '{}'::jsonb")
  end
end
