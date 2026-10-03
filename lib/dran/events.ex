defmodule Dran.Events do
  @moduledoc """
  El contexto de eventos y reminders — CRUD y la **lectura heredada**.

  Un evento es un ítem de contenido con dueño y visibilidad propios
  (`visibility` default `private` + `owner_user_id`), leído por
  `Dran.ContentVisibility.filter/3` como el resto del contenido. NO hay entidad
  «calendario»: el evento lleva su propio dueño (Constraint 18) y no se
  direcciona por slug (Constraint 14) — la dirección canónica es el uuid.

  ## Los reminders heredan la lectura de su evento

  Un reminder NO declara `visibility` ni `owner_user_id`: cuelga de su evento
  (`event_id NOT NULL`) y toda lectura de reminders entra por un JOIN al evento
  visible, de modo que un reminder de un evento fuera del alcance NUNCA
  aparece (Constraint 17 / F2). El filtro es la misma política única, aplicada
  sobre el evento — no hay una segunda regla para reminders.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Events.Event
  alias Dran.Events.Reminder

  # ──────────────────────────────────────────────────────────────────────────
  # Eventos — lectura con la política única
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Lista eventos con scope de lectura.

  Opts: `:scope` (default `:all` para callers internos), `:archived`
  (default `false`), `:limit`. La agenda ordena por fecha.
  """
  def list_events(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    archived = Keyword.get(opts, :archived, false)
    limit = Keyword.get(opts, :limit, 500)

    from(e in Event,
      where: e.archived == ^archived,
      order_by: [asc: e.starts_at, asc: e.inserted_at],
      limit: ^limit
    )
    |> Dran.ContentVisibility.filter(scope, :event)
    |> Repo.all()
  end

  @doc """
  Trae un evento por id con scope de lectura.

  Un evento fuera del scope del lector se lee como inexistente (sin fuga de
  existencia). Un id forjado no-UUID devuelve `nil` (el `Repo` reventaría con
  `Ecto.Query.CastError`).
  """
  def get_event(id, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)

    with true <- valid_uuid?(id) do
      Event
      |> where([e], e.id == ^id)
      |> Dran.ContentVisibility.filter(scope, :event)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  @doc "Changeset para formularios."
  def change_event(%Event{} = event, attrs \\ %{}), do: Event.changeset(event, attrs)

  # ──────────────────────────────────────────────────────────────────────────
  # Eventos — escritura
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea un evento.

  `owner_user_id` llega YA resuelto server-side desde los attrs que le pasa el
  llamador (sesión web o la cuenta dueña del token); jamás desde el body del
  cliente. A diferencia de goals/collections, un evento NO lleva slug: se
  direcciona por uuid (Constraint 18/14).
  """
  def create_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Actualiza un evento."
  def update_event(%Event{} = event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Borra un evento. Sus reminders caen por la FK `on_delete: :delete_all` del
  motor — no quedan huérfanos.
  """
  def delete_event(%Event{} = event), do: Repo.delete(event)

  # ──────────────────────────────────────────────────────────────────────────
  # Reminders — lectura heredada del evento
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Crea un reminder colgando de `event`.

  El `event_id` lo sella este contexto desde el evento dado — nunca el cliente;
  un reminder no puede existir sin evento (el changeset lo exige y el motor lo
  garantiza con `NOT NULL` + FK).
  """
  def create_reminder(%Event{} = event, attrs) do
    attrs
    |> Map.delete("event_id")
    |> Map.delete(:event_id)
    |> Map.put(:event_id, event.id)
    |> then(&(%Reminder{} |> Reminder.changeset(&1) |> Repo.insert()))
  end

  @doc """
  Reminders de un evento, con scope de lectura.

  Acepta el `%Event{}` o su id. La lectura entra por un JOIN al evento visible:
  un reminder de un evento fuera del alcance del lector devuelve `[]` — el
  filtro corre sobre el EVENTO, no sobre el reminder.
  """
  def list_reminders_for_event(event_or_id, opts \\ [])

  def list_reminders_for_event(%Event{} = event, opts) do
    list_reminders_for_event(event.id, opts)
  end

  def list_reminders_for_event(event_id, opts) when is_binary(event_id) and is_list(opts) do
    scope = Keyword.get(opts, :scope, :all)

    from(r in Reminder,
      join: e in subquery(visible_events_query(scope)),
      on: e.id == r.event_id,
      where: r.event_id == ^event_id,
      order_by: [asc: r.fire_at, asc: r.inserted_at],
      select: r
    )
    |> Repo.all()
  end

  @doc """
  Reminders vencidos y todavía sin entregar, con scope de lectura.

  Opts: `:scope` (default `:all`), `:now` (default `utc_now`). Igual que
  `list_reminders_for_event/2`, la lectura se hereda del evento por JOIN: un
  reminder de un evento fuera del alcance del lector no aparece.
  """
  def due_reminders(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

    from(r in Reminder,
      join: e in subquery(visible_events_query(scope)),
      on: e.id == r.event_id,
      where: is_nil(r.delivered_at) and r.fire_at <= ^now,
      order_by: [asc: r.fire_at, asc: r.inserted_at],
      select: r
    )
    |> Repo.all()
  end

  @doc "Marca un reminder como entregado."
  def deliver_reminder(%Reminder{} = reminder) do
    reminder
    |> Reminder.changeset(%{delivered_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  # Mete el evento visible en una subquery para que `filter/3` corra sobre el
  # EVENTO (que es quien tiene `visibility` + `owner_user_id`) y el JOIN no
  # pueda fugar un reminder de un evento ajeno.
  defp visible_events_query(scope) do
    from(e in Event, select: e)
    |> Dran.ContentVisibility.filter(scope, :event)
  end

  # Los params forjados pueden traer cualquier binario; `Repo.get/2` revienta
  # con un id no-UUID.
  defp valid_uuid?(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
