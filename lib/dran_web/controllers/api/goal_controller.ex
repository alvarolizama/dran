defmodule DranWeb.API.GoalController do
  use DranWeb, :controller
  alias Dran.Brain

  @doc "GET /api/goals?context=... — list goals in a context"
  def index(conn, %{"context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      goals = Brain.list_pages(context_id: context.id, type: "goal")
      json(conn, %{data: goals})
    else
      conn |> put_status(:not_found) |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "GET /api/goals/:slug?context=... — goal detail with related todos and plans"
  def show(conn, %{"slug" => slug, "context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          conn |> put_status(:not_found) |> json(%{errors: %{detail: "goal not found"}})

        goal ->
          goal_todos =
            Brain.list_pages(
              context_id: context.id,
              type: "todo",
              status: nil,
              limit: 500,
              include_body: false
            )
            |> Enum.filter(fn t -> get_in(t.meta, ["goal_slug"]) == slug end)

          goal_plans =
            Brain.list_pages(
              context_id: context.id,
              type: "plan",
              limit: 100,
              include_body: false
            )
            |> Enum.filter(fn p -> get_in(p.meta, ["goal_slug"]) == slug end)

          json(conn, %{data: %{goal: goal, todos: goal_todos, plans: goal_plans}})
      end
    else
      conn |> put_status(:not_found) |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
