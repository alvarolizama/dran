defmodule Dran.Repo.Migrations.CreateServiceSessions do
  @moduledoc """
  UNA sesión de Composio por usuario, persistente y reusada.

  El vendor lo dice al revés de lo que sugiere la intuición: «Reuse one session
  — don't create one per request» (F4). Crear una por request quema recurso,
  pierde la configuración y multiplica latencia.

  * `user_id` — la identidad estable del lector que se manda a Composio como
    `user_id` (ver `Dran.Services.identity_for/1`), con índice ÚNICO: la
    segunda llamada reusa, no duplica.
  * `composio_session_id` — el `trs_…` de la sesión. Nunca sale al cliente.
  * `toolkits` — snapshot de la allowlist de instancia en el momento de crear
    (o de reescribir) la sesión: es lo que permite detectar que el catálogo del
    owner cambió y `PATCH`ear en vez de recrear.

  Sin `workspace_id`: la instancia ES el contenedor (modelo single-workspace).
  """

  use Ecto.Migration

  def up do
    create table(:service_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :composio_session_id, :string, null: false
      add :toolkits, {:array, :string}, default: [], null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:service_sessions, [:user_id])
  end

  def down do
    drop_if_exists unique_index(:service_sessions, [:user_id])
    drop table(:service_sessions)
  end
end
