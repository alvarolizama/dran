defmodule DranWeb.DocsContent do
  @moduledoc """
  Static code samples used by the in-app documentation (DocsLive).

  Kept in a plain module (module attributes) because HEEx `~H\"\"\"` templates
  cannot contain nested triple-quoted heredocs.
  """

  @agent_connect_example """
  # Connect to Dran MCP
  POST http://localhost:4000/api/mcp
  Authorization: Bearer ***
  Content-Type: application/json

  {"jsonrpc": "2.0", "id": 1, "method": "initialize",
   "params": {"protocolVersion": "2025-03-26", "capabilities": {},
              "clientInfo": {"name": "my-agent", "version": "1.0"}}}

  # Verify schema
  ./scripts/mcp_smoke.sh
  """

  @auth_api_curl """
  curl -H "Authorization: Bearer ***" \
       http://localhost:4000/api/pages?context=personal
  """

  @planning_hierarchy_diagram """
  Goal (page_type: goal)
   └── Plan (meta.goal_slug → goal)
        ├── Plan A
        └── Plan B
             └── Todo (meta.plan_slug → plan, goal derived)
                  ├── Todo 1
                  └── Todo 2

  Orphan: Todo or Plan with no goal_slug / plan_slug
  part_of relation materialized automatically when links exist
  list_pages(goal_slug: "none") → returns orphan plans
  list_pages(plan_slug: "none") → returns orphan todos
  """

  def agent_connect_example, do: @agent_connect_example
  def auth_api_curl, do: @auth_api_curl
  def planning_hierarchy_diagram, do: @planning_hierarchy_diagram
end
