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
            # Effective types for the workspaces this key reaches, so the agent
            # discovers custom types instead of hardcoding the built-in set.
            page_types: workspaces |> Enum.flat_map(& &1.page_types) |> Enum.uniq(),
            access_levels: Map.get(user, :access_levels, %{})
          }
        })
    end
  end

  # Full definitions are composed in Dran.Knowledge.page_type_defs/1 — shared
  # with GET /api/workspaces/:slug/page-types so both endpoints serve one shape.
end
