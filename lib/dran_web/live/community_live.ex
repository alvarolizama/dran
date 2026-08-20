defmodule DranWeb.CommunityLive do
  @moduledoc """
  LiveView for knowledge communities: clusters of related pages
  detected via Label Propagation, with optional LLM summaries.

  Views:
  - `:index` — `/communities` — grid of all community summaries
  - `:show`  — `/communities/:id` — detail view with summary + member pages
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.Graph
  alias Dran.Graph.CommunitySummaries
  alias DranWeb.Plugs.Auth
  alias DranWeb.PageTypes

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav="communities"
    >
      <div :if={@live_action == :index} class="p-6 overflow-y-auto w-full">
        <.index_view
          summaries={@summaries}
          generating={@generating}
          workspace={@workspace}
        />
      </div>

      <div :if={@live_action == :show} class="p-6 overflow-y-auto w-full">
        <.show_view
          summary={@summary}
          community_pages={@community_pages}
        />
      </div>
    </Layouts.app>
    """
  end

  # ── Index view ───────────────────────────────────────────────────────────

  defp index_view(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-6">
      <div>
        <h1 class="text-title">{gettext("Comunidades")}</h1>
        <p class="text-caption mt-1">
          {gettext("Clusters de páginas relacionadas en tu cerebro")}
        </p>
      </div>
      <button
        phx-click="regenerate"
        disabled={@generating}
        class={[
          "btn btn-primary btn-sm",
          @generating && "btn-disabled"
        ]}
      >
        <.icon
          name={if @generating, do: "hero-arrow-path", else: "hero-sparkles"}
          class={["w-4 h-4", @generating && "animate-spin"]}
        />
        {gettext("Regenerar")}
      </button>
    </div>

    <div
      :if={@summaries != []}
      class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
    >
      <div
        :for={summary <- @summaries}
        class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer"
        phx-click="show_community"
        phx-value-id={summary.community_id}
      >
        <div class="card-body p-5">
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-2">
              <.icon name="hero-squares-2x2" class="w-5 h-5 text-primary/70" />
              <h2 class="card-title text-base">
                {gettext("Comunidad")} #{summary.community_id}
              </h2>
            </div>
            <span class="text-xs text-base-content/50 bg-base-200 px-2 py-0.5 rounded-full">
              {summary.page_count} {ngettext("página", "páginas", summary.page_count)}
            </span>
          </div>

          <p class="text-sm text-base-content/60 line-clamp-3">
            {summary.summary}
          </p>

          <div :if={summary.top_pages != []} class="flex flex-wrap gap-1.5 mt-3">
            <span
              :for={page <- Enum.take(summary.top_pages, 4)}
              class="px-2 py-0.5 text-xs rounded-full bg-base-200 text-base-content/70"
            >
              {page.title || page.slug}
            </span>
            <span
              :if={length(summary.top_pages) > 4}
              class="text-xs text-base-content/40"
            >
              +{length(summary.top_pages) - 4} {gettext("más")}
            </span>
          </div>

          <div :if={summary.generated_at} class="text-xs text-base-content/40 mt-2">
            {Calendar.strftime(summary.generated_at, "%b %d, %Y")}
          </div>
        </div>
      </div>
    </div>

    <.empty_state
      :if={@summaries == []}
      icon="hero-squares-2x2"
      title={gettext("No community summaries yet.")}
    >
      <button
        :if={@workspace}
        phx-click="regenerate"
        disabled={@generating}
        class="btn btn-primary btn-sm mt-4"
      >
        <.icon name="hero-sparkles" class="w-4 h-4" /> {gettext("Generate community summaries")}
      </button>
    </.empty_state>
    """
  end

  # ── Show view ────────────────────────────────────────────────────────────

  defp show_view(assigns) do
    ~H"""
    <div :if={@summary}>
      <div class="flex items-center justify-between mb-6">
        <div>
          <div class="flex items-center gap-2 mb-1">
            <.icon name="hero-squares-2x2" class="w-6 h-6 text-primary/70" />
            <h1 class="text-title">
              {gettext("Comunidad")} #{@summary.community_id}
            </h1>
          </div>
          <p class="text-caption">
            {@summary.page_count} {ngettext("página", "páginas", @summary.page_count)}
            <span :if={@summary.generated_at} class="text-base-content/40 ml-2">
              · {gettext("Generada")} {Calendar.strftime(@summary.generated_at, "%b %d, %Y")}
            </span>
          </p>
        </div>
        <.link navigate={~p"/panel/communities"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back")}
        </.link>
      </div>

      <div :if={@summary.summary} class="surface-2 rounded-lg p-5 mb-6">
        <h3 class="text-sm font-semibold mb-2">{gettext("Resumen")}</h3>
        <p class="text-sm text-base-content/80 leading-relaxed">
          {@summary.summary}
        </p>
      </div>

      <div :if={@summary.top_pages != []} class="mb-6">
        <h3 class="text-sm font-semibold text-base-content/70 mb-3">
          {gettext("Páginas principales")}
        </h3>
        <div class="flex flex-wrap gap-2">
          <span
            :for={page <- @summary.top_pages}
            class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300 cursor-pointer hover:border-primary/40 transition"
            phx-click="show_page"
            phx-value-slug={page.slug}
          >
            {page.title || page.slug}
          </span>
        </div>
      </div>

      <div>
        <h3 class="text-sm font-semibold text-base-content/70 mb-3">
          {gettext("Todas las páginas")} ({length(@community_pages)})
        </h3>
        <div class="space-y-2">
          <div
            :for={page <- @community_pages}
            class="flex items-center gap-3 p-3 rounded-lg border border-base-300 hover:bg-base-200 cursor-pointer transition"
            phx-click="show_page"
            phx-value-slug={page.slug}
            phx-value-type={page.page_type}
          >
            <.icon
              name={PageTypes.icon(page.page_type)}
              class="w-4 h-4 text-base-content/40 shrink-0"
            />
            <span class="font-medium truncate">{page.title}</span>
            <span class="text-xs text-base-content/50 shrink-0 ml-auto">
              {PageTypes.label(page.page_type)}
            </span>
          </div>
        </div>
      </div>
    </div>

    <div :if={!@summary} class="text-center py-16">
      <.icon name="hero-squares-2x2" class="size-12 text-base-content/30 mx-auto mb-4" />
      <h2 class="text-title">{gettext("Community not found")}</h2>
      <.link navigate={~p"/panel/communities"} class="btn btn-ghost btn-sm mt-4">
        <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back")}
      </.link>
    </div>
    """
  end

  # ── Lifecycle ────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    if context do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    {:ok,
     assign(socket,
       context: context,
       summaries: [],
       summary: nil,
       community_pages: [],
       generating: false,
       active_nav: "communities"
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    summaries = load_summaries(socket.assigns.context)
    assign(socket, summaries: summaries, page_title: gettext("Comunidades"))
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    context = socket.assigns.context

    {summary, community_pages} =
      if context do
        with {community_id, ""} <- Integer.parse(id),
             {:ok, raw} <- CommunitySummaries.get_summary(context.id, community_id) do
          pages = Brain.community_pages(context.id, community_id)
          {normalize_summary(raw), pages}
        else
          _ -> {nil, []}
        end
      else
        {nil, []}
      end

    assign(socket,
      summary: summary,
      community_pages: community_pages,
      page_title:
        if(summary,
          do: gettext("Comunidad") <> " ##{summary.community_id}",
          else: gettext("Comunidad")
        )
    )
  end

  # ── Events ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("show_community", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/panel/communities/#{id}")}
  end

  def handle_event("show_page", %{"slug" => slug} = params, socket) do
    type = Map.get(params, "type")

    path =
      if type do
        "/panel/#{PageTypes.path(type)}/#{slug}"
      else
        # For top_pages we don't have the type — try searching
        case Brain.get_page_by_slug(slug, socket.assigns.context && socket.assigns.context.id) do
          nil -> "/panel"
          page -> PageTypes.page_show_path(page)
        end
      end

    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("regenerate", _params, socket) do
    context = socket.assigns.context

    if context do
      # Run detection + summary generation in background
      Task.start(fn ->
        # 1. Run Label Propagation community detection
        Graph.refresh_communities(context.id)

        # 2. Generate LLM summaries
        CommunitySummaries.generate_all(context.id)

        # 3. Notify the LiveView
        Phoenix.PubSub.broadcast(
          Dran.PubSub,
          "brain:#{context.id}",
          {:community_summaries_updated}
        )
      end)

      {:noreply, assign(socket, generating: true)}
    else
      {:noreply, socket}
    end
  end

  # ── PubSub ───────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:community_summaries_updated}, socket) do
    summaries = load_summaries(socket.assigns.context)

    # If we're on a show page, refresh it too
    summary =
      if socket.assigns.summary do
        case CommunitySummaries.get_summary(
               socket.assigns.context.id,
               socket.assigns.summary.community_id
             ) do
          {:ok, s} -> normalize_summary(s)
          _ -> socket.assigns.summary
        end
      else
        nil
      end

    {:noreply, assign(socket, summaries: summaries, summary: summary, generating: false)}
  end

  def handle_info({:page_changed, _action, _page}, socket) do
    # Re-summarize when pages change (for show view)
    if socket.assigns.live_action == :show && socket.assigns.summary do
      context = socket.assigns.context

      if context do
        summary = socket.assigns.summary
        pages = Brain.community_pages(context.id, summary.community_id)
        {:noreply, assign(socket, community_pages: pages)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp load_summaries(nil), do: []

  defp load_summaries(context) do
    context.id
    |> CommunitySummaries.list_summaries()
    |> Enum.map(&normalize_summary/1)
  end

  # Postgres {:array, :map} round-trips maps with string keys, but the HEEX
  # accesses them with dot syntax (page.title). Normalize top_pages maps to
  # atom keys so the template doesn't KeyError.
  defp normalize_summary(summary) do
    top_pages =
      Enum.map(summary.top_pages || [], fn page ->
        %{
          slug: Map.get(page, "slug") || Map.get(page, :slug),
          title: Map.get(page, "title") || Map.get(page, :title),
          pagerank: Map.get(page, "pagerank") || Map.get(page, :pagerank)
        }
      end)

    %{summary | top_pages: top_pages}
  end
end
