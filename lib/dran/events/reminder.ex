defmodule Dran.Events.Reminder do
  @moduledoc """
  El disparo de un evento: cuándo recordar y si ya se entregó.

  Un reminder NO declara `visibility` ni `owner_user_id`: cuelga de su evento
  (`event_id NOT NULL`, FK `on_delete: :delete_all` en el motor) y hereda su
  lectura por join + `Dran.ContentVisibility.filter/3` (Constraint 17 / F2).
  Una columna que nada consulta se enviaría como garantía y no filtraría.

  `fire_at` es el momento del disparo; `delivered_at` NULL es «todavía no
  entregado». `channel` nombra el canal de entrega (default `in_app`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [:id, :event_id, :fire_at, :delivered_at, :channel, :inserted_at, :updated_at]}

  schema "reminders" do
    field :fire_at, :utc_datetime
    field :delivered_at, :utc_datetime
    field :channel, :string, default: "in_app"

    # El contenedor: NOT NULL en la migración; la lectura se hereda de él.
    belongs_to :event, Dran.Events.Event

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de creación/actualización de un reminder."
  def changeset(reminder, attrs) do
    reminder
    |> cast(attrs, [:event_id, :fire_at, :delivered_at, :channel])
    |> validate_required([:event_id, :fire_at])
    |> foreign_key_constraint(:event_id)
  end
end
