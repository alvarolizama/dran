defmodule DranWeb.DashboardLive do
  @moduledoc """
  Dashboard / landing page showing a summary of the second brain with
  metrics and quick access to the most important areas.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @nav_groups [
    %{
      label: "Knowledge",
      items: [
        %{key: "note", label: "Notes", icon: "hero-document-text", path: "/notes"},
        %{key: "concept", label: "Concepts", icon: "hero-light-bulb", path: "/concepts"},
        %{key: "entity", label: "Entities", icon: "hero-user-group", path: "/entities"},
        %{key: "reference", label: "References", icon: "hero-bookmark", path: "/references"}
      ]
    },
    %{
      label: "Planning",
      items: [
        %{key: "goal", label: "Goals", icon: "hero-flag", path: "/goals"},
        %{key: "plan", label: "Plans", icon: "hero-clipboard-document-list", path: "/plans"},
        %{key: "todo", label: "Todos", icon: "hero-check-circle", path: "/todos"}
      ]
    },
    %{
      label: "Outputs",
      items: [
        %{key: "artifact", label: "Artifacts", icon: "hero-cube", path: "/artifacts"},
        %{key: "comparison", label: "Comparisons", icon: "hero-scale", path: "/comparisons"}
      ]
    }
  ]

  @kanban_columns [
    {"backlog", "Backlog", "bg-gray-100 text-gray-600"},
    {"this_week", "This Week", "bg-blue-100 text-blue-700"},
    {"today", "Today", "bg-amber-100 text-amber-700"},
    {"in_progress", "In Progress", "bg-purple-100 text-purple-700"},
    {"done", "Done", "bg-green-100 text-green-700"},
    {"cancelled", "Cancelled", "bg-red-100 text-red-700"}
  ]

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full mx-auto p-6 space-y-8">
          <%!-- Header --%>
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-2xl font-bold">Dashboard</h1>
              <p class="text-sm text-base-content/50 mt-1">
                {if @context, do: @context.name, else: "No context"} · {@stats[:total_pages] || 0} pages
              </p>
            </div>
            <div class="flex gap-2">
              <.link navigate={~p"/graph"} class="btn btn-ghost btn-sm transition-colors active:scale-95">
                <.icon name="hero-share" class="size-4" /> Graph
              </.link>
              <.link navigate={~p"/search"} class="btn btn-ghost btn-sm transition-colors active:scale-95">
                <.icon name="hero-magnifying-glass" class="size-4" /> Search
              </.link>
            </div>
          </div>

          <%!-- Metric cards --%>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <.metric_card
              label="Total Pages"
              value={@stats[:total_pages] || 0}
              icon="hero-document-duplicate"
              color="text-primary"
            />
            <.metric_card
              label="Relations"
              value={@stats[:total_relations] || 0}
              icon="hero-share"
              color="text-secondary"
            />
            <.metric_card
              label="Orphans"
              value={@stats[:orphan_count] || 0}
              icon="hero-exclamation-triangle"
              color={if (@stats[:orphan_count] || 0) > 0, do: "text-warning", else: "text-success"}
            />
            <.metric_card
              label="Broken Links"
              value={@stats[:broken_link_count] || 0}
              icon="hero-link-slash"
              color={if (@stats[:broken_link_count] || 0) > 0, do: "text-error", else: "text-success"}
            />
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <%!-- Pages by type --%>
            <div class="lg:col-span-1 space-y-4">
              <div class="card bg-base-100 border border-base-300">
                <div class="card-body p-5">
                  <h2 class="card-title text-lg font-semibold">Pages by Type</h2>
                  <div class="space-y-2 mt-2">
                    <.type_row
                      :for={{type, count} <- sort_by_type(@stats[:by_type] || %{})}
                      type={type}
                      count={count}
                      total={@stats[:total_pages] || 1}
                    />
                  </div>
                </div>
              </div>

              <%!-- Todo board summary --%>
              <div
                :if={(@stats[:todos_by_status] || %{}) != %{}}
                class="card bg-base-100 border border-base-300"
              >
                <div class="card-body p-5">
                  <h2 class="card-title text-lg font-semibold">Todos</h2>
                  <div class="space-y-1.5 mt-2">
                    <div
                      :for={{status, label, badge} <- @kanban_columns}
                      class="flex items-center justify-between"
                    >
                      <span class={"px-2 py-0.5 text-xs rounded-full #{badge}"}>{label}</span>
                      <span class="text-sm font-semibold">
                        {(@stats[:todos_by_status] || %{})[status] || 0}
                      </span>
                    </div>
                  </div>
                  <div class="card-actions justify-end mt-3">
                    <.link navigate={~p"/todos"} class="btn btn-ghost btn-sm transition-colors active:scale-95">View board</.link>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Recently updated --%>
            <div class="lg:col-span-2 space-y-4">
              <div class="card bg-base-100 border border-base-300">
                <div class="card-body p-5">
                  <div class="flex items-center justify-between">
                    <h2 class="card-title text-lg font-semibold">Recently Updated</h2>
                    <.link navigate={~p"/graph"} class="btn btn-ghost btn-xs transition-colors active:scale-95">
                      <.icon name="hero-share" class="size-3.5" /> Graph view
                    </.link>
                  </div>
                  <div class="space-y-2 mt-2">
                    <.link
                      :for={page <- @stats[:recent] || []}
                      navigate={page_path(page)}
                      class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-200 transition-colors cursor-pointer"
                    >
                      <.icon
                        name={PageTypes.icon(page.page_type)}
                        class="size-5 text-base-content/50 shrink-0"
                      />
                      <div class="min-w-0 flex-1">
                        <div class="font-medium text-sm truncate">{page.title}</div>
                        <div class="text-xs text-base-content/40">
                          {PageTypes.plural(page.page_type)} · {format_date(page.updated_at)}
                        </div>
                      </div>
                      <span
                        :if={page.summary}
                        class="text-xs text-base-content/40 truncate hidden md:block max-w-[200px]"
                      >
                        {page.summary}
                      </span>
                    </.link>
                    <p
                      :if={(@stats[:recent] || []) == []}
                      class="text-sm text-base-content/40 py-8 text-center"
                    >
                      <div class="flex flex-col items-center gap-3">
                        <div class="size-12 rounded-full bg-base-200 flex items-center justify-center">
                          <.icon name="hero-document" class="size-6 text-base-content/40" />
                        </div>
                        <span>No pages yet. Create one to get started.</span>
                      </div>
                    </p>
                  </div>
                </div>
              </div>

              <%!-- Quick access grid --%>
              <div class="card bg-base-100 border border-base-300">
                <div class="card-body p-5">
                  <h2 class="card-title text-lg font-semibold">Quick Access</h2>
                  <div class="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-2">
                    <%= for {_group_label, items} <- @nav_groups do %>
                      <%= for item <- items do %>
                        <.quick_card
                          label={item.label}
                          icon={item.icon}
                          path={item.path}
                          count={(@stats[:by_type] || %{})[item.key] || 0}
                        />
                      <% end %>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    stats =
      if context do
        Brain.stats(context.id)
      else
        %{}
      end

    {:ok,
     assign(socket,
       context: context,
       stats: stats,
       kanban_columns: @kanban_columns,
       nav_groups: @nav_groups,
       page_title: "Dashboard"
     )}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # ── Components ──

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "text-base-content"

  defp metric_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 hover:border-primary/30 transition-colors">
      <div class="card-body p-5 flex-row items-center gap-4">
        <div class={"shrink-0 #{@color}"}>
          <.icon name={@icon} class="size-8" />
        </div>
        <div class="min-w-0">
          <div class="text-2xl font-bold">{@value}</div>
          <div class="text-xs text-base-content/50 uppercase tracking-wider">{@label}</div>
        </div>
      </div>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :count, :integer, required: true
  attr :total, :integer, required: true

  defp type_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <.link
        navigate={"/#{PageTypes.path(@type)}"}
        class="text-sm font-medium hover:text-primary transition-colors shrink-0 w-24"
      >
        {PageTypes.plural(@type)}
      </.link>
      <div class="flex-1 h-2 rounded-full bg-base-200 overflow-hidden">
        <div
          class="h-full rounded-full bg-primary transition-all"
          style={"width: #{pct(@count, @total)}%"}
        >
        </div>
      </div>
      <span class="text-sm font-semibold text-base-content/70 w-8 text-right">{@count}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :path, :string, required: true
  attr :count, :integer, default: 0

  defp quick_card(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class="card bg-base-200/50 border border-base-300 hover:border-primary/40 hover:bg-base-200 transition-colors active:scale-95"
    >
      <div class="card-body p-4 items-center text-center gap-1">
        <.icon name={@icon} class="size-6 text-base-content/60" />
        <div class="text-sm font-medium">{@label}</div>
        <div class="text-xs text-base-content/40">{@count} pages</div>
      </div>
    </.link>
    """
  end

  # ── Helpers ──

  defp pct(count, total) when total > 0, do: trunc(count / total * 100)
  defp pct(_count, _total), do: 0

  defp page_path(%Dran.Brain.Page{} = page) do
    "/#{PageTypes.path(page.page_type)}/#{page.slug}"
  end

  defp page_path(_), do: "#"

  defp sort_by_type(by_type) do
    type_order = ~w(note concept entity reference goal plan todo artifact comparison)

    by_type
    |> Enum.sort_by(fn {type, _count} ->
      idx = Enum.find_index(type_order, &(&1 == type))
      idx || 99
    end)
  end
end
