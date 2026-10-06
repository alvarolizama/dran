defmodule DranWeb.API.GroupTokenTest do
  @moduledoc """
  Gate W2/W3 (contract grupo-credencial): el token de un grupo.

  Un grupo es un PRINCIPAL de pleno derecho:

  - P3: su credencial escribe SÓLO en su grupo — sin `scope` el destino ES el
    grupo, con otro destino es 422, y la fila no queda huérfana.
  - P4: NO hereda privilegio del humano dueño del grupo, ni cuando ese dueño es
    el owner de la instancia.
  - P5: lee EXACTAMENTE lo compartido a su grupo (ni lo público, ni lo privado
    ajeno, ni lo de otro grupo).
  - P15: un grupo sin token no autentica.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Sharing}

  setup do
    ws = Dran.DataCase.ensure_workspace!()

    # El dueño humano del grupo ES el owner de la instancia: el caso más
    # peligroso para P4 — si la identidad heredara `is_owner`, leería todo.
    {:ok, owner} =
      Accounts.create_user(%{
        email: "gt-owner-#{u()}@example.com",
        name: "Instance Owner",
        is_owner: true,
        api_token: "gt-owner-#{u()}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "gt-stranger-#{u()}@example.com",
        name: "Stranger",
        api_token: "gt-stranger-#{u()}"
      })

    {:ok, group} = Sharing.create_group(%{name: "Grupo #{u()}"}, owner_user_id: owner.id)
    {:ok, group} = Sharing.issue_group_token(group)

    {:ok, other_group} = Sharing.create_group(%{name: "Otro #{u()}"}, owner_user_id: owner.id)
    {:ok, other_group} = Sharing.issue_group_token(other_group)

    %{ws: ws, owner: owner, stranger: stranger, group: group, other_group: other_group}
  end

  defp conn_for_token(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  defp titles_for(token) do
    conn = conn_for_token(token) |> get("/api/knowledge-pages")
    assert %{"data" => pages} = json_response(conn, 200)
    Enum.map(pages, & &1["title"])
  end

  defp page!(ctx, owner_id, visibility, title) do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ctx.ws.id,
        title: title,
        page_type: "note",
        owner_user_id: owner_id,
        visibility: visibility
      })

    page
  end

  describe "P3 · el destino de la credencial ES su grupo" do
    test "sin scope, la página nace compartida al grupo (y sólo a él)", ctx do
      title = "Del grupo #{u()}"

      conn =
        conn_for_token(ctx.group.api_token)
        |> post("/api/knowledge-pages", %{"title" => title, "page_type" => "note"})

      assert %{"data" => page} = json_response(conn, 201)
      assert page["visibility"] == "shared"
      assert Sharing.shared_with_group?("page", page["id"], ctx.group.id)

      assert title in titles_for(ctx.group.api_token)
      refute title in titles_for(ctx.stranger.api_token)
      refute title in titles_for(ctx.other_group.api_token)
    end

    test "una escritura (memoria) sin scope también cae en el grupo", ctx do
      conn =
        conn_for_token(ctx.group.api_token)
        |> post("/api/memory", %{"content" => "hecho del grupo #{u()}"})

      assert %{"data" => memory} = json_response(conn, 201)
      assert memory["visibility"] == "shared"
      assert Sharing.shared_with_group?("memory", memory["id"], ctx.group.id)
    end

    test "otro destino es 422 y la fila NO queda huérfana", ctx do
      before = Knowledge.list_pages(workspace_id: ctx.ws.id, scope: :all) |> length()

      for scope <- ["public", "private", %{"group" => ctx.other_group.slug}] do
        conn =
          conn_for_token(ctx.group.api_token)
          |> post("/api/knowledge-pages", %{
            "title" => "Rechazada #{u()}",
            "page_type" => "note",
            "scope" => scope
          })

        assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
        assert detail =~ "writes only to group"
      end

      assert Knowledge.list_pages(workspace_id: ctx.ws.id, scope: :all) |> length() == before
    end

    test "nombrar SU grupo sí se honra (es el mismo destino)", ctx do
      conn =
        conn_for_token(ctx.group.api_token)
        |> post("/api/knowledge-pages", %{
          "title" => "Nombrada #{u()}",
          "page_type" => "note",
          "scope" => %{"group" => ctx.group.slug}
        })

      assert %{"data" => page} = json_response(conn, 201)
      assert page["visibility"] == "shared"
      assert Sharing.shared_with_group?("page", page["id"], ctx.group.id)
    end

    test "una memoria a otro destino también es 422", ctx do
      conn =
        conn_for_token(ctx.group.api_token)
        |> post("/api/memory", %{"content" => "rechazada #{u()}", "scope" => "public"})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "writes only to group"
    end
  end

  describe "P4 · la identidad de grupo no hereda privilegio" do
    test "no ve lo público de la instancia ni lo privado ajeno, aunque su dueño sea el owner",
         ctx do
      # El grupo es de `owner`, que ES el owner de la instancia.
      public = page!(ctx, ctx.stranger.id, "public", "Pública Ajena #{u()}")
      private = page!(ctx, ctx.stranger.id, "private", "Privada Ajena #{u()}")
      group_page = page!(ctx, ctx.stranger.id, "shared", "Compartida al Grupo #{u()}")
      {:ok, :shared} = Sharing.share_with_group("page", group_page.id, ctx.group.id)

      titles = titles_for(ctx.group.api_token)

      refute public.title in titles
      refute private.title in titles
      assert group_page.title in titles

      # Ni siquiera por dirección directa (sin fuga de existencia).
      assert json_response(
               conn_for_token(ctx.group.api_token)
               |> get("/api/knowledge-pages/#{public.slug}"),
               404
             )

      assert json_response(
               conn_for_token(ctx.group.api_token)
               |> get("/api/knowledge-pages/#{private.slug}"),
               404
             )

      # Un token de CUENTA del mismo dueño humano sí ve la instancia entera: la
      # diferencia entre las dos credenciales es la identidad, no el dueño.
      owner_titles = titles_for(ctx.owner.api_token)
      assert public.title in owner_titles
    end
  end

  describe "P5 · la lectura es EXACTAMENTE el grupo" do
    test "ni lo público, ni lo privado del dueño humano, ni otro grupo", ctx do
      own_private = page!(ctx, ctx.owner.id, "private", "Privada del Dueño #{u()}")
      public = page!(ctx, ctx.owner.id, "public", "Pública del Dueño #{u()}")
      mine = page!(ctx, ctx.stranger.id, "shared", "Del Grupo #{u()}")
      other = page!(ctx, ctx.stranger.id, "shared", "De Otro Grupo #{u()}")

      {:ok, :shared} = Sharing.share_with_group("page", mine.id, ctx.group.id)
      {:ok, :shared} = Sharing.share_with_group("page", other.id, ctx.other_group.id)

      titles = titles_for(ctx.group.api_token)

      assert mine.title in titles
      refute own_private.title in titles
      refute public.title in titles
      refute other.title in titles

      # Una fila con share al grupo pero la columna en `private` es INERTE: el
      # share solo no basta (`filter/3` exige `visibility == "shared"`), igual
      # que en la lectura personal.
      inert = page!(ctx, ctx.stranger.id, "private", "Share Inerte #{u()}")
      {:ok, :shared} = Sharing.share_with_group("page", inert.id, ctx.group.id)
      refute inert.title in titles_for(ctx.group.api_token)
    end
  end

  describe "P15 · un grupo sin token no autentica" do
    test "un bearer que no es de nadie es 401 (y uno VACÍO también)", ctx do
      assert json_response(
               conn_for_token("no-such-token-#{u()}") |> get("/api/agent/config"),
               401
             )

      # `secure_compare("", "")` es true: sin la guarda del token legado, un
      # `Bearer ` vacío entraba como owner en una instancia sin api_token.
      assert json_response(conn_for_token("") |> get("/api/agent/config"), 401)
      assert json_response(conn_for_token("   ") |> get("/api/agent/config"), 401)
      _ = ctx
    end

    test "un grupo recién creado nace SIN credencial", ctx do
      {:ok, fresh} =
        Sharing.create_group(%{name: "Sin token #{u()}"}, owner_user_id: ctx.owner.id)

      assert fresh.api_token == nil
      assert Sharing.get_group_by_token("") == nil
      assert json_response(conn_for_token("Bearer-less-#{u()}") |> get("/api/agent/config"), 401)
    end

    test "la credencial del grupo SÍ autentica (la tercera identidad)", ctx do
      conn = conn_for_token(ctx.group.api_token) |> get("/api/agent/config")

      assert %{"data" => %{"agent" => agent}} = json_response(conn, 200)
      assert agent["name"] =~ "group:"
    end
  end

  describe "rotación del token del grupo" do
    test "emitir de nuevo invalida el anterior", ctx do
      old = ctx.group.api_token
      {:ok, rotated} = Sharing.issue_group_token(ctx.group)

      refute rotated.api_token == old
      assert json_response(conn_for_token(old) |> get("/api/agent/config"), 401)

      assert %{"data" => _} =
               json_response(conn_for_token(rotated.api_token) |> get("/api/agent/config"), 200)
    end
  end

  describe "el escenario de tres cuentas: A y C en el grupo, B afuera" do
    setup ctx do
      # El grupo lo crea el owner de la instancia (como el panel /admin/groups);
      # A y C son miembros, B no.
      {:ok, a} =
        Accounts.create_user(%{email: "esc-a-#{u()}@example.com", api_token: "esc-a-#{u()}"})

      {:ok, b} =
        Accounts.create_user(%{email: "esc-b-#{u()}@example.com", api_token: "esc-b-#{u()}"})

      {:ok, c} =
        Accounts.create_user(%{email: "esc-c-#{u()}@example.com", api_token: "esc-c-#{u()}"})

      {:ok, group} =
        Sharing.create_group(%{name: "Escenario #{u()}"}, owner_user_id: ctx.owner.id)

      {:ok, _} = Sharing.add_group_member(group, a.id)
      {:ok, _} = Sharing.add_group_member(group, c.id)
      {:ok, group} = Sharing.issue_group_token(group)

      %{a: a, b: b, c: c, escenario: group}
    end

    defp create_as(token, attrs) do
      conn = conn_for_token(token) |> post("/api/knowledge-pages", attrs)
      json_response(conn, 201)["data"]
    end

    test "cada agente personal escribe privado (lo suyo) y público (para todos)", ctx do
      own_a =
        create_as(ctx.a.api_token, %{"title" => "Privada de A #{u()}", "page_type" => "note"})

      own_b =
        create_as(ctx.b.api_token, %{"title" => "Privada de B #{u()}", "page_type" => "note"})

      own_c =
        create_as(ctx.c.api_token, %{"title" => "Privada de C #{u()}", "page_type" => "note"})

      assert own_a["visibility"] == "private"
      assert own_b["visibility"] == "private"
      assert own_c["visibility"] == "private"

      pub_b =
        create_as(ctx.b.api_token, %{
          "title" => "Pública de B #{u()}",
          "page_type" => "note",
          "scope" => "public"
        })

      assert pub_b["visibility"] == "public"

      # Cada uno ve lo suyo + TODO lo público; no lo privado ajeno.
      for {user, own, others} <- [
            {ctx.a, own_a, [own_b, own_c]},
            {ctx.b, own_b, [own_a, own_c]},
            {ctx.c, own_c, [own_a, own_b]}
          ] do
        titles = titles_for(user.api_token)
        assert own["title"] in titles
        assert pub_b["title"] in titles
        for other <- others, do: refute(other["title"] in titles)
      end
    end

    test "A y C escriben en el grupo; B come 422 (no es miembro)", ctx do
      from_a =
        create_as(ctx.a.api_token, %{
          "title" => "Al grupo desde A #{u()}",
          "page_type" => "note",
          "scope" => %{"group" => ctx.escenario.slug}
        })

      assert from_a["visibility"] == "shared"
      assert Sharing.shared_with_group?("page", from_a["id"], ctx.escenario.id)

      refused =
        conn_for_token(ctx.b.api_token)
        |> post("/api/knowledge-pages", %{
          "title" => "Al grupo desde B #{u()}",
          "page_type" => "note",
          "scope" => %{"group" => ctx.escenario.slug}
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(refused, 422)
      assert detail =~ "not a member"

      # A y C lo leen; B ni por dirección directa.
      assert from_a["title"] in titles_for(ctx.a.api_token)
      assert from_a["title"] in titles_for(ctx.c.api_token)
      refute from_a["title"] in titles_for(ctx.b.api_token)

      assert json_response(
               conn_for_token(ctx.b.api_token) |> get("/api/knowledge-pages/#{from_a["slug"]}"),
               404
             )
    end

    test "el agente del grupo escribe en el grupo y A/C lo leen (B no)", ctx do
      in_group =
        conn_for_token(ctx.escenario.api_token)
        |> post("/api/knowledge-pages", %{
          "title" => "Del agente del grupo #{u()}",
          "page_type" => "note"
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert in_group["visibility"] == "shared"
      assert Sharing.shared_with_group?("page", in_group["id"], ctx.escenario.id)
      assert in_group["title"] in titles_for(ctx.a.api_token)
      assert in_group["title"] in titles_for(ctx.c.api_token)
      refute in_group["title"] in titles_for(ctx.b.api_token)
    end

    test "el agente del grupo NO ve lo privado de nadie ni lo público", ctx do
      privada_a = create_as(ctx.a.api_token, %{"title" => "Sólo A #{u()}", "page_type" => "note"})
      privada_b = create_as(ctx.b.api_token, %{"title" => "Sólo B #{u()}", "page_type" => "note"})

      publica_b =
        create_as(ctx.b.api_token, %{
          "title" => "Pública de todos #{u()}",
          "page_type" => "note",
          "scope" => "public"
        })

      del_grupo =
        conn_for_token(ctx.escenario.api_token)
        |> post("/api/knowledge-pages", %{"title" => "Del grupo #{u()}", "page_type" => "note"})
        |> json_response(201)
        |> Map.fetch!("data")

      titles = titles_for(ctx.escenario.api_token)

      assert del_grupo["title"] in titles
      refute privada_a["title"] in titles
      refute privada_b["title"] in titles
      refute publica_b["title"] in titles

      for page <- [privada_a, privada_b, publica_b] do
        assert json_response(
                 conn_for_token(ctx.escenario.api_token)
                 |> get("/api/knowledge-pages/#{page["slug"]}"),
                 404
               )
      end
    end
  end

  defp u, do: System.unique_integer([:positive])
end
