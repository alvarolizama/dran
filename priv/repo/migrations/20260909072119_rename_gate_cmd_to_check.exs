defmodule Dran.Repo.Migrations.RenameGateCmdToCheck do
  use Ecto.Migration

  @doc """
  Gates: `cmd` → `check`.

  The done-criterion of a gate is no longer required to be a command — it can
  be any verifiable probe (a shell command, an expected output artifact like
  a rendered video, a frame analysis, ...). The embed key is renamed in place
  on the stored JSONB; rows that already carry `check` (future-proofed) or
  have no `cmd` are left untouched.
  """
  def change do
    execute """
            UPDATE workflow_steps
            SET gates = (
              SELECT COALESCE(jsonb_agg(
                CASE
                  WHEN elem ? 'cmd' AND NOT (elem ? 'check')
                  THEN (elem - 'cmd') || jsonb_build_object('check', elem->'cmd')
                  WHEN elem ? 'cmd' AND elem ? 'check'
                  THEN elem - 'cmd'
                  ELSE elem
                END
                ORDER BY ord
              ), '[]'::jsonb)
              FROM jsonb_array_elements(gates) WITH ORDINALITY AS t(elem, ord)
            )
            WHERE gates IS NOT NULL AND gates != '[]'::jsonb;
            """,
            """
            UPDATE workflow_steps
            SET gates = (
              SELECT COALESCE(jsonb_agg(
                CASE
                  WHEN elem ? 'check' AND NOT (elem ? 'cmd')
                  THEN (elem - 'check') || jsonb_build_object('cmd', elem->'check')
                  WHEN elem ? 'check' AND elem ? 'cmd'
                  THEN elem - 'check'
                  ELSE elem
                END
                ORDER BY ord
              ), '[]'::jsonb)
              FROM jsonb_array_elements(gates) WITH ORDINALITY AS t(elem, ord)
            )
            WHERE gates IS NOT NULL AND gates != '[]'::jsonb;
            """
  end
end
