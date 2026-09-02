defmodule DranWeb.API.PageController do
  use DranWeb, :controller

  alias Dran.Knowledge

  @doc "GET /api/pages — list pages with filters"
  def index(conn, params) do
    # Resolve context slug to workspace_id (like TodoController does)
    params = resolve_workspace_id(conn, params)

    opts =
      []
      |> maybe_put(:workspace_id, params["workspace_id"])
      |> maybe_put(:type, params["type"])
      |> maybe_put(:tag, params["tag"])
      |> maybe_put(:status, params["status"])
      |> maybe_put(:owner, params["owner"])
      |> maybe_put(:created_by, params["created_by"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
      |> maybe_put(:include_body, params["include"] == "body")

    pages = Knowledge.list_pages(opts)

    if opts[:include_body] do
      json(conn, %{data: pages})
    else
      # Lightweight listing — no body
      json(conn, %{data: Enum.map(pages, &page_summary/1)})
    end
  end

  @doc "GET /api/pages/:slug — get a page"
  def show(conn, %{"slug" => slug, "workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      case Knowledge.get_page_by_slug(slug, context.id) do
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
    end)
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "POST /api/pages — create a page"
  def create(conn, params) do
    # Resolve context slug to ID if needed
    params = resolve_workspace_id(conn, params)

    # Inject owner/created_by from the authenticated identity.
    # owner and created_by are derived server-side from the actor — never
    # client-settable (same guarantee as MCP; fixes the old put_new gap).
    user = conn.assigns[:user]

    params =
      params
      |> Map.put("owner", Dran.Auth.resolve_owner(user))
      |> Map.put("created_by", Dran.Auth.resolve_created_by(user))

    case Knowledge.create_page(params) do
      {:ok, page} ->
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
  def update(conn, %{"slug" => slug, "workspace" => workspace_slug} = params) do
    with_context(conn, workspace_slug, fn conn, context ->
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          # SEC-006: whitelist instead of blacklist — only these fields are
          # client-settable. Prevents mass assignment of workspace_id, owner,
          # created_by, etc. updated_by is injected server-side from the
          # authenticated actor (never taken from the client).
          params =
            Map.take(params, [
              "title",
              "body",
              "tags",
              "meta",
              "summary",
              "archived",
              "kb_confidence",
              "kb_source_url",
              "kb_contested"
            ])
            |> Map.put("updated_by", Dran.Auth.resolve_created_by(conn.assigns[:user]))

          case Knowledge.update_page(page, params) do
            {:ok, updated} ->
              json(conn, %{data: updated})

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(changeset)})
          end
      end
    end)
  end

  def update(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "DELETE /api/pages/:slug — delete a page"
  def delete(conn, %{"slug" => slug, "workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          case Knowledge.delete_page(page) do
            {:ok, _} ->
              conn |> send_resp(:no_content, "")

            {:error, _} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{errors: %{detail: "could not delete"}})
          end
      end
    end)
  end

  def delete(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "GET /api/pages/:slug/links — inbound + outbound relations"
  def links(conn, %{"slug" => slug, "workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          relations = Knowledge.list_relations_for_page(page.id)
          json(conn, %{data: relations})
      end
    end)
  end

  def links(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end

  @doc "GET /api/pages/:slug/graph — subgraph centered on a page"
  def graph(conn, %{"slug" => slug, "workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          relations = Knowledge.list_relations_for_page(page.id)
          json(conn, %{data: %{node: page, edges: relations}})
      end
    end)
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
      archived: page.archived,
      updated_at: page.updated_at
    }
  end

  defp page_without_body(page) do
    %{page | body: nil}
  end

  defp resolve_workspace_id(conn, params) do
    case params["workspace_id"] || params["workspace"] || conn.query_params["workspace"] do
      nil ->
        params

      context_val ->
        # Always try slug first, then fall back to ID lookup
        context = Knowledge.get_workspace_by_slug(context_val)

        context =
          if context do
            context
          else
            # Try by ID — use Repo.get to avoid raising on invalid UUIDs
            case Ecto.UUID.cast(context_val) do
              {:ok, uuid} -> Dran.Repo.get(Dran.Workspace, uuid)
              :error -> nil
            end
          end

        if context do
          Map.put(params, "workspace_id", context.id)
        else
          params
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
