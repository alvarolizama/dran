defmodule DranWeb.API.AgentConfigController do
  @moduledoc """
  GET /api/agent/config — self-description for agent clients (the Hermes
  memory plugin) authenticated with their per-agent API key.

  Returns the agent's identity and the workspaces its key may reach with
  their access levels. The plugin chooses its memory workspace LOCALLY
  (dran_memory.json) from this list — Dran never decides it server-side.
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

        workspaces =
          user
          |> Map.get(:workspaces, [])
          |> Enum.map(fn ws -> %{id: ws.id, name: ws.name, slug: ws.slug} end)

        json(conn, %{
          data: %{
            agent: %{id: actor.id, name: actor.name, display_name: actor.display_name},
            workspaces: workspaces,
            access_levels: Map.get(user, :access_levels, %{})
          }
        })
    end
  end
end
