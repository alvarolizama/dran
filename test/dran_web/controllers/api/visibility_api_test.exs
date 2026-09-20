defmodule DranWeb.API.VisibilityAPITest do
  @moduledoc """
  Gate W5 (contract-instance-visibility-20260919): the visibility surface
  over REST.

  - P2 (Rules#6): POST /api/memory with `visibility` → 422; without it the
    memory is born PRIVATE.
  - Rules#5: POST/PUT /api/knowledge-pages accept `visibility`.
  - P3 (Rules#3): an API key reads exactly what its owner reads — the
    owner's private items, public items, and items shared with the owner
    (user shares AND group shares).
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Repo, Sharing}

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

    # owner's key: the agent identity (write level on the instance)
    {:ok, key} =
      Accounts.create_api_key(%{
        name: "agent-#{u()}",
        workspace_ids: [{ws.id, "write"}],
        created_by_user_id: owner.id
      })

    # stranger's key
    {:ok, stranger_key} =
      Accounts.create_api_key(%{
        name: "agent-s-#{u()}",
        workspace_ids: [{ws.id, "write"}],
        created_by_user_id: stranger.id
      })

    %{ws: ws, owner: owner, stranger: stranger, key: key, stranger_key: stranger_key}
  end

  defp conn_for(key) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
  end

  describe "memory visibility is web-only (Rules#6 / P2)" do
    test "POST /api/memory with visibility => 422, nothing stored", ctx do
      conn =
        conn_for(ctx.key)
        |> post("/api/memory", %{
          "content" => "fact con visibility #{u()}",
          "visibility" => "public"
        })

      assert %{"errors" => %{"visibility" => _}} = json_response(conn, 422)
    end

    test "POST /api/memory without visibility => born private", ctx do
      conn =
        conn_for(ctx.key)
        |> post("/api/memory", %{"content" => "fact privado por defecto #{u()}"})

      assert %{"data" => memory} = json_response(conn, 201)
      assert memory["visibility"] == "private"
    end
  end

  describe "page visibility is settable via API (Rules#5)" do
    test "create accepts visibility; default private", ctx do
      conn =
        conn_for(ctx.key)
        |> post("/api/knowledge-pages", %{
          "title" => "API Private #{u()}",
          "page_type" => "note"
        })

      assert %{"data" => page} = json_response(conn, 201)
      assert page["visibility"] == "private"

      conn =
        conn_for(ctx.key)
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
        conn_for(ctx.key)
        |> put("/api/knowledge-pages/#{page.slug}", %{"visibility" => "public"})

      assert %{"data" => updated} = json_response(conn, 200)
      assert updated["visibility"] == "public"
    end
  end

  describe "an API key reads exactly as its owner (Rules#3 / P3)" do
    setup ctx do
      # stranger's private page — must be invisible to owner's key
      {:ok, stranger_private} =
        Knowledge.create_page(%{
          workspace_id: ctx.ws.id,
          title: "Stranger Private #{u()}",
          page_type: "note",
          owner_user_id: ctx.stranger.id,
          visibility: "private"
        })

      # a page shared with OWNER (user share) — must be visible to owner's key
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

    test "owner's key: own + public + shared-with-owner (user and group)", ctx do
      conn = conn_for(ctx.key) |> get("/api/knowledge-pages")
      assert %{"data" => pages} = json_response(conn, 200)
      titles = Enum.map(pages, & &1["title"])

      refute Enum.any?(titles, &String.starts_with?(&1, "Stranger Private"))
      assert Enum.any?(titles, &String.starts_with?(&1, "Shared Owner"))
      assert Enum.any?(titles, &String.starts_with?(&1, "Group Page"))
    end

    test "stranger's key sees their own private page but not owner-shared", ctx do
      conn = conn_for(ctx.stranger_key) |> get("/api/knowledge-pages")
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
        conn_for(ctx.key)
        |> get("/api/knowledge-pages/#{ctx.stranger_private.slug}")

      assert json_response(conn, 404)

      conn =
        conn_for(ctx.key)
        |> get("/api/knowledge-pages/#{ctx.shared_with_owner.slug}")

      assert %{"data" => _} = json_response(conn, 200)
    end
  end

  defp u, do: System.unique_integer([:positive])
end
