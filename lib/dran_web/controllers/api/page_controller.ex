defmodule DranWeb.API.PageController do
  use DranWeb, :controller

  alias Dran.Knowledge
  alias DranWeb.API.Instance

  @doc "GET /api/knowledge-pages — list pages with filters"
  def index(conn, _params) do
    # W5: the instance IS the workspace — no context param to resolve.
    opts =
      []
      |> maybe_put(:workspace_id, Instance.instance_context_id())
      |> Keyword.put(:scope, Instance.scope_for(conn, :pages))
      |> maybe_put(:type, conn.query_params["type"])
      |> maybe_put(:tag, conn.query_params["tag"])
      |> maybe_put(:status, conn.query_params["status"])
      |> maybe_put(:owner, conn.query_params["owner"])
      |> maybe_put(:created_by, conn.query_params["created_by"])
      |> maybe_put(:limit, conn.query_params["limit"] && String.to_integer(conn.query_params["limit"]))
      |> maybe_put(:include_body, conn.query_params["include"] == "body")

    pages = Knowledge.list_pages(opts)

    if opts[:include_body] do
      json(conn, %{data: pages})
    else
      # Lightweight listing — no body
      json(conn, %{data: Enum.map(pages, &page_summary/1)})
    end
  end

  @doc "GET /api/knowledge-pages/:slug — get a page"
  def show(conn, %{"slug" => slug, "workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      scope = Instance.scope_for(conn, :pages)

      case Knowledge.get_page_by_slug(slug, context.id, scope: scope) do
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

  # W5: no workspace param required — the flat surface resolves the instance.
  def show(conn, %{"slug" => slug}) do
    show(conn, %{"slug" => slug, "workspace" => nil})
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "slug is required"}})
  end

  @doc "POST /api/knowledge-pages — create a page"
  def create(conn, params) do
    # W5: writes always target the instance workspace.
    params = Map.put(params, "workspace_id", Instance.instance_context_id())

    # Inject attribution from the authenticated identity.
    # created_by is derived server-side from the actor — never client-settable.
    # owner_user_id and agent_name are resolved here too and overwrite any
    # client-supplied value (a client can never set them).
    user = conn.assigns[:user]

    params =
      params
      |> Map.put("created_by", Dran.Auth.resolve_created_by(user))
      |> Map.put("owner_user_id", Dran.Auth.resolve_owner_user_id(user))
      |> Map.put("agent_name", Dran.Auth.agent_name_from_headers(conn.req_headers))

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

  @doc "PUT /api/knowledge-pages/:slug — update a page"
  def update(conn, %{"slug" => slug} = params) do
    with_context(conn, nil, fn conn, context ->
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
            params
            |> Instance.permit_page_params()
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

  @doc "DELETE /api/knowledge-pages/:slug — delete a page"
  def delete(conn, %{"slug" => slug}) do
    with_context(conn, nil, fn conn, context ->
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

  @doc "POST /api/knowledge-pages/:slug/rename — rename a page's slug (rewrites embeds)."
  def rename(conn, %{"slug" => slug} = params) do
    with_context(conn, nil, fn conn, context ->
      new_slug = params["new_slug"]

      cond do
        not is_binary(new_slug) or String.trim(new_slug) == "" ->
          conn
          |> put_status(:bad_request)
          |> json(%{errors: %{detail: "new_slug is required"}})

        true ->
          case Knowledge.get_page_by_slug(slug, context.id) do
            nil ->
              conn
              |> put_status(:not_found)
              |> json(%{errors: %{detail: "page not found"}})

            page ->
              # Rename rewrites `![[old-slug]]` embeds across the workspace —
              # irreversible-ish, which is why the skills gate it behind an ASK.
              case Knowledge.rename_slug(page, String.trim(new_slug)) do
                %{slug: renamed} = updated ->
                  json(conn, %{data: updated, renamed_from: slug, renamed_to: renamed})

                other ->
                  conn
                  |> put_status(:unprocessable_entity)
                  |> json(%{errors: %{detail: "rename failed: #{inspect(other)}"}})
              end
          end
      end
    end)
  end

  @doc "POST /api/knowledge-pages/:slug/reaugment — refresh embeddings/summary."
  def reaugment(conn, %{"slug" => slug}) do
    with_context(conn, nil, fn conn, context ->
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "page not found"}})

        page ->
          # Clear the embedding hash so the augmenter treats the page as
          # stale, then schedule the async pipeline (same as the plugin tool).
          page
          |> Ecto.Changeset.change(embedding_hash: nil)
          |> Dran.Repo.update!()

          Dran.PageAugmenter.schedule(page)

          json(conn, %{data: %{slug: page.slug, scheduled: true}})
      end
    end)
  end

  @doc "POST /api/cluster-summaries — regenerate the nightly cluster summaries."
  def cluster_summaries(conn, _params) do
    workspace_id = Instance.instance_context_id()

    if workspace_id do
      case Dran.Graph.ClusterSummaries.generate_all(workspace_id) do
        :ok ->
          summaries = Dran.Graph.ClusterSummaries.list_summaries(workspace_id)
          json(conn, %{data: %{count: length(summaries)}})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{detail: "failed: #{inspect(reason)}"}})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{errors: %{detail: "workspace query param is required"}})
    end
  end

  @doc "GET /api/knowledge-pages/:slug/links — inbound + outbound relations"
  def links(conn, %{"slug" => slug}) do
    with_context(conn, nil, fn conn, context ->
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

  @doc "GET /api/knowledge-pages/:slug/graph — subgraph centered on a page"
  def graph(conn, %{"slug" => slug}) do
    with_context(conn, nil, fn conn, context ->
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
      created_by: page.created_by,
      archived: page.archived,
      updated_at: page.updated_at
    }
  end

  defp page_without_body(page) do
    %{page | body: nil}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
