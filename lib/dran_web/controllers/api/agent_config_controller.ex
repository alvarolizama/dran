defmodule DranWeb.API.AgentConfigController do
  @moduledoc """
  GET /api/agent/config — self-description for agent clients (the Hermes
  memory plugin) authenticated with their per-agent API key.

  W5 (single-workspace): the answer is the INSTANCE. `workspaces` keeps its
  array shape with exactly one entry (backward compatibility for plugin
  versions that still iterate it), and the effective page types come from
  the instance workspace.
  """

  use DranWeb, :controller

  def show(conn, _params) do
    case conn.assigns[:user][:actor] do
      nil ->
        # Non API-key identities (user tokens / legacy admin) have no agent
        # identity — the endpoint is agent-key-only.
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "agent config requires an agent API key"}})

      actor ->
        user = conn.assigns[:user]

        # The single instance workspace (nil-safe: an empty instance answers
        # an empty list rather than crashing the plugin).
        workspaces =
          case DranWeb.API.Instance.instance_context() do
            nil -> []
            ws -> [ws]
          end
          |> Enum.map(fn ws ->
            %{
              id: ws.id,
              name: ws.name,
              slug: ws.slug,
              page_types: Dran.Knowledge.effective_page_types(ws),
              page_type_defs: Dran.Knowledge.page_type_defs(ws)
            }
          end)

        json(conn, %{
          data: %{
            agent: %{id: actor.id, name: actor.name, display_name: actor.display_name},
            workspaces: workspaces,
            # Effective types of the instance, so the agent discovers custom
            # types instead of hardcoding the built-in set.
            page_types: workspaces |> Enum.flat_map(& &1.page_types) |> Enum.uniq(),
            access_levels: Map.get(user, :access_levels, %{})
          }
        })
    end
  end
end
