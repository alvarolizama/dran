defmodule DranWeb.API.AgentConfigControllerTest do
  @moduledoc """
  GET /api/agent/config — the self-description endpoint the Hermes memory
  plugin hits. W5 (single-workspace): the answer is the INSTANCE — one
  workspace entry, its effective page types, and the key's access level.
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

    # W5: the instance is the only workspace.
    ws = Dran.DataCase.ensure_workspace!()

    %{owner: owner, ws_a: ws, ws_b: ws, unique: unique}
  end

  defp agent_conn(owner, ws_a, _ws_b, unique, _levels \\ nil) do
    {:ok, actor} = Dran.Actors.create_actor(%{name: "cfg-agent-#{unique}", kind: "agent"})

    {:ok, key} =
      Accounts.create_api_key(%{
        name: actor.name,
        workspace_ids: [{ws_a.id, "write"}],
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
    {conn, _actor, key} = agent_conn(owner, ws_a, ws_b, unique)

    conn = get(conn, "/api/agent/config")

    assert %{"data" => data} = json_response(conn, 200)

    # W3: la identidad del agente se DERIVA de la key (una key ya no tiene
    # actor) — el `name` de la key es el nombre del agente y su `id` la key.
    assert data["agent"]["name"] == key.name
    assert data["agent"]["id"] == key.id

    # Exactly one entry: the instance.
    slugs = data["workspaces"] |> Enum.map(& &1["slug"])
    assert slugs == [ws_a.slug]

    # Access levels keyed by workspace id (the key's level on the instance).
    levels = data["access_levels"]
    assert levels[ws_a.id] == "write"
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

    # Top-level: the instance's effective types
    assert "recipe" in data["page_types"]
    assert "note" in data["page_types"]

    alpha = Enum.find(data["workspaces"], &(&1["slug"] == ws_a.slug))
    assert alpha["page_types"] == ~w(note entity concept reference recipe)

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
