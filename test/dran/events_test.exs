defmodule Dran.EventsTest do
  @moduledoc """
  Gate W4d (contract.md): eventos y reminders con dueño y visibilidad propios.

  La matriz lector × evento —dueño, tercero, público, compartido con persona y
  compartido con grupo— pasa por `Dran.ContentVisibility.filter/3` (la política
  única), y los reminders HEREDAN la lectura de su evento: el reminder de un
  evento fuera del alcance no se lista ni se lee (Constraint 17/18 / F2).
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, ContentVisibility, Events, Sharing}

  setup do
    {:ok, author: member!("author"), reader: member!("reader"), outsider: member!("outsider")}
  end

  # ── La matriz de eventos ──────────────────────────────────────────────────

  describe "eventos" do
    test "privado: nace con dueño y solo su dueño lo lee", %{author: author, reader: reader} do
      event = event!(author)

      assert event.visibility == "private"
      assert event.owner_user_id == author.id

      assert Events.get_event(event.id, scope: scope(author)).id == event.id
      assert Events.list_events(scope: scope(author)) == [event]

      # El tercero no lo ve ni por lista ni por id (sin fuga de existencia).
      assert Events.list_events(scope: scope(reader)) == []
      assert is_nil(Events.get_event(event.id, scope: scope(reader)))
    end

    test "público: lo lee cualquier tercero", %{author: author, reader: reader} do
      event = event!(author, %{visibility: "public"})

      assert Events.list_events(scope: scope(reader)) == [event]
      assert Events.get_event(event.id, scope: scope(reader)).id == event.id
    end

    test "compartido con una persona: solo el invitado", %{
      author: author,
      reader: reader,
      outsider: outsider
    } do
      event = event!(author, %{visibility: "shared"})

      # `shared` sin share no lee nadie más que su dueño.
      assert Events.list_events(scope: scope(reader)) == []

      {:ok, :shared} = Sharing.share_with_user("event", event.id, reader.id)

      assert Events.get_event(event.id, scope: scope(reader)).id == event.id
      assert Events.list_events(scope: scope(reader)) == [event]

      # El invitado es el invitado, no cualquiera.
      assert Events.list_events(scope: scope(outsider)) == []
      assert is_nil(Events.get_event(event.id, scope: scope(outsider)))
    end

    test "compartido con un grupo: solo sus miembros", %{
      author: author,
      reader: reader,
      outsider: outsider
    } do
      event = event!(author, %{visibility: "shared"})

      {:ok, group} = Sharing.create_group(%{name: "Lectores #{uniq()}"})
      {:ok, _} = Sharing.add_group_member(group, reader.id)
      {:ok, :shared} = Sharing.share_with_group("event", event.id, group.id)

      assert Events.get_event(event.id, scope: scope(reader)).id == event.id
      assert Events.list_events(scope: scope(reader)) == [event]
      assert Events.list_events(scope: scope(outsider)) == []
    end
  end

  # ── Los reminders heredan la lectura de su evento ─────────────────────────

  describe "reminders" do
    test "el reminder de un evento privado ajeno no se lista ni se lee", %{
      author: author,
      reader: reader
    } do
      event = event!(author)
      reminder = reminder!(event, past())

      # El id del evento ajeno no expone sus reminders…
      assert Events.list_reminders_for_event(event.id, scope: scope(reader)) == []
      # …ni la query de vencidos los devuelve.
      assert Events.due_reminders(scope: scope(reader)) == []

      # El dueño sí los ve.
      assert Events.list_reminders_for_event(event.id, scope: scope(author)) == [reminder]
      assert Events.due_reminders(scope: scope(author)) == [reminder]
    end

    test "el reminder de un evento público lo lee cualquier tercero", %{
      author: author,
      reader: reader
    } do
      event = event!(author, %{visibility: "public"})
      reminder = reminder!(event, past())

      assert Events.list_reminders_for_event(event, scope: scope(reader)) == [reminder]
      assert Events.due_reminders(scope: scope(reader)) == [reminder]
    end

    test "un reminder futuro no es vencido", %{author: author} do
      event = event!(author)
      _futuro = reminder!(event, future())

      assert Events.due_reminders(scope: scope(author)) == []
    end

    test "borrar el evento borra sus reminders", %{author: author} do
      event = event!(author)
      reminder = reminder!(event, past())

      {:ok, _} = Events.delete_event(event)

      assert is_nil(Repo.get(Dran.Events.Reminder, reminder.id))
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp member!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  # La scope que resuelve toda superficie: el módulo único, ninguna regla local.
  defp scope(user), do: ContentVisibility.resolve(nil, user, :event)

  defp event!(owner, extra \\ %{}) do
    extra = Map.new(extra, fn {k, v} -> {to_string(k), v} end)

    {:ok, event} =
      Events.create_event(
        Map.merge(
          %{
            "title" => "Evento #{uniq()}",
            "starts_at" => utc_now(),
            "owner_user_id" => owner.id
          },
          extra
        )
      )

    event
  end

  defp reminder!(event, fire_at) do
    {:ok, reminder} = Events.create_reminder(event, %{fire_at: fire_at})
    reminder
  end

  defp past, do: DateTime.add(utc_now(), -3600, :second)
  defp future, do: DateTime.add(utc_now(), 3600, :second)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp uniq, do: System.unique_integer([:positive])
end
