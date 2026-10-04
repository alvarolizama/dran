defmodule DranWeb.API.GoalsTest do
  @moduledoc """
  Gate W2 (contrato de superficies): la superficie REST de los goals.

  - P1: crear un goal lo sella con el dueño de la credencial y `private`, y un
    tercero no lo lee ni por id ni por slug (404, sin fuga de existencia).
  - P2: el destino se declara por escritura (`scope: group + slug` deja el goal
    compartido y un miembro lo lee; un grupo ajeno da 422 y NO deja fila).
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Goals, Sharing}

  setup do
    Dran.DataCase.ensure_workspace!()
    u = u()

    {:ok, owner} =
      Accounts.create_user(%{
        email: "goal-owner-#{u}@example.com",
        name: "Owner",
        api_token: "tok-goal-owner-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "goal-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-goal-stranger-#{u}"
      })

    {:ok, member} =
      Accounts.create_user(%{
        email: "goal-member-#{u}@example.com",
        name: "Member",
        api_token: "tok-goal-member-#{u}"
      })

    %{owner: owner, stranger: stranger, member: member}
  end

  describe "crear" do
    test "lo sella con el dueño de la credencial y `private`", %{owner: owner} do
      body =
        json_response(post_json(conn_for(owner), "/api/goals", %{"title" => "Lanzamiento"}), 201)

      goal = body["data"]
      assert goal["owner_user_id"] == owner.id
      assert goal["visibility"] == "private"
      assert goal["slug"] == "lanzamiento"
      assert goal["status"] == "active"
    end

    test "el cliente NO puede declarar el dueño", %{owner: owner, stranger: stranger} do
      body =
        json_response(
          post_json(conn_for(owner), "/api/goals", %{
            "title" => "Ajeno",
            "owner_user_id" => stranger.id
          }),
          201
        )

      assert body["data"]["owner_user_id"] == owner.id
    end

    test "sin título es 422 con errores por campo", %{owner: owner} do
      body = json_response(post_json(conn_for(owner), "/api/goals", %{}), 422)
      assert body["errors"]["title"]
    end
  end

  describe "leer (P1)" do
    test "el dueño lee lo suyo por id y por slug; el tercero no", %{
      owner: owner,
      stranger: stranger
    } do
      goal = create_goal!(owner, %{"title" => "Privado"})

      mine = json_response(get_json(conn_for(owner), "/api/goals/#{goal.id}"), 200)
      assert mine["data"]["id"] == goal.id

      by_slug = json_response(get_json(conn_for(owner), "/api/goals/#{goal.slug}"), 200)
      assert by_slug["data"]["id"] == goal.id

      assert json_response(get_json(conn_for(stranger), "/api/goals/#{goal.id}"), 404)
      assert json_response(get_json(conn_for(stranger), "/api/goals/#{goal.slug}"), 404)
    end

    test "el índice no incluye lo ajeno privado", %{owner: owner, stranger: stranger} do
      goal = create_goal!(owner, %{"title" => "Mío"})

      ids =
        conn_for(stranger)
        |> get_json("/api/goals")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      refute goal.id in ids
    end

    test "lo público lo lee cualquiera", %{owner: owner, stranger: stranger} do
      goal = create_goal!(owner, %{"title" => "Público", "scope" => "public"})

      body = json_response(get_json(conn_for(stranger), "/api/goals/#{goal.id}"), 200)
      assert body["data"]["id"] == goal.id
      assert body["data"]["visibility"] == "public"
    end

    test "un segmento forjado es 404 limpio", %{owner: owner} do
      assert json_response(get_json(conn_for(owner), "/api/goals/nope-forjado-xyz"), 404)
    end

    test "el filtro por status funciona", %{owner: owner} do
      create_goal!(owner, %{"title" => "Activo", "status" => "active"})
      create_goal!(owner, %{"title" => "En pausa", "status" => "on_hold"})

      data =
        conn_for(owner)
        |> get_json("/api/goals?status=on_hold")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(data, & &1["title"]) == ["En pausa"]
    end

    test "GET /api/goals/:slug/tasks trae las tasks del goal legible", %{
      owner: owner,
      stranger: stranger
    } do
      goal = create_goal!(owner, %{"title" => "Con tasks"})
      {:ok, task} = Dran.Tasks.create_task(%{"goal_id" => goal.id, "title" => "Una"})

      body = json_response(get_json(conn_for(owner), "/api/goals/#{goal.id}/tasks"), 200)
      assert Enum.map(body["data"], & &1["id"]) == [task.id]

      # El goal ajeno privado no enumera sus tasks: 404, no lista vacía.
      assert json_response(get_json(conn_for(stranger), "/api/goals/#{goal.id}/tasks"), 404)
    end
  end

  describe "actualizar y borrar" do
    test "el dueño actualiza y el tercero recibe 404", %{owner: owner, stranger: stranger} do
      goal = create_goal!(owner, %{"title" => "Editable"})

      body =
        json_response(
          put_json(conn_for(owner), "/api/goals/#{goal.id}", %{"title" => "Editado"}),
          200
        )

      assert body["data"]["title"] == "Editado"

      assert json_response(
               put_json(conn_for(stranger), "/api/goals/#{goal.id}", %{"title" => "Hack"}),
               404
             )

      assert Dran.Repo.get!(Dran.Goals.Goal, goal.id).title == "Editado"
    end

    test "borrar deja 204 y la fila se va; el tercero no borra", %{
      owner: owner,
      stranger: stranger
    } do
      goal = create_goal!(owner, %{"title" => "Borrable"})

      assert conn_for(stranger) |> delete_json("/api/goals/#{goal.id}") |> response(404)
      assert Dran.Repo.get(Dran.Goals.Goal, goal.id)

      assert conn_for(owner) |> delete_json("/api/goals/#{goal.id}") |> response(204)
      assert Dran.Repo.get(Dran.Goals.Goal, goal.id) == nil
    end
  end

  describe "el destino por escritura (P2)" do
    test "scope de grupo: nace compartido y el miembro lo lee", %{
      owner: owner,
      member: member
    } do
      group = group_with(owner, [member])

      body =
        json_response(
          post_json(conn_for(owner), "/api/goals", %{
            "title" => "Del equipo",
            "scope" => %{"group" => group.slug}
          }),
          201
        )

      goal = body["data"]
      assert goal["visibility"] == "shared"

      member_read = json_response(get_json(conn_for(member), "/api/goals/#{goal["id"]}"), 200)
      assert member_read["data"]["id"] == goal["id"]
    end

    test "scope de grupo ajeno: 422 y el conteo de filas no cambia", %{
      owner: owner,
      stranger: stranger
    } do
      # El grupo existe pero el dueño de la escritura NO es miembro.
      {:ok, group} = Sharing.create_group(%{name: "Ajeno #{u()}"})
      {:ok, _} = Sharing.add_group_member(group, stranger.id)

      before = Dran.Repo.aggregate(Goals.Goal, :count, :id)

      body =
        json_response(
          post_json(conn_for(owner), "/api/goals", %{
            "title" => "No debería",
            "scope" => %{"group" => group.slug}
          }),
          422
        )

      assert body["errors"]["detail"] =~ "member"
      assert Dran.Repo.aggregate(Goals.Goal, :count, :id) == before
    end

    test "scope fuera del vocabulario: 422, nunca private en silencio", %{owner: owner} do
      before = Dran.Repo.aggregate(Goals.Goal, :count, :id)

      body =
        json_response(
          post_json(conn_for(owner), "/api/goals", %{
            "title" => "Raro",
            "scope" => "amigos"
          }),
          422
        )

      assert body["errors"]["detail"] =~ "invalid scope"
      assert Dran.Repo.aggregate(Goals.Goal, :count, :id) == before
    end

    test "un update con scope re-traduce la visibilidad", %{owner: owner, member: member} do
      group = group_with(owner, [member])
      goal = create_goal!(owner, %{"title" => "Privado"})

      body =
        json_response(
          put_json(conn_for(owner), "/api/goals/#{goal.id}", %{
            "scope" => %{"group" => group.slug}
          }),
          200
        )

      assert body["data"]["visibility"] == "shared"
      assert json_response(get_json(conn_for(member), "/api/goals/#{goal.id}"), 200)
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

  defp create_goal!(owner, attrs) do
    conn = conn_for(owner)

    {scope, attrs} = Map.pop(attrs, "scope")

    attrs = if scope, do: Map.put(attrs, "scope", scope), else: attrs

    json_response(post_json(conn, "/api/goals", attrs), 201)
    |> Map.fetch!("data")
    |> then(&Dran.Repo.get!(Dran.Goals.Goal, &1["id"]))
  end

  defp group_with(owner, members) do
    {:ok, group} = Sharing.create_group(%{name: "Equipo #{u()}"})
    {:ok, _} = Sharing.add_group_member(group, owner.id)
    Enum.each(members, fn m -> {:ok, _} = Sharing.add_group_member(group, m.id) end)
    group
  end
end
