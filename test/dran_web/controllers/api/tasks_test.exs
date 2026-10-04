defmodule DranWeb.API.TasksTest do
  @moduledoc """
  Gate W2 (contrato de superficies): la superficie REST de las tasks.

  - P3: crear una task sin `goal` cae en el goal bandeja del dueño, creado
    perezosamente e idempotente.
  - P4: mover una task es un `UPDATE` atómico que respeta `lock_version` (409 al
    desfase) y recomputa el progreso derivado de los dos goals.
  - P5: una task de un goal ajeno privado no se lee ni se mueve (hereda la
    visibilidad de su goal y no declara la suya).
  - Constraint 13: `update` NO toca `status`, `position`, `goal_id` ni
    `lock_version`; el move tiene una sola puerta.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Goals, Tasks}
  alias Dran.Sharing

  setup do
    Dran.DataCase.ensure_workspace!()
    u = u()

    {:ok, owner} =
      Accounts.create_user(%{
        email: "task-owner-#{u}@example.com",
        name: "Owner",
        api_token: "tok-task-owner-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "task-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-task-stranger-#{u}"
      })

    {:ok, member} =
      Accounts.create_user(%{
        email: "task-member-#{u}@example.com",
        name: "Member",
        api_token: "tok-task-member-#{u}"
      })

    %{owner: owner, stranger: stranger, member: member}
  end

  describe "crear (P3)" do
    test "con goal explícito: nace en backlog al final de la columna", %{owner: owner} do
      goal = goal!(owner)

      body =
        json_response(
          post_json(conn_for(owner), "/api/tasks", %{
            "goal" => goal.id,
            "title" => "Comprar pan"
          }),
          201
        )

      task = body["data"]
      assert task["goal_id"] == goal.id
      assert task["status"] == "backlog"
      assert task["position"] == 100
    end

    test "sin goal: cae en el goal bandeja, creado perezosamente e idempotente", %{owner: owner} do
      assert Goals.get_inbox(owner.id) == nil

      first =
        json_response(post_json(conn_for(owner), "/api/tasks", %{"title" => "Captura"}), 201)

      inbox = Goals.get_inbox(owner.id)
      assert inbox.slug == "inbox"
      assert first["data"]["goal_id"] == inbox.id

      second =
        json_response(post_json(conn_for(owner), "/api/tasks", %{"title" => "Otra"}), 201)

      assert second["data"]["goal_id"] == inbox.id
      assert Goals.list_goals(owner_user_id: owner.id) |> Enum.count(&(&1.slug == "inbox")) == 1
    end

    test "POST /api/capture es la misma puerta que la captura rápida", %{owner: owner} do
      body =
        json_response(post_json(conn_for(owner), "/api/capture", %{"title" => "Rápida"}), 201)

      assert body["data"]["goal_id"] == Goals.get_inbox(owner.id).id
    end

    test "crear dentro del goal ajeno privado es 404 (fail-closed)", %{
      owner: owner,
      stranger: stranger
    } do
      goal = goal!(owner)
      before = Dran.Repo.aggregate(Tasks.Task, :count, :id)

      assert json_response(
               post_json(conn_for(stranger), "/api/tasks", %{
                 "goal" => goal.id,
                 "title" => "Intrusa"
               }),
               404
             )

      assert Dran.Repo.aggregate(Tasks.Task, :count, :id) == before
    end

    test "el checklist que llega en la creación se normaliza", %{owner: owner} do
      goal = goal!(owner)

      body =
        json_response(
          post_json(conn_for(owner), "/api/tasks", %{
            "goal" => goal.id,
            "title" => "Con pasos",
            "checklist" => ["uno", %{"text" => "dos", "done" => true}]
          }),
          201
        )

      assert body["data"]["checklist"] == [
               %{"text" => "uno", "done" => false},
               %{"text" => "dos", "done" => true}
             ]
    end
  end

  describe "leer (P5)" do
    test "el índice sólo muestra tasks de goals legibles", %{owner: owner, stranger: stranger} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Mía"})

      mine = json_response(get_json(conn_for(owner), "/api/tasks"), 200)
      assert Enum.map(mine["data"], & &1["id"]) == [task.id]

      theirs = json_response(get_json(conn_for(stranger), "/api/tasks"), 200)
      assert theirs["data"] == []

      assert json_response(get_json(conn_for(stranger), "/api/tasks/#{task.id}"), 404)
    end

    test "el filtro por goal funciona y un goal ajeno no enumera nada", %{
      owner: owner,
      stranger: stranger
    } do
      goal = goal!(owner)
      other = goal!(owner)
      task!(goal, %{"title" => "A"})
      task!(other, %{"title" => "B"})

      filtered =
        conn_for(owner)
        |> get_json("/api/tasks?goal=#{goal.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(filtered, & &1["title"]) == ["A"]

      # El goal legible también se puede pedir por slug.
      by_slug =
        conn_for(owner)
        |> get_json("/api/tasks?goal=#{goal.slug}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(by_slug, & &1["title"]) == ["A"]

      assert conn_for(stranger)
             |> get_json("/api/tasks?goal=#{goal.id}")
             |> json_response(200)
             |> Map.fetch!("data") == []
    end

    test "el filtro por columna funciona", %{owner: owner} do
      goal = goal!(owner)
      task!(goal, %{"title" => "Backlog"})
      done = task!(goal, %{"title" => "Hecha", "status" => "done"})

      data =
        conn_for(owner)
        |> get_json("/api/tasks?status=done")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(data, & &1["id"]) == [done.id]
    end

    test "el goal compartido con un grupo: la task la lee el miembro, no el tercero", %{
      owner: owner,
      member: member,
      stranger: stranger
    } do
      # La task NO declara visibilidad: hereda la del goal, así que compartir el
      # goal es lo que comparte sus tasks (y el caso positivo faltaba).
      group = group_with(owner, [member])

      goal =
        json_response(
          post_json(conn_for(owner), "/api/goals", %{
            "title" => "Del equipo",
            "scope" => %{"group" => group.slug}
          }),
          201
        )["data"]

      assert goal["visibility"] == "shared"

      task =
        json_response(
          post_json(conn_for(owner), "/api/tasks", %{
            "goal" => goal["id"],
            "title" => "La del equipo"
          }),
          201
        )["data"]

      # El miembro la lee, y también la ve en el índice…
      assert json_response(get_json(conn_for(member), "/api/tasks/#{task["id"]}"), 200)["data"][
               "id"
             ] ==
               task["id"]

      listed =
        conn_for(member) |> get_json("/api/tasks") |> json_response(200) |> Map.fetch!("data")

      assert Enum.any?(listed, &(&1["id"] == task["id"]))

      # …y el tercero no: 404 (fail-closed, la existencia no se filtra).
      assert json_response(get_json(conn_for(stranger), "/api/tasks/#{task["id"]}"), 404)
    end
  end

  describe "actualizar (Constraint 13)" do
    test "cambia el contenido", %{owner: owner} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Editable"})

      body =
        json_response(
          put_json(conn_for(owner), "/api/tasks/#{task.id}", %{
            "title" => "Editada",
            "priority" => "high",
            "due_date" => "2026-11-01",
            "checklist" => ["paso"]
          }),
          200
        )

      assert body["data"]["title"] == "Editada"
      assert body["data"]["priority"] == "high"
      assert body["data"]["due_date"] == "2026-11-01"
      assert body["data"]["checklist"] == [%{"text" => "paso", "done" => false}]
    end

    test "NO mueve la columna ni el goal: los campos del move se ignoran", %{owner: owner} do
      goal = goal!(owner)
      other = goal!(owner)
      task = task!(goal, %{"title" => "Quieta"})

      body =
        json_response(
          put_json(conn_for(owner), "/api/tasks/#{task.id}", %{
            "status" => "done",
            "goal_id" => other.id,
            "position" => 9999,
            "lock_version" => 42
          }),
          200
        )

      assert body["data"]["status"] == "backlog"
      assert body["data"]["goal_id"] == goal.id
      assert body["data"]["position"] == 100
      assert body["data"]["lock_version"] == 1
    end
  end

  describe "mover (P4)" do
    test "cambia de columna y sube el lock_version", %{owner: owner} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Movible"})

      body =
        json_response(
          post_json(conn_for(owner), "/api/tasks/#{task.id}/move", %{
            "status" => "done",
            "lock_version" => task.lock_version
          }),
          200
        )

      assert body["data"]["status"] == "done"
      assert body["data"]["lock_version"] == task.lock_version + 1
    end

    test "un lock_version viejo es 409 y no cambia nada", %{owner: owner} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Carrera"})

      # La mano rápida mueve primero (lock_version 1 → 2).
      json_response(
        post_json(conn_for(owner), "/api/tasks/#{task.id}/move", %{
          "status" => "in_progress",
          "lock_version" => 1
        }),
        200
      )

      # La mano lenta sigue creyendo que la versión es 1.
      body =
        json_response(
          post_json(conn_for(owner), "/api/tasks/#{task.id}/move", %{
            "status" => "done",
            "lock_version" => 1
          }),
          409
        )

      assert body["errors"]["detail"] =~ "moved elsewhere"
      assert Dran.Repo.get!(Tasks.Task, task.id).status == "in_progress"
    end

    test "mover entre goals recomputa el progreso derivado de los DOS", %{owner: owner} do
      origin = goal!(owner)
      target = goal!(owner)
      task = task!(origin, %{"title" => "Viajera"})
      {:ok, _} = Tasks.create_task(%{"goal_id" => origin.id, "title" => "Compañera"})

      assert Goals.progress(origin).total == 2

      json_response(
        post_json(conn_for(owner), "/api/tasks/#{task.id}/move", %{
          "goal" => target.id,
          "lock_version" => task.lock_version
        }),
        200
      )

      assert Goals.progress(origin).total == 1
      assert Goals.progress(target).total == 1
      assert Dran.Repo.get!(Tasks.Task, task.id).goal_id == target.id
    end

    test "mover al goal ajeno privado es 404 y no mueve", %{owner: owner, stranger: stranger} do
      mine = goal!(owner)
      theirs = goal!(stranger)
      task = task!(mine, %{"title" => "No viaja"})

      assert json_response(
               post_json(conn_for(owner), "/api/tasks/#{task.id}/move", %{
                 "goal" => theirs.id,
                 "lock_version" => task.lock_version
               }),
               404
             )

      assert Dran.Repo.get!(Tasks.Task, task.id).goal_id == mine.id
    end

    test "la task del goal ajeno no se mueve ni se borra", %{owner: owner, stranger: stranger} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Ajena"})

      assert json_response(
               post_json(conn_for(stranger), "/api/tasks/#{task.id}/move", %{"status" => "done"}),
               404
             )

      assert conn_for(stranger) |> delete_json("/api/tasks/#{task.id}") |> response(404)
      assert Dran.Repo.get(Tasks.Task, task.id)
    end
  end

  describe "el checklist tiene su puerta" do
    test "toggle por índice y por texto, sobre la misma ruta que el plan", %{owner: owner} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Con checklist", "checklist" => ["uno", "dos"]})

      body =
        json_response(
          post_json(conn_for(owner), "/api/checklist/toggle", %{
            "target" => "task",
            "id" => task.id,
            "index" => 0
          }),
          200
        )

      assert body["data"]["checklist"] == [
               %{"text" => "uno", "done" => true},
               %{"text" => "dos", "done" => false}
             ]

      body =
        json_response(
          post_json(conn_for(owner), "/api/checklist/toggle", %{
            "target" => "task",
            "id" => task.id,
            "text" => "dos",
            "lock_version" => body["data"]["lock_version"]
          }),
          200
        )

      assert body["data"]["checklist"] == [
               %{"text" => "uno", "done" => true},
               %{"text" => "dos", "done" => true}
             ]
    end

    test "un ítem inexistente es 404 y un lock viejo es 409", %{owner: owner} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Con checklist", "checklist" => ["uno"]})

      assert json_response(
               post_json(conn_for(owner), "/api/checklist/toggle", %{
                 "target" => "task",
                 "id" => task.id,
                 "text" => "no está"
               }),
               404
             )

      # La primera mano tacha.
      json_response(
        post_json(conn_for(owner), "/api/checklist/toggle", %{
          "target" => "task",
          "id" => task.id,
          "index" => 0
        }),
        200
      )

      # La segunda llega con la versión vieja.
      assert json_response(
               post_json(conn_for(owner), "/api/checklist/toggle", %{
                 "target" => "task",
                 "id" => task.id,
                 "index" => 0,
                 "lock_version" => task.lock_version
               }),
               409
             )
    end

    test "target inválido o sin referencia es 400", %{owner: owner} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "X"})

      assert json_response(
               post_json(conn_for(owner), "/api/checklist/toggle", %{
                 "target" => "goal",
                 "id" => task.id,
                 "index" => 0
               }),
               400
             )

      assert json_response(
               post_json(conn_for(owner), "/api/checklist/toggle", %{
                 "target" => "task",
                 "id" => task.id
               }),
               400
             )
    end
  end

  describe "borrar" do
    test "el dueño borra y el tercero no", %{owner: owner, stranger: stranger} do
      goal = goal!(owner)
      task = task!(goal, %{"title" => "Borrable"})

      assert conn_for(stranger) |> delete_json("/api/tasks/#{task.id}") |> response(404)
      assert conn_for(owner) |> delete_json("/api/tasks/#{task.id}") |> response(204)
      assert Dran.Repo.get(Tasks.Task, task.id) == nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  defp post_json(conn, path, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp put_json(conn, path, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end

  defp get_json(conn, path), do: get(conn, path)
  defp delete_json(conn, path), do: delete(conn, path)

  defp goal!(owner) do
    {:ok, goal} =
      Goals.create_goal(%{"title" => "Meta #{u()}", "owner_user_id" => owner.id})

    goal
  end

  defp task!(goal, attrs) do
    {:ok, task} = Tasks.create_task(Map.put(attrs, "goal_id", goal.id))
    task
  end

  # Un grupo con el dueño dentro y los miembros que se pidan (el mismo helper de
  # `goals_test`: la membresía es lo que hace legible lo compartido).
  defp group_with(owner, members) do
    {:ok, group} = Sharing.create_group(%{name: "Equipo #{u()}"})
    {:ok, _} = Sharing.add_group_member(group, owner.id)
    Enum.each(members, fn m -> {:ok, _} = Sharing.add_group_member(group, m.id) end)
    group
  end
end
