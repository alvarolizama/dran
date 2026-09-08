defmodule DranWeb.API.TodoController do
  use DranWeb, :controller

  alias Dran.Tasks

  @moduledoc """
  Legacy `/api/tasks` facade (antes `/api/todos`) — write-through to the
  first-class tasks table.

  The response shape is unchanged for existing consumers (data array with
  title/slug/status fields), but everything now lives in `tasks`.
  """

  @doc "GET /api/tasks?workspace=...&status=... — list tasks in a context"
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

  @doc "POST /api/tasks — create a task"
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

        # Inject attribution from the authenticated identity.
        # created_by is derived server-side — never client-settable.
        # creator_actor_id is the acting actor's id (F6); owner was dropped
        # with the actor model (phase 2).
        user = conn.assigns[:user]

        attrs =
          attrs
          |> Map.put("created_by", Dran.Auth.resolve_created_by(user))
          |> Map.put("creator_actor_id", Dran.Auth.resolve_acting_actor(user))

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

  @doc "PUT /api/tasks/:id — update a task (status, etc.)"
  def update(conn, %{"id" => id} = params) do
    case Tasks.get_task(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "task not found"}})

      task ->
        # SEC: the task is resolved globally by id — authorize the caller
        # against the task's OWN workspace before touching it. Without this,
        # any valid per-user token could update tasks of other workspaces by
        # guessing ids (the write-access plug only scopes API keys).
        if authorized_for_task?(conn, task) do
          # Legacy field mapping: kanban_status → status
          attrs =
            case params["kanban_status"] do
              nil ->
                params

              status ->
                Map.put(params, "status", status)
            end

          attrs =
            Map.take(attrs, [
              "title",
              "body",
              "status",
              "priority",
              "due_date",
              "recurrence",
              "archived"
            ])
            |> Map.put("updated_by", Dran.Auth.resolve_created_by(conn.assigns[:user]))

          case Tasks.update_task(task, attrs) do
            {:ok, updated} ->
              json(conn, %{data: updated})

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(changeset)})
          end
        else
          forbidden(conn)
        end
    end
  end

  # True when the caller may WRITE in the task's own workspace.
  # `authorize/3` is the single policy (legacy owner token and nil-user
  # fail-open, mirroring the read surfaces' behavior).
  defp authorized_for_task?(conn, task) do
    DranWeb.ResourceAuthorization.authorize(conn.assigns[:user], :write, task.workspace_id) == :ok
  end

  defp forbidden(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(403, Jason.encode!(%{errors: %{detail: "access to workspace denied"}}))
  end
end
