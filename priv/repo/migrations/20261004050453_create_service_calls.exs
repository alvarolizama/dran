defmodule Dran.Repo.Migrations.CreateServiceCalls do
  @moduledoc """
  El registro de cada EJECUCIÓN de una tool de servicio.

  dran está en medio de cada llamada (F30) y eso es exactamente lo que permite
  el registro: quién la pidió (`user_id`), qué agente (`actor` + `agent_name`
  del header `X-Hermes-Agent`), qué tool (`toolkit` + `tool_slug`), el `log_id`
  que devuelve el vendor y un resumen TRUNCADO del resultado.

  Lo que NO guarda: credenciales. El vendor las redacta por diseño (F36) y el
  registro además las descarta por nombre antes de escribir (`Call.redact/1`).

  `status` distingue el camino: `ok` (el vendor ejecutó), `error` (el vendor
  falló) y `blocked` (dran cortó antes, p. ej. sin conexión `ACTIVE`) — así el
  log dice también lo que NO llegó al proveedor.
  """

  use Ecto.Migration

  def up do
    create table(:service_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :toolkit, :string, null: false
      add :tool_slug, :string, null: false
      add :actor, :string
      add :agent_name, :string
      add :log_id, :string
      add :status, :string, default: "ok", null: false
      add :result, :text
      add :duration_ms, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:service_calls, [:user_id])
    create index(:service_calls, [:toolkit, :inserted_at])
    create index(:service_calls, [:tool_slug])
  end

  def down do
    drop_if_exists index(:service_calls, [:user_id])
    drop_if_exists index(:service_calls, [:toolkit, :inserted_at])
    drop_if_exists index(:service_calls, [:tool_slug])
    drop table(:service_calls)
  end
end
