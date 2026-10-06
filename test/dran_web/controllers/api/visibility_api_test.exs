defmodule DranWeb.API.VisibilityAPITest do
  @moduledoc """
  Gate W5 (contract-instance-visibility-20260919): the visibility surface
  over REST.

  - P2 (Rules#6): POST /api/memory with `visibility` → 422; without it the
    memory is born PRIVATE.
  - Rules#5: POST/PUT /api/knowledge-pages accept `visibility`.
  - P3 (Rules#3): an API credential reads exactly what its owner reads — the
    owner's private items, public items, and items shared with the owner
    (user shares AND group shares).
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Memory, Sharing}

  setup do
    ws = Dran.DataCase.ensure_workspace!()

    {:ok, owner} =
      Accounts.create_user(%{
        email: "va-owner-#{u()}@example.com",
        name: "Owner",
        api_token: "t#{u()}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "va-stranger-#{u()}@example.com",
        name: "Stranger",
        api_token: "t#{u()}"
      })

    # W3: the credential is each account's api_token.
    %{ws: ws, owner: owner, stranger: stranger}
  end

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  describe "memory visibility is web-only (Rules#6 / P2)" do
    test "POST /api/memory with visibility => 422, nothing stored", ctx do
      conn =
        conn_for(ctx.owner)
        |> post("/api/memory", %{
          "content" => "fact con visibility #{u()}",
          "visibility" => "public"
        })

      assert %{"errors" => %{"visibility" => _}} = json_response(conn, 422)
    end

    test "POST /api/memory without visibility => born private", ctx do
      conn =
        conn_for(ctx.owner)
        |> post("/api/memory", %{"content" => "fact privado por defecto #{u()}"})

      assert %{"data" => memory} = json_response(conn, 201)
      assert memory["visibility"] == "private"
    end
  end

  describe "page visibility is settable via API (Rules#5)" do
    test "create accepts visibility; default private", ctx do
      conn =
        conn_for(ctx.owner)
        |> post("/api/knowledge-pages", %{
          "title" => "API Private #{u()}",
          "page_type" => "note"
        })

      assert %{"data" => page} = json_response(conn, 201)
      assert page["visibility"] == "private"

      conn =
        conn_for(ctx.owner)
        |> post("/api/knowledge-pages", %{
          "title" => "API Public #{u()}",
          "page_type" => "note",
          "visibility" => "public"
        })

      assert %{"data" => pub} = json_response(conn, 201)
      assert pub["visibility"] == "public"
    end

    test "update changes visibility", ctx do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "To flip #{u()}",
          page_type: "note",
          owner_user_id: ctx.owner.id,
          visibility: "private"
        })

      conn =
        conn_for(ctx.owner)
        |> put("/api/knowledge-pages/#{page.slug}", %{"visibility" => "public"})

      assert %{"data" => updated} = json_response(conn, 200)
      assert updated["visibility"] == "public"
    end
  end

  describe "an API credential reads exactly as its owner (Rules#3 / P3)" do
    setup ctx do
      # stranger's private page — must be invisible to owner's credential
      {:ok, stranger_private} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Stranger Private #{u()}",
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "private"
        })

      # a page shared with OWNER (user share) — must be visible to owner's credential
      {:ok, shared_with_owner} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Shared Owner #{u()}",
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "shared"
        })

      {:ok, :shared} = Sharing.share_with_user("page", shared_with_owner.id, ctx.owner.id)

      # a group page: stranger shares with a group OWNER belongs to
      {:ok, group} = Sharing.create_group(%{name: "API Group #{u()}"})
      {:ok, _} = Sharing.add_group_member(group, ctx.owner.id)

      {:ok, group_page} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Group Page #{u()}",
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "shared"
        })

      {:ok, :shared} = Sharing.share_with_group("page", group_page.id, group.id)

      # owner's own shared page granted to a THIRD user — stranger must NOT
      # see it (owned by owner, shared with someone else).
      {:ok, third} =
        Dran.Accounts.create_user(%{
          email: "va-third-#{u()}@example.com",
          api_token: "t#{u()}"
        })

      {:ok, owner_shared_elsewhere} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Owner Elsewhere #{u()}",
          page_type: "note",
          owner_user_id: ctx.owner.id,
          visibility: "shared"
        })

      {:ok, :shared} = Sharing.share_with_user("page", owner_shared_elsewhere.id, third.id)

      Map.merge(ctx, %{
        stranger_private: stranger_private,
        shared_with_owner: shared_with_owner,
        group_page: group_page,
        owner_shared_elsewhere: owner_shared_elsewhere
      })
    end

    test "owner's credential: own + public + shared-with-owner (user and group)", ctx do
      conn = conn_for(ctx.owner) |> get("/api/knowledge-pages")
      assert %{"data" => pages} = json_response(conn, 200)
      titles = Enum.map(pages, & &1["title"])

      refute Enum.any?(titles, &String.starts_with?(&1, "Stranger Private"))
      assert Enum.any?(titles, &String.starts_with?(&1, "Shared Owner"))
      assert Enum.any?(titles, &String.starts_with?(&1, "Group Page"))
    end

    test "stranger's credential sees their own private page but not owner-shared", ctx do
      conn = conn_for(ctx.stranger) |> get("/api/knowledge-pages")
      assert %{"data" => pages} = json_response(conn, 200)
      titles = Enum.map(pages, & &1["title"])

      assert Enum.any?(titles, &String.starts_with?(&1, "Stranger Private"))
      # The stranger's own shared rows stay visible to them...
      assert Enum.any?(titles, &String.starts_with?(&1, "Shared Owner"))
      # ...but the OWNER's shared-with-someone-else page is invisible.
      refute Enum.any?(titles, &String.starts_with?(&1, "Owner Elsewhere"))
    end

    test "show follows the same rule (404 for the invisible)", ctx do
      conn =
        conn_for(ctx.owner)
        |> get("/api/knowledge-pages/#{ctx.stranger_private.slug}")

      assert json_response(conn, 404)

      conn =
        conn_for(ctx.owner)
        |> get("/api/knowledge-pages/#{ctx.shared_with_owner.slug}")

      assert %{"data" => _} = json_response(conn, 200)
    end
  end

  describe "la mutación no alcanza la fila ajena (W1, contract grupo-credencial)" do
    setup ctx do
      title = "Ajena Privada #{u()}"

      {:ok, stranger_private} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: title,
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "private"
        })

      Map.merge(ctx, %{stranger_private: stranger_private, stranger_title: title})
    end

    test "PUT por slug → 404 y la fila queda intacta", ctx do
      conn =
        conn_for(ctx.owner)
        |> put("/api/knowledge-pages/#{ctx.stranger_private.slug}", %{"title" => "Hijacked"})

      assert %{"errors" => %{"detail" => "page not found"}} = json_response(conn, 404)
      assert Knowledge.get_page!(ctx.stranger_private.id).title == ctx.stranger_title
    end

    test "PUT por uuid → 404 y la fila queda intacta", ctx do
      conn =
        conn_for(ctx.owner)
        |> put("/api/knowledge-pages/#{ctx.stranger_private.id}", %{"title" => "Hijacked"})

      assert json_response(conn, 404)
      assert Knowledge.get_page!(ctx.stranger_private.id).title == ctx.stranger_title
    end

    test "DELETE por slug → 404 y la fila sigue viva", ctx do
      conn = conn_for(ctx.owner) |> delete("/api/knowledge-pages/#{ctx.stranger_private.slug}")

      assert json_response(conn, 404)
      assert Knowledge.get_page(ctx.stranger_private.id)
    end

    # Los hermanos del mismo agujero: rename y reaugment ESCRIBEN, links y
    # graph RESUELVEN la fila igual — todos con el scope del lector.
    test "rename, reaugment, links y graph → 404 sobre la fila ajena", ctx do
      slug = ctx.stranger_private.slug

      assert json_response(
               conn_for(ctx.owner)
               |> post("/api/knowledge-pages/#{slug}/rename", %{"new_slug" => "robado"}),
               404
             )

      assert json_response(
               conn_for(ctx.owner) |> post("/api/knowledge-pages/#{slug}/reaugment"),
               404
             )

      assert json_response(conn_for(ctx.owner) |> get("/api/knowledge-pages/#{slug}/links"), 404)
      assert json_response(conn_for(ctx.owner) |> get("/api/knowledge-pages/#{slug}/graph"), 404)

      assert Knowledge.get_page!(ctx.stranger_private.id).slug == slug
    end

    test "lo propio y lo compartido siguen siendo escribibles y legibles", ctx do
      {:ok, mine} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Mía #{u()}",
          page_type: "note",
          owner_user_id: ctx.owner.id,
          visibility: "private"
        })

      conn =
        conn_for(ctx.owner)
        |> put("/api/knowledge-pages/#{mine.slug}", %{"title" => "Mía editada"})

      assert %{"data" => %{"title" => "Mía editada"}} = json_response(conn, 200)

      {:ok, shared} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Compartida #{u()}",
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "shared"
        })

      {:ok, :shared} = Sharing.share_with_user("page", shared.id, ctx.owner.id)

      assert json_response(conn_for(ctx.owner) |> get("/api/knowledge-pages/#{shared.slug}"), 200)
    end

    # El barrido de W1 (P2): el MISMO agujero existía en las mutaciones de
    # memorias y de aristas — las dos resolvían su fila por id o por slug.
    test "una memoria privada ajena no se reescribe ni se borra", ctx do
      conn =
        conn_for(ctx.stranger)
        |> post("/api/memory", %{"content" => "hecho privado ajeno #{u()}"})

      assert %{"data" => memory} = json_response(conn, 201)
      assert memory["visibility"] == "private"

      hijack =
        conn_for(ctx.owner)
        |> patch("/api/memory/#{memory["id"]}", %{"content" => "robado"})

      assert json_response(hijack, 404)
      assert Memory.get_memory!(memory["id"]).content == memory["content"]

      wipe = conn_for(ctx.owner) |> delete("/api/memory/#{memory["id"]}")
      assert json_response(wipe, 404)
      assert Memory.get_scoped_memory(memory["id"], ctx.ws.id)
    end

    test "las aristas entre páginas privadas ajenas ni se cablean ni se borran", ctx do
      {:ok, source} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Arista A #{u()}",
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "private"
        })

      {:ok, target} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Arista B #{u()}",
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "private"
        })

      {:ok, _relation} =
        Knowledge.create_relation_by_slugs(source.slug, target.slug, "related", ctx.ws.id)

      # Cablearlas: una arista toca DOS páginas y las dos caen fuera del scope.
      conn =
        conn_for(ctx.owner)
        |> post("/api/relations", %{
          "source_slug" => source.slug,
          "target_slug" => target.slug,
          "relation_type" => "references",
          "workspace" => "personal"
        })

      assert json_response(conn, 404)

      # Y borrar las suyas tampoco: misma resolución, mismo 404 y la arista viva.
      conn =
        conn_for(ctx.owner)
        |> delete(
          "/api/relations?source_slug=#{source.slug}&target_slug=#{target.slug}&workspace=personal"
        )

      assert json_response(conn, 404)
      assert %{outbound: [%Dran.Relation{} | _]} = Knowledge.list_relations_for_page(source.id)
    end
  end

  defp u, do: System.unique_integer([:positive])
end
