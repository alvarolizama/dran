defmodule DranWeb.API.SkillsBuiltinTest do
  @moduledoc """
  Los built-ins en el WIRE: lo que Dran sirve por DEFAULT a cualquier credencial.

  - el índice y el detalle los traen para una cuenta, para un GRUPO y para el
    privilegiado — sin share y sin configurar nada;
  - el `SKILL.md` montado lleva el cuerpo del archivo del repo (la fuente es
    `skills/<slug>/SKILL.md`);
  - NO los escribe ninguna credencial (403) y su slug está reservado (422);
  - el grupo sigue viendo EXACTAMENTE lo suyo: los built-ins se suman a su
    lectura, no la ensanchan.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.Sharing
  alias Dran.Skills.Builtin

  setup do
    u = System.unique_integer([:positive])
    Dran.DataCase.ensure_workspace!()

    {:ok, owner} =
      Accounts.create_user(%{
        email: "bi-owner-#{u}@example.com",
        name: "Owner",
        is_owner: true,
        api_token: "tok-bi-owner-#{u}"
      })

    {:ok, member} =
      Accounts.create_user(%{
        email: "bi-member-#{u}@example.com",
        name: "Member",
        api_token: "tok-bi-member-#{u}"
      })

    {:ok, group} = Sharing.create_group(%{name: "Builtin API #{u}"}, owner_user_id: owner.id)
    {:ok, group} = Sharing.issue_group_token(group)

    # Los built-ins que el boot sincroniza en producción.
    Builtin.sync!()

    %{owner: owner, member: member, group: group}
  end

  describe "la lectura por default" do
    test "el índice de una cuenta los trae marcados como del sistema y SIN cuerpos", %{
      member: member
    } do
      data = member.api_token |> index() |> Map.fetch!("data")

      assert length(data) == 9
      assert Enum.all?(data, &(&1["system"] == true))
      assert Enum.all?(data, &(&1["mine"] == false))
      assert Enum.all?(data, &(not Map.has_key?(&1, "body")))
      assert "dran" in Enum.map(data, & &1["slug"])
    end

    test "el detalle sirve el SKILL.md montado con el cuerpo del archivo del repo", %{
      member: member
    } do
      definition = Enum.find(Builtin.all(), &(&1.slug == "dran-plan-flow"))

      data =
        member.api_token
        |> conn_for()
        |> get("/api/skills/dran-plan-flow")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["system"] == true
      assert data["body"] == definition.body
      assert data["description"] == definition.description
      assert data["content_hash"] == Dran.Skills.Skill.content_hash(definition.body)
      assert String.ends_with?(data["skill_md"], definition.body)
      assert String.starts_with?(data["skill_md"], "---\nname: dran-plan-flow\n")
    end

    test "el token de un GRUPO también los lee, sin ver el público ajeno", %{
      owner: owner,
      group: group
    } do
      # Un skill público de OTRO dueño: el grupo no lo lee (Constraint 3).
      {:ok, foreign} =
        Dran.Skills.create_skill(
          %{"name" => "ajeno", "description" => "de otro", "body" => "# ajeno"},
          owner_user_id: owner.id
        )

      {:ok, _} = Dran.Sharing.apply_scope(foreign, "public", :skill, owner)

      slugs = group.api_token |> index() |> Map.fetch!("data") |> Enum.map(& &1["slug"])

      assert length(slugs) == 9
      assert "dran" in slugs
      refute "ajeno" in slugs

      # Y el detalle de un built-in responde por la misma puerta.
      data =
        group.api_token
        |> conn_for()
        |> get("/api/skills/dran-goal-flow")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["slug"] == "dran-goal-flow"
    end
  end

  describe "la escritura sigue siendo del código" do
    test "el dueño de la instancia y el grupo reciben 403 con el motivo accionable", %{
      owner: owner,
      group: group
    } do
      # Las dos credenciales que PODRÍAN escribir cualquier cosa legible: el
      # rechazo viene del contexto con el detalle que dice qué hacer.
      for token <- [owner.api_token, group.api_token] do
        conn = token |> conn_for() |> put("/api/skills/dran", %{"body" => "# secuestrado"})
        assert %{"errors" => %{"detail" => detail}} = json_response(conn, 403)
        assert detail =~ "redeploy"

        conn = token |> conn_for() |> delete("/api/skills/dran")
        assert %{"errors" => %{"detail" => detail}} = json_response(conn, 403)
        assert detail =~ "redeploy"
      end

      # El cuerpo sigue siendo el del repo.
      definition = Enum.find(Builtin.all(), &(&1.slug == "dran"))

      assert Dran.Skills.get_system_skill("dran").body == definition.body
    end

    test "una credencial sin autoridad recibe el 403 de siempre", %{member: member} do
      conn = member.api_token |> conn_for() |> put("/api/skills/dran", %{"body" => "# nope"})

      assert %{"errors" => %{"detail" => "forbidden"}} = json_response(conn, 403)
    end

    test "el alta con el slug de un built-in es 422 y no deja fila", %{member: member} do
      conn =
        member.api_token
        |> conn_for()
        |> post("/api/skills", %{
          "name" => "dran",
          "description" => "quiero pisarlo",
          "body" => "# mío"
        })

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["slug"] == ["is reserved by a built-in skill"]
      assert errors["name"] == ["is reserved by a built-in skill"]

      # El catálogo del lector sigue siendo el del código: 9, sin homónimos.
      assert length(index(member.api_token)["data"]) == 9
    end

    test "un slug libre se crea normal y el índice lo suma a los built-ins", %{member: member} do
      conn =
        member.api_token
        |> conn_for()
        |> post("/api/skills", %{
          "name" => "mi-flow",
          "description" => "propio",
          "body" => "# mío"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["system"] == false
      assert data["mine"] == true

      rows = index(member.api_token)["data"]
      assert length(rows) == 10
      assert Enum.count(rows, & &1["system"]) == 9
    end
  end

  defp index(token) do
    token |> conn_for() |> get("/api/skills") |> json_response(200)
  end

  defp conn_for(token) do
    build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end
end
