defmodule DranWeb.API.PageTypeControllerTest do
  @moduledoc """
  GET /api/workspaces/:slug/page-types — read-only introspection of a
  workspace's effective page types (built-in ∪ custom) so an agent discovers
  the workspace vocabulary instead of hardcoding the four built-ins. Same
  shape as the `page_types` / `page_type_defs` fields of `/api/agent/config`,
  but reachable by any identity with read access.
  """
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{
        email: "pt-owner-#{unique}@example.com",
        name: "Owner",
        is_owner: true
      })

    {:ok, ws} =
      Knowledge.create_workspace(%{name: "PT #{unique}", slug: "pt-#{unique}"})

    %{owner: owner, ws: ws, unique: unique}
  end

  defp key_conn(owner, workspace_levels, unique) do
    {:ok, key} =
      Accounts.create_api_key(%{
        name: "pt-key-#{unique}",
        workspace_ids: workspace_levels,
        created_by_user_id: owner.id
      })

    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
  end

  test "lists the built-in effective types with their full definitions", %{
    owner: owner,
    ws: ws,
    unique: unique
  } do
    conn = key_conn(owner, [{ws.id, "read"}], unique)
    conn = get(conn, "/api/workspaces/#{ws.slug}/page-types")

    assert %{"data" => data} = json_response(conn, 200)
    assert data["page_types"] == ~w(note entity concept reference)

    slugs = Enum.map(data["page_type_defs"], & &1["slug"])
    assert slugs == ~w(note entity concept reference)
    assert Enum.all?(data["page_type_defs"], &(&1["builtin"] == true))

    note = Enum.find(data["page_type_defs"], &(&1["slug"] == "note"))
    assert note["path"] == "notes"
    assert is_list(note["meta_fields"])
  end

  test "includes the workspace's custom types (declaration order, builtin: false)", %{
    owner: owner,
    ws: ws,
    unique: unique
  } do
    recipe = %{
      "slug" => "recipe",
      "label" => "Receta",
      "plural" => "Recetas",
      "path" => "recipes",
      "icon" => "hero-beaker",
      "color" => "amber",
      "meta_fields" => []
    }

    {:ok, ws} = Knowledge.update_workspace_settings(ws, %{workspace_page_types: [recipe]})

    conn = key_conn(owner, [{ws.id, "read"}], unique)
    conn = get(conn, "/api/workspaces/#{ws.slug}/page-types")

    data = json_response(conn, 200)["data"]
    assert data["page_types"] == ~w(note entity concept reference recipe)

    custom = Enum.find(data["page_type_defs"], &(&1["slug"] == "recipe"))
    assert custom["path"] == "recipes"
    assert custom["label"] == "Receta"
    assert custom["builtin"] == false
  end

  test "403 when the key does not reach the workspace", %{
    owner: owner,
    ws: ws,
    unique: unique
  } do
    {:ok, other} =
      Knowledge.create_workspace(%{name: "Other #{unique}", slug: "pt-other-#{unique}"})

    conn = key_conn(owner, [{other.id, "read"}], unique)
    conn = get(conn, "/api/workspaces/#{ws.slug}/page-types")

    assert json_response(conn, 403)
  end

  test "401 without a token", %{ws: ws} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> get("/api/workspaces/#{ws.slug}/page-types")

    assert json_response(conn, 401)
  end
end
