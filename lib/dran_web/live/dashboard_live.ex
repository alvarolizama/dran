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
      label: gettext("Knowledge"),
      items: [
        %{key: "note", label: gettext("Notes"), icon: "hero-document-text", path: "/notes"},
        %{key: "concept", label: gettext("Concepts"), icon: "hero-light-bulb", path: "/concepts"},
        %{key: "entity", label: gettext("Entities"), icon: "hero-user-group", path: "/entities"},
        %{
          key: "reference",
          label: gettext("References"),
          icon: "hero-bookmark",
          path: "/references"
        }
      ]
    },
    %{
      label: gettext("Planning"),
      items: [
        %{key: "goal", label: gettext("Goals"), icon: "hero-flag", path: "/goals"},
        %{
          key: "plan",
          label: gettext("Plans"),
          icon: "hero-clipboard-document-list",
          path: "/plans"
        },
        %{key: "todo", label: gettext("Todos"), icon: "hero-check-circle", path: "/todos"}
      ]
    },
    %{
      label: gettext("Outputs"),
      items: [
        %{key: "artifact", label: gettext("Artifacts"), icon: "hero-cube", path: "/artifacts"},
        %{
          key: "comparison",
          label: gettext("Comparisons"),
          icon: "hero-scale",
          path: "/comparisons"
        }
      ]
    }
  ]

  @kanban_columns [
    {"backlog", gettext("Backlog"), "bg-base-300 text-base-content/70"},
    {"this_week", gettext("This Week"), "bg-info/15 text-info"},
    {"today", gettext("Today"), "bg-warning/15 text-warning"},
    {"in_progress", gettext("In Progress"), "bg-accent/15 text-accent"},
    {"done", gettext("Done"), "bg-success/15 text-success"},
    {"cancelled", gettext("Cancelled"), "bg-error/15 text-error"}
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
              <h1 class="text-title">{gettext("Dashboard")}</h1>
              <p class="text-caption mt-1">
                {if @context, do: @context.name, else: gettext("No context")} · {@stats[:total_pages] ||
                  0} {gettext("pages")}
              </p>
            </div>
            <div class="flex gap-2">
              <.link
                navigate={~p"/graph"}
                class="btn btn-ghost btn-sm transition-colors active:scale-95"
              >
                <.icon name="hero-share" class="size-4" /> {gettext("Graph")}
              </.link>
              <.link
                navigate={~p"/search"}
                class="btn btn-ghost btn-sm transition-colors active:scale-95"
              >
                <.icon name="hero-magnifying-glass" class="size-4" /> {gettext("Search")}
              </.link>
            </div>
          </div>

          <%!-- Metric cards --%>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <.metric_card
              label={gettext("Total Pages")}
              value={@stats[:total_pages] || 0}
              icon="hero-document-duplicate"
              color="text-primary"
            />
            <.metric_card
              label={gettext("Relations")}
              value={@stats[:total_relations] || 0}
              icon="hero-share"
              color="text-secondary"
            />
            <.metric_card
              label={gettext("Orphans")}
              value={@stats[:orphan_count] || 0}
              icon="hero-exclamation-triangle"
              color={if (@stats[:orphan_count] || 0) > 0, do: "text-warning", else: "text-success"}
            />
            <.metric_card
              label={gettext("Broken Links")}
              value={@stats[:broken_link_count] || 0}
              icon="hero-link-slash"
              color={if (@stats[:broken_link_count] || 0) > 0, do: "text-error", else: "text-success"}
            />
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <%!-- Pages by type --%>
            <div class="lg:col-span-1 space-y-8">
              <div class="surface-2 p-5">
                <div class="flex items-center justify-between">
                  <h2 class="text-heading">{gettext("Pages by Type")}</h2>
                  <.link navigate={~p"/search"} class="text-sm text-primary hover:underline">
                    {gettext("View all")}
                  </.link>
                </div>
                <div class="space-y-2 mt-4">
                  <.type_row
                    :for={{type, count} <- sort_by_type(@stats[:by_type] || %{})}
                    type={type}
                    count={count}
                    total={@stats[:total_pages] || 1}
                  />
                </div>
              </div>

              <%!-- Todo board summary --%>
              <div
                :if={(@stats[:todos_by_status] || %{}) != %{}}
                class="surface-2 p-5"
              >
                <div class="flex items-center justify-between">
                  <h2 class="text-heading">{gettext("Todos")}</h2>
                  <.link navigate={~p"/todos"} class="text-sm text-primary hover:underline">
                    {gettext("View all")}
                  </.link>
                </div>
                <div class="space-y-1.5 mt-4">
                  <div
                    :for={{status, label, badge} <- @kanban_columns}
                    class="flex items-center justify-between"
                  >
                    <span class={"px-2.5 py-1 text-xs rounded-lg #{badge}"}>{label}</span>
                    <span class="text-sm font-semibold tabular-nums">
                      {(@stats[:todos_by_status] || %{})[status] || 0}
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Recently updated --%>
            <div class="lg:col-span-2 space-y-8">
              <div class="surface-2 p-5">
                <div class="flex items-center justify-between">
                  <h2 class="text-heading">{gettext("Recently Updated")}</h2>
                  <.link navigate={~p"/graph"} class="text-sm text-primary hover:underline">
                    {gettext("View all")}
                  </.link>
                </div>
                <div class="space-y-2 mt-4">
                  <.link
                    :for={page <- @stats[:recent] || []}
                    navigate={page_path(page)}
                    class="flex items-center gap-3 p-3 rounded-lg hover:bg-base-200 transition cursor-pointer"
                  >
                    <.icon
                      name={PageTypes.icon(page.page_type)}
                      class="size-5 text-base-content/50 shrink-0"
                    />
                    <div class="min-w-0 flex-1">
                      <div class="font-medium text-sm truncate">{page.title}</div>
                      <div class="text-caption">
                        {PageTypes.plural(page.page_type)} · {format_date(page.updated_at)}
                      </div>
                    </div>
                    <span
                      :if={page.summary}
                      class="text-caption truncate hidden md:block max-w-[200px]"
                    >
                      {page.summary}
                    </span>
                  </.link>
                  <p
                    :if={(@stats[:recent] || []) == []}
                    class="text-caption py-8 text-center"
                  >
                    <div class="flex flex-col items-center gap-3">
                      <div class="size-12 rounded-full bg-base-200 flex items-center justify-center">
                        <.icon name="hero-document" class="size-6 text-base-content/40" />
                      </div>
                      <span>{gettext("No pages yet. Create one to get started.")}</span>
                    </div>
                  </p>
                </div>
              </div>

              <%!-- Quick access grid --%>
              <div class="surface-2 p-5">
                <div class="flex items-center justify-between">
                  <h2 class="text-heading">{gettext("Quick Access")}</h2>
                </div>
                <div class="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-4">
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
       page_title: gettext("Dashboard")
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
    <div class="surface-2 lift p-5 flex items-center gap-3">
      <div class={[
        "shrink-0 size-10 rounded-lg flex items-center justify-center",
        bg_for_color(@color)
      ]}>
        <.icon name={@icon} class={["size-5", @color]} />
      </div>
      <div class="min-w-0">
        <div class="text-2xl font-bold tabular-nums">{@value}</div>
        <div class="text-caption">{@label}</div>
      </div>
    </div>
    """
  end

  defp bg_for_color("text-primary"), do: "bg-primary/10"
  defp bg_for_color("text-secondary"), do: "bg-secondary/10"
  defp bg_for_color("text-accent"), do: "bg-accent/10"
  defp bg_for_color("text-info"), do: "bg-info/10"
  defp bg_for_color("text-success"), do: "bg-success/10"
  defp bg_for_color("text-warning"), do: "bg-warning/10"
  defp bg_for_color("text-error"), do: "bg-error/10"
  defp bg_for_color(_), do: "bg-base-content/10"

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
      class="surface-2 lift p-4 flex flex-col items-center text-center gap-1 active:scale-95"
    >
      <.icon name={@icon} class="size-6 text-base-content/60" />
      <div class="text-sm font-medium">{@label}</div>
      <div class="text-caption">{gettext("%{count} pages", count: @count)}</div>
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
