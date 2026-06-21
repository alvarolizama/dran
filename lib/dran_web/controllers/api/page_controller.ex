defmodule DranWeb.API.PageController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/pages — list pages with filters"
  def index(conn, params) do
    opts =
      []
      |> maybe_put(:context_id, params["context"])
      |> maybe_put(:type, params["type"])
      |> maybe_put(:tag, params["tag"])
      |> maybe_put(:status, params["status"])
      |> maybe_put(:owner, params["owner"])
      |> maybe_put(:created_by, params["created_by"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
      |> maybe_put(:include_body, params["include"] == "body")

    pages = Brain.list_pages(opts)

    if opts[:include_body] do
      json(conn, %{data: pages})
    else
      # Lightweight listing — no body
      json(conn, %{data: Enum.map(pages, &page_summary/1)})
    end
  end

  @doc "GET /api/pages/:slug — get a page"
  def show(conn, %{"slug" => slug, "context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          if conn.query_params["include"] == "body" do
            json(conn, %{data: page})
          else
            json(conn, %{data: page_without_body(page)})
          end
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "POST /api/pages — create a page"
  def create(conn, params) do
    # Resolve context slug to ID if needed
    params = resolve_context_id(conn, params)

    case Brain.create_page(params) do
      {:ok, page} ->
        # Auto-resolve wikilinks in background
        Brain.resolve_wikilinks(page)

        conn
        |> put_status(:created)
        |> json(%{data: page})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "PUT /api/pages/:slug — update a page"
  def update(conn, %{"slug" => slug, "context" => context_slug} = params) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          params = Map.drop(params, ["slug", "context"])

          case Brain.update_page(page, params) do
            {:ok, updated} ->
              Brain.resolve_wikilinks(updated)
              json(conn, %{data: updated})

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(changeset)})
          end
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def update(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "DELETE /api/pages/:slug — delete a page"
  def delete(conn, %{"slug" => slug, "context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          case Brain.delete_page(page) do
            {:ok, _} ->
              conn |> send_resp(:no_content, "")

            {:error, _} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{errors: %{detail: "could not delete"}})
          end
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def delete(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "GET /api/pages/:slug/links — inbound + outbound relations"
  def links(conn, %{"slug" => slug, "context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          relations = Brain.list_relations_for_page(page.id)
          json(conn, %{data: relations})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def links(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "GET /api/pages/:slug/graph — subgraph centered on a page"
  def graph(conn, %{"slug" => slug, "context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          relations = Brain.list_relations_for_page(page.id)
          json(conn, %{data: %{node: page, edges: relations}})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def graph(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp page_summary(page) do
    %{
      id: page.id,
      title: page.title,
      slug: page.slug,
      page_type: page.page_type,
      summary: page.summary,
      tags: page.tags,
      meta: page.meta,
      version: page.version,
      owner: page.owner,
      created_by: page.created_by,
      updated_at: page.updated_at
    }
  end

  defp page_without_body(page) do
    %{page | body: nil}
  end

  defp resolve_context_id(conn, params) do
    case params["context_id"] || params["context"] || conn.query_params["context"] do
      nil ->
        params

      context_val ->
        # Always try slug first, then fall back to ID lookup
        context = Brain.get_context_by_slug(context_val)

        context =
          if context do
            context
          else
            # Try by ID — use Repo.get to avoid raising on invalid UUIDs
            case Ecto.UUID.cast(context_val) do
              {:ok, uuid} -> Dran.Repo.get(Dran.Brain.Context, uuid)
              :error -> nil
            end
          end

        if context do
          Map.put(params, "context_id", context.id)
        else
          params
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
  end
end
