defmodule DranWeb.API.GoalController do
  use DranWeb, :controller
  alias Dran.Goals

  @doc "GET /api/goals?context=... — list goals in a context"
  def index(conn, %{"workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      json(conn, %{data: Goals.list_goals(context.id)})
    end)
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "GET /api/goals/:slug?context=... — goal detail"
  def show(conn, %{"slug" => slug, "workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      case Goals.get_goal_by_slug(slug, context.id) do
        nil ->
          conn |> put_status(:not_found) |> json(%{errors: %{detail: "goal not found"}})

        goal ->
          json(conn, %{data: goal})
      end
    end)
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
