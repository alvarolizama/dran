defmodule DranWeb.API.ExportControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "authorization", "Bearer dran-token")}
  end

  describe "GET /api/contexts/:slug/export" do
    test "returns exported JSON with context, pages, and relations", %{conn: conn} do
      context = Brain.get_context_by_slug("personal")

      {:ok, page_a} =
        Brain.create_page(%{
          context_id: context.id,
          title: "Page A",
          slug: "export-page-a",
          body: "Body of page A",
          page_type: "note",
          tags: ["alpha"],
          summary: "A summary"
        })

      {:ok, page_b} =
        Brain.create_page(%{
          context_id: context.id,
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

      conn = get(conn, ~p"/api/contexts/personal/export")

      body = json_response(conn, 200)

      assert body["context"]["slug"] == "personal"
      assert body["context"]["name"] == context.name
      assert Map.has_key?(body["context"], "description")
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
      conn = get(conn, ~p"/api/contexts/nonexistent-context/export")

      assert json_response(conn, 404)
      assert %{"errors" => %{"detail" => "context not found"}} = json_response(conn, 404)
    end
  end
end
