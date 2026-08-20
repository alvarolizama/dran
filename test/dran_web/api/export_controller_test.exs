defmodule DranWeb.API.ExportControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "authorization", "Bearer dran-token")}
  end

  describe "GET /api/workspaces/:slug/export" do
    test "returns exported JSON with context, pages, and relations", %{conn: conn} do
      context = Brain.get_workspace_by_slug("personal")

      {:ok, page_a} =
        Brain.create_page(%{
          workspace_id: context.id,
          title: "Page A",
          slug: "export-page-a",
          body: "Body of page A",
          page_type: "note",
          tags: ["alpha"],
          summary: "A summary"
        })

      {:ok, page_b} =
        Brain.create_page(%{
          workspace_id: context.id,
          title: "Page B",
          slug: "export-page-b",
          body: "Body of page B",
          page_type: "concept",
          tags: ["beta"]
        })

      Brain.create_relation(%{
        source_id: page_a.id,
        target_id: page_b.id,
        relation_type: "related"
      })

      conn = get(conn, ~p"/api/workspaces/personal/export")

      body = json_response(conn, 200)

      assert body["workspace"]["slug"] == "personal"
      assert body["workspace"]["name"] == context.name
      assert Map.has_key?(body["workspace"], "description")
      assert Map.has_key?(body, "exported_at")

      page_maps =
        Enum.filter(body["pages"], &(&1["slug"] in ["export-page-a", "export-page-b"]))

      assert length(page_maps) == 2

      page_a_map = Enum.find(page_maps, &(&1["slug"] == "export-page-a"))
      assert page_a_map["title"] == "Page A"
      assert page_a_map["page_type"] == "note"
      assert page_a_map["body"] == "Body of page A"
      assert page_a_map["summary"] == "A summary"
      assert "alpha" in page_a_map["tags"]
      assert Map.has_key?(page_a_map, "meta")
      assert Map.has_key?(page_a_map, "inserted_at")
      assert Map.has_key?(page_a_map, "updated_at")

      rel =
        Enum.find(body["relations"], fn r ->
          r["source_slug"] == "export-page-a" and r["target_slug"] == "export-page-b"
        end)

      assert rel != nil
      assert rel["relation_type"] == "related"
    end

    test "returns 404 for unknown context slug", %{conn: conn} do
      conn = get(conn, ~p"/api/workspaces/nonexistent-context/export")

      assert json_response(conn, 404)
      assert %{"errors" => %{"detail" => "context not found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/export/:workspace/full" do
    test "returns full export with pages, relations, and versions keys", %{conn: conn} do
      context = Brain.get_workspace_by_slug("personal")

      {:ok, page_a} =
        Brain.create_page(%{
          workspace_id: context.id,
          title: "Full A",
          slug: "full-page-a",
          body: "v1 body",
          page_type: "note"
        })

      # Create a version snapshot by updating the body
      {:ok, _} = Brain.update_page(page_a, %{"body" => "v2 body"})

      {:ok, page_b} =
        Brain.create_page(%{
          workspace_id: context.id,
          title: "Full B",
          slug: "full-page-b",
          body: "Body B",
          page_type: "concept"
        })

      Brain.create_relation(%{
        source_id: page_a.id,
        target_id: page_b.id,
        relation_type: "related"
      })

      conn = get(conn, "/api/export/#{context.id}/full")

      assert conn.status == 200
      assert [disp | _] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disp =~ "attachment"

      body = json_response(conn, 200)

      assert body["workspace"]["slug"] == "personal"
      assert Map.has_key?(body, "exported_at")
      assert is_list(body["pages"])
      assert is_list(body["relations"])
      assert is_list(body["versions"])

      # The page_a version snapshot should be present
      assert Enum.any?(body["versions"], &(&1["page_slug"] == "full-page-a"))

      # The relation should be present
      assert Enum.any?(body["relations"], fn r ->
               r["source_slug"] == "full-page-a" and r["target_slug"] == "full-page-b"
             end)
    end

    test "returns 404 for unknown context id", %{conn: conn} do
      conn = get(conn, "/api/export/00000000-0000-0000-0000-000000000000/full")
      assert json_response(conn, 404)
    end
  end
end
