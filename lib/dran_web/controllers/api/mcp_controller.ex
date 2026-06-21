defmodule DranWeb.API.MCPController do
  @moduledoc """
  MCP Streamable HTTP transport endpoint.

  Serves the MCP protocol at POST/GET/DELETE /api/mcp per spec 2025-03-26.
  """

  use DranWeb, :controller

  alias Dran.MCP

  @doc "POST /api/mcp — send JSON-RPC message"
  def handle_post(conn, _params) do
    # Validate Accept header
    accept = get_req_header(conn, "accept") |> Enum.join(",")

    if String.contains?(accept, "application/json") or
         String.contains?(accept, "text/event-stream") or
         String.contains?(accept, "*/*") do
      handle_post_body(conn)
    else
      conn
      |> put_status(:not_acceptable)
      |> json(%{
        errors: %{detail: "Accept header must include application/json or text/event-stream"}
      })
    end
  end

  defp handle_post_body(conn) do
    case conn.body_params do
      %{} = msg when map_size(msg) > 0 ->
        # Check if it's a notification (has method but no id)
        is_notification =
          Map.has_key?(msg, "method") and
            not Map.has_key?(msg, "id")

        if is_notification do
          # Process notification but return 202 with no body
          MCP.process_message(msg)
          conn |> send_resp(:accepted, "")
        else
          # Process and return JSON response
          response = MCP.process_message(msg)

          case response do
            nil ->
              conn |> send_resp(:accepted, "")

            resp ->
              # Check if this is an initialize — generate session ID
              conn =
                if msg["method"] == "initialize" do
                  session_id = MCP.generate_session_id()
                  put_resp_header(conn, "mcp-session-id", session_id)
                else
                  conn
                end

              conn
              |> put_resp_header("mcp-protocol-version", MCP.protocol_version())
              |> json(resp)
          end
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "Invalid JSON-RPC message"}})
    end
  end

  @doc "GET /api/mcp — open SSE stream (optional, returns 405 if not supported)"
  def handle_get(conn, _params) do
    # We don't support server-initiated SSE streams in v1
    # Return 405 Method Not Allowed per spec
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_resp(:method_not_allowed, "")
  end

  @doc "DELETE /api/mcp — terminate session"
  def handle_delete(conn, _params) do
    # Session termination — just return 200
    conn |> send_resp(:ok, "")
  end
end
