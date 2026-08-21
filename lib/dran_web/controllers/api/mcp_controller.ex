defmodule DranWeb.API.MCPController do
  @moduledoc """
  MCP Streamable HTTP transport endpoint with per-user context auth.
  """

  use DranWeb, :controller

  alias Dran.{Accounts, MCP}

  @doc "POST /api/mcp — send JSON-RPC message"
  def handle_post(conn, _params) do
    with {:ok, user} <- authenticate(conn),
         :ok <- validate_context_access(conn, user) do
      process_mcp_request(conn, user)
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{errors: %{detail: "invalid token"}}))
        |> halt()

      {:error, :forbidden} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{errors: %{detail: "access to context denied"}}))
        |> halt()
    end
  end

  defp authenticate(conn) do
    case extract_token(conn) do
      {:ok, token} ->
        cond do
          # 1. Legacy admin token (backward compat)
          token == Dran.Auth.api_token() ->
            {:ok, %{is_owner: true, email: "admin", workspaces: :all}}

          # 2. Per-user token
          match?({:ok, _}, Accounts.valid_token?(token)) ->
            {:ok, user} = Accounts.valid_token?(token)
            {:ok, user}

          # 3. Context-scoped API key — masquerades as a synthetic user whose
          # workspaces are those granted by the key. Access checks then work unchanged.
          match?({:ok, _}, Accounts.valid_api_key?(token)) ->
            {:ok, key} = Accounts.valid_api_key?(token)

            # Build workspaces list and access_levels map
            workspaces =
              key.api_key_workspaces
              |> Enum.map(& &1.workspace)

            access_levels =
              key.api_key_workspaces
              |> Enum.into(%{}, fn akw -> {akw.workspace_id, akw.access_level} end)

            {:ok,
             %{
               is_owner: false,
               email: "api-key:***",
               key_name: key.name,
               workspaces: workspaces,
               access_levels: access_levels,
               created_by_user_id: key.created_by_user_id
             }}

          true ->
            {:error, :unauthorized}
        end

      :error ->
        {:error, :unauthorized}
    end
  end

  defp validate_context_access(conn, user) do
    requested_context = conn.params["workspace"] || get_default_context(user)

    if user.is_owner or user_has_context_access?(user, requested_context) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp get_default_context(user) do
    case user.workspaces do
      :all -> Dran.Auth.default_workspace_slug()
      [] -> Dran.Auth.default_workspace_slug()
      [first | _] -> first.slug
    end
  end

  # F2: a per-user token's access is members ∪ public workspaces (the plain
  # membership list would wrongly deny public workspaces the user can reach).
  defp user_has_context_access?(%Dran.Accounts.User{} = user, workspace_slug) do
    Enum.any?(Accounts.accessible_workspaces(user), &(&1.slug == workspace_slug))
  end

  # API-key synthetic users keep the workspaces granted by the key (scoped,
  # not broadened by instance-wide public visibility).
  defp user_has_context_access?(user, workspace_slug) do
    case user.workspaces do
      :all -> true
      contexts -> Enum.any?(contexts, &(&1.slug == workspace_slug))
    end
  end

  defp process_mcp_request(conn, user) do
    # Validate Accept header
    accept = get_req_header(conn, "accept") |> Enum.join(",")

    if String.contains?(accept, "application/json") or
         String.contains?(accept, "text/event-stream") or
         String.contains?(accept, "*/*") do
      handle_post_body(conn, user)
    else
      conn
      |> put_status(:not_acceptable)
      |> json(%{
        errors: %{detail: "Accept header must include application/json or text/event-stream"}
      })
    end
  end

  defp handle_post_body(conn, user) do
    case conn.body_params do
      %{} = msg when map_size(msg) > 0 ->
        is_notification = Map.has_key?(msg, "method") and not Map.has_key?(msg, "id")

        if is_notification do
          MCP.process_message(msg, user: user)
          conn |> send_resp(:accepted, "")
        else
          response = MCP.process_message(msg, user: user)

          case response do
            nil ->
              conn |> send_resp(:accepted, "")

            resp ->
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

  @doc "GET /api/mcp — respond 405 (SSE stream not implemented)"
  def handle_get(conn, _params) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_resp(:method_not_allowed, "")
  end

  @doc "DELETE /api/mcp — terminate session"
  def handle_delete(conn, _params) do
    conn |> send_resp(:ok, "")
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
