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
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  # Page types excluded from the wiki index — operational or second-citizen.
  @wiki_hidden_types ~w(todo plan report)

  # ── Mount ─────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)
    {:ok, assign(socket, graph_data: %{nodes: [], edges: []})}
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
      page_title: gettext("Wiki")
    )
  end

  # ── :context_home — collections + pinned + index by type ───────────────────

  defp apply_action(socket, :context_home, %{"context_slug" => context_slug}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        collections = SmartCollection.list_all(context.id)
        pinned = Brain.list_pinned_pages(context.id)
        type_index = build_type_index(context)

        socket
        |> assign(
          context: context,
          collections: collections,
          pinned_pages: pinned,
          type_index: type_index,
          page_title: context.name
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

        # Group by first letter for A-Z index
        grouped = group_alphabetically(pages)

        socket
        |> assign(
          context: context,
          page_type: page_type,
          pages: pages,
          grouped_pages: grouped,
          page_title: "#{context.name} · #{PageTypes.label(page_type)}"
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

            socket
            |> assign(
              context: context,
              page: page,
              rendered_body: rendered_body,
              relations: relations,
              page_title: page.title
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

            socket
            |> assign(
              context: context,
              collection: collection,
              results: results,
              page_title: collection.title
            )
        end

      _ ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── :graph — graph view of the context ─────────────────────────────────────

  defp apply_action(socket, :graph, %{"context_slug" => context_slug}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        graph_data = Brain.graph_data(context.id)

        socket
        |> assign(
          context: context,
          graph_data: graph_data,
          page_title: "#{context.name} · Graph"
        )

      _ ->
        push_navigate(socket, to: ~p"/")
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.wiki
      flash={@flash}
      current_user={@current_user}
      context_slug={@context && @context.slug}
      contexts={@contexts}
      page_title={@page_title}
    >
      <%= case @live_action do %>
        <% :index -> %>
          <.index_view contexts={@contexts} />
        <% :context_home -> %>
          <.context_home_view
            context={@context}
            collections={@collections}
            pinned_pages={@pinned_pages}
            type_index={@type_index}
          />
        <% :type_list -> %>
          <.type_list_view
            context={@context}
            page_type={@page_type}
            grouped_pages={@grouped_pages}
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
          <.graph_view context={@context} />
      <% end %>
    </Layouts.wiki>
    """
  end

  # ── Views ───────────────────────────────────────────────────────────────────

  defp index_view(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto px-6 py-10">
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
    <div class="max-w-5xl mx-auto px-6 py-8 space-y-10">
      <%!-- Context header --%>
      <div>
        <h1 class="text-3xl font-bold tracking-tight">{@context.name}</h1>
        <p :if={@context.wiki_description} class="text-base-content/60 mt-2">
          {@context.wiki_description}
        </p>
        <div class="flex items-center gap-3 mt-3">
          <.link
            navigate={~p"/#{@context.slug}/graph"}
            class="btn btn-ghost btn-sm gap-1.5"
          >
            <.icon name="hero-share" class="size-4" />
            {gettext("Graph")}
          </.link>
        </div>
      </div>

      <%!-- Smart Collections as categories --%>
      <div :if={@collections != []}>
        <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
          <.icon name="hero-funnel" class="size-5 text-primary/70" />
          {gettext("Collections")}
        </h2>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
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

      <%!-- Pinned pages --%>
      <div :if={@pinned_pages != []}>
        <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
          <.icon name="hero-bookmark" class="size-5 text-amber-500" />
          {gettext("Pinned")}
        </h2>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.link
            :for={page <- @pinned_pages}
            navigate={~p"/#{@context.slug}/type/#{page.page_type}/#{page.slug}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer group"
          >
            <div class="card-body p-5">
              <div class="flex items-center gap-2 mb-1">
                <.icon
                  name={PageTypes.icon(page.page_type)}
                  class="size-4 text-base-content/40 group-hover:text-primary transition-colors"
                />
                <h3 class="font-medium">{page.title}</h3>
              </div>
              <p :if={page.summary} class="text-sm text-base-content/60 line-clamp-2">
                {page.summary}
              </p>
            </div>
          </.link>
        </div>
      </div>

      <%!-- Index by type + A-Z --%>
      <div>
        <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
          <.icon name="hero-square-3-stack-3d" class="size-5 text-primary/70" />
          {gettext("Index")}
        </h2>
        <div class="space-y-2">
          <details
            :for={%{type: type, label: label, count: count, icon: icon} <- @type_index}
            class="group border border-base-300 rounded-lg overflow-hidden"
          >
            <summary class="flex items-center gap-2 px-4 py-3 cursor-pointer hover:bg-base-200 transition-colors select-none">
              <.icon name={icon} class="size-4 text-base-content/50 shrink-0" />
              <span class="font-medium flex-1">{label}</span>
              <span class="text-sm text-base-content/40">{count}</span>
              <.icon
                name="hero-chevron-right"
                class="size-4 text-base-content/30 group-open:rotate-90 transition-transform"
              />
            </summary>
            <div class="border-t border-base-300 bg-base-200/30 p-4">
              <.link
                navigate={~p"/#{@context.slug}/type/#{type}"}
                class="text-sm text-primary hover:underline"
              >
                {gettext("View all")} →
              </.link>
            </div>
          </details>
        </div>
      </div>
    </div>
    """
  end

  defp type_list_view(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-6 py-8">
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

      <div :if={@grouped_pages == []} class="text-center py-12">
        <.icon name={PageTypes.icon(@page_type)} class="size-10 text-base-content/30 mx-auto mb-3" />
        <p class="text-base-content/50">{gettext("No pages of this type.")}</p>
      </div>

      <div :for={{letter, pages} <- @grouped_pages} class="mb-6">
        <h2 class="text-sm font-semibold text-base-content/40 uppercase tracking-wider mb-2 border-b border-base-300 pb-1">
          {letter}
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
    <div class="max-w-3xl mx-auto px-6 py-8">
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
    <div class="max-w-4xl mx-auto px-6 py-8">
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
          :for={page <- @results}
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

  defp graph_view(assigns) do
    ~H"""
    <div class="h-[calc(100vh-4rem)]">
      <div class="max-w-5xl mx-auto px-6 pt-4 pb-2">
        <div class="flex items-center gap-2 text-sm text-base-content/50 mb-1">
          <.link navigate={~p"/#{@context.slug}"} class="hover:underline">
            {@context.name}
          </.link>
          <span>/</span>
          <span>{gettext("Graph")}</span>
        </div>
      </div>
      <.graph_3d
        id="wiki-graph"
        nodes={@graph_data.nodes}
        edges={@graph_data.edges}
        class="w-full h-full"
      />
    </div>
    """
  end

  # ── Event handlers ──────────────────────────────────────────────────────────

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp build_type_index(context) do
    disabled = context.disabled_page_types || []
    excluded = @wiki_hidden_types ++ disabled

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
end
