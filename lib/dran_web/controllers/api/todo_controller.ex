defmodule DranWeb.API.TodoController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/todos?context=...&status=... — list todo-style notes in a context"
  def index(conn, %{"workspace" => workspace_slug} = params) do
    with_context(conn, workspace_slug, fn conn, context ->
      opts = [workspace_id: context.id, type: "note", include_body: false]

      opts =
        if params["status"] do
          Keyword.put(opts, :status, params["status"])
        else
          opts
        end

      # Only notes with kind: "todo" are todo-style notes
      todos =
        Brain.list_pages(opts)
        |> Enum.filter(fn p -> get_in(p.meta, ["kind"]) == "todo" end)

      json(conn, %{data: todos})
    end)
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "POST /api/todos — create a todo-style note"
  def create(conn, params) do
    params = Map.put_new(params, "page_type", "note")

    # Set default kind "todo" and kanban_status in meta
    meta = params["meta"] || %{}
    meta = Map.put_new(meta, "kind", "todo")
    params = Map.put(params, "meta", Map.put_new(meta, "kanban_status", "backlog"))

    # Inject owner/created_by from the authenticated identity.
    user = conn.assigns[:user]

    params =
      params
      |> Map.put_new("owner", Dran.Auth.resolve_owner(user))
      |> Map.put_new("created_by", Dran.Auth.resolve_created_by(user))

    case Brain.create_page(params) do
      {:ok, todo} ->
        conn
        |> put_status(:created)
        |> json(%{data: todo})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "PUT /api/todos/:id — update a todo-style note (kanban status, etc.)"
  def update(conn, %{"id" => id} = params) do
    case Brain.get_page(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "todo not found"}})

      todo ->
        # Merge kanban_status into meta if provided directly
        params =
          case params["kanban_status"] do
            nil ->
              params

            status ->
              meta = todo.meta || %{}
              params = Map.delete(params, "kanban_status")
              Map.put(params, "meta", Map.put(meta, "kanban_status", status))
          end

        case Brain.update_page(todo, params) do
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
