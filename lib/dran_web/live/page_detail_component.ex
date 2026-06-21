defmodule DranWeb.PageDetailComponent do
  @moduledoc """
  A shared component for rendering a single page's detail view
  (title, type, tags, updated date, and body) used by the
  page-type LiveViews.
  """
  use DranWeb, :html

  attr :page, :map, default: nil
  attr :label, :string, default: "Page"

  def page_detail(assigns) do
    ~H"""
    <%= if @page do %>
      <div class="space-y-3 max-w-3xl">
        <h2 class="text-xl font-semibold">{@page.title}</h2>
        <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/60">
          <span>{@label}</span>
          <span>·</span>
          <span>{format_date(@page.updated_at)}</span>
        </div>
        <div :if={@page.tags != []} class="flex flex-wrap gap-1">
          <span
            :for={tag <- @page.tags}
            class="px-2 py-0.5 text-xs rounded bg-base-200 text-base-content/70"
          >
            {tag}
          </span>
        </div>
        <div class="whitespace-pre-wrap text-base-content/90">{@page.body}</div>
      </div>
    <% else %>
      <p class="text-base-content/60">{@label} not found.</p>
    <% end %>
    """
  end

  defp format_date(%{updated_at: updated_at}), do: format_date(updated_at)

  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_date(_), do: ""
end
