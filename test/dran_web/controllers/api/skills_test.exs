defmodule DranWeb.API.SkillsTest do
  @moduledoc """
  Gate W1 (contrato de skills remotos): la superficie REST del catálogo.

  - P2: el índice y el detalle leen con el scope del LECTOR — dos usuarios con
    claves distintas no se ven entre sí y un slug fuera de scope es 404 (sin
    confirmar existencia);
  - P3: el detalle sirve `name` + `description` + `body` + `version` +
    `content_hash` y el `SKILL.md` montado; el índice sirve SIN cuerpos;
  - el caso anónimo NO existe: sin credencial no hay lista (la trampa del `nil`
    es `:all`, así que la ruta sin lector sería la fuga).
  """

  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.Repo
  alias Dran.Sharing
  alias Dran.Skills
  alias Dran.Skills.Skill

  setup do
    Dran.DataCase.ensure_workspace!()
    u = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{
        email: "skill-owner-#{u}@example.com",
        name: "Owner",
        api_token: "tok-skill-owner-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "skill-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-skill-stranger-#{u}"
      })

    {:ok, member} =
      Accounts.create_user(%{
        email: "skill-member-#{u}@example.com",
        name: "Member",
        api_token: "tok-skill-member-#{u}"
      })

    %{owner: owner, stranger: stranger, member: member}
  end

  describe "el índice (P2, P3)" do
    test "trae lo que el lector puede leer y NUNCA cuerpos", %{owner: owner, stranger: stranger} do
      insert_skill!(owner, %{"slug" => "mio"})
      insert_skill!(stranger, %{"slug" => "ajeno"})

      data =
        conn_for(owner)
        |> get_json("/api/skills")
        |> json_response(200)
        |> Map.fetch!("data")

      slugs = Enum.map(data, & &1["slug"])
      assert slugs == ["mio"]
      refute "ajeno" in slugs

      [entry] = data
      assert entry["mine"] == true
      refute Map.has_key?(entry, "body")
      refute Map.has_key?(entry, "skill_md")
      assert entry["content_hash"]
      assert entry["version"] == 1
    end

    test "lo público lo lee un tercero y lo marca como ajeno", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "publico", "visibility" => "public"})

      [entry] =
        conn_for(stranger)
        |> get_json("/api/skills")
        |> json_response(200)
        |> Map.fetch!("data")

      assert entry["slug"] == "publico"
      assert entry["mine"] == false
      assert entry["visibility"] == "public"
    end

    test "el filtro de destino y el orden viajan en la query", %{owner: owner} do
      insert_skill!(owner, %{"slug" => "privado"})
      insert_skill!(owner, %{"slug" => "publico", "visibility" => "public"})

      data =
        conn_for(owner)
        |> get_json("/api/skills?visibility=public")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(data, & &1["slug"]) == ["publico"]

      # Un valor fuera del vocabulario se ignora como filtro, no revienta.
      assert conn_for(owner)
             |> get_json("/api/skills?visibility=amigos")
             |> json_response(200)
             |> Map.fetch!("data")
             |> length() == 2
    end

    test "el filtro de texto (`q`) viaja en la query y no ensancha el scope", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "revision-semanal", "description" => "cerrar la semana"})
      insert_skill!(owner, %{"slug" => "informe-mensual", "description" => "los numeros"})

      data =
        conn_for(owner)
        |> get_json("/api/skills?q=semanal")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(data, & &1["slug"]) == ["revision-semanal"]
      refute Map.has_key?(hd(data), "body")

      # Un `q` vacío (o de otro tipo) no filtra: el catálogo completo.
      assert conn_for(owner)
             |> get_json("/api/skills?q=")
             |> json_response(200)
             |> Map.fetch!("data")
             |> length() == 2

      # El filtro es del listado, no una puerta nueva: lo ajeno privado sigue
      # fuera del alcance del lector aunque el texto lo nombre.
      assert conn_for(stranger)
             |> get_json("/api/skills?q=semanal")
             |> json_response(200)
             |> Map.fetch!("data") == []
    end

    test "sin credencial NO hay lista: el caso anónimo no existe", %{owner: owner} do
      insert_skill!(owner, %{"slug" => "privado"})

      assert Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("accept", "application/json")
             |> get("/api/skills")
             |> response(401)

      assert Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("accept", "application/json")
             |> Plug.Conn.put_req_header("authorization", "Bearer tok-inventado")
             |> get("/api/skills")
             |> response(401)
    end
  end

  describe "el detalle (P2, P3)" do
    test "el dueño lee el SKILL.md montado y el tercero recibe 404", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "montado", "body" => "# Instrucciones"})

      body =
        conn_for(owner)
        |> get_json("/api/skills/montado")
        |> json_response(200)

      data = body["data"]
      assert data["name"] == "montado"
      assert data["description"] == "para probar"
      assert data["body"] == "# Instrucciones"
      assert data["version"] == 1
      assert data["content_hash"] == Dran.Skills.content_hash("# Instrucciones")
      assert data["skill_md"] =~ "---\nname: montado"
      assert data["skill_md"] =~ "# Instrucciones"

      # El slug no confirma existencia fuera del scope del lector.
      assert json_response(get_json(conn_for(stranger), "/api/skills/montado"), 404)
    end

    test "un slug forjado es un 404 limpio", %{owner: owner} do
      assert conn_for(owner)
             |> get_json("/api/skills/no-existe-xyz")
             |> json_response(404)

      assert conn_for(owner)
             |> get_json("/api/skills/#{Ecto.UUID.generate()}")
             |> json_response(404)
    end

    test "el slug público se lee con cualquier credencial", %{owner: owner, stranger: stranger} do
      insert_skill!(owner, %{"slug" => "publico", "visibility" => "public"})

      assert conn_for(stranger)
             |> get_json("/api/skills/publico")
             |> json_response(200)
             |> Map.fetch!("data")
             |> Map.fetch!("slug") == "publico"
    end
  end

  describe "la escritura (P5)" do
    test "el alta sella el dueño de la credencial y arranca en versión 1", %{owner: owner} do
      body = json_response(post_json(conn_for(owner), "/api/skills", params("nuevo")), 201)
      skill = body["data"]

      assert skill["slug"] == "nuevo"
      assert skill["version"] == 1
      assert skill["visibility"] == "private"
      assert skill["content_hash"] == Skills.content_hash("# uno")
      assert skill["mine"] == true
      assert Repo.get_by(Skill, slug: "nuevo").owner_user_id == owner.id
    end

    test "el cliente NO puede declarar el dueño", %{owner: owner, stranger: stranger} do
      body =
        json_response(
          post_json(
            conn_for(owner),
            "/api/skills",
            Map.put(params("mio"), "owner_user_id", stranger.id)
          ),
          201
        )

      assert body["data"]["mine"] == true
      assert Repo.get_by(Skill, slug: "mio").owner_user_id == owner.id
    end

    test "nombre fuera de formato, descripción de 61 y cuerpo fuera de tamaño: 422 y SIN fila",
         %{owner: owner} do
      before = Repo.aggregate(Skill, :count, :id)

      assert json_response(
               post_json(
                 conn_for(owner),
                 "/api/skills",
                 Map.put(params("malo"), "name", "Bad Name")
               ),
               422
             )["errors"]["name"]

      assert json_response(
               post_json(conn_for(owner), "/api/skills", %{
                 "slug" => "sin-desc",
                 "name" => "sin-desc"
               }),
               422
             )["errors"]["description"]

      assert json_response(
               post_json(
                 conn_for(owner),
                 "/api/skills",
                 Map.put(params("grande"), "body", String.duplicate("a", 100_001))
               ),
               422
             )["errors"]["body"]

      assert json_response(
               post_json(conn_for(owner), "/api/skills", Map.put(params("vacio"), "body", "")),
               422
             )["errors"]["body"]

      assert Repo.aggregate(Skill, :count, :id) == before
    end

    test "un PUT con cuerpo nuevo versiona y el mismo cuerpo no", %{owner: owner} do
      insert_skill!(owner, %{"slug" => "demo", "body" => "# uno"})

      first =
        json_response(put_json(conn_for(owner), "/api/skills/demo", %{"body" => "# dos"}), 200)[
          "data"
        ]

      assert first["version"] == 2

      second =
        json_response(put_json(conn_for(owner), "/api/skills/demo", %{"body" => "# dos"}), 200)[
          "data"
        ]

      assert second["version"] == 2
      assert second["content_hash"] == first["content_hash"]
    end

    test "el slug no se renombra: 422 y la fila queda igual", %{owner: owner} do
      insert_skill!(owner, %{"slug" => "demo"})

      # El rename se pide por el `name` del wire: el `slug` de la ruta gana
      # sobre el del body (params de path mandan en Phoenix), así que la
      # dirección la fija la URL y lo que puede intentar renombrar es el nombre.
      body =
        json_response(put_json(conn_for(owner), "/api/skills/demo", %{"name" => "otro"}), 422)

      assert body["errors"]["detail"] =~ "cannot be renamed"
      assert Repo.get_by(Skill, slug: "demo")
    end

    test "un skill público ajeno se LEE pero no se escribe (403)", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "publico", "visibility" => "public"})

      assert json_response(get_json(conn_for(stranger), "/api/skills/publico"), 200)

      assert json_response(
               put_json(conn_for(stranger), "/api/skills/publico", %{"body" => "# hack"}),
               403
             )

      assert conn_for(stranger) |> delete_json("/api/skills/publico") |> response(403)
      assert Repo.get_by(Skill, slug: "publico").body == "# x"
    end

    test "lo ajeno privado ni se escribe ni se borra: 404 sin fuga", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "privado"})

      assert json_response(
               put_json(conn_for(stranger), "/api/skills/privado", %{"body" => "# x"}),
               404
             )

      assert conn_for(stranger) |> delete_json("/api/skills/privado") |> response(404)
      assert Repo.get_by(Skill, slug: "privado")
    end

    test "borrar deja 204 y la fila se va", %{owner: owner} do
      insert_skill!(owner, %{"slug" => "borrable"})

      assert conn_for(owner) |> delete_json("/api/skills/borrable") |> response(204)
      assert Repo.get_by(Skill, slug: "borrable") == nil
    end
  end

  describe "el destino por escritura (P6)" do
    test "scope de grupo: nace shared y el miembro lo lee", %{owner: owner, member: member} do
      group = group_with(owner, [member])

      body =
        json_response(
          post_json(
            conn_for(owner),
            "/api/skills",
            Map.put(params("equipo"), "scope", %{"group" => group.slug})
          ),
          201
        )

      assert body["data"]["visibility"] == "shared"

      assert json_response(get_json(conn_for(member), "/api/skills/equipo"), 200)["data"]["slug"] ==
               "equipo"
    end

    test "scope de grupo ajeno: 422 y el conteo no cambia", %{owner: owner, stranger: stranger} do
      {:ok, group} = Sharing.create_group(%{name: "Ajeno #{u()}"})
      {:ok, _} = Sharing.add_group_member(group, stranger.id)

      before = Repo.aggregate(Skill, :count, :id)

      body =
        json_response(
          post_json(
            conn_for(owner),
            "/api/skills",
            Map.put(params("nada"), "scope", %{"group" => group.slug})
          ),
          422
        )

      assert body["errors"]["detail"] =~ "member"
      assert Repo.aggregate(Skill, :count, :id) == before
    end

    test "scope fuera del vocabulario: 422, nunca private en silencio", %{owner: owner} do
      before = Repo.aggregate(Skill, :count, :id)

      body =
        json_response(
          post_json(conn_for(owner), "/api/skills", Map.put(params("raro"), "scope", "amigos")),
          422
        )

      assert body["errors"]["detail"] =~ "invalid scope"
      assert Repo.aggregate(Skill, :count, :id) == before
    end

    test "un update con scope re-traduce la visibilidad", %{owner: owner, member: member} do
      group = group_with(owner, [member])
      insert_skill!(owner, %{"slug" => "demo"})

      body =
        json_response(
          put_json(conn_for(owner), "/api/skills/demo", %{"scope" => %{"group" => group.slug}}),
          200
        )

      assert body["data"]["visibility"] == "shared"
      assert json_response(get_json(conn_for(member), "/api/skills/demo"), 200)
    end

    test "visibility `shared` por el body: sólo el dueño lo lee hasta que haya grant", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "demo"})

      body =
        json_response(
          put_json(conn_for(owner), "/api/skills/demo", %{"visibility" => "shared"}),
          200
        )

      assert body["data"]["visibility"] == "shared"
      assert json_response(get_json(conn_for(stranger), "/api/skills/demo"), 404)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp params(slug, body \\ "# uno") do
    %{"slug" => slug, "name" => slug, "description" => "para probar", "body" => body}
  end

  defp u, do: System.unique_integer([:positive])

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  defp get_json(conn, path), do: get(conn, path)

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

  defp delete_json(conn, path), do: delete(conn, path)

  defp group_with(owner, members) do
    {:ok, group} = Sharing.create_group(%{name: "Equipo #{u()}"})
    {:ok, _} = Sharing.add_group_member(group, owner.id)
    Enum.each(members, fn m -> {:ok, _} = Sharing.add_group_member(group, m.id) end)
    group
  end

  defp insert_skill(owner, attrs) do
    slug = Map.get(attrs, "slug", "demo")
    base = %{"slug" => slug, "name" => slug, "description" => "para probar", "body" => "# x"}

    Skills.create_skill(Map.merge(base, attrs), owner_user_id: owner.id)
  end

  defp insert_skill!(owner, attrs) do
    {:ok, skill} = insert_skill(owner, attrs)
    skill
  end
end
