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

  @doc "DELETE /api/relations/:id — delete a relation"
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

  defp user_has_context_access?(%{contexts: :all}, _workspace_id), do: true

  defp user_has_context_access?(%{contexts: contexts}, workspace_id) when is_list(contexts) do
    Enum.any?(contexts, &(&1.id == workspace_id))
  end

  defp user_has_context_access?(_, _), do: false
end
