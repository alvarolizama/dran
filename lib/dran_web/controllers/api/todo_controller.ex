defmodule DranWeb.API.TodoController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/todos?context=...&status=... — list todos in a context"
  def index(conn, %{"context" => context_slug} = params) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      opts = [context_id: context.id, type: "todo", include_body: false]

      opts =
        if params["status"] do
          Keyword.put(opts, :status, params["status"])
        else
          opts
        end

      todos = Brain.list_pages(opts)
      json(conn, %{data: todos})
    else
      conn |> put_status(:not_found) |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "POST /api/todos — create a todo"
  def create(conn, params) do
    params = Map.put_new(params, "page_type", "todo")

    # Set default kanban_status in meta
    meta = params["meta"] || %{}
    params = Map.put(params, "meta", Map.put_new(meta, "kanban_status", "backlog"))

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

  @doc "PUT /api/todos/:id — update a todo (kanban status, etc.)"
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

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
  end
end
