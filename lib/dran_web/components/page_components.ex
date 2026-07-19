defmodule DranWeb.PageComponents do
  @moduledoc """
  Shared function components for page detail views.
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext
  import Phoenix.HTML, only: [raw: 1]
  import DranWeb.CoreComponents, only: [icon: 1]

  alias Dran.Brain
  alias Dran.Brain.Page
  alias DranWeb.PageTypes
  alias Phoenix.LiveView.JS

  attr :page, :map, required: true
  attr :relations, :map, default: %{outbound: [], inbound: []}
  attr :versions, :list, default: []
  attr :logs, :list, default: []
  attr :compare_version, :map, default: nil
  attr :context_slug, :string, default: "personal"
  attr :rendered_body, :any, default: nil

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

    # Use pre-computed rendered_body if provided (avoids re-parsing markdown on every render).
    # Otherwise, fall back to rendering inline (backward-compatible with callers that don't pass rendered_body).
    rendered_body =
      Map.get(assigns, :rendered_body) ||
        render_markdown(assigns.page.body,
          context_id: assigns.page.context_id,
          inline_links: inline_links
        )

    assigns = assign(assigns, :inline_links, inline_links)
    assigns = assign(assigns, :rendered_body, rendered_body)

    tag_map =
      case assigns.page.tags do
        nil -> %{}
        [] -> %{}
        tags -> Brain.get_pages_by_slugs(tags, assigns.page.context_id)
      end

    assigns = assign(assigns, :tag_map, tag_map)

    ~H"""
    <div class="h-full overflow-y-auto">
      <div class="p-6 space-y-6">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0 flex-1">
            <%!-- Metadata bar: type badge · slug · dates — all in one row --%>
            <div class="flex flex-wrap items-center gap-2 mb-2 text-caption">
              <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-primary/10 text-primary">
                <.icon name={PageTypes.icon(@page.page_type)} class="size-3" />
                {PageTypes.label(@page.page_type)}
              </span>
              <span class="text-base-content/30">·</span>
              <code class="font-mono text-caption text-base-content/60">{@page.slug}</code>
              <span class="text-base-content/30">·</span>
              <span class="inline-flex items-center gap-1 text-caption text-base-content/50">
                <.icon name="hero-calendar" class="size-3" />
                {gettext("Created")} {format_date(@page.inserted_at)}
              </span>
              <span class="text-base-content/30">·</span>
              <span class="inline-flex items-center gap-1 text-caption text-base-content/50">
                <.icon name="hero-clock" class="size-3" />
                {gettext("Updated")} {format_date(@page.updated_at)}
              </span>
            </div>
            <h1 class="text-title break-words">{@page.title}</h1>
            <div class="flex flex-wrap gap-2 mt-2">
              <.link
                :for={tag <- @page.tags || []}
                navigate={"/tags/#{URI.encode_www_form(tag)}"}
                class={[
                  "px-2 py-0.5 text-xs rounded transition",
                  "tag-link",
                  Map.has_key?(@tag_map, tag) && "tag-link-exists",
                  not Map.has_key?(@tag_map, tag) && "tag-link-missing"
                ]}
              >
                {tag}
              </.link>
            </div>
          </div>
          <div class="flex gap-2 shrink-0">
            {render_slot(@actions)}
            <button
              phx-click="delete_page"
              data-confirm={gettext("Are you sure? This cannot be undone.")}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
            </button>
            <button
              :if={Dran.Firecrawl.enabled?()}
              phx-click="enrich_page"
              phx-value-slug={@page.slug}
              class="btn btn-ghost btn-sm"
              title={gettext("Search the web and enrich this page with new content")}
            >
              <.icon name="hero-sparkles" class="size-4" /> {gettext("Enrich")}
            </button>
          </div>
        </div>

        <.detail_tabs_bar />

        <%!-- ── Tab: Content (default visible) ─────────────────────────────── --%>
        <div id="detail-panel-content" data-detail-panel class="space-y-6">
          {render_slot(@tabs)}

          <div :if={@tabs == []} class="prose prose-base dark:prose-invert">
            {@rendered_body}
          </div>

          <div class="border-t border-base-300 pt-4">
            <.backlinks_section relations={@relations} />
          </div>

          <div :if={@tabs == []} class="border-t border-base-300 pt-4">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-2">
              {gettext("Changelog")}
            </h3>
            <div class="space-y-1">
              <div
                :for={version <- @versions}
                class="surface-2 px-3 py-2 text-sm text-base-content/60 transition hover:bg-base-200/50"
              >
                {gettext("v%{version} — %{date} by %{author}",
                  version: version.version,
                  date: format_date(version.inserted_at),
                  author: version.changed_by || gettext("system")
                )}
              </div>
              <p :if={@versions == []} class="text-caption text-base-content/40">
                {gettext("No version history yet.")}
              </p>
            </div>
          </div>

          <div :if={@compare_version} class="border-t border-base-300 pt-4">
            <DranWeb.VersionDiffComponent.diff
              old_version={@compare_version}
              new_version={@page}
            />
          </div>
        </div>

        <%!-- ── Tab: Metadata ─────────────────────────────────────────────── --%>
        <div
          id="detail-panel-metadata"
          data-detail-panel
          class="hidden space-y-3"
        >
          <h3 class="text-caption font-semibold text-base-content/40 uppercase tracking-wider">
            {gettext("Metadata")}
          </h3>
          <div class="surface-2 rounded-lg overflow-hidden">
            <div class="divide-y divide-base-300/50">
              <div class="flex justify-between gap-2 px-4 py-2.5 text-sm">
                <span class="text-base-content/60">{gettext("Type")}</span>
                <span class="font-medium">{@page.page_type}</span>
              </div>
              <div class="flex justify-between gap-2 px-4 py-2.5 text-sm">
                <span class="text-base-content/60">{gettext("Version")}</span>
                <span class="font-mono">v{@page.version}</span>
              </div>
              <div class="flex justify-between gap-2 px-4 py-2.5 text-sm">
                <span class="text-base-content/60">{gettext("Owner")}</span>
                <span>{@page.owner}</span>
              </div>
              <div class="flex justify-between gap-2 px-4 py-2.5 text-sm">
                <span class="text-base-content/60">{gettext("Created by")}</span>
                <span>{@page.created_by}</span>
              </div>
              <div :if={@page.updated_by} class="flex justify-between gap-2 px-4 py-2.5 text-sm">
                <span class="text-base-content/60">{gettext("Updated by")}</span>
                <span>{@page.updated_by}</span>
              </div>
              <div
                :for={{key, value} <- Enum.reject(@page.meta || %{}, fn {k, _v} -> k == "inline_links" end)}
                class="flex justify-between gap-2 px-4 py-2.5 text-sm break-words"
              >
                <span class="text-base-content/60">{format_meta_key(key)}</span>
                <span class="text-right">{format_meta_value(value)}</span>
              </div>
            </div>
          </div>
          <p :if={map_size(@page.meta || %{}) == 0} class="text-caption text-base-content/40">
            {gettext("No additional metadata.")}
          </p>
        </div>

        <%!-- ── Tab: Relations ────────────────────────────────────────────── --%>
        <div
          id="detail-panel-relations"
          data-detail-panel
          class="hidden space-y-4"
        >
          <h3 class="text-caption font-semibold text-base-content/40 uppercase tracking-wider">
            {gettext("Relations")}
          </h3>

          <div :if={length(@relations.outbound) > 0} class="space-y-1">
            <div class="text-caption text-base-content/40 mb-1 inline-flex items-center gap-1">
              <.icon name="hero-arrow-right" class="size-3" />
              {gettext("Outbound")} ({length(@relations.outbound)})
            </div>
            <div :for={rel <- @relations.outbound} class="surface-2 px-3 py-2 transition">
              <.link
                navigate={PageTypes.page_show_path(rel.target)}
                class="text-sm hover:text-primary transition"
              >
                {rel.target.title}
              </.link>
              <div class="mt-0.5">
                <span class={"text-[11px] font-medium px-1.5 py-0.5 rounded-full #{relation_type_badge_class(rel.relation_type)}"}>
                  {rel.relation_type}
                </span>
              </div>
            </div>
          </div>

          <div :if={length(@relations.inbound) > 0} class="space-y-1">
            <div class="text-caption text-base-content/40 mb-1 inline-flex items-center gap-1">
              <.icon name="hero-arrow-left" class="size-3" />
              {gettext("Inbound")} ({length(@relations.inbound)})
            </div>
            <div :for={rel <- @relations.inbound} class="surface-2 px-3 py-2 transition">
              <.link
                navigate={PageTypes.page_show_path(rel.source)}
                class="text-sm hover:text-primary transition"
              >
                {rel.source.title}
              </.link>
              <div class="mt-0.5">
                <span class={"text-[11px] font-medium px-1.5 py-0.5 rounded-full #{relation_type_badge_class(rel.relation_type)}"}>
                  {rel.relation_type}
                </span>
              </div>
            </div>
          </div>

          <p
            :if={@relations.outbound == [] and @relations.inbound == []}
            class="text-caption text-base-content/40"
          >
            {gettext("No relations yet")}
          </p>
        </div>

        <%!-- ── Tab: Versions ─────────────────────────────────────────────── --%>
        <div
          id="detail-panel-versions"
          data-detail-panel
          class="hidden space-y-4"
        >
          <h3 class="text-caption font-semibold text-base-content/40 uppercase tracking-wider">
            {gettext("Versions")}
          </h3>
          <div :if={@compare_version} class="surface-2 rounded-lg p-3 mb-2">
            <div class="flex items-center justify-between mb-2">
              <span class="text-sm text-base-content/60">
                {gettext("Comparing v%{version} with current", version: @compare_version.version)}
              </span>
              <button phx-click="clear_compare" class="btn btn-ghost btn-xs">
                <.icon name="hero-x-mark" class="size-3" /> {gettext("Clear")}
              </button>
            </div>
            <DranWeb.VersionDiffComponent.diff
              old_version={@compare_version}
              new_version={@page}
            />
          </div>
          <div class="space-y-1">
            <div
              :for={version <- @versions}
              class="surface-2 px-3 py-2 flex items-center justify-between gap-2 transition hover:bg-base-200/50"
            >
              <span class="text-sm text-base-content/60">
                <span class="font-mono">v{version.version}</span>
                <span class="text-base-content/30 mx-1">·</span>
                {format_date(version.inserted_at)}
              </span>
              <button
                phx-click="compare_version"
                phx-value-version={version.version}
                class="btn btn-ghost btn-xs"
              >
                {gettext("Compare")}
              </button>
            </div>
            <p :if={@versions == []} class="text-caption text-base-content/40">
              {gettext("No version history yet.")}
            </p>
          </div>
        </div>

        <%!-- ── Tab: Activity ────────────────────────────────────────────── --%>
        <div
          id="detail-panel-activity"
          data-detail-panel
          class="hidden space-y-4"
        >
          <h3 class="text-caption font-semibold text-base-content/40 uppercase tracking-wider">
            {gettext("Activity")}
          </h3>
          <div class="space-y-1">
            <div :for={log <- @logs} class="text-xs text-base-content/60">
              <span class="font-mono">{log.action}</span> — {format_date(log.inserted_at)}
            </div>
            <p :if={@logs == []} class="text-xs text-base-content/40">
              {gettext("No activity recorded.")}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the sub-tab bar for the page detail view: Content, Metadata,
  Relations, Versions, Activity. Tab switching is handled entirely
  client-side via Phoenix LiveView JS commands (no server state, no
  router changes). Default visible tab is "content".
  """
  def detail_tabs_bar(assigns) do
    tabs = [
      {"content", gettext("Content")},
      {"metadata", gettext("Metadata")},
      {"relations", gettext("Relations")},
      {"versions", gettext("Versions")},
      {"activity", gettext("Activity")}
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <div class="border-b border-base-300">
      <nav class="flex gap-1" role="tablist" aria-label={gettext("Page sections")}>
        <button
          :for={{tab, label} <- @tabs}
          id={"detail-tab-#{tab}"}
          data-detail-tab
          data-detail-tab-key={tab}
          phx-click={switch_detail_tab(tab)}
          role="tab"
          aria-selected={tab == "content"}
          data-testid={"detail-tab-#{tab}"}
          class={[
            "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
            tab == "content" && "border-primary text-primary",
            tab != "content" && "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
          ]}
        >
          {label}
        </button>
      </nav>
    </div>
    """
  end

  @doc """
  JS command that switches the active detail sub-tab client-side.

  Hides every `[data-detail-panel]`, shows only the target panel, and
  resets the active style on every `[data-detail-tab]` before applying
  the active style to the clicked one. No server round-trip required.
  """
  def switch_detail_tab(js \\ %JS{}, tab) do
    js
    |> JS.hide(to: "[data-detail-panel]")
    |> JS.remove_class(
      "border-primary text-primary",
      to: "[data-detail-tab]"
    )
    |> JS.add_class(
      "border-transparent text-base-content/60",
      to: "[data-detail-tab]"
    )
    |> JS.show(to: "#detail-panel-#{tab}")
    |> JS.remove_class(
      "border-transparent text-base-content/60",
      to: "#detail-tab-#{tab}"
    )
    |> JS.add_class("border-primary text-primary", to: "#detail-tab-#{tab}")
    |> JS.set_attribute({"aria-selected", "false"}, to: "[data-detail-tab]")
    |> JS.set_attribute({"aria-selected", "true"}, to: "#detail-tab-#{tab}")
  end

  @doc """
  Collapsible "Linked from (N)" section showing inbound backlinks.

  Renders in the main content area below the page body. Each backlink shows
  the source page title (as a link) and a small relation-type badge.
  Includes an empty state when there are no backlinks.
  """
  attr :relations, :map, default: %{outbound: [], inbound: []}

  def backlinks_section(assigns) do
    inbound = Map.get(assigns.relations, :inbound, [])
    outbound = Map.get(assigns.relations, :outbound, [])
    inbound_count = length(inbound)
    outbound_count = length(outbound)

    assigns =
      assigns
      |> assign(:inbound, inbound)
      |> assign(:outbound, outbound)
      |> assign(:inbound_count, inbound_count)
      |> assign(:outbound_count, outbound_count)

    ~H"""
    <details class="group" open={@inbound_count > 0}>
      <summary class="flex items-center gap-2 cursor-pointer select-none mb-3">
        <.icon
          name="hero-chevron-right"
          class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
        />
        <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
          {gettext("Linked from")}
          <span class="ml-1 text-base-content/40">({@inbound_count})</span>
        </h3>
      </summary>

      <div :if={@inbound_count > 0} class="space-y-2 ml-6">
        <div
          :for={rel <- @inbound}
          class="surface-2 px-3 py-2 flex items-center justify-between gap-2 transition"
        >
          <.link
            navigate={PageTypes.page_show_path(rel.source)}
            class="text-sm hover:text-primary transition min-w-0 truncate"
          >
            {rel.source.title}
          </.link>
          <span class={"shrink-0 text-[11px] font-medium px-1.5 py-0.5 rounded-full #{relation_type_badge_class(rel.relation_type)}"}>
            {rel.relation_type}
          </span>
        </div>
      </div>

      <p :if={@inbound_count == 0} class="text-caption text-base-content/40 ml-6">
        {gettext("No backlinks yet")}
      </p>
    </details>

    <details :if={@outbound_count > 0} class="group mt-4">
      <summary class="flex items-center gap-2 cursor-pointer select-none mb-3">
        <.icon
          name="hero-chevron-right"
          class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
        />
        <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
          {gettext("Links to")}
          <span class="ml-1 text-base-content/40">({@outbound_count})</span>
        </h3>
      </summary>

      <div class="space-y-2 ml-6">
        <div
          :for={rel <- @outbound}
          class="surface-2 px-3 py-2 flex items-center justify-between gap-2 transition"
        >
          <.link
            navigate={PageTypes.page_show_path(rel.target)}
            class="text-sm hover:text-primary transition min-w-0 truncate"
          >
            {rel.target.title}
          </.link>
          <span class={"shrink-0 text-[11px] font-medium px-1.5 py-0.5 rounded-full #{relation_type_badge_class(rel.relation_type)}"}>
            {rel.relation_type}
          </span>
        </div>
      </div>
    </details>
    """
  end

  @doc """
  Returns a Tailwind badge class for a relation type.
  """
  def relation_type_badge_class(type) when is_binary(type) do
    case type do
      "semantic" -> "bg-primary/10 text-primary"
      "embeds" -> "bg-accent/10 text-accent"
      "related" -> "bg-base-content/10 text-base-content/60"
      "part_of" -> "bg-success/10 text-success"
      "supersedes" -> "bg-warning/10 text-warning"
      "contradicts" -> "bg-error/10 text-error"
      _ -> "bg-base-content/10 text-base-content/60"
    end
  end

  def relation_type_badge_class(_), do: "bg-base-content/10 text-base-content/60"

  @doc """
  Renders a standard tab bar with Content + Graph tabs (plus any extras).
  Clicking a tab fires `switch_tab` with `phx-value-tab`.
  """
  attr :tabs, :list, required: true, doc: "list of {key, label} tuples"
  attr :active_tab, :string, required: true

  def tabs_bar(assigns) do
    ~H"""
    <div class="mb-4">
      <div class="inline-flex rounded-lg bg-base-200 p-1">
        <button
          :for={{tab, label} <- @tabs}
          phx-click="switch_tab"
          phx-value-tab={tab}
          data-testid={"tab-#{tab}"}
          class={[
            "px-3 py-1.5 rounded-md text-sm transition",
            @active_tab == tab && "bg-base-100 shadow-sm font-medium",
            @active_tab != tab && "text-base-content/60 hover:text-base-content"
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
        {gettext("Scroll to zoom · Drag the background to pan · Drag a node to reposition")}
      </div>
    </div>
    """
  end

  # ── Helpers ──

  defdelegate type_icon(type), to: DranWeb.PageTypes, as: :icon
  defdelegate type_label(type), to: DranWeb.PageTypes, as: :label
  defdelegate type_plural(type), to: DranWeb.PageTypes, as: :plural
  defdelegate type_path(type), to: DranWeb.PageTypes, as: :path
  defdelegate page_show_path(page), to: DranWeb.PageTypes

  def tag_page_exists?(tag, context_id) when is_binary(tag) and is_binary(context_id) do
    Dran.Brain.get_page_by_slug(tag, context_id) != nil
  end

  def tag_page_exists?(_tag, _context_id), do: false

  def tag_link_path(tag, context_id, tag_map \\ nil)

  def tag_link_path(tag, _context_id, tag_map) when is_binary(tag) and is_map(tag_map) do
    case Map.get(tag_map, tag) do
      nil ->
        "/search?q=#{URI.encode_www_form(tag)}"

      page_type ->
        "/#{PageTypes.path(page_type)}/#{tag}"
    end
  end

  def tag_link_path(tag, context_id, nil) when is_binary(tag) and is_binary(context_id) do
    case Dran.Brain.get_page_by_slug(tag, context_id) do
      %Page{page_type: type, slug: slug} ->
        "/#{PageTypes.path(type)}/#{slug}"

      nil ->
        "/search?q=#{URI.encode_www_form(tag)}"
    end
  end

  def tag_link_path(tag, _context_id, _tag_map), do: "/search?q=#{URI.encode_www_form(tag)}"

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
  those into proper internal links using `PageTypes.page_show_path/1`.

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

  defp apply_inline_links(html, links, context_id)
       when is_list(links) and links != [] do
    # Resolve slugs to page types for correct URLs (batched to avoid N+1)
    slug_to_path =
      if context_id do
        slugs =
          links
          |> Enum.map(fn %{"slug" => slug} -> slug end)
          |> Enum.uniq()

        slug_types = Dran.Brain.get_pages_by_slugs(slugs, context_id)

        Enum.reduce(slugs, %{}, fn slug, acc ->
          case Map.get(slug_types, slug) do
            nil -> acc
            page_type -> Map.put(acc, slug, "/#{PageTypes.path(page_type)}/#{slug}")
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
      Regex.replace(
        pattern,
        html,
        fn _full, prefix, matched_text ->
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
