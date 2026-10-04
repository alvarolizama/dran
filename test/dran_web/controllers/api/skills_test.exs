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

    %{owner: owner, stranger: stranger}
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

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  defp get_json(conn, path), do: get(conn, path)

  defp insert_skill(owner, attrs) do
    slug = Map.get(attrs, "slug", "demo")

    attrs =
      Map.merge(
        %{"slug" => slug, "name" => slug, "description" => "para probar", "body" => "# x"},
        attrs
      )

    %Skill{}
    |> Skill.changeset(Map.put(attrs, "owner_user_id", owner.id))
    |> Dran.Repo.insert()
  end

  defp insert_skill!(owner, attrs) do
    {:ok, skill} = insert_skill(owner, attrs)
    skill
  end
end
