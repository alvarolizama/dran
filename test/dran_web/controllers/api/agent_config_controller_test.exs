defmodule DranWeb.API.AgentConfigControllerTest do
  @moduledoc """
  GET /api/agent/config — the self-description endpoint the Hermes memory
  plugin hits. W3/W5: authenticated with the account's `api_token`; the answer
  is the INSTANCE (one workspace entry, its effective page types) and the agent
  name comes from the `X-Hermes-Agent` header.
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

  defp agent_conn(owner, unique) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{owner.api_token}")
    |> Plug.Conn.put_req_header("x-hermes-agent", "cfg-agent-#{unique}")
  end

  test "lists the agent identity and the instance it reaches", %{
    owner: owner,
    ws_a: ws_a,
    unique: unique
  } do
    conn = agent_conn(owner, unique)
    conn = get(conn, "/api/agent/config")

    assert %{"data" => data} = json_response(conn, 200)

    # W3: la identidad del agente sale del header X-Hermes-Agent; el agente ES
    # la credencial de su dueño (id sintético).
    assert data["agent"]["name"] == "cfg-agent-#{unique}"
    assert data["agent"]["id"] == "account:#{owner.id}"

    # Exactly one entry: the instance.
    slugs = data["workspaces"] |> Enum.map(& &1["slug"])
    assert slugs == [ws_a.slug]

    # La matriz por workspace murió con la key: vacía, nunca inventada.
    assert data["access_levels"] == %{}
  end

  test "agent.name falls back to the owner email when no header came", %{owner: owner} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{owner.api_token}")

    conn = get(conn, "/api/agent/config")

    assert %{"data" => data} = json_response(conn, 200)
    assert data["agent"]["name"] == owner.email
  end

  # W2 (?04/?07): the endpoint exposes the EFFECTIVE page types per workspace
  # (built-in ∪ custom) so the agent discovers a workspace's own vocabulary
  # instead of hardcoding the built-in set.
  test "exposes the effective page types (built-in ∪ custom) per workspace", %{
    owner: owner,
    ws_a: ws_a,
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

    conn = agent_conn(owner, unique)
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
