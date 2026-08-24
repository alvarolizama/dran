defmodule DranWeb.PageDetail do
  @moduledoc """
  Shared plumbing for the per-page-type LiveViews (note, entity, concept,
  reference, todo, goal, plan, project).

  Those LiveViews all follow the same shape: an index list at `/notes` and a
  detail view at `/notes/:slug` with relations, versions, activity log,
  cluster summary and a rendered markdown body. This module holds the
  duplicated plumbing so each LiveView only keeps its template and its
  type-specific index logic.

  ## Usage

      alias DranWeb.PageDetail

      def mount(_params, session, socket) do
        PageDetail.mount_page_viewer(socket, session,
          page_type: @page_type,
          active_nav: "notes",
          extra_assigns: [cluster_summary: nil]
        )
      end

      def handle_params(%{"slug" => slug} = params, _url, socket) do
        PageDetail.load_page_detail(socket, params, slug, redirect_to: "/notes")
      end
  """

  import Phoenix.LiveView, only: [allow_upload: 3, push_navigate: 2, connected?: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 2]

  alias Dran.Knowledge
  alias DranWeb.Plugs.Auth

  @upload_accept ~w(image/* video/* audio/* application/pdf text/plain text/markdown text/csv text/html application/json application/zip)

  @doc """
  Shared mount for page-type viewer LiveViews.

  Resolves auth/context from the session, subscribes to the context PubSub
  topic, enables the `:file` upload (with `progress: &handle_progress/3` —
  the LiveView must keep defining that callback) and assigns the base keys
  every viewer uses (`context`, `page_type`, `active_tab`, `editing`,
  `save_status`, `active_nav`, `cluster_summary`) plus any
  `:extra_assigns`.

  ## Options

  * `:page_type` (required) — the page type this LiveView serves.
  * `:active_nav` (required) — sidebar nav key, e.g. `"notes"`.
  * `:extra_assigns` — keyword list merged into the base assigns.
  """
  def mount_page_viewer(socket, params, session, opts) do
    page_type = Keyword.fetch!(opts, :page_type)
    active_nav = Keyword.fetch!(opts, :active_nav)
    extra_assigns = Keyword.get(opts, :extra_assigns, [])

    # The URL slug wins over the session (see Plugs.Auth.assign_to_socket/3).
    {socket, context} = Auth.assign_to_socket(socket, session, params)

    socket =
      if context do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
        end

        allow_upload(
          socket,
          :file,
          accept: @upload_accept,
          max_file_size: Dran.Uploads.max_size(),
          auto_upload: true,
          progress: &handle_progress/3
        )
      else
        socket
      end

    base_assigns =
      [
        context: context,
        page_type: page_type,
        active_tab: "content",
        editing: false,
        save_status: "idle",
        active_nav: active_nav,
        cluster_summary: nil
      ]
      |> Keyword.merge(extra_assigns)

    {:ok, assign(socket, base_assigns)}
  end

  # Default no-op upload progress callback. LiveViews that already define
  # their own `handle_progress/3` keep using theirs — the `allow_upload`
  # capture above resolves at runtime to the socket's view.
  @doc false
  def handle_progress(_name, _entry, socket), do: {:noreply, socket}

  @doc """
  Load the detail view for `slug`: page, relations, versions, recent log,
  cluster summary, edit form and rendered markdown body.

  Redirects to `redirect_to` when the context is missing or the page does
  not exist.

  ## Options

  * `:redirect_to` (required) — index path, e.g. `"/notes"`.
  """
  def load_page_detail(socket, params, slug, opts) do
    redirect_to = Keyword.fetch!(opts, :redirect_to)
    {socket, context} = Auth.resolve_workspace(socket, params)

    with %{} = context <- context,
         %Dran.Page{} = page <- Knowledge.get_page_by_slug(slug, context.id) do
      active_tab = Map.get(socket.assigns, :active_tab, "content")

      {:noreply,
       assign(socket,
         page: page,
         relations: Knowledge.list_relations_for_page(page.id),
         versions: Knowledge.list_page_versions(page.id),
         compare_version: nil,
         logs: Knowledge.list_log(workspace_id: context.id, limit: 10),
         page_title: page.title,
         active_tab: active_tab,
         cluster_summary: load_cluster_summary(page),
         editing: Map.get(params, "edit") == "true",
         form: Knowledge.change_page(page) |> to_form(as: :page),
         workspace_id: context.id,
         save_status: "idle",
         rendered_body: render_body(page)
       )}
    else
      _ -> {:noreply, push_navigate(socket, to: redirect_to)}
    end
  end

  @doc """
  Fetch the GraphRAG cluster summary for a page, swallowing any error
  (clusters may not be computed yet, inference may be off, etc.).
  """
  def load_cluster_summary(%Dran.Page{} = page) do
    case Dran.Graph.ClusterSummaries.get_summary_for_page(page.id) do
      {:ok, summary} -> summary
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Render a page's markdown body with embeds and inline links resolved.
  """
  def render_body(%Dran.Page{} = page) do
    import DranWeb.PageComponents, only: [render_markdown: 2]

    render_markdown(page.body,
      workspace_id: page.workspace_id,
      inline_links: Map.get(page.meta || %{}, "inline_links", [])
    )
  end
end
