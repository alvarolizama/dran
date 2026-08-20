defmodule DranWeb.ControllerHelpers do
  @moduledoc """
  Shared helpers for API controllers.

  Imported automatically by every controller via `use DranWeb, :controller`.
  """

  @doc """
  Format an `Ecto.Changeset`'s errors as a plain map of strings, interpolating
  `%{key}` placeholders with their values — the JSON shape the API returns in
  `%{errors: ...}` responses.
  """
  @spec format_errors(Ecto.Changeset.t()) :: map()
  def format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
  end

  @doc """
  Resolve a context by slug and invoke `fun` with the connection and the
  context. Responds 404 `context not found` when the slug does not resolve.

  Replaces the recurring pattern in API controllers:

      context = Brain.get_workspace_by_slug(slug)
      if context do
        # ...happy path with context
      else
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "context not found"}})
      end

  ## Usage

      def index(conn, %{"workspace" => slug}) do
        with_context(conn, slug, fn conn, context ->
          json(conn, %{data: Brain.list_pages(workspace_id: context.id)})
        end)
      end
  """
  @spec with_context(Plug.Conn.t(), binary(), (Plug.Conn.t(), Dran.Brain.Workspace.t() ->
                                                 Plug.Conn.t())) ::
          Plug.Conn.t()
  def with_context(conn, workspace_slug, fun) do
    case Dran.Brain.get_workspace_by_slug(workspace_slug) do
      nil ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> Phoenix.Controller.json(%{errors: %{detail: "context not found"}})

      context ->
        fun.(conn, context)
    end
  end
end
