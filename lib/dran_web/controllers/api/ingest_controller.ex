defmodule DranWeb.API.IngestController do
  use DranWeb, :controller

  alias Dran.{Agent, Brain}

  @doc "POST /api/ingest — save a URL or download a file as a reference page"
  def ingest(conn, %{"url" => url, "context" => context_slug} = params) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Agent.Ingest.Utils.do_ingest(context, url, params) do
        {:ok, page} ->
          conn
          |> put_status(:created)
          |> json(%{data: %{slug: page.slug, title: page.title, page_type: page.page_type}})

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{errors: %{detail: reason}})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "url and context are required"}})
  end

  @doc "POST /api/ingest/file — upload and convert a file to a markdown note"
  def file(conn, %{"context" => context_slug, "file" => %Plug.Upload{} = upload} = params) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      tag_list = parse_tags(params["tags"])

      case Agent.Ingest.Utils.upload_file(context, upload, tag_list) do
        {:ok, page} ->
          conn
          |> put_status(:created)
          |> json(%{data: %{slug: page.slug, title: page.title, page_type: page.page_type}})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{detail: reason}})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def file(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "file and context are required"}})
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(tags) when is_list(tags), do: tags
  defp parse_tags(_), do: []
end
