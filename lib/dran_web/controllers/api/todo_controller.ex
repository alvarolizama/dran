defmodule DranWeb.API.TodoController do
  use DranWeb, :controller

  alias Dran.Tasks

  @moduledoc """
  Legacy `/api/todos` facade — write-through to the first-class tasks table.

  The response shape is unchanged for existing consumers (data array with
  title/slug/status fields), but everything now lives in `tasks`.
  """

  @doc "GET /api/todos?workspace=...&status=... — list tasks in a context"
  def index(conn, %{"workspace" => workspace_slug} = params) do
    with_context(conn, workspace_slug, fn conn, context ->
      opts = [workspace_id: context.id, limit: 500]

      opts =
        if params["status"] do
          Keyword.put(opts, :status, params["status"])
        else
          opts
        end

      todos = Tasks.list_tasks(opts)
      json(conn, %{data: todos})
    end)
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "POST /api/todos — create a task"
  def create(conn, params) do
    workspace_slug = params["workspace"] || params["context"]

    if is_nil(workspace_slug) do
      conn
      |> put_status(:bad_request)
      |> json(%{errors: %{detail: "workspace param is required"}})
    else
      with_context(conn, workspace_slug, fn conn, context ->
        # Legacy field mapping: kanban_status → status
        params =
          case params["kanban_status"] do
            nil -> params
            status -> Map.put(params, "status", status)
          end

        attrs =
          params
          |> Map.take(["title", "slug", "body", "status", "priority", "due_date", "recurrence"])
          |> Map.put("workspace_id", context.id)

        # Inject owner/created_by from the authenticated identity.
        user = conn.assigns[:user]

        attrs =
          attrs
          |> Map.put_new("owner", Dran.Auth.resolve_owner(user))
          |> Map.put_new("created_by", Dran.Auth.resolve_created_by(user))

        case Tasks.create_task(attrs) do
          {:ok, todo} ->
            conn
            |> put_status(:created)
            |> json(%{data: todo})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(changeset)})
        end
      end)
    end
  end

  @doc "PUT /api/todos/:id — update a task (status, etc.)"
  def update(conn, %{"id" => id} = params) do
    case Tasks.get_task(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "task not found"}})

      task ->
        # Legacy field mapping: kanban_status → status
        attrs =
          case params["kanban_status"] do
            nil ->
              params

            status ->
              Map.put(params, "status", status)
          end

        attrs =
          Map.take(attrs, ["title", "body", "status", "priority", "due_date", "recurrence"])

        case Tasks.update_task(task, attrs) do
          {:ok, updated} ->
            json(conn, %{data: updated})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(changeset)})
        end
    end
  end
end
