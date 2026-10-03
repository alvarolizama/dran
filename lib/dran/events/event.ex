defmodule Dran.Events.Event do
  @moduledoc """
  Un evento de la agenda: un rango temporal con dueño y visibilidad propios.

  A diferencia de una task (que hereda la lectura de su goal), un evento ES el
  ítem de contenido: declara `visibility` (default `private`) y `owner_user_id`,
  y su lectura pasa por `Dran.ContentVisibility.filter/3`. NO hay entidad
  «calendario»: el evento lleva su propio dueño (Constraint 18).

  Sus reminders NO declaran visibilidad: cuelgan de este evento (`event_id NOT
  NULL`) y heredan su lectura (Constraint 17 / F2).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :title,
             :notes,
             :starts_at,
             :ends_at,
             :all_day,
             :recurrence,
             :visibility,
             :owner_user_id,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @recurrences ~w(none daily weekly monthly)

  schema "events" do
    field :title, :string
    field :notes, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :all_day, :boolean, default: false
    field :recurrence, :string, default: "none"

    # Visibilidad por ítem, default privado (Constraint 2).
    field :visibility, :string, default: "private"

    # Dueño server-side; NULL = contenido de sistema (workspace-wide).
    field :owner_user_id, :integer

    field :archived, :boolean, default: false

    has_many :reminders, Dran.Events.Reminder, foreign_key: :event_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de creación/actualización de un evento."
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :title,
      :notes,
      :starts_at,
      :ends_at,
      :all_day,
      :recurrence,
      :visibility,
      :owner_user_id,
      :archived
    ])
    |> validate_required([:title, :starts_at])
    |> validate_length(:title, max: 500)
    |> validate_inclusion(:visibility, ~w(private public shared))
    |> validate_inclusion(:recurrence, @recurrences)
    |> foreign_key_constraint(:owner_user_id)
  end

  @doc "Opciones de recurrencia."
  def recurrences, do: @recurrences
end
