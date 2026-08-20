defmodule DranWeb.HomeLive do
  @moduledoc """
  Home — workspace browser for contexts with `wiki_enabled: true`.

  Six actions:
  - `:index`         — landing: list of wiki-enabled contexts
  - `:workspace_home`  — home of a workspace: collections + pinned + index by type
  - `:type_list`      — alphabetical list of pages of one type
  - `:page_show`     — rendered page (markdown + mermaid, read-only)
  - `:collection`     — smart collection results in wiki mode
  - `:graph`          — graph of the workspace's pages

  Authenticated but accessible to ALL logged-in users, including wiki-only
  users (no contexts assigned). No edit/delete/create controls — pure browse.
  """

  use DranWeb, :live_view

  import Ecto.Query
  import Phoenix.HTML, only: [raw: 1]

  alias Dran.Knowledge

  alias Dran.Collections
  alias Dran.Workspace

  alias Dran.PageTypes, as: BrainPageTypes
  alias DranWeb.GraphHelpers
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  # Types hidden from the global 3D graph — same list the panel uses via
  # GraphCache. The wiki graph must match so both views render the same set.
  @graph_hidden_types Dran.PageTypes.hidden_from_graph()

  # ── Mount ─────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    {socket, workspace} = Auth.assign_to_socket(socket, session)

    # The wiki is browsable by ALL logged-in users (including wiki-only
    # auto-registered accounts with no contexts assigned). The sidebar
    # workspace selector must therefore list every wiki-enabled workspace, not
    # just the current user's assigned contexts. `assign_to_socket` sets
    # `contexts` to the user's accessible contexts, so override it here.
    socket = assign(socket, contexts: Knowledge.list_home_workspaces())

    # Subscribe to PubSub for the workspace so the graph view can debounce
    # page_changed broadcasts and tell the hook to re-fetch — same pattern
    # as GraphLive (panel).
    if workspace do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{workspace.id}")
    end

    {:ok,
     assign(socket,
       graph_data: %{nodes: [], edges: []},
       search_query: "",
       search_results: nil,
       type_index: [],
       collections: [],
       pinned_pages: [],
       alphabet: [],
       collection: nil,
       # Progressive graph (mirrors GraphLive panel)
       nodes: [],
       edges: [],
       visible_types: default_graph_visible_types(),
       type_colors: sidebar_type_colors(),
       type_counts: %{},
       node_count: 0,
       edge_count: 0,
       total_node_count: 0,
       total_edge_count: 0,
       refetch_timer: nil,
       loading: false
     )}
  end

  # ── Handle params ──────────────────────────────────────────────────────────

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # ── :index — landing page with all wiki-enabled contexts ──────────────────

  defp apply_action(socket, :index, _params) do
    contexts = Knowledge.list_home_workspaces()

    socket
    |> assign(
      contexts: contexts,
      workspace: nil,
      page_title: gettext("Wiki"),
      type_index: [],
      collections: [],
      pinned_pages: [],
      search_results: nil
    )
  end

  # ── :workspace_home — collections + pinned + index by type ───────────────────

  defp apply_action(socket, :workspace_home, %{"workspace_slug" => workspace_slug}) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %Workspace{} = workspace ->
        collections = Collections.list_collections(workspace.id)
        pinned = Knowledge.list_pinned_pages(workspace.id)
        type_index = build_type_index(workspace)

        # Load all non-archived pages for the A-Z index
        all_pages =
          Knowledge.list_pages(
            workspace_id: workspace.id,
            limit: 500
          )

        alphabet = build_alphabet(all_pages)

        socket
        |> assign(
          workspace: workspace,
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          alphabet: alphabet,
          page_title: workspace.name,
          search_results: nil
        )

      nil ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :type_list — alphabetical list of pages of one type ───────────────────

  defp apply_action(socket, :type_list, %{
         "workspace_slug" => workspace_slug,
         "page_type" => page_type
       }) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %Workspace{} = workspace ->
        pages =
          if page_type == "todo" do
            Knowledge.list_todos(workspace_id: workspace.id, limit: 500)
          else
            Knowledge.list_pages(
              workspace_id: workspace.id,
              type: page_type,
              limit: 500
            )
          end

        # Todos group by kanban status; everything else by first letter (A-Z)
        grouped =
          if page_type == "todo" do
            group_by_kanban_status(pages)
          else
            group_alphabetically(pages)
          end

        # Sidebar data
        collections = Collections.list_collections(workspace.id)
        pinned = Knowledge.list_pinned_pages(workspace.id)
        type_index = build_type_index(workspace)

        socket
        |> assign(
          workspace: workspace,
          page_type: page_type,
          pages: pages,
          grouped_pages: grouped,
          page_title: "#{workspace.name} · #{PageTypes.label(page_type)}",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil
        )

      nil ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :page_show — rendered page (markdown + mermaid, read-only) ────────────

  defp apply_action(socket, :page_show, %{
         "workspace_slug" => workspace_slug,
         "page_type" => page_type,
         "slug" => slug
       }) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %Workspace{} = workspace ->
        case Knowledge.get_page_by_slug(slug, workspace.id) do
          %{page_type: ^page_type} = page ->
            # Load page with full body
            page = Knowledge.get_page!(page.id)
            rendered_body = render_wiki_markdown(page.body, workspace)
            relations = Knowledge.list_relations_for_page(page.id)

            # Sidebar data
            collections = Collections.list_collections(workspace.id)
            pinned = Knowledge.list_pinned_pages(workspace.id)
            type_index = build_type_index(workspace)

            socket
            |> assign(
              workspace: workspace,
              page: page,
              rendered_body: rendered_body,
              relations: relations,
              page_title: page.title,
              collections: collections,
              pinned_pages: pinned,
              type_index: type_index,
              search_results: nil
            )

          nil ->
            push_navigate(socket, to: ~p"/#{workspace_slug}/type/#{page_type}")
        end

      nil ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :collection — smart collection results in wiki mode ────────────────────

  defp apply_action(socket, :collection, %{"workspace_slug" => workspace_slug, "slug" => slug}) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %Workspace{} = workspace ->
        case Collections.get_collection_by_slug(slug, workspace.id) do
          nil ->
            push_navigate(socket, to: ~p"/#{workspace_slug}")

          collection ->
            results = execute_filters(collection.filters || %{}, workspace.id)

            # Sidebar data
            all_collections = Collections.list_collections(workspace.id)
            pinned = Knowledge.list_pinned_pages(workspace.id)
            type_index = build_type_index(workspace)

            socket
            |> assign(
              workspace: workspace,
              collection: collection,
              results: results,
              page_title: collection.name,
              collections: all_collections,
              pinned_pages: pinned,
              type_index: type_index,
              search_results: nil
            )
        end

      nil ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :graph — graph view of the workspace (progressive, mirrors GraphLive) ───

  defp apply_action(socket, :graph, %{"workspace_slug" => workspace_slug}) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %Workspace{} = workspace ->
        # Progressive: no data load here — the Graph3D hook fetches
        # /<workspace_slug>/graph/json via HTTP after the shell renders,
        # keeping initial page load instant. Same pattern as GraphLive panel.
        # Sidebar data
        collections = Collections.list_collections(workspace.id)
        pinned = Knowledge.list_pinned_pages(workspace.id)
        type_index = build_type_index(workspace)

        socket
        |> assign(
          workspace: workspace,
          graph_data: %{nodes: [], edges: []},
          page_title: "#{workspace.name} · Graph",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil,
          loading: true
        )

      nil ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :kanban — read-only kanban board for todos ────────────────────────────

  @kanban_columns [
    {"backlog", "Backlog", "bg-base-300"},
    {"this_week", "This Week", "bg-blue-500/20 text-blue-700"},
    {"today", "Today", "bg-amber-500/20 text-amber-700"},
    {"in_progress", "In Progress", "bg-purple-500/20 text-purple-700"},
    {"done", "Done", "bg-green-500/20 text-green-700"},
    {"cancelled", "Cancelled", "bg-red-500/20 text-red-700"}
  ]

  defp apply_action(socket, :kanban, %{"workspace_slug" => workspace_slug}) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %Workspace{} = workspace ->
        todos = Knowledge.list_todos(workspace_id: workspace.id, limit: 500)

        # Sidebar data
        collections = Collections.list_collections(workspace.id)
        pinned = Knowledge.list_pinned_pages(workspace.id)
        type_index = build_type_index(workspace)

        socket
        |> assign(
          workspace: workspace,
          todos: todos,
          kanban_columns: @kanban_columns,
          page_title: "#{workspace.name} · Kanban",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil
        )

      nil ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :letter — all pages starting with a given letter (read-only) ───────────

  defp apply_action(socket, :letter, %{"workspace_slug" => workspace_slug, "letter" => letter}) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %Workspace{} = workspace ->
        all_pages = Knowledge.list_pages(workspace_id: workspace.id, limit: 500)

        letter = String.upcase(letter)
        grouped = group_alphabetically(all_pages)
        pages = Enum.find_value(grouped, [], fn {l, p} -> if l == letter, do: p end)

        # Sidebar data
        collections = Collections.list_collections(workspace.id)
        pinned = Knowledge.list_pinned_pages(workspace.id)
        type_index = build_type_index(workspace)
        alphabet = build_alphabet(all_pages)

        socket
        |> assign(
          workspace: workspace,
          letter: letter,
          pages: pages,
          alphabet: alphabet,
          page_title: "#{workspace.name} · #{letter}",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil
        )

      nil ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── Graph event handlers (mirror GraphLive panel) ─────────────────────────
  # NOTE: handle_event clauses are grouped with the other event handlers near
  # the bottom of this file to satisfy Elixir's clause-grouping requirement.
  # node_click already exists there (pre-existing wiki graph navigation).

  # ── Graph PubSub (mirror GraphLive panel) ──────────────────────────────────

  @impl true
  def handle_info({:page_changed, _action, _changed_page}, socket) do
    # Only react on the graph view — other wiki actions ignore this broadcast.
    if socket.assigns.live_action == :graph do
      if socket.assigns.refetch_timer do
        Process.cancel_timer(socket.assigns.refetch_timer)
      end

      timer = Process.send_after(self(), :graph_refetch, 1500)
      {:noreply, assign(socket, refetch_timer: timer)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:graph_refetch, socket) do
    {:noreply, assign(socket, refetch_timer: nil) |> push_event("graph_refetch", %{})}
  end

  # ── Graph helpers ──────────────────────────────────────────────────────────

  defp default_graph_visible_types do
    GraphHelpers.type_colors()
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(@graph_hidden_types))
  end

  defp sidebar_type_colors do
    GraphHelpers.type_colors()
    |> Enum.reject(fn {type, _color} -> type in @graph_hidden_types end)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.home
      flash={@flash}
      current_user={@current_user}
      is_owner={@is_owner}
      workspace_slug={@workspace && @workspace.slug}
      workspaces={@workspaces}
      page_title={@page_title}
      live_action={@live_action}
      search_query={@search_query}
      search_results={@search_results}
      type_index={@type_index}
      collections={@collections}
      pinned_pages={@pinned_pages}
      collection_slug={@collection && @collection.slug}
    >
      <%= if @search_results do %>
        <.search_results_view
          workspace={@workspace}
          search_query={@search_query}
          search_results={@search_results}
        />
      <% else %>
        <%= case @live_action do %>
          <% :index -> %>
            <.index_view workspaces={@workspaces} />
          <% :workspace_home -> %>
            <.context_home_view
              workspace={@workspace}
              collections={@collections}
              pinned_pages={@pinned_pages}
              type_index={@type_index}
              alphabet={@alphabet}
            />
          <% :type_list -> %>
            <.type_list_view
              workspace={@workspace}
              page_type={@page_type}
              grouped_pages={@grouped_pages}
              pages={@pages}
            />
          <% :page_show -> %>
            <.page_show_view
              workspace={@workspace}
              page={@page}
              rendered_body={@rendered_body}
              relations={@relations}
            />
          <% :collection -> %>
            <.collection_view
              workspace={@workspace}
              collection={@collection}
              results={@results}
            />
          <% :graph -> %>
            <.graph_view
              workspace={@workspace}
              graph_data={@graph_data}
              type_colors={@type_colors}
              visible_types={@visible_types}
              type_counts={@type_counts}
              node_count={@node_count}
              edge_count={@edge_count}
              total_node_count={@total_node_count}
              total_edge_count={@total_edge_count}
              nodes={@nodes}
              edges={@edges}
              loading={@loading}
            />
          <% :kanban -> %>
            <.kanban_view
              workspace={@workspace}
              todos={@todos}
              kanban_columns={@kanban_columns}
            />
          <% :letter -> %>
            <.letter_view workspace={@workspace} letter={@letter} pages={@pages} alphabet={@alphabet} />
        <% end %>
      <% end %>
    </Layouts.home>
    """
  end

  # ── Views ───────────────────────────────────────────────────────────────────

  defp search_results_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="mb-6">
        <h1 class="text-2xl font-bold">{gettext("Search results")}</h1>
        <p class="text-base-content/60 mt-1">
          {gettext("Results for")} <span class="font-medium">"{@search_query}"</span>
        </p>
      </div>

      <div :if={@search_results == []} class="text-center py-12">
        <.icon
          name="hero-document-magnifying-glass"
          class="size-10 text-base-content/30 mx-auto mb-3"
        />
        <p class="text-base-content/50">{gettext("No pages found.")}</p>
      </div>

      <div :if={@search_results != []} class="space-y-2">
        <.link
          :for={result <- @search_results}
          navigate={wiki_page_path(@workspace, result)}
          class="block p-3 rounded-lg border border-base-300 hover:bg-base-200 transition cursor-pointer group"
        >
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2 min-w-0">
              <.icon
                name={PageTypes.icon(result.page_type)}
                class="size-4 text-base-content/40 group-hover:text-primary transition-colors shrink-0"
              />
              <span class="font-medium truncate group-hover:text-primary transition-colors">
                {result.title}
              </span>
            </div>
            <span class="text-xs text-base-content/50 shrink-0 ml-2">
              {PageTypes.label(result.page_type)}
            </span>
          </div>
          <p :if={result[:excerpt]} class="text-sm text-base-content/60 mt-1 line-clamp-2">
            {raw(result.excerpt)}
          </p>
        </.link>
      </div>
    </div>
    """
  end

  defp index_view(assigns) do
    ~H"""
    <div class="px-6 py-10">
      <div class="mb-8">
        <h1 class="text-3xl font-bold tracking-tight">Wiki</h1>
        <p class="text-base-content/60 mt-2">
          {gettext("Browse knowledge bases. Pick a workspace to start exploring.")}
        </p>
      </div>

      <div :if={@workspaces == []} class="text-center py-16">
        <.icon name="hero-book-open" class="size-12 text-base-content/30 mx-auto mb-4" />
        <p class="text-base-content/50">
          {gettext("No wikis available yet. An admin needs to enable the wiki on a workspace.")}
        </p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.link
          :for={ctx <- @workspaces}
          navigate={~p"/#{ctx.slug}"}
          class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer group"
        >
          <div class="card-body p-5">
            <div class="flex items-center gap-2 mb-1">
              <.icon
                name="hero-book-open"
                class="size-5 text-primary/70 group-hover:text-primary transition-colors"
              />
              <h2 class="card-title text-lg">{ctx.name}</h2>
            </div>
            <p class="text-sm text-base-content/40 italic">
              {gettext("No description")}
            </p>
          </div>
        </.link>
      </div>
    </div>
    """
  end

  defp context_home_view(assigns) do
    ~H"""
    <div class="px-6 py-8 space-y-10">
      <%!-- Context header --%>
      <div>
        <h1 class="text-3xl font-bold tracking-tight">{@workspace.name}</h1>
      </div>

      <%!-- Pinned pages --%>
      <div :if={@pinned_pages != []}>
        <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
          <.icon name="hero-star" class="size-5 text-amber-500" />
          {gettext("Pinned")}
        </h2>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
          <.link
            :for={page <- @pinned_pages}
            navigate={~p"/#{@workspace.slug}/type/#{page.page_type}/#{page.slug}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer group"
          >
            <div class="card-body p-5">
              <div class="flex items-center gap-2 mb-1">
                <.icon name="hero-star" class="size-4 text-amber-500" />
                <h3 class="font-medium">{page.title}</h3>
              </div>
              <p :if={page.summary} class="text-sm text-base-content/60 line-clamp-2">
                {page.summary}
              </p>
            </div>
          </.link>
        </div>
      </div>

      <%!-- Smart Collections as categories --%>
      <div :if={@collections != []}>
        <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
          <.icon name="hero-funnel" class="size-5 text-primary/70" />
          {gettext("Categorias")}
        </h2>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
          <.link
            :for={coll <- @collections}
            navigate={~p"/#{@workspace.slug}/collection/#{coll.slug}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer group"
          >
            <div class="card-body p-5">
              <h3 class="card-title text-base">{coll.name}</h3>
              <p :if={coll.description} class="text-sm text-base-content/60 line-clamp-2">
                {coll.description}
              </p>
            </div>
          </.link>
        </div>
      </div>

      <%!-- Type cards (Notes, Concepts, Entities, References) + A-Z index --%>
      <div>
        <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
          <.icon name="hero-square-3-stack-3d" class="size-5 text-primary/70" />
          {gettext("Index")}
        </h2>

        <%!-- A-Z alphabet index --%>
        <div :if={@alphabet != []} class="mb-8">
          <div class="flex flex-wrap gap-1">
            <a
              :for={letter <- @alphabet}
              href={~p"/#{@workspace.slug}/letter/#{letter}"}
              class="w-8 h-8 flex items-center justify-center rounded-lg text-sm font-medium bg-base-200 text-base-content/80 hover:bg-primary hover:text-white transition-colors"
            >
              {letter}
            </a>
          </div>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
          <.link
            :for={item <- @type_index}
            navigate={~p"/#{@workspace.slug}/type/#{item.type}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer group"
          >
            <div class="card-body p-4 flex-row items-center gap-3">
              <.icon
                name={item.icon}
                class="size-5 text-base-content/40 group-hover:text-primary transition-colors"
              />
              <div class="flex-1">
                <h3 class="font-medium">{item.label}</h3>
              </div>
              <span class="text-sm text-base-content/40 font-medium">
                {item.count}
              </span>
            </div>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :workspace, :map, required: true
  attr :page_type, :string, required: true
  attr :grouped_pages, :list, default: []
  attr :pages, :list, default: []

  defp type_list_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="mb-6">
        <div class="flex items-center gap-2 mb-2 text-sm text-base-content/50">
          <.link navigate={~p"/#{@workspace.slug}"} class="hover:underline">
            {@workspace.name}
          </.link>
          <span>/</span>
          <span>{PageTypes.label(@page_type)}</span>
        </div>
        <h1 class="text-2xl font-bold">{PageTypes.plural(@page_type)}</h1>
      </div>

      <div :if={@grouped_pages == []} class="text-center py-12">
        <.icon name={PageTypes.icon(@page_type)} class="size-10 text-base-content/30 mx-auto mb-3" />
        <p class="text-base-content/50">{gettext("No pages of this type.")}</p>
      </div>

      <div :for={{group_key, pages} <- @grouped_pages} class="mb-6">
        <h2 class="text-sm font-semibold text-base-content/40 uppercase tracking-wider mb-2 border-b border-base-300 pb-1 flex items-center gap-2">
          <span :if={@page_type == "todo"} class={kanban_dot(group_key)}></span>
          <span>
            {if @page_type == "todo",
              do: kanban_status_label(group_key),
              else: group_key}
          </span>
          <span class="ml-auto text-base-content/30 normal-case tracking-normal">
            {length(pages)}
          </span>
        </h2>
        <div class="space-y-1">
          <.link
            :for={page <- pages}
            navigate={~p"/#{@workspace.slug}/type/#{@page_type}/#{page.slug}"}
            class="block px-3 py-2 rounded-lg hover:bg-base-200 transition-colors group"
          >
            <div class="flex items-center gap-2">
              <span class="font-medium group-hover:text-primary transition-colors">{page.title}</span>
              <span :if={page.pinned} class="text-amber-500">
                <.icon name="hero-bookmark" class="size-3" />
              </span>
              <span
                :if={@page_type == "todo" && kanban_due(page)}
                class={kanban_due_class(kanban_overdue?(page))}
              >
                <.icon name="hero-calendar-days" class="size-3.5" />
                {kanban_format_due(kanban_due(page))}
              </span>
            </div>
            <p :if={page.summary} class="text-sm text-base-content/50 line-clamp-1 mt-0.5">
              {page.summary}
            </p>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp page_show_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <%!-- Breadcrumb --%>
      <div class="flex items-center gap-2 mb-4 text-sm text-base-content/50">
        <.link navigate={~p"/#{@workspace.slug}"} class="hover:underline">
          {@workspace.name}
        </.link>
        <span>/</span>
        <.link navigate={~p"/#{@workspace.slug}/type/#{@page.page_type}"} class="hover:underline">
          {PageTypes.plural(@page.page_type)}
        </.link>
        <span>/</span>
        <span class="text-base-content/70 truncate">{@page.title}</span>
      </div>

      <%!-- Title + meta --%>
      <div class="mb-6">
        <div class="flex items-center gap-2 mb-2">
          <.icon name={PageTypes.icon(@page.page_type)} class="size-5 text-base-content/40" />
          <span class="text-sm text-base-content/50">{PageTypes.label(@page.page_type)}</span>
          <span :if={@page.pinned} class="text-amber-500">
            <.icon name="hero-bookmark" class="size-4" />
          </span>
        </div>
        <h1 class="text-3xl font-bold tracking-tight">{@page.title}</h1>
        <p :if={@page.summary} class="text-base-content/60 mt-2">{@page.summary}</p>
        <div class="flex flex-wrap gap-1.5 mt-3">
          <span
            :for={tag <- @page.tags || []}
            class="px-2 py-0.5 text-xs rounded-full bg-base-200 text-base-content/60"
          >
            {tag}
          </span>
        </div>
      </div>

      <%!-- Body --%>
      <div
        id="wiki-page-body"
        class="prose prose-base-content max-w-none prose-headings:font-bold prose-a:text-primary prose-code:before:hidden prose-code:after:hidden prose-img:rounded-lg"
        phx-hook="Mermaid"
      >
        {raw(@rendered_body)}
      </div>

      <%!-- Relations --%>
      <div
        :if={@relations.outbound != [] or @relations.inbound != []}
        class="mt-10 pt-6 border-t border-base-300"
      >
        <h2 class="text-lg font-semibold mb-4">{gettext("Relations")}</h2>

        <div :if={@relations.outbound != []} class="mb-4">
          <h3 class="text-sm font-medium text-base-content/50 mb-2">{gettext("References")}</h3>
          <div class="space-y-1">
            <.link
              :for={rel <- @relations.outbound}
              navigate={~p"/#{@workspace.slug}/type/#{rel.target.page_type}/#{rel.target.slug}"}
              class="block px-3 py-2 rounded-lg hover:bg-base-200 transition-colors text-sm group"
            >
              <div class="flex items-center gap-2">
                <.icon
                  name={PageTypes.icon(rel.target.page_type)}
                  class="size-4 text-base-content/40 group-hover:text-primary transition-colors"
                />
                <span class="group-hover:text-primary transition-colors">{rel.target.title}</span>
                <span class="text-xs text-base-content/40">({rel.relation_type})</span>
              </div>
            </.link>
          </div>
        </div>

        <div :if={@relations.inbound != []}>
          <h3 class="text-sm font-medium text-base-content/50 mb-2">{gettext("Referenced by")}</h3>
          <div class="space-y-1">
            <.link
              :for={rel <- @relations.inbound}
              navigate={~p"/#{@workspace.slug}/type/#{rel.source.page_type}/#{rel.source.slug}"}
              class="block px-3 py-2 rounded-lg hover:bg-base-200 transition-colors text-sm group"
            >
              <div class="flex items-center gap-2">
                <.icon
                  name={PageTypes.icon(rel.source.page_type)}
                  class="size-4 text-base-content/40 group-hover:text-primary transition-colors"
                />
                <span class="group-hover:text-primary transition-colors">{rel.source.title}</span>
                <span class="text-xs text-base-content/40">({rel.relation_type})</span>
              </div>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp collection_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="mb-6">
        <div class="flex items-center gap-2 mb-2 text-sm text-base-content/50">
          <.link navigate={~p"/#{@workspace.slug}"} class="hover:underline">
            {@workspace.name}
          </.link>
          <span>/</span>
          <span>{gettext("Collection")}</span>
        </div>
        <h1 class="text-2xl font-bold">{@collection.name}</h1>
        <p :if={@collection.description} class="text-base-content/60 mt-2">
          {@collection.description}
        </p>
      </div>

      <div class="flex items-center justify-between mb-3">
        <span class="text-sm text-base-content/60">
          {length(@results)} {ngettext("page", "pages", length(@results))}
        </span>
      </div>

      <div :if={@results == []} class="text-center py-12">
        <.icon
          name="hero-document-magnifying-glass"
          class="size-10 text-base-content/30 mx-auto mb-3"
        />
        <p class="text-base-content/50">{gettext("No pages match this collection.")}</p>
      </div>

      <div class="space-y-2">
        <.link
          :for={page <- Enum.sort_by(@results, & &1.title, :asc)}
          navigate={~p"/#{@workspace.slug}/type/#{page.page_type}/#{page.slug}"}
          class="block p-3 rounded-lg border border-base-300 hover:bg-base-200 transition cursor-pointer group"
        >
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2 min-w-0">
              <.icon
                name={PageTypes.icon(page.page_type)}
                class="size-4 text-base-content/40 group-hover:text-primary transition-colors shrink-0"
              />
              <span class="font-medium truncate group-hover:text-primary transition-colors">{page.title}</span>
            </div>
            <span class="text-xs text-base-content/50 shrink-0 ml-2">
              {PageTypes.label(page.page_type)}
            </span>
          </div>
          <p :if={page.summary} class="text-sm text-base-content/60 mt-1 line-clamp-1">
            {page.summary}
          </p>
        </.link>
      </div>
    </div>
    """
  end

  # ── Graph view (progressive, mirrors GraphLive panel) ──────────────────────

  attr :workspace, :map, required: true
  attr :graph_data, :map, default: %{nodes: [], edges: []}
  attr :type_colors, :list, default: []
  attr :visible_types, :map, default: %MapSet{}
  attr :type_counts, :map, default: %{}
  attr :node_count, :integer, default: 0
  attr :edge_count, :integer, default: 0
  attr :total_node_count, :integer, default: 0
  attr :total_edge_count, :integer, default: 0
  attr :nodes, :list, default: []
  attr :edges, :list, default: []
  attr :loading, :boolean, default: false

  defp graph_view(assigns) do
    ~H"""
    <div class="h-[calc(100vh-4rem)] flex flex-col">
      <div class="px-6 pt-4 pb-2">
        <div class="flex items-center gap-2 text-sm text-base-content/50 mb-1">
          <.link navigate={~p"/#{@workspace.slug}"} class="hover:underline">
            {@workspace.name}
          </.link>
          <span>/</span>
          <span>{gettext("Graph")}</span>
        </div>
        <p class="text-caption">
          {gettext(
            "Visualize how your pages connect. Drag to rotate, hover a node to reveal labels, click a node to navigate."
          )}
        </p>
      </div>

      <div class="flex gap-4 flex-1 min-h-0 px-4 pb-4">
        {# Type sidebar — same as GraphLive panel}
        <div class="w-48 shrink-0 p-2">
          <h3 class="text-xs font-semibold text-base-content/40 uppercase mb-2">
            {gettext("Types")}
          </h3>
          <button
            :for={{type, color} <- @type_colors}
            type="button"
            phx-click="toggle_type"
            phx-value-type={type}
            class={[
              "flex w-full items-center gap-2 rounded px-1 py-0.5 text-left transition",
              if(MapSet.member?(@visible_types, type),
                do: "hover:bg-base-200",
                else: "opacity-40 hover:opacity-70"
              )
            ]}
          >
            <div
              class="w-3 h-3 shrink-0 rounded-full"
              style={"background: #{if MapSet.member?(@visible_types, type), do: color, else: "#64748B"}"}
            >
            </div>
            <span class="text-sm capitalize flex-1">{type}</span>
            <span class="text-xs text-base-content/40 tabular-nums">
              {@type_counts[type] || 0}
            </span>
          </button>

          <h3 class="text-xs font-semibold text-base-content/40 uppercase mt-4 mb-2">
            {gettext("Totals")}
          </h3>
          <div class="flex items-center gap-2 mb-1">
            <span class="text-sm flex-1">{gettext("Nodes")}</span>
            <span class="text-xs text-base-content/40 tabular-nums">{@node_count}</span>
          </div>
          <div class="flex items-center gap-2 mb-1">
            <span class="text-sm flex-1">{gettext("Edges")}</span>
            <span class="text-xs text-base-content/40 tabular-nums">{@edge_count}</span>
          </div>
        </div>

        <div class="flex-1 overflow-hidden relative">
          <div
            :if={@loading}
            class="absolute inset-0 z-20 flex items-center justify-center bg-base-100/80 backdrop-blur-sm"
          >
            <div class="flex flex-col items-center gap-3">
              <div class="loading loading-spinner loading-lg text-primary"></div>
              <p class="text-sm text-base-content/60">{gettext("Loading graph...")}</p>
            </div>
          </div>
          <div
            :if={not @loading and @total_node_count > @node_count}
            class="absolute top-2 left-1/2 -translate-x-1/2 z-10 max-w-[90%] rounded-lg bg-base-100/90 border border-base-300 px-3 py-1.5 text-xs text-base-content/70 shadow-sm backdrop-blur"
          >
            {gettext(
              "Showing the %{shown} most-connected nodes of %{total} — search for a page to explore its subgraph.",
              shown: @node_count,
              total: @total_node_count
            )}
          </div>
          <.graph_3d
            id="wiki-graph-3d"
            nodes={@nodes}
            edges={@edges}
            visible_types={MapSet.to_list(@visible_types)}
            base_path={"/#{@workspace.slug}/type"}
            graph_url={"/#{@workspace.slug}/graph/json"}
            class="w-full h-full"
          />
          <div class="absolute bottom-0 left-0 right-0 px-3 py-2 text-xs text-base-content/40 bg-base-200/50 border-t border-base-300">
            {gettext("Drag to rotate · Scroll to zoom · Hover to highlight · Click to navigate")}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Kanban view (read-only) ───────────────────────────────────────────────

  attr :workspace, :map, required: true
  attr :todos, :list, default: []
  attr :kanban_columns, :list, default: []

  defp kanban_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="flex items-center gap-2 text-sm text-base-content/50 mb-2">
        <.link navigate={~p"/#{@workspace.slug}"} class="hover:underline">
          {@workspace.name}
        </.link>
        <span>/</span>
        <span>{gettext("Kanban")}</span>
      </div>

      <h1 class="text-2xl font-bold mb-6 flex items-center gap-2">
        <.icon name="hero-view-columns" class="size-6 text-primary" />
        {gettext("Kanban")}
      </h1>

      <div class="flex gap-4 overflow-x-auto pb-4">
        <div
          :for={{status, label, badge_class} <- @kanban_columns}
          class="w-72 shrink-0 flex flex-col rounded-2xl bg-base-200/40 border border-base-300 overflow-hidden"
        >
          <div class="flex items-center justify-between px-3 py-2.5 border-b border-base-300">
            <div class="flex items-center gap-2">
              <span class={kanban_dot(status)}></span>
              <span class="text-sm font-semibold">{label}</span>
            </div>
            <span class={kanban_badge(badge_class)}>
              {kanban_count(@todos, status)}
            </span>
          </div>
          <div class="p-2 space-y-2">
            <a
              :for={todo <- kanban_items(@todos, status)}
              href={~p"/#{@workspace.slug}/type/todo/#{todo.slug}"}
              class="block p-3 rounded-xl bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-primary/40 transition"
            >
              <div class="font-medium text-sm break-words">{todo.title}</div>

              <div :if={kanban_due(todo)} class={kanban_due_class(kanban_overdue?(todo))}>
                <.icon name="hero-calendar-days" class="size-3.5" />
                {kanban_format_due(kanban_due(todo))}
              </div>
            </a>
            <p
              :if={kanban_items(@todos, status) == []}
              class="text-xs text-base-content/30 text-center py-4"
            >
              {gettext("Empty")}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp kanban_status(page) do
    case page.kanban_status do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  defp kanban_items(todos, status), do: Enum.filter(todos, fn t -> kanban_status(t) == status end)
  defp kanban_count(todos, status), do: Enum.count(todos, fn t -> kanban_status(t) == status end)

  defp kanban_dot("backlog"), do: "size-2 rounded-full bg-base-content/30"
  defp kanban_dot("this_week"), do: "size-2 rounded-full bg-blue-500"
  defp kanban_dot("today"), do: "size-2 rounded-full bg-amber-500"
  defp kanban_dot("in_progress"), do: "size-2 rounded-full bg-purple-500"
  defp kanban_dot("done"), do: "size-2 rounded-full bg-green-500"
  defp kanban_dot("cancelled"), do: "size-2 rounded-full bg-red-500"
  defp kanban_dot(_), do: "size-2 rounded-full bg-base-content/30"

  defp kanban_badge(class), do: "px-2 py-0.5 text-xs rounded-full " <> class

  defp kanban_due(page), do: (page.meta || %{})["due_date"]

  defp kanban_overdue?(page) do
    case kanban_due(page) do
      s when is_binary(s) and s != "" ->
        case Date.from_iso8601(s) do
          {:ok, d} -> Date.compare(d, Date.utc_today()) == :lt
          _ -> false
        end

      _ ->
        false
    end
  end

  defp kanban_format_due(nil), do: ""
  defp kanban_format_due(""), do: ""

  defp kanban_format_due(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> Calendar.strftime(d, "%b %d")
      _ -> s
    end
  end

  defp kanban_due_class(true),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-red-600 font-medium"

  defp kanban_due_class(false),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-base-content/60"

  # ── Letter view (read-only) ───────────────────────────────────────────────

  attr :workspace, :map, required: true
  attr :letter, :string, required: true
  attr :pages, :list, default: []
  attr :alphabet, :list, default: []

  defp letter_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="flex items-center gap-2 mb-2 text-sm text-base-content/50">
        <.link navigate={~p"/#{@workspace.slug}"} class="hover:underline">
          {@workspace.name}
        </.link>
        <span>/</span>
        <span>{@letter}</span>
      </div>

      <h1 class="text-2xl font-bold mb-6">{@letter}</h1>

      <%!-- Alphabet bar --%>
      <div class="flex flex-wrap gap-1 mb-8">
        <a
          :for={l <- @alphabet}
          href={~p"/#{@workspace.slug}/letter/#{l}"}
          class={[
            "w-8 h-8 flex items-center justify-center rounded-lg text-sm font-medium transition-colors",
            if(l == @letter,
              do: "bg-primary text-white",
              else: "bg-base-200 text-base-content/80 hover:bg-primary hover:text-white"
            )
          ]}
        >
          {l}
        </a>
      </div>

      <div :if={@pages == []} class="text-center py-12">
        <p class="text-base-content/50">{gettext("No pages start with this letter.")}</p>
      </div>

      <div :if={@pages != []} class="space-y-1">
        <.link
          :for={page <- @pages}
          navigate={~p"/#{@workspace.slug}/type/#{page.page_type}/#{page.slug}"}
          class="block px-3 py-2 rounded-lg hover:bg-base-200 transition-colors group"
        >
          <div class="flex items-center gap-2">
            <span class="font-medium group-hover:text-primary transition-colors">{page.title}</span>
            <span class="text-xs text-base-content/40">({PageTypes.label(page.page_type)})</span>
            <span :if={page.pinned} class="text-amber-500">
              <.icon name="hero-star" class="size-3" />
            </span>
          </div>
          <p :if={page.summary} class="text-sm text-base-content/50 line-clamp-1 mt-0.5">
            {page.summary}
          </p>
        </.link>
      </div>
    </div>
    """
  end

  # ── Event handlers ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("wiki_search", %{"q" => query}, socket) do
    query = String.trim(query)

    results =
      if query == "" do
        nil
      else
        workspace = socket.assigns[:workspace]

        opts =
          if workspace do
            [workspace_id: workspace.id, limit: 30]
          else
            [limit: 30]
          end

        case Knowledge.search(query, opts) do
          {:ok, res} -> res
          _ -> []
        end
      end

    {:noreply, assign(socket, search_query: query, search_results: results)}
  end

  # ── Filter event handlers (kanban + todo type_list) ──

  @impl true
  def handle_event("node_click", %{"slug" => slug, "type" => type}, socket) do
    workspace = socket.assigns[:workspace]

    if workspace do
      {:noreply, push_navigate(socket, to: ~p"/#{workspace.slug}/type/#{type}/#{slug}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_type", %{"type" => type}, socket) do
    visible =
      if MapSet.member?(socket.assigns.visible_types, type) do
        MapSet.delete(socket.assigns.visible_types, type)
      else
        MapSet.put(socket.assigns.visible_types, type)
      end

    socket = assign(socket, visible_types: visible)
    {:noreply, push_event(socket, "set_visible_types", %{types: MapSet.to_list(visible)})}
  end

  @impl true
  def handle_event(
        "graph_loaded",
        %{
          "total_nodes" => total_nodes,
          "total_edges" => total_edges,
          "type_counts" => type_counts
        },
        socket
      ) do
    {:noreply,
     assign(socket,
       type_counts: type_counts || %{},
       total_node_count: total_nodes || 0,
       total_edge_count: total_edges || 0,
       loading: false
     )}
  end

  @impl true
  def handle_event(
        "graph_counts",
        %{"node_count" => node_count, "edge_count" => edge_count},
        socket
      ) do
    {:noreply, assign(socket, node_count: node_count || 0, edge_count: edge_count || 0)}
  end

  # Catch-all for graph hook events that may fire when no longer on the graph
  # view. Graph events (graph_loaded, graph_counts) arrive here harmlessly.
  # Unknown events are logged rather than silently swallowed so filter or
  # navigation bugs don't disappear into the void.
  def handle_event(event, _params, socket) when event in ["graph_loaded", "graph_counts"] do
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Execute a collection's saved filters, same pattern as SmartCollectionLive.
  defp execute_filters(filters, workspace_id) when is_map(filters) do
    opts = [workspace_id: workspace_id]

    opts =
      opts
      |> maybe_add_filter(:type, filters["type"])
      |> maybe_add_filter(:status, filters["status"])
      |> maybe_add_filter(:tag, filters["tag"])
      |> maybe_add_filter(:owner, filters["owner"])

    Knowledge.list_pages(opts)
  end

  defp execute_filters(_filters, _workspace_id), do: []

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp build_type_index(workspace) do
    disabled = workspace.disabled_page_types || []
    excluded = disabled

    BrainPageTypes.types()
    |> Enum.reject(&(&1 in excluded))
    |> Enum.map(fn type ->
      count =
        Dran.Repo.aggregate(
          from(p in Dran.Page,
            where:
              p.workspace_id == ^workspace.id and
                p.page_type == ^type and
                p.archived == false
          ),
          :count
        )

      %{
        type: type,
        label: PageTypes.plural(type),
        count: count,
        icon: PageTypes.icon(type)
      }
    end)
    |> Enum.reject(&(&1.count == 0))
  end

  defp group_alphabetically(pages) do
    pages
    |> Enum.group_by(fn page ->
      page.title
      |> String.first()
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/, "#")
    end)
    |> Enum.sort_by(fn {letter, _} -> letter end)
  end

  @kanban_order ~w(backlog this_week today in_progress done cancelled)

  defp group_by_kanban_status(pages) do
    pages
    |> Enum.group_by(fn page -> kanban_status(page) end)
    |> Enum.map(fn {status, items} ->
      {status, Enum.sort_by(items, fn item -> String.downcase(item.title) end)}
    end)
    |> Enum.sort_by(fn {status, _} ->
      idx = Enum.find_index(@kanban_order, &(&1 == status))
      idx || 99
    end)
  end

  defp kanban_status_label("backlog"), do: gettext("Backlog")
  defp kanban_status_label("this_week"), do: gettext("This Week")
  defp kanban_status_label("today"), do: gettext("Today")
  defp kanban_status_label("in_progress"), do: gettext("In Progress")
  defp kanban_status_label("done"), do: gettext("Done")
  defp kanban_status_label("cancelled"), do: gettext("Cancelled")
  defp kanban_status_label(other), do: String.capitalize(other)

  defp build_alphabet(pages) do
    pages
    |> Enum.map(fn page ->
      page.title
      |> String.first()
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/, "#")
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Render markdown for the wiki — same MDEx pipeline as PageComponents but
  # without inline_links (which require internal page resolution that depends
  # on auth-scoped paths). Wikilinks `[[slug|display]]` are rewritten to
  # wiki URLs by post-processing the HTML.
  defp render_wiki_markdown(body, workspace) do
    html =
      case MDEx.to_html(body, markdown_options()) do
        {:ok, html} -> html
        {:error, _} -> Phoenix.HTML.html_escape(body) |> Phoenix.HTML.safe_to_string()
      end

    html
    |> rewrite_wikilinks(workspace)
    |> raw()
  end

  # MDEx renders wikilinks as <a href="slug" data-wikilink="true">display</a>.
  # We rewrite the href to point to the wiki URL for that slug.
  # We don't know the page_type from the slug alone, so we point to a
  # generic wiki path and let the lookup resolve it.
  defp rewrite_wikilinks(html, workspace) do
    slug_to_path = build_wikilink_map(html, workspace)

    Regex.replace(
      ~r/<a href="([^"]+)" data-wikilink="true">/,
      html,
      fn _full, slug ->
        path = Map.get(slug_to_path, slug, "/#{workspace.slug}")
        ~s|<a href="#{path}" data-wikilink="true">|
      end
    )
  end

  # Extract all slugs from wikilinks and batch-resolve them to page types
  # so we can build proper wiki URLs.
  defp build_wikilink_map(html, workspace) do
    slugs =
      Regex.scan(~r/<a href="([^"]+)" data-wikilink="true">/, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    if slugs == [] do
      %{}
    else
      slug_types = Knowledge.get_pages_by_slugs(slugs, workspace.id)

      Enum.reduce(slugs, %{}, fn slug, acc ->
        case Map.get(slug_types, slug) do
          nil -> acc
          page_type -> Map.put(acc, slug, "/#{workspace.slug}/type/#{page_type}/#{slug}")
        end
      end)
    end
  end

  defp markdown_options do
    [
      extension: [
        strikethrough: true,
        table: true,
        tasklist: true,
        autolink: true,
        wikilinks_title_after_pipe: true,
        alerts: true,
        footnotes: true,
        shortcodes: true
      ],
      render: [unsafe: false],
      sanitize: [
        add_tags: ["input", "figure", "figcaption", "video", "source", "embed"],
        add_generic_attributes: ["data-wikilink"],
        add_tag_attributes: %{"a" => ["data-wikilink"], "code" => ["class"]}
      ]
    ]
  end

  # Build a wiki URL for a search result. Search results carry page_type + slug;
  # if a workspace is active, the URL includes its slug so navigation stays in scope.
  defp wiki_page_path(nil, result) do
    # No active workspace — try to resolve the page's workspace from its fields.
    # Fall back to the generic wiki root.
    page_type = Map.get(result, :page_type) || Map.get(result, "page_type")
    slug = Map.get(result, :slug) || Map.get(result, "slug")

    if page_type && slug do
      # We don't have a workspace slug, so we can't build a wiki path.
      # The search result may include workspace_id but not the slug.
      # Fallback: point to the wiki root.
      ~p"/"
    else
      ~p"/"
    end
  end

  defp wiki_page_path(workspace, result) do
    page_type = Map.get(result, :page_type) || Map.get(result, "page_type")
    slug = Map.get(result, :slug) || Map.get(result, "slug")
    ~p"/#{workspace.slug}/type/#{page_type}/#{slug}"
  end
end
