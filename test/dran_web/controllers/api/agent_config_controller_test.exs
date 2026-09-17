defmodule DranWeb.API.AgentConfigControllerTest do
  @moduledoc """
  GET /api/agent/config — the self-description endpoint the Hermes memory
  plugin hits to learn which workspaces its key may reach. The memory
  workspace CHOICE is made locally in Hermes (dran_memory.json); this
  endpoint only lists the options + access levels.
  """
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{
        email: "owner-#{unique}@example.com",
        name: "Owner",
        is_owner: true
      })

    {:ok, ws_a} =
      Knowledge.create_workspace(%{name: "Alpha #{unique}", slug: "alpha-#{unique}"})

    {:ok, ws_b} =
      Knowledge.create_workspace(%{name: "Beta #{unique}", slug: "beta-#{unique}"})

    %{owner: owner, ws_a: ws_a, ws_b: ws_b, unique: unique}
  end

  defp agent_conn(owner, ws_a, ws_b, unique, levels \\ {"write", "read"}) do
    {:ok, actor} = Dran.Actors.create_actor(%{name: "cfg-agent-#{unique}", kind: "agent"})

    {lvl_a, lvl_b} = levels

    {:ok, key} =
      Accounts.create_api_key(%{
        name: actor.name,
        workspace_ids: [
          {ws_a.id, lvl_a},
          {ws_b.id, lvl_b}
        ],
        created_by_user_id: owner.id,
        actor_id: actor.id
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")

    {conn, actor, key}
  end

  test "lists the agent identity and the workspaces its key may reach", %{
    owner: owner,
    ws_a: ws_a,
    ws_b: ws_b,
    unique: unique
  } do
    {conn, actor, _key} = agent_conn(owner, ws_a, ws_b, unique)

    conn = get(conn, "/api/agent/config")

    assert %{"data" => data} = json_response(conn, 200)

    assert data["agent"]["name"] == actor.name
    assert data["agent"]["id"] == actor.id

    slugs = data["workspaces"] |> Enum.map(& &1["slug"]) |> Enum.sort()
    assert slugs == Enum.sort([ws_a.slug, ws_b.slug])

    # access levels keyed by workspace id — what the plugin checks to know
    # if its memory workspace choice is writable
    levels = data["access_levels"]
    assert levels[ws_a.id] == "write"
    assert levels[ws_b.id] == "read"
  end

  # W2 (?04/?07): the endpoint now also exposes the EFFECTIVE page types per
  # workspace (built-in ∪ custom) so the agent discovers a workspace's own
  # vocabulary instead of hardcoding the built-in set. The Python plugin's
  # hardcoded list is untouched here — that is W5.
  test "exposes the effective page types (built-in ∪ custom) per workspace", %{
    owner: owner,
    ws_a: ws_a,
    ws_b: ws_b,
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

    {:ok, ws_a} = Knowledge.update_workspace_settings(ws_a, %{workspace_page_types: [recipe]})

    {conn, _actor, _key} = agent_conn(owner, ws_a, ws_b, unique)
    conn = get(conn, "/api/agent/config")

    assert %{"data" => data} = json_response(conn, 200)

    # Top-level union across the key's workspaces
    assert "recipe" in data["page_types"]
    assert "note" in data["page_types"]

    alpha = Enum.find(data["workspaces"], &(&1["slug"] == ws_a.slug))
    assert alpha["page_types"] == ~w(note entity concept reference recipe)

    beta = Enum.find(data["workspaces"], &(&1["slug"] == ws_b.slug))
    assert beta["page_types"] == ~w(note entity concept reference)

    # Full per-type shape: the custom entry carries its declared path/UI attrs
    custom = Enum.find(alpha["page_type_defs"], &(&1["slug"] == "recipe"))
    assert custom["path"] == "recipes"
    assert custom["label"] == "Receta"
    assert custom["plural"] == "Recetas"
    assert custom["icon"] == "hero-beaker"
    assert custom["color"] == "amber"
    assert custom["builtin"] == false

    builtin = Enum.find(alpha["page_type_defs"], &(&1["slug"] == "note"))
    assert builtin["path"] == "notes"
    assert builtin["builtin"] == true
    # meta_fields ship as JSON arrays (no tuples/atoms), so they encode cleanly
    assert is_list(builtin["meta_fields"])
    assert Enum.all?(builtin["meta_fields"], &is_list/1)
  end

  test "401 without a token" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> get("/api/agent/config")

    assert json_response(conn, 401)
  end
end
