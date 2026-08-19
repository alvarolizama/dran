defmodule DranWeb.WikiLive do
  @moduledoc """
  Read-only wiki browser for contexts with `wiki_enabled: true`.

  Six actions:
  - `:index`         — landing: list of wiki-enabled contexts
  - `:context_home`  — home of a context: collections + pinned + index by type
  - `:type_list`      — alphabetical list of pages of one type
  - `:page_show`     — rendered page (markdown + mermaid, read-only)
  - `:collection`     — smart collection results in wiki mode
  - `:graph`          — graph of the context's pages

  Authenticated but accessible to ALL logged-in users, including wiki-only
  users (no contexts assigned). No edit/delete/create controls — pure browse.
  """

  use DranWeb, :live_view

  import Ecto.Query
  import Phoenix.HTML, only: [raw: 1]

  alias Dran.Brain
  alias Dran.Brain.PageTypes, as: BrainPageTypes
  alias Dran.SmartCollection
  alias DranWeb.GraphHelpers
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  # Page types excluded from the wiki index — operational or second-citizen.
  @wiki_hidden_types ~w(todo plan report query)

  # Types hidden from the global 3D graph — same list the panel uses via
  # GraphCache. The wiki graph must match so both views render the same set.
  @graph_hidden_types Dran.Brain.PageTypes.hidden_from_graph()

  # ── Mount ─────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    # The wiki is browsable by ALL logged-in users (including wiki-only
    # auto-registered accounts with no contexts assigned). The sidebar
    # context selector must therefore list every wiki-enabled context, not
    # just the current user's assigned contexts. `assign_to_socket` sets
    # `contexts` to the user's accessible contexts, so override it here.
    socket = assign(socket, contexts: Brain.list_wiki_contexts())

    # Subscribe to PubSub for the context so the graph view can debounce
    # page_changed broadcasts and tell the hook to re-fetch — same pattern
    # as GraphLive (panel).
    if context do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
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
       loading: false,
       # Todo filters (kanban + type_list :todo)
       filter_project: "all",
       filter_goal: "all",
       filter_plan: "all",
       filter_project_options: [],
       filter_goal_options: [],
       filter_plan_options: [],
       slug_maps: %{},
       project_enabled: true,
       goal_enabled: true,
       plan_enabled: true,
       filtered_count: nil
     )}
  end

  # ── Handle params ──────────────────────────────────────────────────────────

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # ── :index — landing page with all wiki-enabled contexts ──────────────────

  defp apply_action(socket, :index, _params) do
    contexts = Brain.list_wiki_contexts()

    socket
    |> assign(
      contexts: contexts,
      context: nil,
      page_title: gettext("Wiki"),
      type_index: [],
      collections: [],
      pinned_pages: [],
      search_results: nil
    )
  end

  # ── :context_home — collections + pinned + index by type ───────────────────

  defp apply_action(socket, :context_home, %{"context_slug" => context_slug}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        collections = SmartCollection.list_all(context.id)
        pinned = Brain.list_pinned_pages(context.id)
        type_index = build_type_index(context)

        # Load all non-archived pages for the A-Z index
        all_pages =
          Brain.list_pages(
            context_id: context.id,
            limit: 500
          )

        alphabet = build_alphabet(all_pages)

        socket
        |> assign(
          context: context,
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          alphabet: alphabet,
          page_title: context.name,
          search_results: nil
        )

      _ ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :type_list — alphabetical list of pages of one type ───────────────────

  defp apply_action(socket, :type_list, %{
         "context_slug" => context_slug,
         "page_type" => page_type
       }) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        pages =
          Brain.list_pages(
            context_id: context.id,
            type: page_type,
            limit: 500
          )

        # Todos group by kanban status; everything else by first letter (A-Z)
        grouped =
          if page_type == "todo" do
            group_by_kanban_status(pages)
          else
            group_alphabetically(pages)
          end

        # Sidebar data
        collections = SmartCollection.list_all(context.id)
        pinned = Brain.list_pinned_pages(context.id)
        type_index = build_type_index(context)

        # When page_type == "todo", load filter options + enabled flags so the
        # filter bar can render (mirrors KanbanLive panel pattern).
        {filter_opts, enabled_flags} =
          if page_type == "todo" do
            load_todo_filter_data(context)
          else
            {%{}, %{project_enabled: true, goal_enabled: true, plan_enabled: true}}
          end

        socket
        |> assign(
          context: context,
          page_type: page_type,
          pages: pages,
          grouped_pages: grouped,
          page_title: "#{context.name} · #{PageTypes.label(page_type)}",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil
        )
        |> assign(
          filter_project: "all",
          filter_goal: "all",
          filter_plan: "all",
          filter_project_options: filter_opts[:project_options] || [],
          filter_goal_options: filter_opts[:goal_options] || [],
          filter_plan_options: filter_opts[:plan_options] || [],
          slug_maps: filter_opts[:slug_maps] || %{},
          project_enabled: enabled_flags[:project_enabled],
          goal_enabled: enabled_flags[:goal_enabled],
          plan_enabled: enabled_flags[:plan_enabled],
          filtered_count: nil
        )

      _ ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :page_show — rendered page (markdown + mermaid, read-only) ────────────

  defp apply_action(socket, :page_show, %{
         "context_slug" => context_slug,
         "page_type" => page_type,
         "slug" => slug
       }) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        case Brain.get_page_by_slug(slug, context.id) do
          %{page_type: ^page_type} = page ->
            # Load page with full body
            page = Brain.get_page!(page.id)
            rendered_body = render_wiki_markdown(page.body, context)
            relations = Brain.list_relations_for_page(page.id)

            # Sidebar data
            collections = SmartCollection.list_all(context.id)
            pinned = Brain.list_pinned_pages(context.id)
            type_index = build_type_index(context)

            socket
            |> assign(
              context: context,
              page: page,
              rendered_body: rendered_body,
              relations: relations,
              page_title: page.title,
              collections: collections,
              pinned_pages: pinned,
              type_index: type_index,
              search_results: nil
            )

          _ ->
            push_navigate(socket, to: ~p"/#{context_slug}/type/#{page_type}")
        end

      _ ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :collection — smart collection results in wiki mode ────────────────────

  defp apply_action(socket, :collection, %{"context_slug" => context_slug, "slug" => slug}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        case SmartCollection.get_by_slug(slug, context.id) do
          nil ->
            push_navigate(socket, to: ~p"/#{context_slug}")

          collection ->
            query = Map.get(collection.meta || %{}, "query", %{})
            results = SmartCollection.execute(query, context.id)

            # Sidebar data
            all_collections = SmartCollection.list_all(context.id)
            pinned = Brain.list_pinned_pages(context.id)
            type_index = build_type_index(context)

            socket
            |> assign(
              context: context,
              collection: collection,
              results: results,
              page_title: collection.title,
              collections: all_collections,
              pinned_pages: pinned,
              type_index: type_index,
              search_results: nil
            )
        end

      _ ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :graph — graph view of the context (progressive, mirrors GraphLive) ───

  defp apply_action(socket, :graph, %{"context_slug" => context_slug}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        # Progressive: no data load here — the Graph3D hook fetches
        # /<context_slug>/graph/json via HTTP after the shell renders,
        # keeping initial page load instant. Same pattern as GraphLive panel.
        # Sidebar data
        collections = SmartCollection.list_all(context.id)
        pinned = Brain.list_pinned_pages(context.id)
        type_index = build_type_index(context)

        socket
        |> assign(
          context: context,
          graph_data: %{nodes: [], edges: []},
          page_title: "#{context.name} · Graph",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil,
          loading: true
        )

      _ ->
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

  defp apply_action(socket, :kanban, %{"context_slug" => context_slug}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        todos =
          Brain.list_pages(
            context_id: context.id,
            type: "todo",
            include_body: false,
            limit: 500
          )

        # Sidebar data
        collections = SmartCollection.list_all(context.id)
        pinned = Brain.list_pinned_pages(context.id)
        type_index = build_type_index(context)

        {filter_opts, enabled_flags} = load_todo_filter_data(context)

        socket
        |> assign(
          context: context,
          todos: todos,
          kanban_columns: @kanban_columns,
          page_title: "#{context.name} · Kanban",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil
        )
        |> assign(
          filter_project: "all",
          filter_goal: "all",
          filter_plan: "all",
          filter_project_options: filter_opts[:project_options] || [],
          filter_goal_options: filter_opts[:goal_options] || [],
          filter_plan_options: filter_opts[:plan_options] || [],
          slug_maps: filter_opts[:slug_maps] || %{},
          project_enabled: enabled_flags[:project_enabled],
          goal_enabled: enabled_flags[:goal_enabled],
          plan_enabled: enabled_flags[:plan_enabled],
          filtered_count: nil
        )

      _ ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :letter — all pages starting with a given letter (read-only) ───────────

  defp apply_action(socket, :letter, %{"context_slug" => context_slug, "letter" => letter}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        all_pages = Brain.list_pages(context_id: context.id, limit: 500)

        letter = String.upcase(letter)
        grouped = group_alphabetically(all_pages)
        pages = Enum.find_value(grouped, [], fn {l, p} -> if l == letter, do: p end)

        # Sidebar data
        collections = SmartCollection.list_all(context.id)
        pinned = Brain.list_pinned_pages(context.id)
        type_index = build_type_index(context)
        alphabet = build_alphabet(all_pages)

        socket
        |> assign(
          context: context,
          letter: letter,
          pages: pages,
          alphabet: alphabet,
          page_title: "#{context.name} · #{letter}",
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          search_results: nil
        )

      _ ->
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
    <Layouts.wiki
      flash={@flash}
      current_user={@current_user}
      is_admin={@is_admin}
      is_editor={@is_editor}
      context_slug={@context && @context.slug}
      contexts={@contexts}
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
          context={@context}
          search_query={@search_query}
          search_results={@search_results}
        />
      <% else %>
        <%= case @live_action do %>
          <% :index -> %>
            <.index_view contexts={@contexts} />
          <% :context_home -> %>
            <.context_home_view
              context={@context}
              collections={@collections}
              pinned_pages={@pinned_pages}
              type_index={@type_index}
              alphabet={@alphabet}
            />
          <% :type_list -> %>
            <.type_list_view
              context={@context}
              page_type={@page_type}
              grouped_pages={@grouped_pages}
              filter_project={@filter_project}
              filter_goal={@filter_goal}
              filter_plan={@filter_plan}
              filter_project_options={@filter_project_options}
              filter_goal_options={@filter_goal_options}
              filter_plan_options={@filter_plan_options}
              project_enabled={@project_enabled}
              goal_enabled={@goal_enabled}
              plan_enabled={@plan_enabled}
              pages={@pages}
              slug_maps={@slug_maps}
            />
          <% :page_show -> %>
            <.page_show_view
              context={@context}
              page={@page}
              rendered_body={@rendered_body}
              relations={@relations}
            />
          <% :collection -> %>
            <.collection_view
              context={@context}
              collection={@collection}
              results={@results}
            />
          <% :graph -> %>
            <.graph_view
              context={@context}
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
              context={@context}
              todos={@todos}
              kanban_columns={@kanban_columns}
              filter_project={@filter_project}
              filter_goal={@filter_goal}
              filter_plan={@filter_plan}
              filter_project_options={@filter_project_options}
              filter_goal_options={@filter_goal_options}
              filter_plan_options={@filter_plan_options}
              project_enabled={@project_enabled}
              goal_enabled={@goal_enabled}
              plan_enabled={@plan_enabled}
              filtered_count={@filtered_count}
              slug_maps={@slug_maps}
            />
          <% :letter -> %>
            <.letter_view context={@context} letter={@letter} pages={@pages} alphabet={@alphabet} />
        <% end %>
      <% end %>
    </Layouts.wiki>
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
          navigate={wiki_page_path(@context, result)}
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
          {gettext("Browse knowledge bases. Pick a context to start exploring.")}
        </p>
      </div>

      <div :if={@contexts == []} class="text-center py-16">
        <.icon name="hero-book-open" class="size-12 text-base-content/30 mx-auto mb-4" />
        <p class="text-base-content/50">
          {gettext("No wikis available yet. An admin needs to enable the wiki on a context.")}
        </p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.link
          :for={ctx <- @contexts}
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
            <p :if={ctx.wiki_description} class="text-sm text-base-content/60 line-clamp-2">
              {ctx.wiki_description}
            </p>
            <p :if={!ctx.wiki_description} class="text-sm text-base-content/40 italic">
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
        <h1 class="text-3xl font-bold tracking-tight">{@context.name}</h1>
        <p :if={@context.wiki_description} class="text-base-content/60 mt-2">
          {@context.wiki_description}
        </p>
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
            navigate={~p"/#{@context.slug}/type/#{page.page_type}/#{page.slug}"}
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
            navigate={~p"/#{@context.slug}/collection/#{coll.slug}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer group"
          >
            <div class="card-body p-5">
              <h3 class="card-title text-base">{coll.title}</h3>
              <p :if={coll.summary} class="text-sm text-base-content/60 line-clamp-2">
                {coll.summary}
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
              href={~p"/#{@context.slug}/letter/#{letter}"}
              class="w-8 h-8 flex items-center justify-center rounded-lg text-sm font-medium bg-base-200 text-base-content/80 hover:bg-primary hover:text-white transition-colors"
            >
              {letter}
            </a>
          </div>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
          <.link
            :for={item <- @type_index}
            navigate={~p"/#{@context.slug}/type/#{item.type}"}
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

  attr :context, :map, required: true
  attr :page_type, :string, required: true
  attr :grouped_pages, :list, default: []
  attr :filter_project, :string, default: "all"
  attr :filter_goal, :string, default: "all"
  attr :filter_plan, :string, default: "all"
  attr :filter_project_options, :list, default: []
  attr :filter_goal_options, :list, default: []
  attr :filter_plan_options, :list, default: []
  attr :project_enabled, :boolean, default: true
  attr :goal_enabled, :boolean, default: true
  attr :plan_enabled, :boolean, default: true
  attr :pages, :list, default: []
  attr :slug_maps, :map, default: %{}

  defp type_list_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="mb-6">
        <div class="flex items-center gap-2 mb-2 text-sm text-base-content/50">
          <.link navigate={~p"/#{@context.slug}"} class="hover:underline">
            {@context.name}
          </.link>
          <span>/</span>
          <span>{PageTypes.label(@page_type)}</span>
        </div>
        <h1 class="text-2xl font-bold">{PageTypes.plural(@page_type)}</h1>
      </div>

      <%!-- Filtros combinables para todos (mismo patrón que kanban_view) --%>
      <div
        :if={@page_type == "todo" and (@project_enabled or @goal_enabled or @plan_enabled)}
        class="flex flex-wrap gap-3 mb-6 p-3 rounded-lg bg-base-200/50 border border-base-300"
      >
        <.wiki_filter_select
          :if={@project_enabled and @filter_project_options != []}
          label={gettext("Project")}
          id="wiki-todo-filter-project"
          value={@filter_project}
          options={@filter_project_options}
          phx_change="filter_project"
        />
        <.wiki_filter_select
          :if={@goal_enabled and @filter_goal_options != []}
          label={gettext("Goal")}
          id="wiki-todo-filter-goal"
          value={@filter_goal}
          options={@filter_goal_options}
          phx_change="filter_goal"
        />
        <.wiki_filter_select
          :if={@plan_enabled and @filter_plan_options != []}
          label={gettext("Plan")}
          id="wiki-todo-filter-plan"
          value={@filter_plan}
          options={@filter_plan_options}
          phx_change="filter_plan"
        />
        <button
          :if={
            @page_type == "todo" and
              ((@project_enabled and @filter_project != "all") or
                 (@goal_enabled and @filter_goal != "all") or
                 (@plan_enabled and @filter_plan != "all"))
          }
          phx-click="clear_filters"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-x-mark" class="size-4" /> {gettext("Clear")}
        </button>
        <div
          :if={@page_type == "todo"}
          class="ml-auto text-sm text-base-content/60 self-center"
        >
          {wiki_filtered_count(@pages, @filter_project, @filter_goal, @filter_plan)} {gettext("todos")}
        </div>
      </div>

      <div :if={@grouped_pages == []} class="text-center py-12">
        <.icon name={PageTypes.icon(@page_type)} class="size-10 text-base-content/30 mx-auto mb-3" />
        <p class="text-base-content/50">{gettext("No pages of this type.")}</p>
      </div>

      <div
        :for={
          {group_key, pages} <-
            wiki_filter_grouped(
              @grouped_pages,
              @page_type,
              @filter_project,
              @filter_goal,
              @filter_plan
            )
        }
        class="mb-6"
      >
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
            navigate={~p"/#{@context.slug}/type/#{@page_type}/#{page.slug}"}
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
            <%!-- Badges de vínculos (project/goal/plan) — solo para todos --%>
            <div
              :if={@page_type == "todo" and wiki_todo_badges(page, @context, @slug_maps) != []}
              class="flex flex-wrap items-center gap-1.5 mt-1"
            >
              <span
                :for={badge <- wiki_todo_badges(page, @context, @slug_maps)}
                class={"px-1.5 py-0.5 text-[11px] rounded " <> wiki_badge_class(badge.type)}
                title={badge.label}
              >
                {badge.label}
              </span>
              <span
                :if={@page_type == "todo" and wiki_extra_badge_count(page, @context, @slug_maps) > 0}
                class="px-1.5 py-0.5 text-[11px] rounded bg-base-300 text-base-content/60"
              >
                +{wiki_extra_badge_count(page, @context, @slug_maps)}
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
        <.link navigate={~p"/#{@context.slug}"} class="hover:underline">
          {@context.name}
        </.link>
        <span>/</span>
        <.link navigate={~p"/#{@context.slug}/type/#{@page.page_type}"} class="hover:underline">
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
              navigate={~p"/#{@context.slug}/type/#{rel.target.page_type}/#{rel.target.slug}"}
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
              navigate={~p"/#{@context.slug}/type/#{rel.source.page_type}/#{rel.source.slug}"}
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
          <.link navigate={~p"/#{@context.slug}"} class="hover:underline">
            {@context.name}
          </.link>
          <span>/</span>
          <span>{gettext("Collection")}</span>
        </div>
        <h1 class="text-2xl font-bold">{@collection.title}</h1>
        <p :if={@collection.summary} class="text-base-content/60 mt-2">
          {@collection.summary}
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
          navigate={~p"/#{@context.slug}/type/#{page.page_type}/#{page.slug}"}
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

  attr :context, :map, required: true
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
          <.link navigate={~p"/#{@context.slug}"} class="hover:underline">
            {@context.name}
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
            base_path={"/#{@context.slug}/type"}
            graph_url={"/#{@context.slug}/graph/json"}
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

  attr :context, :map, required: true
  attr :todos, :list, default: []
  attr :kanban_columns, :list, default: []
  attr :filter_project, :string, default: "all"
  attr :filter_goal, :string, default: "all"
  attr :filter_plan, :string, default: "all"
  attr :filter_project_options, :list, default: []
  attr :filter_goal_options, :list, default: []
  attr :filter_plan_options, :list, default: []
  attr :project_enabled, :boolean, default: true
  attr :goal_enabled, :boolean, default: true
  attr :plan_enabled, :boolean, default: true
  attr :filtered_count, :integer, default: nil
  attr :slug_maps, :map, default: %{}

  defp kanban_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="flex items-center gap-2 text-sm text-base-content/50 mb-2">
        <.link navigate={~p"/#{@context.slug}"} class="hover:underline">
          {@context.name}
        </.link>
        <span>/</span>
        <span>{gettext("Kanban")}</span>
      </div>

      <h1 class="text-2xl font-bold mb-6 flex items-center gap-2">
        <.icon name="hero-view-columns" class="size-6 text-primary" />
        {gettext("Kanban")}
      </h1>

      <%!-- Filtros combinables — solo se muestran si hay opciones reales --%>
      <div
        :if={@project_enabled or @goal_enabled or @plan_enabled}
        class="flex flex-wrap gap-3 mb-4 p-3 rounded-lg bg-base-200/50 border border-base-300"
      >
        <.wiki_filter_select
          :if={@project_enabled and @filter_project_options != []}
          label={gettext("Project")}
          id="wiki-filter-project"
          value={@filter_project}
          options={@filter_project_options}
          phx_change="filter_project"
        />
        <.wiki_filter_select
          :if={@goal_enabled and @filter_goal_options != []}
          label={gettext("Goal")}
          id="wiki-filter-goal"
          value={@filter_goal}
          options={@filter_goal_options}
          phx_change="filter_goal"
        />
        <.wiki_filter_select
          :if={@plan_enabled and @filter_plan_options != []}
          label={gettext("Plan")}
          id="wiki-filter-plan"
          value={@filter_plan}
          options={@filter_plan_options}
          phx_change="filter_plan"
        />
        <button
          :if={
            (@project_enabled and @filter_project != "all") or
              (@goal_enabled and @filter_goal != "all") or
              (@plan_enabled and @filter_plan != "all")
          }
          phx-click="clear_filters"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-x-mark" class="size-4" /> {gettext("Clear")}
        </button>
        <div class="ml-auto text-sm text-base-content/60 self-center">
          {wiki_filtered_count(@todos, @filter_project, @filter_goal, @filter_plan)} {gettext("todos")}
        </div>
      </div>

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
              {kanban_count(
                wiki_filter_todos(@todos, @filter_project, @filter_goal, @filter_plan),
                status
              )}
            </span>
          </div>
          <div class="p-2 space-y-2">
            <a
              :for={
                todo <-
                  kanban_items(
                    wiki_filter_todos(@todos, @filter_project, @filter_goal, @filter_plan),
                    status
                  )
              }
              href={~p"/#{@context.slug}/type/todo/#{todo.slug}"}
              class="block p-3 rounded-xl bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-primary/40 transition"
            >
              <div class="font-medium text-sm break-words">{todo.title}</div>

              <%!-- Badges de vínculos (project/goal/plan) — max 2 visibles --%>
              <div
                :if={wiki_todo_badges(todo, @context, @slug_maps) != []}
                class="flex flex-wrap items-center gap-1.5 mt-1.5"
              >
                <span
                  :for={badge <- wiki_todo_badges(todo, @context, @slug_maps)}
                  class={"px-1.5 py-0.5 text-[11px] rounded " <> wiki_badge_class(badge.type)}
                  title={badge.label}
                >
                  {badge.label}
                </span>
                <span
                  :if={wiki_extra_badge_count(todo, @context, @slug_maps) > 0}
                  class="px-1.5 py-0.5 text-[11px] rounded bg-base-300 text-base-content/60"
                >
                  +{wiki_extra_badge_count(todo, @context, @slug_maps)}
                </span>
              </div>

              <div :if={kanban_due(todo)} class={kanban_due_class(kanban_overdue?(todo))}>
                <.icon name="hero-calendar-days" class="size-3.5" />
                {kanban_format_due(kanban_due(todo))}
              </div>
            </a>
            <p
              :if={
                kanban_items(
                  wiki_filter_todos(@todos, @filter_project, @filter_goal, @filter_plan),
                  status
                ) == []
              }
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
    case (page.meta || %{})["kanban_status"] do
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

  attr :context, :map, required: true
  attr :letter, :string, required: true
  attr :pages, :list, default: []
  attr :alphabet, :list, default: []

  defp letter_view(assigns) do
    ~H"""
    <div class="px-6 py-8">
      <div class="flex items-center gap-2 mb-2 text-sm text-base-content/50">
        <.link navigate={~p"/#{@context.slug}"} class="hover:underline">
          {@context.name}
        </.link>
        <span>/</span>
        <span>{@letter}</span>
      </div>

      <h1 class="text-2xl font-bold mb-6">{@letter}</h1>

      <%!-- Alphabet bar --%>
      <div class="flex flex-wrap gap-1 mb-8">
        <a
          :for={l <- @alphabet}
          href={~p"/#{@context.slug}/letter/#{l}"}
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
          navigate={~p"/#{@context.slug}/type/#{page.page_type}/#{page.slug}"}
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
        context = socket.assigns[:context]

        opts =
          if context do
            [context_id: context.id, limit: 30]
          else
            [limit: 30]
          end

        case Brain.search(query, opts) do
          {:ok, res} -> res
          _ -> []
        end
      end

    {:noreply, assign(socket, search_query: query, search_results: results)}
  end

  # ── Filter event handlers (kanban + todo type_list) ──

  def handle_event("filter_project", %{"value" => value}, socket) do
    {:noreply, assign(socket, filter_project: value)}
  end

  def handle_event("filter_goal", %{"value" => value}, socket) do
    {:noreply, assign(socket, filter_goal: value)}
  end

  def handle_event("filter_plan", %{"value" => value}, socket) do
    {:noreply, assign(socket, filter_plan: value)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, assign(socket, filter_project: "all", filter_goal: "all", filter_plan: "all")}
  end

  @impl true
  def handle_event("node_click", %{"slug" => slug, "type" => type}, socket) do
    context = socket.assigns[:context]

    if context do
      {:noreply, push_navigate(socket, to: ~p"/#{context.slug}/type/#{type}/#{slug}")}
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Filter helpers ──

  # Loads project/goal/plan pages from the context and builds filter dropdown
  # options + page_type_enabled flags (mirrors KanbanLive panel pattern).
  defp load_todo_filter_data(context) do
    disabled = context.disabled_page_types || []

    project_enabled = "project" not in disabled
    goal_enabled = "goal" not in disabled
    plan_enabled = "plan" not in disabled

    {project_pages, goal_pages, plan_pages} =
      {
        if project_enabled do
          Brain.list_pages(context_id: context.id, type: "project", limit: 200)
        else
          []
        end,
        if goal_enabled do
          Brain.list_pages(context_id: context.id, type: "goal", limit: 200)
        else
          []
        end,
        if plan_enabled do
          Brain.list_pages(context_id: context.id, type: "plan", limit: 200)
        else
          []
        end
      }

    filter_opts = %{
      project_options: if(project_enabled, do: build_filter_options(project_pages), else: []),
      goal_options: if(goal_enabled, do: build_filter_options(goal_pages), else: []),
      plan_options: if(plan_enabled, do: build_filter_options(plan_pages), else: []),
      slug_maps: %{
        "project" => Map.new(project_pages, &{&1.slug, &1.title}),
        "goal" => Map.new(goal_pages, &{&1.slug, &1.title}),
        "plan" => Map.new(plan_pages, &{&1.slug, &1.title})
      }
    }

    {filter_opts,
     %{
       project_enabled: project_enabled,
       goal_enabled: goal_enabled,
       plan_enabled: plan_enabled
     }}
  end

  defp build_filter_options(pages) do
    [{gettext("All"), "all"}, {gettext("None (orphan)"), "none"}] ++
      Enum.map(pages, fn p -> {p.title, p.slug} end)
  end

  # Filters a list of todo pages by project/goal/plan slugs.
  # "all" = no filter; "none" = todos WITHOUT that link (orphan); anything else = exact slug match.
  defp filter_by_slug(todos, _type, "all"), do: todos

  defp filter_by_slug(todos, type, "none") do
    key = "#{type}_slug"

    Enum.reject(todos, fn t ->
      v = wiki_meta_get(t.meta, key)
      v != nil and v != ""
    end)
  end

  defp filter_by_slug(todos, type, slug) do
    key = "#{type}_slug"
    Enum.filter(todos, fn t -> wiki_meta_get(t.meta, key) == slug end)
  end

  defp wiki_meta_get(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp wiki_meta_get(nil, _key), do: nil

  # ── Todo badge helpers (project/goal/plan labels) ──

  @wiki_badge_styles %{
    "project" => "bg-blue-100 text-blue-700",
    "goal" => "bg-green-100 text-green-700",
    "plan" => "bg-purple-100 text-purple-700"
  }

  # Build the list of badges for a todo, resolving slug→title via slug_maps.
  # Filters by disabled page types. Max 2 visible, rest in +N.
  defp wiki_todo_badges(todo, context, slug_maps) do
    todo
    |> wiki_all_badges(context, slug_maps)
    |> Enum.take(2)
  end

  defp wiki_all_badges(todo, context, slug_maps) do
    disabled = (context && context.disabled_page_types) || []

    []
    |> wiki_maybe_add_badge(
      "project",
      wiki_meta_get(todo.meta, "project_slug"),
      disabled,
      slug_maps
    )
    |> wiki_maybe_add_badge("goal", wiki_meta_get(todo.meta, "goal_slug"), disabled, slug_maps)
    |> wiki_maybe_add_badge("plan", wiki_meta_get(todo.meta, "plan_slug"), disabled, slug_maps)
  end

  defp wiki_maybe_add_badge(list, _type, nil, _disabled, _slug_maps), do: list
  defp wiki_maybe_add_badge(list, _type, "", _disabled, _slug_maps), do: list

  defp wiki_maybe_add_badge(list, type, slug, disabled, slug_maps) do
    if type in disabled do
      list
    else
      type_map = Map.get(slug_maps, type, %{})
      title = Map.get(type_map, slug, slug)
      [%{type: type, slug: slug, label: title} | list]
    end
  end

  defp wiki_extra_badge_count(todo, context, slug_maps) do
    max(0, length(wiki_all_badges(todo, context, slug_maps)) - 2)
  end

  defp wiki_badge_class(type),
    do: Map.get(@wiki_badge_styles, type, "bg-base-300 text-base-content/60")

  # Pure filter function used in the template (no socket state needed).
  defp wiki_filter_todos(todos, filter_project, filter_goal, filter_plan) do
    todos
    |> filter_by_slug(:project, filter_project)
    |> filter_by_slug(:goal, filter_goal)
    |> filter_by_slug(:plan, filter_plan)
  end

  defp wiki_filtered_count(todos, filter_project, filter_goal, filter_plan) do
    length(wiki_filter_todos(todos, filter_project, filter_goal, filter_plan))
  end

  # For type_list_view: when page_type == "todo", filter grouped_pages by the
  # active filters. For non-todo types, return the grouped list unchanged.
  defp wiki_filter_grouped(grouped_pages, "todo", filter_project, filter_goal, filter_plan) do
    grouped_pages
    |> Enum.map(fn {status, pages} ->
      filtered = wiki_filter_todos(pages, filter_project, filter_goal, filter_plan)
      {status, filtered}
    end)
    |> Enum.reject(fn {_status, pages} -> pages == [] end)
  end

  defp wiki_filter_grouped(grouped_pages, _page_type, _fp, _fg, _fpl), do: grouped_pages

  # Filter dropdown component (read-only wiki, phx-change updates assigns)
  attr :label, :string, required: true
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :phx_change, :string, required: true

  defp wiki_filter_select(assigns) do
    ~H"""
    <div class="flex flex-col">
      <label for={@id} class="text-xs font-medium text-base-content/60 mb-1">{@label}</label>
      <select
        id={@id}
        class="px-2 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100"
        phx-change={@phx_change}
      >
        <%= for {label, value} <- @options do %>
          <option value={value} selected={value == @value}>{label}</option>
        <% end %>
      </select>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Types shown as featured links (Proyectos, Objetivos) above the type_index
  # in the sidebar — excluded from the generic list to avoid duplication.
  @featured_types ~w(project goal)

  defp build_type_index(context) do
    disabled = context.disabled_page_types || []
    excluded = @wiki_hidden_types ++ disabled ++ @featured_types

    BrainPageTypes.types()
    |> Enum.reject(&(&1 in excluded))
    |> Enum.map(fn type ->
      count =
        Dran.Repo.aggregate(
          from(p in Dran.Brain.Page,
            where:
              p.context_id == ^context.id and
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
  defp render_wiki_markdown(body, context) do
    html =
      case MDEx.to_html(body, markdown_options()) do
        {:ok, html} -> html
        {:error, _} -> Phoenix.HTML.html_escape(body) |> Phoenix.HTML.safe_to_string()
      end

    html
    |> rewrite_wikilinks(context)
    |> raw()
  end

  # MDEx renders wikilinks as <a href="slug" data-wikilink="true">display</a>.
  # We rewrite the href to point to the wiki URL for that slug.
  # We don't know the page_type from the slug alone, so we point to a
  # generic wiki path and let the lookup resolve it.
  defp rewrite_wikilinks(html, context) do
    slug_to_path = build_wikilink_map(html, context)

    Regex.replace(
      ~r/<a href="([^"]+)" data-wikilink="true">/,
      html,
      fn _full, slug ->
        path = Map.get(slug_to_path, slug, "/#{context.slug}")
        ~s|<a href="#{path}" data-wikilink="true">|
      end
    )
  end

  # Extract all slugs from wikilinks and batch-resolve them to page types
  # so we can build proper wiki URLs.
  defp build_wikilink_map(html, context) do
    slugs =
      Regex.scan(~r/<a href="([^"]+)" data-wikilink="true">/, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    if slugs == [] do
      %{}
    else
      slug_types = Brain.get_pages_by_slugs(slugs, context.id)

      Enum.reduce(slugs, %{}, fn slug, acc ->
        case Map.get(slug_types, slug) do
          nil -> acc
          page_type -> Map.put(acc, slug, "/#{context.slug}/type/#{page_type}/#{slug}")
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
  # if a context is active, the URL includes its slug so navigation stays in scope.
  defp wiki_page_path(nil, result) do
    # No active context — try to resolve the page's context from its fields.
    # Fall back to the generic wiki root.
    page_type = Map.get(result, :page_type) || Map.get(result, "page_type")
    slug = Map.get(result, :slug) || Map.get(result, "slug")

    if page_type && slug do
      # We don't have a context slug, so we can't build a wiki path.
      # The search result may include context_id but not the slug.
      # Fallback: point to the wiki root.
      ~p"/"
    else
      ~p"/"
    end
  end

  defp wiki_page_path(context, result) do
    page_type = Map.get(result, :page_type) || Map.get(result, "page_type")
    slug = Map.get(result, :slug) || Map.get(result, "slug")
    ~p"/#{context.slug}/type/#{page_type}/#{slug}"
  end
end
