defmodule DranWeb.SearchLive do
  @moduledoc """
  LiveView for full-text search across the second brain.

  The sidebar search form submits a GET to `/search?q=...`, which loads
  this page with the query. The in-page form uses `phx-submit` for live
  updates without a full page reload.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.HTMLSanitizer
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @search_modes [
    {"auto", gettext("Auto")},
    {"fts", gettext("FTS")},
    {"semantic", gettext("Semantic")},
    {"hybrid", gettext("Hybrid")},
    {"graph", gettext("Graph")}
  ]

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       context: context,
       active_nav: "search",
       query: "",
       results: [],
       graph_nodes: [],
       graph_edges: [],
       search_mode: "auto",
       search_modes: @search_modes
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params["q"] do
      q when is_binary(q) and q != "" ->
        {:ok, results} =
          Brain.search(q,
            workspace_id: socket.assigns.context.id,
            limit: 20,
            strategy: String.to_atom(socket.assigns.search_mode)
          )

        %{nodes: graph_nodes, edges: graph_edges} = graph_data(socket, results)

        {:noreply,
         assign(socket,
           query: q,
           results: results,
           graph_nodes: graph_nodes,
           graph_edges: graph_edges
         )}

      _ ->
        {:noreply, assign(socket, query: "", results: [], graph_nodes: [], graph_edges: [])}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    results =
      case q do
        q when is_binary(q) and q != "" ->
          {:ok, r} =
            Brain.search(q,
              workspace_id: socket.assigns.context.id,
              limit: 20,
              strategy: String.to_atom(socket.assigns.search_mode)
            )

          r

        _ ->
          []
      end

    %{nodes: graph_nodes, edges: graph_edges} = graph_data(socket, results)

    {:noreply,
     assign(socket,
       query: q,
       results: results,
       graph_nodes: graph_nodes,
       graph_edges: graph_edges
     )}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, search_mode: mode)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
    >
      <div class="p-6 overflow-y-auto w-full">
        <form phx-submit="search" class="mb-4">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="size-5 text-base-content/40 absolute left-4 top-1/2 -translate-y-1/2 pointer-events-none"
            />
            <.input
              id="search-q"
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search pages...")}
              class="focus-ring w-full py-3 pl-12 pr-4 text-base"
            />
          </div>
        </form>

        <div class="mb-6">
          <div
            role="group"
            aria-label={gettext("Search strategy")}
            class="inline-flex rounded-lg bg-base-200 p-1"
          >
            <button
              :for={{mode, label} <- @search_modes}
              type="button"
              phx-click="set_mode"
              phx-value-mode={mode}
              class={[
                "px-3 py-1.5 text-sm transition-colors rounded-md",
                if @search_mode == mode do
                  "bg-base-100 shadow-sm font-medium"
                else
                  "text-base-content/60 hover:text-base-content"
                end
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <div data-testid="search-results" class="space-y-4">
          <.empty_hero :if={@query == ""} />

          <.no_results
            :if={@query != "" && @results == [] && @search_mode != "graph"}
            query={@query}
          />

          <div :if={@query != "" && @results != [] && @search_mode != "graph"}>
            <.results_header query={@query} count={length(@results)} />

            <div class="space-y-2">
              <.result_card :for={result <- @results} result={result} />
            </div>
          </div>
        </div>

        <div
          :if={@search_mode == "graph" && @query != ""}
          data-testid="search-graph"
          class="mt-6"
        >
          <div class="flex items-baseline justify-between mb-4">
            <h1 class="text-title">{gettext("Graph")}</h1>
            <p class="text-caption">
              {gettext("%{count} results for '%{query}'", count: length(@results), query: @query)}
            </p>
          </div>

          <p
            :if={@results == []}
            class="text-caption text-base-content/40 text-center py-10"
          >
            {gettext("No results to graph. Try a different query.")}
          </p>

          <.graph_3d
            :if={@results != []}
            id="search-graph-3d"
            nodes={@graph_nodes}
            edges={@graph_edges}
            class="w-full rounded-2xl overflow-hidden surface-2"
            style="height: 70vh;"
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Render-only components ─────────────────────────────────────────────────

  attr :query, :string, required: true
  attr :count, :integer, required: true

  defp results_header(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between border-b border-base-300 pb-2">
      <h1 class="text-title">
        {gettext("Search")}
      </h1>
      <p class="text-caption">
        {gettext("%{count} results for '%{query}'", count: @count, query: @query)}
      </p>
    </div>
    """
  end

  defp empty_hero(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center text-center py-20">
      <div class="size-16 rounded-2xl bg-primary/10 flex items-center justify-center">
        <.icon name="hero-magnifying-glass" class="size-8 text-primary" />
      </div>
      <h1 class="text-title mt-5">{gettext("Search your second brain")}</h1>
      <p class="text-caption mt-2 max-w-sm">
        {gettext("Find pages, concepts, and notes by content, tags, or meaning.")}
      </p>

      <p class="text-caption mt-6 flex items-center gap-1.5">
        <.icon name="hero-key" class="size-3.5" />
        {gettext("Press")}
        <kbd class="border border-base-300 rounded px-1.5 py-0.5 text-[10px] font-mono text-base-content/60 bg-base-200">
          ⌘K
        </kbd>
        {gettext("from anywhere to open the command palette.")}
      </p>

      <div class="mt-8 flex flex-col items-center gap-2">
        <p class="text-caption text-base-content/50">{gettext("Try one of these:")}</p>
        <div class="flex flex-wrap justify-center gap-2 max-w-lg">
          <.example_chip :for={{label, query} <- example_queries()} label={label} query={query} />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :query, :string, required: true

  defp example_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="search"
      phx-value-q={@query}
      class="px-3 py-1.5 text-sm rounded-full border border-base-300 bg-base-100 hover:border-primary/40 hover:bg-primary/5 hover:text-primary transition-colors lift"
    >
      <span class="text-base-content/40 mr-1.5 font-mono text-xs">↵</span>
      {@label}
    </button>
    """
  end

  attr :query, :string, required: true

  defp no_results(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center text-center py-20">
      <div class="size-14 rounded-2xl bg-base-200 flex items-center justify-center">
        <.icon name="hero-magnifying-glass" class="size-7 text-base-content/30" />
      </div>
      <p class="text-heading mt-4">{gettext("No results for '%{query}'", query: @query)}</p>
      <p class="text-caption mt-1 max-w-sm text-base-content/50">
        {gettext("Check the spelling or try a different strategy above.")}
      </p>

      <div class="mt-6 flex flex-wrap justify-center gap-2 max-w-lg">
        <.example_chip :for={{label, query} <- suggestion_queries()} label={label} query={query} />
      </div>
    </div>
    """
  end

  attr :result, :map, required: true

  defp result_card(assigns) do
    ~H"""
    <div class="surface-2 lift p-4 relative hover:border-primary/40">
      <div class="flex items-start gap-3">
        <div class={[
          "shrink-0 size-9 rounded-lg flex items-center justify-center",
          type_chip_bg(@result.page_type)
        ]}>
          <.icon
            name={PageTypes.icon(@result.page_type)}
            class={["size-4", type_icon_color(@result.page_type)]}
          />
        </div>

        <div class="flex-1 min-w-0">
          <div class="flex items-start justify-between gap-3">
            <h3 class="font-medium text-sm break-words text-heading">
              <.link
                navigate={page_path_for(@result)}
                class="after:absolute after:inset-0 after:content-[''] hover:text-primary transition-colors"
              >
                {@result.title}
              </.link>
            </h3>
            <span class={[
              "shrink-0 text-[11px] font-medium px-2 py-0.5 rounded-full",
              type_badge(@result.page_type)
            ]}>
              {PageTypes.label(@result.page_type)}
            </span>
          </div>

          <div
            :if={@result.excerpt && @result.excerpt != ""}
            class="mt-1.5 text-sm text-base-content/60 line-clamp-2 [&_b]:font-semibold [&_b]:text-base-content [&_mark]:bg-warning/20 [&_mark]:px-0.5 [&_mark]:rounded"
          >
            {raw(HTMLSanitizer.sanitize_to_string(@result.excerpt))}
          </div>

          <div :if={tags_for(@result) != []} class="relative z-10 flex flex-wrap gap-1.5 mt-2.5">
            <.link
              :for={tag <- Enum.take(tags_for(@result), 5)}
              navigate={"/panel/tags/#{URI.encode_www_form(tag)}"}
              class="px-1.5 py-0.5 text-[11px] rounded bg-base-200 text-base-content/60 hover:bg-primary/10 hover:text-primary transition-colors"
            >
              #{tag}
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Render-only helpers ────────────────────────────────────────────────────

  defp page_path_for(%{page_type: type, slug: slug})
       when is_binary(type) and is_binary(slug),
       do: "/panel/#{PageTypes.path(type)}/#{slug}"

  defp page_path_for(_), do: "#"

  # Builds the merged graph data for "graph" search mode: a mini subgraph for
  # each result, merged into one set of nodes/edges (deduped by id). Uses a
  # single batched query for all relations instead of N+1 per result, and
  # Map-based dedup (O(n)) instead of Enum.any? scans (O(n²)).
  defp graph_data(socket, results) do
    if socket.assigns.search_mode == "graph" do
      page_ids = Enum.map(results, & &1.id)

      # One query for ALL relations touching any result page (inbound or
      # outbound), with target/source pages pre-loaded. Replaces the old
      # N+1: 20 results × 2 queries each = 40+ queries.
      relations_map = Brain.list_relations_for_pages(page_ids)

      results
      |> Enum.reduce({%{}, %{}}, fn result, {nodes_acc, edges_acc} ->
        relations = Map.get(relations_map, result.id, %{outbound: [], inbound: []})

        %{nodes: sub_nodes, edges: sub_edges} =
          GraphHelpers.build_page_subgraph(result, relations: relations, max_neighbors: 50)

        nodes_acc =
          Enum.reduce(sub_nodes, nodes_acc, fn node, acc ->
            Map.put_new(acc, node.id, node)
          end)

        edges_acc =
          Enum.reduce(sub_edges, edges_acc, fn edge, acc ->
            key = {edge.source_id, edge.target_id}
            Map.put_new(acc, key, edge)
          end)

        {nodes_acc, edges_acc}
      end)
      |> then(fn {nodes_map, edges_map} ->
        %{nodes: Map.values(nodes_map), edges: Map.values(edges_map)}
      end)
    else
      %{nodes: [], edges: []}
    end
  end

  defp tags_for(%{tags: tags}) when is_list(tags), do: tags
  defp tags_for(_), do: []

  # Per-type icon chip background and icon color, for the result card leading
  # icon. Uses semantic surface tints so the chip reads as "this kind of page"
  # at a glance without resorting to flat primary-everywhere.
  defp type_chip_bg("note"), do: "bg-info/10"
  defp type_chip_bg("concept"), do: "bg-warning/10"
  defp type_chip_bg("entity"), do: "bg-accent/10"
  defp type_chip_bg("project"), do: "bg-primary/10"
  defp type_chip_bg("reference"), do: "bg-success/10"
  defp type_chip_bg("goal"), do: "bg-error/10"
  defp type_chip_bg("plan"), do: "bg-secondary/10"
  defp type_chip_bg("todo"), do: "bg-success/10"
  defp type_chip_bg(_), do: "bg-base-content/10"

  defp type_icon_color("note"), do: "text-info"
  defp type_icon_color("concept"), do: "text-warning"
  defp type_icon_color("entity"), do: "text-accent"
  defp type_icon_color("project"), do: "text-primary"
  defp type_icon_color("reference"), do: "text-success"
  defp type_icon_color("goal"), do: "text-error"
  defp type_icon_color("plan"), do: "text-secondary"
  defp type_icon_color("todo"), do: "text-success"
  defp type_icon_color(_), do: "text-base-content/60"

  # Colored type badge shown on the right side of each card title.
  defp type_badge("note"), do: "bg-info/15 text-info"
  defp type_badge("concept"), do: "bg-warning/15 text-warning"
  defp type_badge("entity"), do: "bg-accent/15 text-accent"
  defp type_badge("project"), do: "bg-primary/15 text-primary"
  defp type_badge("reference"), do: "bg-success/15 text-success"
  defp type_badge("goal"), do: "bg-error/15 text-error"
  defp type_badge("plan"), do: "bg-secondary/15 text-secondary"
  defp type_badge("todo"), do: "bg-success/15 text-success"
  defp type_badge(_), do: "bg-base-200 text-base-content/60"

  # Example queries shown as clickable chips in the empty hero. Each tuple is
  # {display_label, query_string}. The query_string is what gets submitted
  # when the chip is clicked (phx-value-q).
  defp example_queries do
    [
      {gettext("Notes about elixir"), "elixir"},
      {gettext("Meeting notes"), "meeting"},
      {gettext("Tagged programming"), "tag:programming"},
      {gettext("Concepts about AI"), "inteligencia artificial"}
    ]
  end

  # Suggestions shown in the no-results state. Shorter, more generic than
  # example_queries so they read as recovery hints rather than tutorials.
  defp suggestion_queries do
    [
      {gettext("Notes about elixir"), "elixir"},
      {gettext("Meeting notes"), "meeting"},
      {gettext("Tagged programming"), "tag:programming"}
    ]
  end
end
