defmodule DranWeb.API.WorkspaceController do
  use DranWeb, :controller

  alias Dran.Brain

  # SEC-007: context CRUD is admin-only. The :api_auth pipeline validates the
  # token but not the user's role — we plug require_admin on top.
  plug :require_admin when action in [:create, :update, :delete]

  @doc "GET /api/workspaces — list all contexts"
  def index(conn, _params) do
    contexts = Brain.list_workspaces()
    json(conn, %{data: contexts})
  end

  @doc "POST /api/workspaces — create a context"
  def create(conn, %{"name" => _name, "slug" => _slug} = params) do
    case Brain.create_workspace(params) do
      {:ok, context} ->
        conn
        |> put_status(:created)
        |> json(%{data: context})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "name and slug are required"}})
  end

  @doc "GET /api/workspaces/:slug — get a context"
  def show(conn, %{"slug" => slug}) do
    case Brain.get_workspace_by_slug(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})

      context ->
        json(conn, %{data: context})
    end
  end

  @doc "PUT /api/workspaces/:slug — update a context"
  def update(conn, %{"slug" => slug} = params) do
    context = Brain.get_workspace_by_slug(slug)

    if context do
      params = Map.drop(params, ["slug"])

      case Brain.update_workspace(context, params) do
        {:ok, updated} ->
          json(conn, %{data: updated})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  @doc "DELETE /api/workspaces/:slug — delete a context"
  def delete(conn, %{"slug" => slug}) do
    case Brain.get_workspace_by_slug(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})

      context ->
        case Brain.delete_workspace(context) do
          {:ok, _} ->
            conn |> put_status(:no_content) |> send_resp(:no_content, "")

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{errors: %{detail: "could not delete"}})
        end
    end
  end

  # SEC-007: admin check for destructive context operations
  defp require_admin(conn, _opts) do
    # The :api_auth pipeline already validated the token and set conn.assigns.user
    # (or we need to look it up). For API token auth, the user is in the token.
    # We need to check if the authenticated identity is admin.
    case conn.assigns[:user] do
      %{is_owner: true} ->
        conn

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{errors: %{detail: "admin access required"}})
        |> halt()
    end
  end
end
