defmodule DranWeb.PageComponents do
  @moduledoc """
  Shared function components for page detail views.
  """

  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import DranWeb.CoreComponents, only: [icon: 1]

  alias Dran.Brain.Page

  attr :page, :map, required: true
  attr :relations, :map, default: %{outbound: [], inbound: []}
  attr :versions, :list, default: []
  attr :logs, :list, default: []
  attr :context_slug, :string, default: "personal"

  slot :actions
  slot :tabs

  def page_detail(assigns) do
    inline_links =
      cond do
        is_map(assigns.page.meta) and Map.has_key?(assigns.page.meta, "inline_links") ->
          Map.get(assigns.page.meta, "inline_links")
        is_map(assigns.page.meta) and Map.has_key?(assigns.page.meta, :inline_links) ->
          Map.get(assigns.page.meta, :inline_links)
        true ->
          []
      end
    assigns = assign(assigns, :inline_links, inline_links)

    ~H"""
    <div class="flex h-full">
      <div class="flex-1 overflow-y-auto">
        <div class="w-full mx-auto p-6 space-y-6">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <.icon name={type_icon(@page.page_type)} class="w-5 h-5 text-base-content/60" />
                <span class="text-sm text-base-content/60 uppercase tracking-wider">
                  {type_label(@page.page_type)}
                </span>
              </div>
              <h1 class="text-3xl font-bold break-words">{@page.title}</h1>
              <div class="flex flex-wrap gap-2 mt-2">
                <.link
                  :for={tag <- @page.tags || []}
                  navigate={tag_link_path(tag, @page.context_id)}
                  class={[
                    "px-2 py-0.5 text-xs rounded transition",
                    "tag-link",
                    tag_page_exists?(tag, @page.context_id) && "tag-link-exists",
                    not tag_page_exists?(tag, @page.context_id) && "tag-link-missing"
                  ]}
                >
                  {tag}
                </.link>
              </div>
            </div>
            <div class="flex gap-2 shrink-0">
              {render_slot(@actions)}
              <button
                :if={Dran.Firecrawl.enabled?()}
                phx-click="enrich_page"
                phx-value-slug={@page.slug}
                class="btn btn-ghost btn-sm"
                title="Search the web and enrich this page with new content"
              >
                <.icon name="hero-sparkles" class="w-4 h-4" /> Enrich
              </button>
            </div>
          </div>

          {render_slot(@tabs)}

          <div :if={@tabs == []} class="prose prose-base dark:prose-invert max-w-none">
            {render_markdown(@page.body, context_id: @page.context_id, inline_links: @inline_links)}
          </div>

          <div :if={@tabs == []} class="border-t border-base-300 pt-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-2">Changelog</h3>
            <div class="space-y-1">
              <div :for={version <- @versions} class="text-sm text-base-content/60">
                v{version.version} — {format_date(version.inserted_at)} by {version.changed_by ||
                  "system"}
              </div>
              <p :if={@versions == []} class="text-sm text-base-content/40">
                No version history yet.
              </p>
            </div>
          </div>
        </div>
      </div>

      <aside class="w-72 shrink-0 border-l border-base-300 bg-base-200/30 overflow-y-auto">
        <div class="p-4 space-y-4">
          <div>
            <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-2">
              Metadata
            </h3>
            <div class="space-y-1 text-sm">
              <div class="flex justify-between gap-2">
                <span class="text-base-content/60">Type</span>
                <span>{@page.page_type}</span>
              </div>
              <div class="flex justify-between gap-2">
                <span class="text-base-content/60">Version</span>
                <span>v{@page.version}</span>
              </div>
              <div class="flex justify-between gap-2">
                <span class="text-base-content/60">Owner</span>
                <span>{@page.owner}</span>
              </div>
              <div class="flex justify-between gap-2">
                <span class="text-base-content/60">Created by</span>
                <span>{@page.created_by}</span>
              </div>
              <div :if={@page.updated_by} class="flex justify-between gap-2">
                <span class="text-base-content/60">Updated by</span>
                <span>{@page.updated_by}</span>
              </div>
              <div class="flex justify-between gap-2">
                <span class="text-base-content/60">Created</span>
                <span>{format_date(@page.inserted_at)}</span>
              </div>
              <div class="flex justify-between gap-2">
                <span class="text-base-content/60">Updated</span>
                <span>{format_date(@page.updated_at)}</span>
              </div>
            </div>

            <div
              :if={map_size(@page.meta || %{}) > 0}
              class="mt-3 pt-3 border-t border-base-300/50 space-y-1"
            >
              <div :for={
                {key, value} <- Enum.reject(@page.meta, fn {k, _v} -> k == "inline_links" end)
              } class="text-sm break-words">
                <span class="text-base-content/60">{format_meta_key(key)}:</span>
                {format_meta_value(value)}
              </div>
            </div>
          </div>

          <div>
            <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-2">
              Relations
            </h3>
            <div class="space-y-2">
              <div :if={length(@relations.outbound) > 0}>
                <div class="text-xs text-base-content/40 mb-1">Outbound</div>
                <div :for={rel <- @relations.outbound} class="text-sm">
                  <.link navigate={page_show_path(rel.target)} class="text-primary hover:underline">
                    {rel.target.title}
                  </.link>
                  <span class="text-base-content/40 text-xs ml-1">{rel.relation_type}</span>
                </div>
              </div>

              <div :if={length(@relations.inbound) > 0}>
                <div class="text-xs text-base-content/40 mb-1">Inbound</div>
                <div :for={rel <- @relations.inbound} class="text-sm">
                  <.link navigate={page_show_path(rel.source)} class="text-primary hover:underline">
                    {rel.source.title}
                  </.link>
                  <span class="text-base-content/40 text-xs ml-1">{rel.relation_type}</span>
                </div>
              </div>

              <p
                :if={@relations.outbound == [] and @relations.inbound == []}
                class="text-sm text-base-content/40"
              >
                No relations
              </p>
            </div>
          </div>

          <div>
            <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-2">
              Activity
            </h3>
            <div class="space-y-1">
              <div :for={log <- @logs} class="text-xs text-base-content/60">
                <span class="font-mono">{log.action}</span> — {format_date(log.inserted_at)}
              </div>
              <p :if={@logs == []} class="text-xs text-base-content/40">No activity recorded.</p>
            </div>
          </div>
        </div>
      </aside>
    </div>
    """
  end

  @doc """
  Renders a standard tab bar with Content + Graph tabs (plus any extras).
  Clicking a tab fires `switch_tab` with `phx-value-tab`.
  """
  attr :tabs, :list, required: true, doc: "list of {key, label} tuples"
  attr :active_tab, :string, required: true

  def tabs_bar(assigns) do
    ~H"""
    <div class="border-b border-base-300 mb-4">
      <div class="flex gap-1">
        <button
          :for={{tab, label} <- @tabs}
          phx-click="switch_tab"
          phx-value-tab={tab}
          class={[
            "px-3 py-2 text-sm font-medium border-b-2 transition",
            @active_tab == tab && "border-primary text-primary",
            @active_tab != tab && "border-transparent text-base-content/60 hover:text-base-content"
          ]}
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders the inline subgraph SVG centered on the current page.

  Uses the GraphPanZoom hook for zoom/pan and node dragging.
  """
  attr :id, :string, default: "page-graph"
  attr :nodes, :list, required: true
  attr :edges, :list, required: true

  def page_graph(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg overflow-hidden relative">
      <svg
        id={@id}
        width="100%"
        height="500"
        phx-hook="GraphPanZoom"
      >
        <line
          :for={edge <- @edges}
          x1={edge.x1}
          y1={edge.y1}
          x2={edge.x2}
          y2={edge.y2}
          stroke={edge.color}
          stroke-width="1.5"
          opacity="0.6"
          data-source={edge.source_id}
          data-target={edge.target_id}
        />

        <g
          :for={node <- @nodes}
          class="cursor-pointer"
          phx-click="node_click"
          phx-value-slug={node.slug}
          data-node-id={node.id}
          data-node-x={node.x}
          data-node-y={node.y}
        >
          <circle
            cx={node.x}
            cy={node.y}
            r={node.radius}
            fill={node.color}
            stroke="white"
            stroke-width="2"
          />
          <text
            x={node.x}
            y={node.y + node.radius + 15}
            text-anchor="middle"
            class="text-xs fill-current"
          >
            {node.label}
          </text>
        </g>
      </svg>

      <div class="px-3 py-2 text-xs text-base-content/40 border-t border-base-300 bg-base-200/50">
        Scroll para zoom · Arrastra el fondo para moverte · Arrastra un nodo para reposicionar
      </div>
    </div>
    """
  end

  # ── Helpers ──

  def type_icon("note"), do: "hero-document-text"
  def type_icon("comparison"), do: "hero-scale"
  def type_icon("plan"), do: "hero-calendar-days"
  def type_icon("todo"), do: "hero-check-circle"
  def type_icon("goal"), do: "hero-flag"
  def type_icon("entity"), do: "hero-user"
  def type_icon("concept"), do: "hero-light-bulb"
  def type_icon("reference"), do: "hero-bookmark"
  def type_icon("artifact"), do: "hero-paper-clip"
  def type_icon(_), do: "hero-document"

  def type_label("note"), do: "Note"
  def type_label("comparison"), do: "Comparison"
  def type_label("plan"), do: "Plan"
  def type_label("todo"), do: "Todo"
  def type_label("goal"), do: "Goal"
  def type_label("entity"), do: "Entity"
  def type_label("concept"), do: "Concept"
  def type_label("reference"), do: "Reference"
  def type_label("artifact"), do: "Artifact"
  def type_label(other), do: other |> to_string() |> String.capitalize()

  def type_path("note"), do: "notes"
  def type_path("comparison"), do: "comparisons"
  def type_path("plan"), do: "plans"
  def type_path("todo"), do: "todos"
  def type_path("goal"), do: "goals"
  def type_path("entity"), do: "entities"
  def type_path("concept"), do: "concepts"
  def type_path("reference"), do: "references"
  def type_path("artifact"), do: "artifacts"
  def type_path(other), do: to_string(other) <> "s"

  def page_show_path(%Page{page_type: type, slug: slug})
      when is_binary(type) and is_binary(slug) do
    "/#{type_path(type)}/#{slug}"
  end

  def page_show_path(%{page_type: type, slug: slug})
      when is_binary(type) and is_binary(slug) do
    "/#{type_path(type)}/#{slug}"
  end

  def page_show_path(_), do: "#"

  def tag_page_exists?(tag, context_id) when is_binary(tag) and is_binary(context_id) do
    Dran.Brain.get_page_by_slug(tag, context_id) != nil
  end

  def tag_page_exists?(_tag, _context_id), do: false

  def tag_link_path(tag, context_id) when is_binary(tag) and is_binary(context_id) do
    case Dran.Brain.get_page_by_slug(tag, context_id) do
      %Page{page_type: type, slug: slug} ->
        "/#{type_path(type)}/#{slug}"

      nil ->
        "/search?q=#{URI.encode_www_form(tag)}"
    end
  end

  def tag_link_path(tag, _context_id), do: "/search?q=#{URI.encode_www_form(tag)}"

  def format_date(nil), do: ""

  def format_date(%mod{} = datetime) when mod in [DateTime, NaiveDateTime, Date] do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  def format_date(other), do: to_string(other)

  def format_meta_key(key) when is_atom(key), do: key |> Atom.to_string() |> format_meta_key()

  def format_meta_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  def format_meta_key(other), do: other |> to_string() |> format_meta_key()

  def format_meta_value(nil), do: ""
  def format_meta_value(true), do: "true"
  def format_meta_value(false), do: "false"
  def format_meta_value(%DateTime{} = dt), do: format_date(dt)
  def format_meta_value(%NaiveDateTime{} = dt), do: format_date(dt)
  def format_meta_value(%Date{} = d), do: format_date(d)

  def format_meta_value(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      Enum.join(value, ", ")
    else
      inspect(value)
    end
  end

  def format_meta_value(value) when is_map(value) and not is_struct(value), do: inspect(value)
  def format_meta_value(other), do: to_string(other)

  # ── Markdown rendering ──

  @markdown_options [
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
      add_tag_attributes: %{"a" => ["data-wikilink"]}
    ]
  ]

  @doc """
  Render a markdown body to safe HTML using MDEx (comrak).

  Supports the full GFM feature set: tables, strikethrough, tasklists,
  autolinks, alerts, footnotes, emoji shortcodes, and wikilinks.

  Wikilinks `[[slug|display]]` are rendered by MDEx as
  `<a href="slug" data-wikilink="true">display</a>`. We post-process
  those into proper internal links using `page_show_path/1`.

  Embeds `![[slug|display]]` are not native to MDEx; we post-process
  the HTML to replace the literal `![[...]]` text with `<img>` or
  `<video>` tags when the slug resolves to an artifact page in the
  given context.

  Pass `:context_id` to resolve embeds; otherwise embeds render as
  literal text.
  """
  def render_markdown(body, opts \\ [])

  def render_markdown(nil, _opts), do: raw("")
  def render_markdown("", _opts), do: raw("")

  def render_markdown(body, opts) when is_binary(body) do
    context_id = Keyword.get(opts, :context_id)
    inline_links = Keyword.get(opts, :inline_links) || []
    embeds = if context_id, do: Dran.Brain.fetch_embeds(body, context_id), else: %{}

    html =
      case MDEx.to_html(body, @markdown_options) do
        {:ok, html} -> html
        {:error, _} -> escape_html(body)
      end

    html
    |> apply_inline_links(inline_links, context_id)
    |> rewrite_embeds(embeds)
    |> raw()
  end

  # Insert inline links into the rendered HTML.
  # Each link is %{"text" => "...", "slug" => "..."}.
  # We find the first occurrence of text inside <p> tags that isn't already
  # inside an <a> tag, and wrap it in a link to the target page.
  @type_routes %{
    "note" => "notes",
    "concept" => "concepts",
    "entity" => "entities",
    "reference" => "references",
    "goal" => "goals",
    "plan" => "plans",
    "todo" => "todos",
    "artifact" => "artifacts",
    "comparison" => "comparisons"
  }

  defp apply_inline_links(html, links, context_id)
       when is_list(links) and links != [] do
    # Resolve slugs to page types for correct URLs
    slug_to_path =
      if context_id do
        links
        |> Enum.map(fn %{"slug" => slug} -> slug end)
        |> Enum.uniq()
        |> Enum.reduce(%{}, fn slug, acc ->
          case Dran.Brain.get_page_by_slug(slug, context_id) do
            nil -> acc
            page -> Map.put(acc, slug, "/#{Map.get(@type_routes, page.page_type, "notes")}/#{slug}")
          end
        end)
      else
        %{}
      end

    Enum.reduce(links, html, fn link, acc ->
      case link do
        %{"text" => text, "slug" => slug} when is_binary(text) and is_binary(slug) ->
          path = Map.get(slug_to_path, slug, "/#{slug}")
          insert_link(acc, text, path)

        _ ->
          acc
      end
    end)
  end

  defp apply_inline_links(html, _, _), do: html

  defp insert_link(html, text, path) do
    escaped = Regex.escape(text)

    # Match text that is NOT inside an existing <a>...</a> tag.
    # Only replace the first occurrence to avoid double-linking.
    pattern = ~r/(<(?:p|li|h[1-6]|td|blockquote)[^>]*>(?:(?!<a\b).)*?)(#{escaped})/s

    if Regex.match?(pattern, html) do
      Regex.replace(pattern, html, fn _full, prefix, matched_text ->
        "#{prefix}<a href=\"#{path}\" class=\"inline-link\">#{matched_text}</a>"
      end,
        global: false
      )
    else
      html
    end
  end

  # Rewrite ![[slug|display]] embeds into media elements.
  # MDEx leaves them as literal text in paragraphs.
  defp rewrite_embeds(html, embeds) when embeds == %{}, do: html

  defp rewrite_embeds(html, embeds) do
    Regex.replace(
      ~r/!\[\[([^|\]]+)(?:\|([^\]]+))?\]\]/,
      html,
      fn _match, slug, display ->
        slug = String.trim(slug)
        display = if display == "", do: slug, else: display

        case Map.get(embeds, slug) do
          nil ->
            # Unresolved embed — render as a broken-link placeholder.
            ~s|<span class="embed-broken" title="embed not found: #{escape_html(slug)}">#{escape_html(display)}</span>|

          page ->
            render_embed(page, display)
        end
      end
    )
  end

  defp render_embed(%Dran.Brain.Page{} = page, display) do
    meta = page.meta || %{}
    mime = Map.get(meta, "mime_type") || ""
    src = escape_html(Map.get(meta, "storage_path") || "")
    safe_mime = escape_html(mime)

    cond do
      String.starts_with?(mime, "image/") ->
        ~s|<figure class="embed embed-image"><img src="#{src}" alt="#{escape_html(display)}" loading="lazy"/><figcaption>#{escape_html(display)}</figcaption></figure>|

      String.starts_with?(mime, "video/") ->
        ~s|<figure class="embed embed-video"><video controls preload="metadata"><source src="#{src}" type="#{safe_mime}"/></video><figcaption>#{escape_html(display)}</figcaption></figure>|

      String.starts_with?(mime, "audio/") ->
        ~s|<figure class="embed embed-audio"><audio controls preload="metadata"><source src="#{src}" type="#{safe_mime}"/></audio><figcaption>#{escape_html(display)}</figcaption></figure>|

      mime == "application/pdf" ->
        ~s|<figure class="embed embed-pdf"><embed src="#{src}" type="application/pdf"/><figcaption><a href="#{src}" target="_blank" rel="noopener">#{escape_html(display)}</a></figcaption></figure>|

      true ->
        ~s|<a href="#{src}" class="embed embed-file" target="_blank" rel="noopener">#{escape_html(display)}</a>|
    end
  end

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
