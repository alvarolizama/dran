defmodule DranWeb.PageListComponents do
  @moduledoc """
  Shared function components for page list views.
  """

  use Phoenix.Component
  import DranWeb.CoreComponents, only: [icon: 1]

  alias DranWeb.PageTypes

  attr :pages, :list, required: true
  attr :page_type, :string, default: nil
  attr :context_slug, :string, default: "personal"

  def page_list(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">
          {if @page_type, do: PageTypes.plural(@page_type), else: "All Pages"}
        </h1>
        <div class="flex gap-2">
          <.link
            :if={@page_type}
            navigate={"/collections/new?type=#{@page_type}&title=All #{PageTypes.plural(@page_type)}"}
            class="btn btn-ghost btn-sm"
            title="Save as smart collection"
          >
            <.icon name="hero-funnel" class="w-4 h-4" /> Save as Smart Collection
          </.link>
          <.link navigate={"/#{PageTypes.path(@page_type)}/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> New
          </.link>
        </div>
      </div>

      <div :if={@pages == []} class="text-center py-16 space-y-4">
        <div class="flex justify-center">
          <div class="size-16 rounded-full bg-base-200 flex items-center justify-center">
            <.icon name="hero-document-plus" class="size-8 text-base-content/40" />
          </div>
        </div>
        <div class="space-y-1">
          <h3 class="text-lg font-semibold text-base-content/60">No pages yet</h3>
          <p class="text-sm text-base-content/40">Get started by creating your first page.</p>
        </div>
        <.link
          navigate={"/#{PageTypes.path(@page_type)}/new"}
          class="btn btn-primary btn-sm transition-colors active:scale-95"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Create Page
        </.link>
      </div>

      <div class="space-y-2">
        <div
          :for={page <- @pages}
          class="p-3 rounded-lg border border-base-300 hover:bg-base-200 cursor-pointer"
          phx-click="show_page"
          phx-value-slug={page.slug}
        >
          <div class="flex items-center gap-2">
            <.icon name={PageTypes.icon(page.page_type)} class="w-4 h-4 text-base-content/40" />
            <span class="font-medium">{page.title}</span>
          </div>
          <p :if={page.summary} class="text-sm text-base-content/60 mt-1">{page.summary}</p>
          <div class="flex gap-1 mt-2">
            <.link
              :for={tag <- Enum.take(page.tags || [], 5)}
              navigate={"/tags/#{URI.encode_www_form(tag)}"}
              class="px-1.5 py-0.5 text-xs rounded bg-base-300 hover:bg-base-200 transition"
            >
              {tag}
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
