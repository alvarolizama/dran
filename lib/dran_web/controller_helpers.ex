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
  Invoke `fun` with the connection and the INSTANCE context
  (single-workspace model, W5): the legacy `workspace_slug` argument is
  accepted for call-site compatibility but no longer selects anything.

  Responds 404 `context not found` when the instance has no workspace.

  ## Usage

      def show(conn, %{"slug" => slug, "workspace" => slug}) do
        with_context(conn, slug, fn conn, context ->
          json(conn, %{data: Knowledge.get_page_by_slug(slug, context.id)})
        end)
      end
  """
  @spec with_context(Plug.Conn.t(), binary() | nil, (Plug.Conn.t(), Dran.Workspace.t() ->
                                                       Plug.Conn.t())) ::
          Plug.Conn.t()
  def with_context(conn, _legacy_slug, fun) do
    case Dran.Auth.instance_workspace() do
      nil ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> Phoenix.Controller.json(%{errors: %{detail: "context not found"}})

      context ->
        fun.(conn, context)
    end
  end
end
