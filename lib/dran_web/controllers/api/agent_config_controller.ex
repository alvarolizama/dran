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
              page_type_defs: agent_page_type_defs(ws)
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

  # One entry per built-in type (flag + UI attrs) followed by the workspace's
  # custom types in declaration order. The agent gets the full shape — slug,
  # label, plural, path, icon, color, meta_fields — so it can build URLs and
  # render the same vocabulary as the web UI.
  defp agent_page_type_defs(ws) do
    builtin =
      for type <- Dran.Knowledge.Page.all_types() do
        ui = Dran.PageRegistry.ui(type) || %{}

        %{
          "slug" => type,
          "label" => ui[:label],
          "plural" => ui[:plural],
          "path" => ui[:path],
          "icon" => ui[:icon],
          "color" => ui[:color],
          "meta_fields" => Dran.Workspace.meta_fields_json(type),
          "builtin" => true
        }
      end

    builtin ++ Dran.Workspace.page_type_defs(ws)
  end
end