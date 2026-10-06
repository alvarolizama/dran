defmodule DranWeb.API.RelationController do
  use DranWeb, :controller

  alias Dran.Knowledge
  alias DranWeb.API.Instance

  # ── Las aristas tocan DOS páginas (W1, contract grupo-credencial) ──────────
  #
  # Una arista no es un objeto suelto: es contenido ENTRE dos páginas. Escribir
  # o borrar una exige poder LEER las dos — con el scope del lector, en el punto
  # único (`Dran.ContentVisibility`). Antes, un token con rol `editor` cableaba
  # o desconectaba páginas privadas ajenas por slug, y el par se resolvía sin
  # scope. Una página fuera de scope es un 404, nunca un 403: el endpoint no
  # delata que la fila existe.

  @doc "POST /api/relations — create a relation"
  def create(
        conn,
        %{
          "source_slug" => source_slug,
          "target_slug" => target_slug,
          "workspace" => workspace_slug
        } =
          params
      ) do
    relation_type = params["relation_type"] || "related"

    with_context(conn, workspace_slug, fn conn, context ->
      case scoped_pair(conn, context.id, source_slug, target_slug) do
        :ok ->
          case Knowledge.create_relation_by_slugs(
                 source_slug,
                 target_slug,
                 relation_type,
                 context.id
               ) do
            {:ok, relation} ->
              conn
              |> put_status(:created)
              |> json(%{data: relation})

            {:error, :source_not_found} ->
              page_not_found(conn, "source page not found")

            {:error, :target_not_found} ->
              page_not_found(conn, "target page not found")

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(changeset)})
          end

        {:error, :source_not_found} ->
          page_not_found(conn, "source page not found")

        {:error, :target_not_found} ->
          page_not_found(conn, "target page not found")
      end
    end)
  end

  def create(conn, %{"source_id" => source_id, "target_id" => target_id} = params) do
    scope = Instance.scope_for(conn, :pages)

    with :ok <- scoped_page(source_id, scope),
         :ok <- scoped_page(target_id, scope) do
      case Knowledge.create_relation(params) do
        {:ok, relation} ->
          conn
          |> put_status(:created)
          |> json(%{data: relation})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      {:error, :not_found} -> page_not_found(conn, "page not found")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      errors: %{
        detail: "source_slug, target_slug, and context are required (or source_id + target_id)"
      }
    })
  end

  @doc """
  DELETE /api/relations — delete relations between two pages (by slug pair).

  Semantics inherited from the plugin tool: `relation_type` optional —
  omitting it deletes ALL relations between the pair in both directions.
  Returns the count of deleted relations.
  """
  def delete_by_slugs(conn, params) do
    user = conn.assigns[:user]
    source_slug = params["source_slug"]
    target_slug = params["target_slug"]
    relation_type = params["relation_type"]
    workspace_slug = params["workspace"]

    cond do
      blank?(source_slug) or blank?(target_slug) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "source_slug and target_slug are required"}})

      is_nil(workspace_slug) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "workspace query param is required"}})

      true ->
        case DranWeb.API.Instance.instance_context() do
          nil ->
            page_not_found(conn, "workspace not found")

          workspace ->
            # SEC-011: same access gate as delete/2 before touching rows.
            case DranWeb.ResourceAuthorization.authorize(user, :write, workspace) do
              :ok ->
                delete_pair(conn, workspace, source_slug, target_slug, relation_type)

              {:error, :forbidden} ->
                forbidden(conn)
            end
        end
    end
  end

  @doc "DELETE /api/relations/:id — delete a relation by id."
  def delete(conn, %{"id" => id}) do
    # SEC-011: se resuelve la página origen con el SCOPE del lector (W1): una
    # arista cuya página no se puede leer no se puede borrar — 404, sin fuga.
    user = conn.assigns[:user]

    # W4a (F31): canonical addressing is the uuid. `Ecto.UUID.cast/1` runs
    # before `Repo.get/2` — a forged/non-uuid binary is a clean 404, never a
    # Postgres uuid-cast crash.
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Dran.Relation{} = relation <- Dran.Repo.get(Dran.Relation, uuid),
         %{} = source_page <-
           Knowledge.get_page(relation.source_id, scope: Instance.scope_for(conn, :pages)) do
      if user && (user.is_owner or user_has_context_access?(user, source_page.workspace_id)) do
        case Knowledge.delete_relation(relation) do
          {:ok, _} ->
            conn |> send_resp(:no_content, "")

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{errors: %{detail: "could not delete"}})
        end
      else
        page_not_found(conn, "relation not found")
      end
    else
      _ ->
        page_not_found(conn, "relation not found")
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp delete_pair(conn, workspace, source_slug, target_slug, relation_type) do
    case scoped_pair(conn, workspace.id, source_slug, target_slug) do
      :ok ->
        case Dran.Knowledge.delete_relation_by_slugs(
               source_slug,
               target_slug,
               relation_type,
               workspace.id
             ) do
          {:error, :source_not_found} ->
            page_not_found(conn, "source page not found")

          {:error, :target_not_found} ->
            page_not_found(conn, "target page not found")

          {count, errors} ->
            json(conn, %{data: %{deleted: count, errors: errors}})
        end

      {:error, :source_not_found} ->
        page_not_found(conn, "source page not found")

      {:error, :target_not_found} ->
        page_not_found(conn, "target page not found")
    end
  end

  # Las DOS páginas de la arista, resueltas con el scope del lector: la primera
  # que falte nombra el 404 (mismos términos que el contexto de Knowledge).
  defp scoped_pair(conn, workspace_id, source_slug, target_slug) do
    scope = Instance.scope_for(conn, :pages)

    cond do
      not scoped_slug?(source_slug, workspace_id, scope) -> {:error, :source_not_found}
      not scoped_slug?(target_slug, workspace_id, scope) -> {:error, :target_not_found}
      true -> :ok
    end
  end

  defp scoped_slug?(slug, workspace_id, scope) when is_binary(slug) and is_binary(workspace_id),
    do: not is_nil(Knowledge.get_page_by_slug(slug, workspace_id, scope: scope))

  defp scoped_slug?(_slug, _workspace_id, _scope), do: false

  defp scoped_page(id, scope) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        if Knowledge.get_page(uuid, scope: scope), do: :ok, else: {:error, :not_found}

      :error ->
        {:error, :not_found}
    end
  end

  defp page_not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: detail}})
  end

  # `forbidden/1` vive en `DranWeb.ControllerHelpers` (W3, contract
  # auditoria-fixes): este controller lo usaba en privado, ahora es la casa.

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  # Single authorization policy (SEC-001 read access).
  defp user_has_context_access?(user, workspace_id) do
    DranWeb.ResourceAuthorization.authorize(user, :read, workspace_id) == :ok
  end
end
