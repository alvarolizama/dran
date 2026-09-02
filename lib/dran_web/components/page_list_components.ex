defmodule DranWeb.PageListComponents do
  @moduledoc """
  Shared function components for page list views.
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext
  import DranWeb.CoreComponents, only: [icon: 1]

  alias Dran.PageRegistry
  alias DranWeb.PageTypes

  # Returns the empty-state metadata (title, description, cta) for a page type.
  # Falls back to the default "All Pages" state when `page_type` is `nil`.
  # gettext() is called with literal strings so the extractor (pot) can find them.
  defp empty_state(page_type) do
    {title, description, cta} =
      case page_type do
        "note" ->
          {gettext("No notes yet"), gettext("Capture your first thought, idea or journal entry."),
           gettext("Create Note")}

        "concept" ->
          {gettext("No concepts yet"),
           gettext("Define the ideas and techniques you keep coming back to."),
           gettext("Create Concept")}

        "entity" ->
          {gettext("No entities yet"),
           gettext("Track people, companies, tools and places that matter."),
           gettext("Create Entity")}

        "project" ->
          {gettext("No projects yet"),
           gettext("Group goals, plans and todos under a shared initiative."),
           gettext("Create Project")}

        "reference" ->
          {gettext("No references yet"),
           gettext("Save articles, papers, videos and books worth remembering."),
           gettext("Add Reference")}

        "goal" ->
          {gettext("No goals yet"),
           gettext("Set objectives with target dates and track their health."),
           gettext("Create Goal")}

        "plan" ->
          {gettext("No plans yet"), gettext("Lay out weekly, monthly or quarterly plans."),
           gettext("Create Plan")}

        "todo" ->
          {gettext("No todos yet"),
           gettext("Add actionable items and move them across the board."),
           gettext("Create Todo")}

        _ ->
          {gettext("No pages yet"),
           gettext("Your second brain is empty. Capture your first page."),
           gettext("Create Page")}
      end

    %{title: title, description: description, cta: cta}
  end

  defp archived_types(archived_pages) do
    types =
      archived_pages
      |> Enum.map(& &1.page_type)
      |> Enum.uniq()
      |> Enum.sort()

    ["all" | types]
  end

  defp filtered_archived(archived_pages, "all"), do: archived_pages

  defp filtered_archived(archived_pages, type) do
    Enum.filter(archived_pages, &(&1.page_type == type))
  end

  attr :pages, :list, required: true
  attr :archived_pages, :list, default: []
  attr :archived_filter, :string, default: "all"
  attr :page_type, :string, default: nil
  attr :workspace_slug, :string, default: "personal"
  # Pagination state (driven by the parent LiveView).
  attr :show_archived, :boolean, default: false
  attr :total_count, :integer, default: 0
  attr :total_archived, :integer, default: 0
  # Active kind filters (meta.kind slugs) — [] = unfiltered.
  attr :kind_filters, :list, default: []
  # Dropdown open state (parent owns it so patching the URL keeps it open).
  attr :kind_menu_open, :boolean, default: false

  def page_list(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-title">
          {if @page_type, do: PageTypes.plural(@page_type), else: gettext("All Pages")}
        </h1>
        <div class="flex gap-2">
          <.link
            :if={@page_type}
            navigate={
              "/#{@workspace_slug}/collections/new?type=#{@page_type}" <>
                if(@kind_filters != [],
                  do: "&kind=" <> URI.encode_www_form(Enum.join(@kind_filters, ",")),
                  else: ""
                ) <>
                "&title=" <>
                URI.encode_www_form("#{gettext("All")} #{kind_title(@kind_filters, @page_type)}")
            }
            class="btn btn-ghost btn-sm"
            title={gettext("Save as smart collection")}
          >
            <.icon name="hero-funnel" class="w-4 h-4" /> {gettext("Save as Smart Collection")}
          </.link>
          <button
            :if={@total_archived > 0}
            type="button"
            phx-click="toggle_archived"
            class={[
              "btn btn-ghost btn-sm",
              @show_archived && "btn-active border-primary/40"
            ]}
            data-testid="toggle-archived"
          >
            <.icon
              name={if @show_archived, do: "hero-document-text", else: "hero-archive-box"}
              class="w-4 h-4"
            />
            {if @show_archived,
              do: if(@page_type, do: PageTypes.plural(@page_type), else: gettext("All Pages")),
              else: gettext("Archived")} ({if @show_archived, do: @total_count, else: @total_archived})
          </button>
          <.link
            patch={"/#{@workspace_slug}/#{PageTypes.path(@page_type)}?new=true"}
            class="btn btn-primary btn-sm"
            data-testid="new-page-button"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New")}
          </.link>
        </div>
      </div>

      <div
        :if={not @show_archived and kind_options(@page_type) != []}
        class="mb-4"
        data-testid="kind-filters"
      >
        <div class="relative" id="kind-filter-root">
          <button
            type="button"
            phx-click="toggle_kind_menu"
            class={[
              "inline-flex items-center gap-2 px-3 py-1.5 text-sm rounded-lg border transition-colors",
              if(@kind_filters == [],
                do: "border-base-300 text-base-content/70 hover:border-primary/40",
                else: "border-primary bg-primary/10 text-primary font-medium"
              )
            ]}
            data-testid="kind-filter-toggle"
          >
            <.icon name="hero-funnel" class="size-3.5" />
            {gettext("Kind")}
            <span
              :if={@kind_filters != []}
              class="px-1.5 py-0.5 text-[11px] font-semibold rounded-full bg-primary/15"
            >
              {length(@kind_filters)}
            </span>
            <.icon
              name={if @kind_menu_open, do: "hero-chevron-up", else: "hero-chevron-down"}
              class="size-3.5 opacity-60"
            />
          </button>

          <div
            :if={@kind_menu_open}
            class="absolute z-20 mt-1.5 w-64 max-h-72 overflow-y-auto rounded-xl border border-base-300 bg-base-100 shadow-lg p-2"
            data-testid="kind-filter-menu"
          >
            <button
              :for={{slug, label} <- kind_options(@page_type)}
              type="button"
              phx-click="toggle_kind"
              phx-value-kind={slug || ""}
              class={[
                "w-full flex items-center gap-2.5 px-2.5 py-1.5 rounded-lg text-sm text-left transition-colors",
                if(slug in @kind_filters,
                  do: "bg-primary/10 text-primary",
                  else: "hover:bg-base-200 text-base-content/80"
                )
              ]}
              data-testid={"kind-option-#{slug || "all"}"}
            >
              <span class={[
                "size-4 rounded border flex items-center justify-center shrink-0 transition-colors",
                if(slug in @kind_filters,
                  do: "border-primary bg-primary text-primary-content",
                  else: "border-base-300"
                )
              ]}>
                <.icon :if={slug in @kind_filters} name="hero-check" class="size-3" />
              </span>
              <span class="flex-1 truncate">{label}</span>
            </button>

            <div class="border-t border-base-300 mt-1.5 pt-1.5">
              <button
                type="button"
                phx-click="clear_kinds"
                class="w-full px-2.5 py-1.5 rounded-lg text-xs text-base-content/50 hover:text-error hover:bg-error/10 transition-colors text-left"
                data-testid="kind-clear"
              >
                {gettext("Clear filters")}
              </button>
            </div>
          </div>
        </div>
      </div>

      <%= if @show_archived do %>
        <%!-- Switch ON: show only archived pages --%>
        <div class="rounded-xl border border-base-300 bg-base-200/30" data-testid="archived-section">
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
            <div class="flex items-center gap-2 text-sm font-semibold text-base-content/60">
              <.icon name="hero-archive-box" class="size-4" />
              {gettext("Archived")}
              <span class="px-1.5 py-0.5 text-xs rounded-md bg-base-300 text-base-content/60">
                {@total_archived}
              </span>
            </div>
          </div>
          <div
            :if={length(archived_types(@archived_pages)) > 1}
            class="px-4 py-2 flex flex-wrap gap-1.5"
          >
            <button
              :for={type <- archived_types(@archived_pages)}
              phx-click="filter_archived"
              phx-value-type={type}
              class={[
                "px-2 py-1 text-xs rounded-full border transition-colors",
                @archived_filter == type &&
                  "border-primary bg-primary/10 text-primary font-medium",
                @archived_filter != type &&
                  "border-base-300 text-base-content/60 hover:border-primary/40 hover:text-base-content"
              ]}
            >
              {if type == "all", do: gettext("All"), else: PageTypes.plural(type)}
            </button>
          </div>
          <div class="px-4 py-2 space-y-1">
            <div
              :for={page <- filtered_archived(@archived_pages, @archived_filter)}
              class="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-base-200 transition-colors opacity-70 hover:opacity-100"
              data-testid={"archived-page-" <> page.slug}
            >
              <.icon
                name={PageTypes.icon(page.page_type)}
                class="size-4 text-base-content/40 shrink-0"
              />
              <.link
                navigate={PageTypes.page_show_path(page, @workspace_slug)}
                class="text-sm flex-1 truncate hover:text-primary transition-colors"
              >
                {page.title}
              </.link>
              <span class="text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300 text-base-content/50">
                {PageTypes.label(page.page_type)}
              </span>
              <span :if={page.updated_at} class="text-caption shrink-0">
                {Calendar.strftime(page.updated_at, "%b %d")}
              </span>
              <button
                type="button"
                phx-click="unarchive_page"
                phx-value-slug={page.slug}
                title={gettext("Unarchive")}
                class="p-1 rounded-lg text-base-content/40 hover:text-success hover:bg-success/10 transition-colors"
                data-testid={"unarchive-btn-" <> page.slug}
              >
                <.icon name="hero-arrow-up-on-square" class="size-4" />
              </button>
            </div>
            <p
              :if={filtered_archived(@archived_pages, @archived_filter) == []}
              class="text-xs text-base-content/30 text-center py-2"
            >
              {gettext("No archived pages")}
            </p>
            <button
              :if={length(@archived_pages) < @total_archived}
              type="button"
              phx-click="load_more_archived"
              class="w-full mt-1 py-2 rounded-lg border border-dashed border-base-300 text-sm text-base-content/50 hover:text-primary hover:border-primary/40 transition-colors"
              data-testid="load-more-archived"
            >
              {gettext("Load more")} ({@total_archived - length(@archived_pages)})
            </button>
          </div>
        </div>
      <% else %>
        <%!-- Switch OFF: show only active pages --%>
        <div
          :if={@pages == []}
          data-testid="empty-state"
          class="py-20 text-center space-y-4"
        >
          <div class="flex justify-center">
            <div class="size-20 rounded-full bg-base-200 flex items-center justify-center">
              <.icon
                name={if @page_type, do: PageTypes.icon(@page_type), else: "hero-sparkles"}
                class="size-10 text-base-content/40"
              />
            </div>
          </div>
          <div class="space-y-1">
            <h3 class="text-lg font-semibold">{empty_state(@page_type).title}</h3>
            <p class="text-sm text-base-content/50">{empty_state(@page_type).description}</p>
          </div>
          <.link
            patch={"/#{@workspace_slug}/#{PageTypes.path(@page_type)}?new=true"}
            class="btn btn-primary btn-sm transition hover:scale-105 active:scale-95"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {empty_state(@page_type).cta}
          </.link>
        </div>

        <div class="space-y-2">
          <.page_card
            :for={page <- @pages}
            page={page}
            page_type={@page_type}
            workspace_slug={@workspace_slug}
          />
        </div>

        <button
          :if={length(@pages) < @total_count}
          type="button"
          phx-click="load_more"
          class="w-full mt-4 py-2 rounded-lg border border-dashed border-base-300 text-sm text-base-content/50 hover:text-primary hover:border-primary/40 transition-colors"
          data-testid="load-more"
        >
          {gettext("Load more")} ({@total_count - length(@pages)})
        </button>
      <% end %>
    </div>
    """
  end

  # ── Page card (extracted for reuse in grouped + flat layouts) ──

  # ── Kind filter options ──
  #
  # One option per registered kind of the type. `nil` slug marks the "All"
  # pseudo-option (sent as empty string to toggle_kind, which... is never
  # rendered as an option — see the menu markup: only real kinds appear;
  # "Clear filters" resets the selection). Kinds the workspace disabled
  # (disabled_page_types) don't apply here — kinds are orthogonal to the
  # type-level enable/disable switch.
  defp kind_options(nil), do: []

  defp kind_options(page_type) do
    Enum.map(PageRegistry.kinds(page_type) || [], fn slug ->
      {slug, PageRegistry.kind_label(slug)}
    end)
  end

  # Title for the "Save as Smart Collection" CTA — names the filtered subset.
  # With several kinds picked we fall back to the type plural (the collection
  # still stores the full kind list; the title is just a suggested name).
  defp kind_title([], page_type), do: PageTypes.plural(page_type)

  defp kind_title([kind], _page_type), do: PageRegistry.kind_label(kind)

  defp kind_title([_ | _], page_type), do: PageTypes.plural(page_type)

  attr :page, :map, required: true
  attr :page_type, :string, default: nil
  attr :workspace_slug, :string, default: "personal"

  defp page_card(assigns) do
    ~H"""
    <div
      class="surface-2 lift hover:border-primary/40 p-4 rounded-xl"
      data-testid={"page-card-" <> @page.slug}
    >
      <div class="flex items-center gap-3">
        <span class="size-8 rounded-md bg-primary/10 flex items-center justify-center">
          <.icon name={PageTypes.icon(@page.page_type)} class="size-4 text-primary" />
        </span>
        <.link
          navigate={PageTypes.page_show_path(@page, @workspace_slug)}
          class="font-medium leading-snug flex-1 hover:text-primary transition-colors"
        >
          {@page.title}
        </.link>
        <span class="text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300 text-base-content/60">
          {PageTypes.label(@page.page_type)}
        </span>
      </div>
      <p :if={@page.summary} class="text-sm text-base-content/60 line-clamp-2 mt-2">
        {@page.summary}
      </p>
      <div class="flex items-center justify-between mt-2">
        <div class="flex items-center gap-2">
          <div class="flex gap-1">
            <.link
              :for={tag <- Enum.take(@page.tags || [], 5)}
              navigate={"/#{@workspace_slug}/search?q=#{URI.encode_www_form(tag)}"}
              class="px-1.5 py-0.5 text-xs rounded bg-base-300 hover:bg-primary/10 hover:text-primary transition-colors"
            >
              {tag}
            </.link>
          </div>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <span :if={@page.updated_at} class="text-caption">
            {Calendar.strftime(@page.updated_at, "%b %d")}
          </span>
          <button
            type="button"
            phx-click="archive_page"
            phx-value-slug={@page.slug}
            title={gettext("Archive")}
            class="p-1 rounded-lg text-base-content/40 hover:text-error hover:bg-error/10 transition-colors"
            data-testid={"archive-btn-" <> @page.slug}
          >
            <.icon name="hero-archive-box" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end
end
