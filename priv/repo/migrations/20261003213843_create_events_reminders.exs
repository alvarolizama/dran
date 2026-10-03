defmodule Dran.Repo.Migrations.CreateEventsReminders do
  @moduledoc """
  Eventos y sus reminders (W4d, contract Constraints 17/18).

  ## El evento tiene su propio dueño y visibilidad

  `events` declara `owner_user_id` + `visibility` (default `private`) y se lee
  por `Dran.ContentVisibility.filter/3`, igual que páginas, memoria, colecciones,
  reports y goals. NO hay entidad «calendario»: el evento lleva su propio dueño
  (Constraint 18, resuelve `?02`).

  ## Los reminders NO declaran visibilidad ni dueño

  `reminders` cuelga de su evento (`event_id` NOT NULL, FK `on_delete:
  :delete_all`) y hereda su lectura — la lección de F2: una columna que nada
  consulta se envía como garantía y no filtra (Constraint 17). Borrar el evento
  borra sus reminders, no los deja huérfanos.
  """

  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :title, :string, null: false
      add :notes, :text

      # El rango temporal del evento: `starts_at` + `ends_at`; un `ends_at`
      # NULL es un evento puntual (sin duración).
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime

      add :all_day, :boolean, default: false, null: false

      # Vocabulario cerrado de recurrencia, como el de las tasks.
      add :recurrence, :string, default: "none", null: false

      # Visibilidad por ítem (el dueño y su política de lectura).
      add :visibility, :string, default: "private", null: false
      add :owner_user_id, references(:users, on_delete: :nilify_all)

      add :archived, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:events, [:visibility], where: "visibility = 'public'")
    create index(:events, [:owner_user_id])
    # La agenda ordena por fecha.
    create index(:events, [:starts_at])

    create table(:reminders, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # ── El invariante del motor: un reminder no existe sin evento ──
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all), null: false

      add :fire_at, :utc_datetime, null: false
      # La entrega: NULL = todavía no entregado.
      add :delivered_at, :utc_datetime
      add :channel, :string, default: "in_app", null: false

      timestamps(type: :utc_datetime)
    end

    # Los vencidos se buscan por (evento, disparo).
    create index(:reminders, [:event_id, :fire_at])
  end
end
