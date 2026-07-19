defmodule DranWeb.PageListComponents do
  @moduledoc """
  Shared function components for page list views.
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext
  import DranWeb.CoreComponents, only: [icon: 1]

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

        "artifact" ->
          {gettext("No artifacts yet"),
           gettext("Upload files and deliverables that live in your brain."),
           gettext("Upload Artifact")}

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

        "comparison" ->
          {gettext("No comparisons yet"),
           gettext("Compare options side by side and record your verdict."),
           gettext("Create Comparison")}

        "query" ->
          {gettext("No queries yet"), gettext("Save smart queries over your knowledge graph."),
           gettext("Create Query")}

        _ ->
          {gettext("No pages yet"),
           gettext("Your second brain is empty. Capture your first page."),
           gettext("Create Page")}
      end

    %{title: title, description: description, cta: cta}
  end

  attr :pages, :list, required: true
  attr :page_type, :string, default: nil
  attr :context_slug, :string, default: "personal"

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
            navigate={"/collections/new?type=#{@page_type}&title=#{gettext("All")} #{PageTypes.plural(@page_type)}"}
            class="btn btn-ghost btn-sm"
            title={gettext("Save as smart collection")}
          >
            <.icon name="hero-funnel" class="w-4 h-4" /> {gettext("Save as Smart Collection")}
          </.link>
          <.link navigate={"/#{PageTypes.path(@page_type)}/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New")}
          </.link>
        </div>
      </div>

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
          navigate={"/#{PageTypes.path(@page_type)}/new"}
          class="btn btn-primary btn-sm transition hover:scale-105 active:scale-95"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> {empty_state(@page_type).cta}
        </.link>
      </div>

      <div class="space-y-2">
        <div
          :for={page <- @pages}
          class="surface-2 lift hover:border-primary/40 cursor-pointer p-4 rounded-xl"
          phx-click="show_page"
          phx-value-slug={page.slug}
          data-testid={"page-card-" <> page.slug}
        >
          <div class="flex items-center gap-3">
            <span class="size-8 rounded-md bg-primary/10 flex items-center justify-center">
              <.icon name={PageTypes.icon(page.page_type)} class="size-4 text-primary" />
            </span>
            <span class="font-medium leading-snug flex-1">{page.title}</span>
            <span class="text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300 text-base-content/60">
              {PageTypes.label(page.page_type)}
            </span>
          </div>
          <p :if={page.summary} class="text-sm text-base-content/60 line-clamp-2 mt-2">
            {page.summary}
          </p>
          <div class="flex items-center justify-between mt-2">
            <div class="flex gap-1">
              <.link
                :for={tag <- Enum.take(page.tags || [], 5)}
                navigate={"/tags/#{URI.encode_www_form(tag)}"}
                class="px-1.5 py-0.5 text-xs rounded bg-base-300 hover:bg-primary/10 hover:text-primary transition-colors"
              >
                {tag}
              </.link>
            </div>
            <span :if={page.updated_at} class="text-caption">
              {Calendar.strftime(page.updated_at, "%b %d")}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
