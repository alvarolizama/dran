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

  # ── Respuestas de error (contrato de superficies, W2) ─────────────────────
  #
  # Un recurso FUERA del scope de lectura es 404, nunca 403: la existencia no se
  # filtra (la misma postura que las páginas). El 409 es del bloqueo optimista
  # (una mano perdió la carrera) y el 422 del destino `scope` que no se puede
  # honrar — nunca un fallback silencioso.

  @doc "404 con el envelope del API (recurso fuera del scope = inexistente)."
  def not_found(conn, detail \\ "not found") do
    conn
    |> Plug.Conn.put_status(:not_found)
    |> Phoenix.Controller.json(%{errors: %{detail: detail}})
  end

  @doc "422 con errores por campo, o con un `detail` suelto."
  def unprocessable(conn, errors) when is_map(errors) do
    conn
    |> Plug.Conn.put_status(:unprocessable_entity)
    |> Phoenix.Controller.json(%{errors: errors})
  end

  @doc "409: la escritura perdió la carrera del `lock_version`."
  def conflict(conn, detail) do
    conn
    |> Plug.Conn.put_status(:conflict)
    |> Phoenix.Controller.json(%{errors: %{detail: detail}})
  end

  @doc "400: a la ruta le falta un dato del request."
  def bad_request(conn, detail) do
    conn
    |> Plug.Conn.put_status(:bad_request)
    |> Phoenix.Controller.json(%{errors: %{detail: detail}})
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
