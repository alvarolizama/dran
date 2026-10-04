defmodule DranWeb.API.PlansTest do
  @moduledoc """
  Gate W2 (contrato de superficies): la superficie REST de los planes.

  - P6: el plan es una entidad con dueño y visibilidad propios — ninguna lectura
    escapa del filtro único.
  - P9: el checklist se administra por su propia puerta desde las dos superficies
    que ya existen (`PUT /api/plans/:slug/checklist` y
    `POST /api/checklist/toggle`), sobre la misma fila y con `lock_version`.
  - El plan NO es un tipo de página: la API de páginas no lo crea.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Plans, Sharing}

  setup do
    Dran.DataCase.ensure_workspace!()
    u = u()

    {:ok, owner} =
      Accounts.create_user(%{
        email: "plan-owner-#{u}@example.com",
        name: "Owner",
        api_token: "tok-plan-owner-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "plan-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-plan-stranger-#{u}"
      })

    {:ok, member} =
      Accounts.create_user(%{
        email: "plan-member-#{u}@example.com",
        name: "Member",
        api_token: "tok-plan-member-#{u}"
      })

    %{owner: owner, stranger: stranger, member: member}
  end

  describe "crear" do
    test "nace privado, con dueño y con sus pasos normalizados", %{owner: owner} do
      body =
        json_response(
          post_json(conn_for(owner), "/api/plans", %{
            "title" => "Lanzamiento",
            "checklist" => ["uno", %{"text" => "dos", "done" => true}]
          }),
          201
        )

      plan = body["data"]
      assert plan["owner_user_id"] == owner.id
      assert plan["visibility"] == "private"
      assert plan["slug"] == "lanzamiento"
      assert plan["status"] == "draft"

      assert plan["checklist"] == [
               %{"text" => "uno", "done" => false},
               %{"text" => "dos", "done" => true}
             ]
    end

    test "el cliente no declara el dueño", %{owner: owner, stranger: stranger} do
      body =
        json_response(
          post_json(conn_for(owner), "/api/plans", %{
            "title" => "Mío",
            "owner_user_id" => stranger.id
          }),
          201
        )

      assert body["data"]["owner_user_id"] == owner.id
    end

    test "el slug es único por dueño: dos dueños conservan el mismo slug", %{
      owner: owner,
      stranger: stranger
    } do
      a = create_plan!(owner, %{"title" => "Roadmap"})
      b = create_plan!(stranger, %{"title" => "Roadmap"})

      assert a["slug"] == "roadmap"
      assert b["slug"] == "roadmap"
      assert a["id"] != b["id"]
    end
  end

  describe "leer (P6)" do
    test "el dueño lee lo suyo por id y por slug; el tercero no", %{
      owner: owner,
      stranger: stranger
    } do
      plan = create_plan!(owner, %{"title" => "Privado", "checklist" => ["a", "b"]})

      body = json_response(get_json(conn_for(owner), "/api/plans/#{plan["id"]}"), 200)
      assert body["data"]["id"] == plan["id"]
      # El progreso se DERIVA del checklist y viaja con la lectura.
      assert body["progress"] == %{"done" => 0, "total" => 2, "percent" => 0}

      by_slug = json_response(get_json(conn_for(owner), "/api/plans/#{plan["slug"]}"), 200)
      assert by_slug["data"]["id"] == plan["id"]

      assert json_response(get_json(conn_for(stranger), "/api/plans/#{plan["id"]}"), 404)
      assert json_response(get_json(conn_for(stranger), "/api/plans/#{plan["slug"]}"), 404)
    end

    test "l pública lo lee cualquiera y la compartida solo el invitado", %{
      owner: owner,
      stranger: stranger,
      member: member
    } do
      public = create_plan!(owner, %{"title" => "Público", "scope" => "public"})
      assert json_response(get_json(conn_for(stranger), "/api/plans/#{public["id"]}"), 200)

      group = group_with(owner, [member])

      shared =
        create_plan!(owner, %{"title" => "Del equipo", "scope" => %{"group" => group.slug}})

      assert json_response(get_json(conn_for(member), "/api/plans/#{shared["id"]}"), 200)
      assert json_response(get_json(conn_for(stranger), "/api/plans/#{shared["id"]}"), 404)
    end

    test "el índice sólo trae lo legible", %{owner: owner, stranger: stranger} do
      plan = create_plan!(owner, %{"title" => "Mío"})

      ids =
        conn_for(stranger) |> get_json("/api/plans") |> json_response(200) |> Map.fetch!("data")

      assert ids == []

      mine = conn_for(owner) |> get_json("/api/plans") |> json_response(200) |> Map.fetch!("data")
      assert Enum.map(mine, & &1["id"]) == [plan["id"]]
    end
  end

  describe "el checklist tiene UNA puerta (P9)" do
    test "el PUT del plan NO lo toca", %{owner: owner} do
      plan = create_plan!(owner, %{"title" => "Con pasos", "checklist" => ["uno"]})

      body =
        json_response(
          put_json(conn_for(owner), "/api/plans/#{plan["id"]}", %{
            "title" => "Renombrado",
            "checklist" => []
          }),
          200
        )

      assert body["data"]["title"] == "Renombrado"
      assert body["data"]["checklist"] == [%{"text" => "uno", "done" => false}]
    end

    test "PUT /checklist reescribe el array completo", %{owner: owner} do
      plan = create_plan!(owner, %{"title" => "Reescritura", "checklist" => ["uno"]})

      body =
        json_response(
          put_json(conn_for(owner), "/api/plans/#{plan["id"]}/checklist", %{
            "checklist" => ["dos", %{"text" => "tres", "done" => true}],
            "lock_version" => 1
          }),
          200
        )

      assert body["data"]["checklist"] == [
               %{"text" => "dos", "done" => false},
               %{"text" => "tres", "done" => true}
             ]

      assert body["progress"] == %{"done" => 1, "total" => 2, "percent" => 50}
    end

    test "un lock_version viejo es 409 en el PUT", %{owner: owner} do
      plan = create_plan!(owner, %{"title" => "Carrera", "checklist" => ["uno"]})

      # La mano rápida escribe (lock 1 → 2).
      json_response(
        put_json(conn_for(owner), "/api/plans/#{plan["id"]}/checklist", %{
          "checklist" => ["uno", "dos"],
          "lock_version" => 1
        }),
        200
      )

      assert json_response(
               put_json(conn_for(owner), "/api/plans/#{plan["id"]}/checklist", %{
                 "checklist" => ["pisado"],
                 "lock_version" => 1
               }),
               409
             )

      assert Dran.Repo.get!(Plans.Plan, plan["id"]).checklist |> Enum.map(& &1["text"]) ==
               ["uno", "dos"]
    end

    test "toggle de un plan por índice y por texto, con la misma ruta que la task", %{
      owner: owner
    } do
      plan = create_plan!(owner, %{"title" => "Toggle", "checklist" => ["uno", "dos"]})

      body =
        json_response(
          post_json(conn_for(owner), "/api/checklist/toggle", %{
            "target" => "plan",
            "id" => plan["id"],
            "index" => 0
          }),
          200
        )

      assert body["data"]["checklist"] == [
               %{"text" => "uno", "done" => true},
               %{"text" => "dos", "done" => false}
             ]

      lock = body["data"]["lock_version"]

      body =
        json_response(
          post_json(conn_for(owner), "/api/checklist/toggle", %{
            "target" => "plan",
            "id" => plan["id"],
            "text" => "dos",
            "lock_version" => lock
          }),
          200
        )

      assert body["data"]["checklist"] == [
               %{"text" => "uno", "done" => true},
               %{"text" => "dos", "done" => true}
             ]
    end

    test "un ítem que no existe es 404 y un lock viejo es 409", %{owner: owner} do
      plan = create_plan!(owner, %{"title" => "Sin ítem", "checklist" => ["uno"]})

      assert json_response(
               post_json(conn_for(owner), "/api/checklist/toggle", %{
                 "target" => "plan",
                 "id" => plan["id"],
                 "text" => "no está"
               }),
               404
             )

      json_response(
        post_json(conn_for(owner), "/api/checklist/toggle", %{
          "target" => "plan",
          "id" => plan["id"],
          "index" => 0
        }),
        200
      )

      assert json_response(
               post_json(conn_for(owner), "/api/checklist/toggle", %{
                 "target" => "plan",
                 "id" => plan["id"],
                 "index" => 0,
                 "lock_version" => 1
               }),
               409
             )
    end
  end

  describe "destino, borrado y aislamiento" do
    test "scope de grupo ajeno: 422 y el conteo no cambia", %{owner: owner, stranger: stranger} do
      {:ok, group} = Sharing.create_group(%{name: "Ajeno #{u()}"})
      {:ok, _} = Sharing.add_group_member(group, stranger.id)

      before = Dran.Repo.aggregate(Plans.Plan, :count, :id)

      body =
        json_response(
          post_json(conn_for(owner), "/api/plans", %{
            "title" => "No debería",
            "scope" => %{"group" => group.slug}
          }),
          422
        )

      assert body["errors"]["detail"] =~ "member"
      assert Dran.Repo.aggregate(Plans.Plan, :count, :id) == before
    end

    test "el tercero no edita ni borra el plan ajeno", %{owner: owner, stranger: stranger} do
      plan = create_plan!(owner, %{"title" => "Privado"})

      assert json_response(
               put_json(conn_for(stranger), "/api/plans/#{plan["id"]}", %{"title" => "Hack"}),
               404
             )

      assert conn_for(stranger) |> delete_json("/api/plans/#{plan["id"]}") |> response(404)
      assert Dran.Repo.get(Plans.Plan, plan["id"])

      assert conn_for(owner) |> delete_json("/api/plans/#{plan["id"]}") |> response(204)
      assert Dran.Repo.get(Plans.Plan, plan["id"]) == nil
    end

    test "el plan no se crea por la API de páginas (no es un tipo de página)", %{owner: owner} do
      body =
        json_response(
          post_json(conn_for(owner), "/api/knowledge-pages", %{
            "title" => "Plan falso",
            "page_type" => "plan"
          }),
          422
        )

      assert body["errors"]["page_type"]
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

  defp create_plan!(owner, attrs) do
    json_response(post_json(conn_for(owner), "/api/plans", attrs), 201) |> Map.fetch!("data")
  end

  defp group_with(owner, members) do
    {:ok, group} = Sharing.create_group(%{name: "Equipo #{u()}"})
    {:ok, _} = Sharing.add_group_member(group, owner.id)
    Enum.each(members, fn m -> {:ok, _} = Sharing.add_group_member(group, m.id) end)
    group
  end
end
