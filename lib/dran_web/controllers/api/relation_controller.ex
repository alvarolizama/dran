defmodule DranWeb.API.RelationController do
  use DranWeb, :controller

  alias Dran.Knowledge

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
      case Knowledge.create_relation_by_slugs(source_slug, target_slug, relation_type, context.id) do
        {:ok, relation} ->
          conn
          |> put_status(:created)
          |> json(%{data: relation})

        {:error, :source_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "source page not found"}})

        {:error, :target_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "target page not found"}})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    end)
  end

  def create(conn, %{"source_id" => _, "target_id" => _} = params) do
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

  Semantics inherited from the retired MCP tool: `relation_type` optional —
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
        case resolve_workspace(workspace_slug) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{errors: %{detail: "workspace not found"}})

          workspace ->
            # SEC-011: same access gate as delete/2 before touching rows.
            case DranWeb.ResourceAuthorization.authorize(user, :write, workspace) do
              :ok ->
                case Dran.Knowledge.delete_relation_by_slugs(
                       source_slug,
                       target_slug,
                       relation_type,
                       workspace.id
                     ) do
                  {:error, :source_not_found} ->
                    conn
                    |> put_status(:not_found)
                    |> json(%{errors: %{detail: "source page not found"}})

                  {:error, :target_not_found} ->
                    conn
                    |> put_status(:not_found)
                    |> json(%{errors: %{detail: "target page not found"}})

                  {count, errors} ->
                    json(conn, %{data: %{deleted: count, errors: errors}})
                end

              {:error, :forbidden} ->
                conn
                |> put_status(:forbidden)
                |> json(%{errors: %{detail: "forbidden"}})
            end
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  defp resolve_workspace(slug) do
    Dran.Knowledge.get_workspace_by_slug(slug) ||
      case Ecto.UUID.cast(slug) do
        {:ok, uuid} -> Dran.Repo.get(Dran.Workspace, uuid)
        :error -> nil
      end
  end

  @doc "DELETE /api/relations/:id — delete a relation by id."
  def delete(conn, %{"id" => id}) do
    # SEC-011: validate the user has access to the relation's context before deleting
    user = conn.assigns[:user]

    case Dran.Repo.get(Dran.Relation, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "relation not found"}})

      relation ->
        # Load the source page to check context access
        source_page = Dran.Knowledge.get_page(relation.source_id)

        if user && source_page &&
             (user.is_owner or user_has_context_access?(user, source_page.workspace_id)) do
          case Knowledge.delete_relation(relation) do
            {:ok, _} ->
              conn |> send_resp(:no_content, "")

            {:error, _} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{errors: %{detail: "could not delete"}})
          end
        else
          conn
          |> put_status(:forbidden)
          |> json(%{errors: %{detail: "access to context denied"}})
        end
    end
  end

  # Single authorization policy (SEC-001 read access).
  defp user_has_context_access?(user, workspace_id) do
    DranWeb.ResourceAuthorization.authorize(user, :read, workspace_id) == :ok
  end
end
