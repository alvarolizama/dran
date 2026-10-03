defmodule DranWeb.API.AgentConfigController do
  @moduledoc """
  GET /api/agent/config — self-description for agent clients (the Hermes
  memory plugin) authenticated with the account's `api_token`.

  W3 (single credential): there is no per-agent key any more. The agent
  identity comes from the `X-Hermes-Agent` header (else the account email),
  resolved by the auth pipeline.

  W5 (single-workspace): the answer is the INSTANCE. `workspaces` keeps its
  array shape with exactly one entry (backward compatibility for plugin
  versions that still iterate it), and the effective page types come from
  the instance workspace.
  """

  use DranWeb, :controller

  def show(conn, _params) do
    case conn.assigns[:user] do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "agent config requires an authenticated token"}})

      user ->
        agent = Map.get(user, :actor) || fallback_agent(user)

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
            agent: %{id: agent.id, name: agent.name, display_name: agent.display_name},
            workspaces: workspaces,
            # Effective types of the instance, so the agent discovers custom
            # types instead of hardcoding the built-in set.
            page_types: workspaces |> Enum.flat_map(& &1.page_types) |> Enum.uniq(),
            # The per-workspace access matrix died with the per-agent key; the
            # account credential carries no levels. Kept as an empty map so old
            # plugin builds that read it keep working without inventing data.
            access_levels: %{}
          }
        })
    end
  end

  # Non-account identities (e.g. the legacy admin token) have no `:actor`;
  # describe them from the header/email the pipeline resolved.
  defp fallback_agent(user) do
    %{
      id: nil,
      name: Map.get(user, :agent_name) || Map.get(user, :email) || "agent",
      display_name: nil
    }
  end
end
