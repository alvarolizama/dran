defmodule DranWeb.PageListComponents do
  @moduledoc """
  Shared function components for page list views.
  """

  use Phoenix.Component
  import DranWeb.CoreComponents, only: [icon: 1]
  import DranWeb.PageComponents, only: [type_icon: 1, type_path: 1, type_plural: 1]

  attr :pages, :list, required: true
  attr :page_type, :string, default: nil
  attr :context_slug, :string, default: "personal"

  def page_list(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">
          {if @page_type, do: type_plural(@page_type), else: "All Pages"}
        </h1>
        <.link navigate={"/#{type_path(@page_type)}/new"} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> New
        </.link>
      </div>

      <div :if={@pages == []} class="text-center py-12 text-base-content/40">
        No pages yet. Click "New" to create one.
      </div>

      <div class="space-y-2">
        <div
          :for={page <- @pages}
          class="p-3 rounded-lg border border-base-300 hover:bg-base-200 cursor-pointer"
          phx-click="show_page"
          phx-value-slug={page.slug}
        >
          <div class="flex items-center gap-2">
            <.icon name={type_icon(page.page_type)} class="w-4 h-4 text-base-content/40" />
            <span class="font-medium">{page.title}</span>
          </div>
          <p :if={page.summary} class="text-sm text-base-content/60 mt-1">{page.summary}</p>
          <div class="flex gap-1 mt-2">
            <span
              :for={tag <- Enum.take(page.tags || [], 5)}
              class="px-1.5 py-0.5 text-xs rounded bg-base-300"
            >
              {tag}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
