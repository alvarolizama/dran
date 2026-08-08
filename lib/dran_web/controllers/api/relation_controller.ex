defmodule DranWeb.API.RelationController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "POST /api/relations — create a relation"
  def create(
        conn,
        %{"source_slug" => source_slug, "target_slug" => target_slug, "context" => context_slug} =
          params
      ) do
    relation_type = params["relation_type"] || "related"

    with_context(conn, context_slug, fn conn, context ->
      case Brain.create_relation_by_slugs(source_slug, target_slug, relation_type, context.id) do
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
    case Brain.create_relation(params) do
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
    case Brain.get_page(id) do
      nil ->
        # The id is a relation id — we need a delete_relation by id
        case Dran.Repo.get(Dran.Brain.Relation, id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{errors: %{detail: "relation not found"}})

          relation ->
            case Brain.delete_relation(relation) do
              {:ok, _} ->
                conn |> send_resp(:no_content, "")

              {:error, _} ->
                conn
                |> put_status(:internal_server_error)
                |> json(%{errors: %{detail: "could not delete"}})
            end
        end
    end
  end
end
