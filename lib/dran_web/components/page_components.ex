defmodule DranWeb.PageComponents do
  @moduledoc """
  Shared function components for page detail views.
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext
  import Phoenix.HTML, only: [raw: 1]
  import DranWeb.CoreComponents, only: [icon: 1, input: 1]

  import DranWeb.MarkdownEditorComponents,
    only: [meta_fields: 1, tag_input: 1]

  import DranWeb.ResourceComponents, only: [markdown_body_field: 1, form_actions: 1]

  alias Dran.Knowledge
  alias Dran.Page
  alias Dran.PageRegistry
  alias DranWeb.PageTypes
  alias Phoenix.LiveView.JS

  attr :page, :map, required: true
  attr :relations, :map, default: %{outbound: [], inbound: []}
  attr :versions, :list, default: []
  attr :logs, :list, default: []
  attr :compare_version, :map, default: nil
  attr :workspace_slug, :string, default: "personal"
  attr :rendered_body, :any, default: nil
  attr :editing, :boolean, default: false

  attr :content_hidden, :boolean,
    default: false,
    doc: "hide the content panel when a server-side tab is active"

  attr :content_tab_value, :string,
    default: "overview",
    doc: "switch_tab value for the Content tab"

  attr :active_tab, :string,
    default: "content",
    doc: "server-side active tab key (e.g. \"insights\")"

  slot :actions
  slot :tabs
  slot :extra_tabs, doc: "extra server-side tabs rendered alongside Content"
  slot :extra_content, doc: "server-side tab content rendered outside the content panel"
  slot :insights, doc: "rendered inside the insights tab panel"
  slot :attributes, doc: "edit form attributes rendered at the top of the sidebar"

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
          workspace_id: assigns.page.workspace_id,
          inline_links: inline_links
        )

    assigns = assign(assigns, :inline_links, inline_links)
    assigns = assign(assigns, :rendered_body, rendered_body)

    tag_map =
      case assigns.page.tags do
        nil -> %{}
        [] -> %{}
        tags -> Knowledge.get_pages_by_slugs(tags, assigns.page.workspace_id)
      end

    assigns = assign(assigns, :tag_map, tag_map)

    ~H"""
    <div class="h-full overflow-y-auto">
      <div
        :if={@page.archived}
        class="flex items-center gap-2 px-4 py-2.5 bg-amber-500/10 border-b border-amber-500/30 text-amber-700 dark:text-amber-400 text-sm"
      >
        <.icon name="hero-archive-box" class="size-4 shrink-0" />
        <span class="font-medium">{gettext("Archived")}</span>
        <span class="text-amber-700/70 dark:text-amber-400/70">
          — {gettext("this page is hidden from lists and boards.")}
        </span>
      </div>
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
          </div>
          <div class="flex gap-2 shrink-0">
            {render_slot(@actions)}
            <button
              :if={@page.archived}
              phx-click="unarchive_page"
              class="btn btn-ghost btn-sm"
              title={gettext("Restore this page from the archive")}
            >
              <.icon name="hero-arrow-uturn-up" class="size-4" /> {gettext("Unarchive")}
            </button>
            <button
              :if={not @page.archived}
              phx-click="archive_page"
              data-confirm={gettext("Archive this page? It will be hidden from lists.")}
              class="btn btn-ghost btn-sm"
              title={gettext("Hide this page from lists without deleting it")}
            >
              <.icon name="hero-archive-box" class="size-4" /> {gettext("Archive")}
            </button>
            <button
              phx-click="toggle_pinned"
              class={[
                "btn btn-sm",
                if(@page.pinned, do: "btn-warning", else: "btn-ghost")
              ]}
              title={gettext("Pin this page in the wiki home")}
            >
              <.icon
                name={if @page.pinned, do: "hero-star-solid", else: "hero-star"}
                class={[
                  "size-4",
                  if(@page.pinned, do: "text-white", else: "text-amber-400")
                ]}
              />
              {if @page.pinned, do: gettext("Unpin"), else: gettext("Pin")}
            </button>
            <button
              phx-click="delete_page"
              data-confirm={gettext("Are you sure? This cannot be undone.")}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
            </button>
          </div>
        </div>

        <div class="border-b border-base-300">
          <nav class="flex gap-1" role="tablist" aria-label={gettext("Page sections")}>
            <button
              id="detail-tab-content"
              phx-click="switch_tab"
              phx-value-tab={@content_tab_value}
              role="tab"
              aria-selected={not @content_hidden}
              data-testid="detail-tab-content"
              class={[
                "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
                not @content_hidden && "border-primary text-primary",
                @content_hidden &&
                  "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
              ]}
            >
              {gettext("Content")}
            </button>
            {render_slot(@extra_tabs)}
            <button
              id="detail-tab-insights"
              phx-click="switch_tab"
              phx-value-tab="insights"
              role="tab"
              aria-selected={@active_tab == "insights"}
              data-testid="detail-tab-insights"
              class={[
                "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
                @active_tab == "insights" && "border-primary text-primary",
                @active_tab != "insights" &&
                  "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
              ]}
            >
              {gettext("Insights")}
            </button>
          </nav>
        </div>

        <%!-- ── Two-column layout: main content + sidebar ─────────────────── --%>
        <div class="flex flex-col lg:flex-row gap-6">
          <%!-- Main column: tabs content ────────────────────────────────── --%>
          <div class="flex-1 min-w-0 space-y-6">
            <div
              id="detail-panel-content"
              data-detail-panel
              class={["space-y-6", @content_hidden && "hidden"]}
              phx-hook="Mermaid"
            >
              {render_slot(@tabs)}

              <div
                :if={@tabs == [] and not @content_hidden}
                class="prose prose-base dark:prose-invert"
              >
                {@rendered_body}
              </div>

              <div :if={@compare_version} class="border-t border-base-300 pt-4">
                <DranWeb.VersionDiffComponent.diff
                  old_version={@compare_version}
                  new_version={@page}
                />
              </div>
            </div>

            {render_slot(@extra_content)}

            <%!-- ── Tab: Insights ─────────────────────────────────────────────── --%>
            <div
              id="detail-panel-insights"
              data-detail-panel
              class={["space-y-4 p-4", @active_tab != "insights" && "hidden"]}
            >
              {render_slot(@insights)}
            </div>
          </div>

          <%!-- Sidebar: attributes + metadata + backlinks + changelog + activity ──────── --%>
          <aside class="lg:w-72 xl:w-80 shrink-0 space-y-4">
            {render_slot(@attributes)}

            <%!-- Metadata collapsible ─────────────────────────────────────── % --%>
            <details class="group surface-2 rounded-lg p-4">
              <summary class="flex items-center gap-2 cursor-pointer select-none">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
                />
                <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
                  {gettext("Metadata")}
                </h3>
              </summary>
              <div class="divide-y divide-base-300/50 mt-2">
                <div class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Type")}</span>
                  <span class="font-medium">{@page.page_type}</span>
                </div>
                <div class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Version")}</span>
                  <span class="font-mono">v{@page.version}</span>
                </div>
                <div class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Created by")}</span>
                  <span>{@page.created_by}</span>
                </div>
                <div :if={@page.updated_by} class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Updated by")}</span>
                  <span>{@page.updated_by}</span>
                </div>
                <div
                  :for={
                    {key, value} <-
                      Enum.reject(@page.meta || %{}, fn {k, _v} -> k == "inline_links" end)
                  }
                  class="flex justify-between gap-2 py-2 text-sm break-words"
                >
                  <span class="text-base-content/60">{format_meta_key(key)}</span>
                  <span class="text-right">{format_meta_value(value)}</span>
                </div>
              </div>
            </details>

            <details class="group surface-2 rounded-lg p-4">
              <summary class="flex items-center gap-2 cursor-pointer select-none">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
                />
                <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
                  {gettext("Links")}
                </h3>
              </summary>
              <div class="mt-2">
                <.backlinks_section relations={@relations} />
              </div>
            </details>

            <details class="group surface-2 rounded-lg p-4">
              <summary class="flex items-center gap-2 cursor-pointer select-none">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
                />
                <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
                  {gettext("Changelog")}
                </h3>
              </summary>
              <div class="space-y-1 mt-2">
                <div
                  :for={version <- @versions}
                  class="px-3 py-2 text-sm text-base-content/60 transition hover:bg-base-200/50 rounded"
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
            </details>

            <%!-- Activity collapsible ──────────────────────────────────────── % --%>
            <details class="group surface-2 rounded-lg p-4">
              <summary class="flex items-center gap-2 cursor-pointer select-none">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
                />
                <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
                  {gettext("Activity")}
                </h3>
              </summary>
              <div class="space-y-1 mt-2">
                <div :for={log <- @logs} class="text-xs text-base-content/60">
                  <span class="font-mono">{log.action}</span> — {format_date(log.inserted_at)}
                </div>
                <p :if={@logs == []} class="text-xs text-base-content/40">
                  {gettext("No activity recorded.")}
                </p>
              </div>
            </details>
          </aside>
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
      {"graph", gettext("Graph")}
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
            tab != "content" &&
              "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
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
    <div>
      <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-2">
        {gettext("Linked from")}
        <span class="ml-1 text-base-content/40">({@inbound_count})</span>
      </h3>

      <div :if={@inbound_count > 0} class="space-y-2">
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

      <p :if={@inbound_count == 0} class="text-caption text-base-content/40">
        {gettext("No backlinks yet")}
      </p>
    </div>

    <div :if={@outbound_count > 0} class="mt-4">
      <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-2">
        {gettext("Links to")}
        <span class="ml-1 text-base-content/40">({@outbound_count})</span>
      </h3>

      <div class="space-y-2">
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
    </div>
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
  Shared empty-state component: icon in a tinted rounded square, heading,
  caption, and an optional CTA slot.

  Modeled on `search_live.ex`'s `empty_hero`. Use this anywhere a list/view
  has no content to show so the empty state is consistent across the app.

  ## Example

      <.empty_state
        icon="hero-folder-plus"
        title={gettext("No smart collections yet.")}
        caption={gettext("Save a set of filters from search or any page list to create one.")}
      >
        <.link navigate="/workspace/collections/new" class="btn btn-primary btn-sm mt-4">
          <.icon name="hero-plus" class="w-4 h-4" />
          {gettext("Create your first collection")}
        </.link>
      </.empty_state>
  """
  attr :icon, :string, required: true, doc: "hero icon name, e.g. \"hero-folder-plus\""
  attr :title, :string, required: true
  attr :caption, :string, default: nil
  attr :class, :string, default: nil, doc: "extra classes for the outer wrapper"

  slot :inner_block, doc: "optional CTA / action block rendered below the caption"

  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center text-center py-16", @class]}>
      <div class="size-16 rounded-2xl bg-primary/10 flex items-center justify-center">
        <.icon name={@icon} class="size-8 text-primary" />
      </div>
      <h2 class="text-title mt-5">{@title}</h2>
      <p :if={@caption} class="text-caption mt-2 max-w-sm">
        {@caption}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders the 3D force-directed graph using the Graph3D hook.
  Replaces the old SVG 2D page_graph.

  The hook div is ALWAYS rendered (no empty-state branch): in index mode the
  LiveView starts with `nodes == []` and the hook fetches /api/graph-json via
  HTTP after the shell renders. A `nil` empty-state here would block the mount
  and the progressive fetch would never start. The "Loading graph..." overlay
  in GraphLive covers the initial load.
  """
  attr :id, :string, default: "graph-3d"
  attr :nodes, :list, required: true, doc: "list of %{id, slug, label, type, color}"
  attr :edges, :list, required: true, doc: "list of %{source_id, target_id, color}"

  attr :visible_types, :list,
    default: nil,
    doc: "types the hook may show (used by GraphLive index). nil = show all (subgraphs)"

  attr :base_path, :string,
    default: nil,
    doc:
      "URL prefix for page navigation (e.g. \"/personal/type\"). nil = root-level \"/plural/slug\""

  attr :graph_url, :string,
    default: nil,
    doc: "URL for progressive graph JSON fetch. nil = panel default (\"/graph-json\")"

  attr :class, :string, default: ""
  attr :style, :string, default: ""

  def graph_3d(assigns) do
    # Build the JSON data for the hook
    graph_data = %{nodes: assigns.nodes, edges: assigns.edges}
    assigns = assign(assigns, :graph_json, Jason.encode!(graph_data))
    # nil attribute values are omitted by HEEx, so passing nil skips the hook's
    # client-side type filter (subgraphs always render everything).
    assigns =
      assign(
        assigns,
        :visible_types_json,
        assigns.visible_types && Jason.encode!(assigns.visible_types)
      )

    ~H"""
    <div
      class={["relative overflow-hidden", @class]}
      style={"background: #0a0e27; #{@style}"}
    >
      <div
        id={@id}
        phx-hook="Graph3D"
        data-graph={@graph_json}
        data-visible-types={@visible_types_json}
        data-base-path={@base_path}
        data-graph-url={@graph_url}
        style="width: 100%; height: 100%; min-height: 300px;"
      />
    </div>
    """
  end

  # ── Helpers ──

  defdelegate type_icon(type), to: DranWeb.PageTypes, as: :icon
  defdelegate type_label(type), to: DranWeb.PageTypes, as: :label
  defdelegate type_plural(type), to: DranWeb.PageTypes, as: :plural
  defdelegate type_path(type), to: DranWeb.PageTypes, as: :path
  defdelegate page_show_path(page), to: DranWeb.PageTypes

  def tag_page_exists?(tag, workspace_id) when is_binary(tag) and is_binary(workspace_id) do
    Dran.Knowledge.get_page_by_slug(tag, workspace_id) != nil
  end

  def tag_page_exists?(_tag, _workspace_id), do: false

  def tag_link_path(tag, workspace_id, tag_map \\ nil)

  def tag_link_path(tag, _workspace_id, tag_map) when is_binary(tag) and is_map(tag_map) do
    case Map.get(tag_map, tag) do
      nil ->
        "/search?q=#{URI.encode_www_form(tag)}"

      page_type ->
        "/#{PageTypes.path(page_type)}/#{tag}"
    end
  end

  def tag_link_path(tag, workspace_id, nil) when is_binary(tag) and is_binary(workspace_id) do
    case Dran.Knowledge.get_page_by_slug(tag, workspace_id) do
      %Page{page_type: type, slug: slug} ->
        "/#{PageTypes.path(type)}/#{slug}"

      nil ->
        "/search?q=#{URI.encode_www_form(tag)}"
    end
  end

  def tag_link_path(tag, _workspace_id, _tag_map),
    do: "/search?q=#{URI.encode_www_form(tag)}"

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
      add_tag_attributes: %{"a" => ["data-wikilink"], "code" => ["class"]}
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
  `<video>` tags when the slug resolves to a file page in the
  given context.

  Pass `:workspace_id` to resolve embeds; otherwise embeds render as
  literal text.
  """
  def render_markdown(body, opts \\ [])

  def render_markdown(nil, _opts), do: raw("")
  def render_markdown("", _opts), do: raw("")

  def render_markdown(body, opts) when is_binary(body) do
    workspace_id = Keyword.get(opts, :workspace_id)
    inline_links = Keyword.get(opts, :inline_links) || []
    embeds = if workspace_id, do: Dran.Knowledge.fetch_embeds(body, workspace_id), else: %{}

    html =
      case MDEx.to_html(body, @markdown_options) do
        {:ok, html} -> html
        {:error, _} -> escape_html(body)
      end

    html
    |> apply_inline_links(inline_links, workspace_id)
    |> rewrite_embeds(embeds)
    |> raw()
  end

  # Insert inline links into the rendered HTML.
  # Each link is %{"text" => "...", "slug" => "..."}.
  # We find the first occurrence of text inside <p> tags that isn't already
  # inside an <a> tag, and wrap it in a link to the target page.

  defp apply_inline_links(html, links, workspace_id)
       when is_list(links) and links != [] do
    # Resolve slugs to page types for correct URLs (batched to avoid N+1)
    slug_to_path =
      if workspace_id do
        slugs =
          links
          |> Enum.map(fn %{"slug" => slug} -> slug end)
          |> Enum.uniq()

        slug_types = Dran.Knowledge.get_pages_by_slugs(slugs, workspace_id)

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

  defp render_embed(%Dran.Page{} = page, display) do
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

  @doc """
  Attributes panel rendered in the sidebar — summary, tags, and meta fields.
  Used via the `<:attributes>` slot of `page_detail`.
  """
  attr :form, :any, required: true
  attr :page, :map, required: true
  attr :page_type, :string, required: true
  attr :workspace_id, :any, required: true
  attr :editor_id, :string, required: true
  attr :tag_suggestions, :list, default: nil

  def page_attributes(assigns) do
    suggestions =
      case assigns.tag_suggestions do
        nil ->
          case assigns.workspace_id do
            nil -> []
            id -> Dran.Knowledge.list_tags(id)
          end

        list ->
          list
      end

    assigns = assign(assigns, :tag_suggestions, suggestions)

    ~H"""
    <details class="group surface-2 rounded-lg p-4" open>
      <summary class="flex items-center gap-2 cursor-pointer select-none">
        <.icon
          name="hero-chevron-right"
          class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
        />
        <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
          {gettext("Attributes")}
        </h3>
      </summary>
      <div class="space-y-3 mt-2">
        <.input
          field={@form[:summary]}
          type="text"
          label={gettext("Summary")}
          placeholder={gettext("One-line description")}
          class="text-sm"
        />

        <.tag_input
          id={"#{@editor_id}-tags"}
          name="page[tags]"
          value={Phoenix.HTML.Form.input_value(@form, :tags)}
          label={gettext("Tags")}
          suggestions={@tag_suggestions}
        />

        <.meta_fields page_type={@page_type} meta={@page.meta || %{}} workspace_id={@workspace_id} />
      </div>
    </details>
    """
  end

  @doc """
  Shared inline edit form for page detail views — two-column layout with the
  title + markdown editor on the left and an attributes sidebar on the right
  (summary, tags, meta fields). Replaces the per-LiveView copy-pasted form
  blocks (which also carried a manual slug input now removed).
  """
  attr :form, :any, required: true
  attr :page, :map, required: true
  attr :page_type, :string, required: true
  attr :workspace_id, :any, required: true
  attr :save_status, :string, default: "idle"
  attr :editor_id, :string, required: true
  attr :tag_suggestions, :list, default: nil

  def page_edit_form(assigns) do
    # Lazy fallback — when the LiveView doesn't pass suggestions (e.g. direct
    # ?edit=true entry), load them here so the component always works.
    suggestions =
      case assigns.tag_suggestions do
        nil ->
          case assigns.workspace_id do
            nil -> []
            id -> Dran.Knowledge.list_tags(id)
          end

        list ->
          list
      end

    assigns = assign(assigns, :tag_suggestions, suggestions)

    ~H"""
    <.form for={@form} id="page-edit-form" phx-change="validate_page">
      <div class="flex-1 min-w-0 space-y-5">
        <.input
          field={@form[:title]}
          type="text"
          label={gettext("Title")}
          placeholder={gettext("Enter a title…")}
          class="text-lg font-medium"
        />

        <.markdown_body_field
          id={@editor_id}
          body={@page.body}
          workspace_id={@workspace_id}
          autosave={true}
          save_status={@save_status}
          label={gettext("Content")}
        />
      </div>
    </.form>
    """
  end

  @doc """
  Creation form for a brand-new page — same visual language as the edit form
  (title + markdown editor + attributes) but with a proper submit flow:
  `phx-change` validates, `phx-submit` creates the page via `save_page`.
  The editor runs with `autosave={false}` (nothing exists to autosave yet);
  its hook syncs the markdown into the hidden `page[body]` field on submit.
  """
  attr :form, :any, required: true
  attr :page_type, :string, required: true
  attr :workspace_id, :any, required: true
  attr :editor_id, :string, required: true
  attr :tag_suggestions, :list, default: nil
  attr :cancel_path, :string, default: nil

  def page_new_form(assigns) do
    suggestions =
      case assigns.tag_suggestions do
        nil ->
          case assigns.workspace_id do
            nil -> []
            id -> Dran.Knowledge.list_tags(id)
          end

        list ->
          list
      end

    assigns = assign(assigns, :tag_suggestions, suggestions)

    ~H"""
    <div class="p-6 max-w-3xl">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-title">
          {new_title(@page_type)}
        </h1>
      </div>

      <.form
        for={@form}
        id={"page-new-form-#{@page_type}"}
        phx-change="validate_page"
        phx-submit="save_page"
        class="space-y-5"
      >
        <.input
          field={@form[:title]}
          type="text"
          label={gettext("Title")}
          placeholder={gettext("Enter a title…")}
          class="text-lg font-medium"
          autofocus
        />

        <.input
          field={@form[:summary]}
          type="text"
          label={gettext("Summary")}
          placeholder={gettext("One-line description")}
          class="text-sm"
        />

        <.input
          type="select"
          name="page[meta][kind]"
          value={Phoenix.HTML.Form.input_value(@form, :meta) |> meta_kind()}
          options={kind_options_for(@page_type)}
          prompt={gettext("Ninguno")}
          label={gettext("Kind")}
        />

        <div>
          <.tag_input
            id={"#{@editor_id}-new-tags"}
            name="page[tags]"
            value={Phoenix.HTML.Form.input_value(@form, :tags)}
            suggestions={@tag_suggestions}
          />
        </div>

        <.markdown_body_field
          id={@editor_id}
          body=""
          workspace_id={@workspace_id}
          autosave={false}
          label={gettext("Content")}
        />

        <.form_actions
          submit_label={new_title(@page_type)}
          submit_icon="hero-check"
          submit_testid="create-page-submit"
          cancel_path={@cancel_path}
        />
      </.form>
    </div>
    """
  end

  # Creation form title per page type — reuses the empty-state CTAs, which
  # carry correct gender per type ("Crear nota", "Añadir referencia", …).
  # Kind options for the creation-form select — registry labels, raw slugs.
  defp kind_options_for(page_type) do
    (PageRegistry.kinds(page_type) || [])
    |> Enum.map(&{PageRegistry.kind_label(&1), &1})
  end

  # Current meta.kind from the form (live params) or the persisted struct.
  defp meta_kind(%Phoenix.HTML.Form{params: %{"meta" => %{"kind" => kind}}}), do: kind
  defp meta_kind(%{params: %{"meta" => %{"kind" => kind}}}), do: kind
  defp meta_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp meta_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp meta_kind(_), do: nil

  defp new_title("note"), do: gettext("Create Note")
  defp new_title("concept"), do: gettext("Create Concept")
  defp new_title("entity"), do: gettext("Create Entity")
  defp new_title("reference"), do: gettext("Add Reference")
  defp new_title(_), do: gettext("Create Page")

  @doc "Renders a horizontal stats bar with metric badges."
  attr :stats, :list,
    required: true,
    doc: "list of %{label: string, value: string/integer, icon: string, color: string}"

  attr :class, :string, default: ""

  def stats_bar(assigns) do
    ~H"""
    <div class={"flex items-center gap-4 #{@class}"}>
      <div :for={stat <- @stats} class="flex items-center gap-1.5">
        <.icon
          :if={stat[:icon]}
          name={stat.icon}
          class={"size-4 #{Map.get(stat, :color, "text-base-content/50")}"}
        />
        <span class="text-sm font-medium tabular-nums">{stat.value}</span>
        <span class="text-xs text-base-content/50">{stat.label}</span>
      </div>
    </div>
    """
  end

  @doc "Renders a single stat badge with icon and value."
  attr :icon, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :color, :string, default: "text-base-content/50"

  def stat_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <.icon name={@icon} class={"size-4 #{@color}"} />
      <span class="text-sm font-medium tabular-nums">{@value}</span>
      <span class="text-xs text-base-content/50">{@label}</span>
    </div>
    """
  end

  @doc "Renders a standardized actions toolbar for page detail views."
  attr :page, :map, required: true, doc: "%Page{} struct"
  attr :editing, :boolean, default: false
  attr :class, :string, default: ""
  slot :extra_actions, doc: "additional action buttons"

  def page_actions(assigns) do
    ~H"""
    <div class={"flex items-center gap-2 flex-wrap #{@class}"}>
      <.link navigate={back_path(@page)} class="btn btn-ghost btn-sm">
        <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
      </.link>
      <div class="flex-1"></div>
      {render_slot(@extra_actions)}
      <div class="dropdown dropdown-end">
        <button tabindex="0" class="btn btn-ghost btn-sm btn-square">
          <.icon name="hero-ellipsis-vertical" class="size-4" />
        </button>
        <ul tabindex="0" class="dropdown-content menu p-2 shadow-lg bg-base-100 rounded-box z-10 w-48">
          <li>
            <.link navigate={"#{@page.slug}/edit"} class="text-sm"><.icon
              name="hero-pencil"
              class="size-4"
            /> {gettext("Edit")}</.link>
          </li>
          <li>
            <a class="text-sm text-error" phx-click="archive_page" phx-value-slug={@page.slug}><.icon
              name="hero-archive-box"
              class="size-4"
            /> {gettext("Archive")}</a>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp back_path(%{page_type: "note"}), do: "/notes"
  defp back_path(%{page_type: "concept"}), do: "/concepts"
  defp back_path(%{page_type: "entity"}), do: "/entities"
  defp back_path(%{page_type: "reference"}), do: "/references"
  defp back_path(_), do: "/"
end
