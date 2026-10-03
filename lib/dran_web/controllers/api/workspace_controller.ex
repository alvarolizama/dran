defmodule DranWeb.API.WorkspaceController do
  @moduledoc """
  The instance workspace over the API — READ ONLY.

  W5 (F11/P6): the INSTANCE does not admit extra containers through the API.
  The write actions that used to live here (`create`, `update`, `delete`) are
  gone with their routes: `POST` left orphan containers behind (the report that
  opened this wave), and `PUT`/`DELETE` were the same class one step further —
  `DELETE /api/workspaces/:slug` removed ANY container, including the only
  instance. The container set is instance policy, not an agent capability.

  Reads stay: the plugin iterates `GET /api/workspaces`.
  """

  use DranWeb, :controller

  @doc """
  GET /api/workspaces (also /api/instance) — the instance workspace.

  W5 single-workspace: there is exactly one container. The response keeps
  the list shape (the plugin iterates it) with one entry.
  """
  def index(conn, _params) do
    case DranWeb.API.Instance.instance_context() do
      nil -> json(conn, %{data: []})
      context -> json(conn, %{data: [context]})
    end
  end

  @doc """
  GET /api/workspaces/:slug — the instance (any legacy slug segment).

  W5: the slug stopped selecting anything; unknown slugs still answer the
  instance so old plugin builds keep working after the fold.
  """
  def show(conn, %{"slug" => _legacy}) do
    case DranWeb.API.Instance.instance_context() do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})

      context ->
        json(conn, %{data: context})
    end
  end
end
