defmodule DranWeb.DashboardLive do
  @moduledoc """
  Dashboard / landing page showing a summary of the second brain with
  metrics and quick access to the most important areas.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.Settings
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @nav_groups [
    %{
      label: gettext("Top"),
      items: [
        %{key: "kanban", label: gettext("Kanban"), icon: "hero-view-columns", path: "/kanban"},
        %{
          key: "project",
          label: gettext("Projects"),
          icon: "hero-rocket-launch",
          path: "/projects"
        }
      ]
    },
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
    }
  ]

  @kanban_columns [
    {"backlog", gettext("Backlog"), "bg-base-300 text-base-content/70"},
    {"this_week", gettext("This Week"), "bg-blue-500/15 text-blue-600 dark:text-blue-400"},
    {"today", gettext("Today"), "bg-amber-500/15 text-amber-600 dark:text-amber-400"},
    {"in_progress", gettext("In Progress"),
     "bg-purple-500/15 text-purple-600 dark:text-purple-400"},
    {"done", gettext("Done"), "bg-green-500/15 text-green-600 dark:text-green-400"},
    {"cancelled", gettext("Cancelled"), "bg-red-500/15 text-red-600 dark:text-red-400"}
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
        <div class="w-full p-6 space-y-8">
          <%!-- Header --%>
          <div class="flex items-center justify-between">
            <div class="space-y-1">
              <h1 class="text-title">{greeting()}</h1>
              <p class="text-caption">
                {format_today()} · {if @context, do: @context.name, else: gettext("No context")} · {@stats[
                  :total_pages
                ] ||
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

          <%!-- Brain health --%>
          <div class="surface-2 p-5 space-y-5 rounded-2xl">
            <div class="flex items-center justify-between">
              <h2 class="text-heading">{gettext("Brain health")}</h2>
              <span :if={@brain_metrics[:contested_count] > 0} class="text-xs text-warning">
                {gettext("%{count} contested", count: @brain_metrics[:contested_count])}
              </span>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-5">
              <%!-- This week --%>
              <div class="flex items-center gap-3">
                <div class="shrink-0 size-10 rounded-lg flex items-center justify-center bg-info/10">
                  <.icon name="hero-calendar-days" class="size-5 text-info" />
                </div>
                <div class="min-w-0">
                  <div class="text-xl font-bold tabular-nums leading-tight">
                    {@brain_metrics[:pages_this_week] || 0}
                  </div>
                  <div class="text-caption">{gettext("This week")}</div>
                  <div
                    :if={
                      (@brain_metrics[:pages_this_week] || 0) !=
                        (@brain_metrics[:pages_last_week] || 0)
                    }
                    class={[
                      "text-xs font-medium mt-0.5",
                      if(
                        (@brain_metrics[:pages_this_week] || 0) >
                          (@brain_metrics[:pages_last_week] || 0),
                        do: "text-success",
                        else: "text-base-content/50"
                      )
                    ]}
                  >
                    {delta_label(
                      @brain_metrics[:pages_this_week] || 0,
                      @brain_metrics[:pages_last_week] || 0
                    )}
                  </div>
                </div>
              </div>

              <%!-- Embedding coverage --%>
              <div class="flex items-center gap-3">
                <div class="shrink-0 size-10 rounded-lg flex items-center justify-center bg-accent/10">
                  <.icon name="hero-cpu-chip" class="size-5 text-accent" />
                </div>
                <div class="min-w-0 flex-1">
                  <div class="text-xl font-bold tabular-nums leading-tight">
                    {trunc((@brain_metrics[:embedding_coverage] || 0.0) * 100)}%
                  </div>
                  <div class="text-caption">{gettext("Embedding coverage")}</div>
                  <div class="h-1 rounded-full bg-base-200 overflow-hidden mt-1.5">
                    <div
                      class={[
                        "h-full rounded-full transition-all",
                        if((@brain_metrics[:embedding_coverage] || 0.0) >= 0.9,
                          do: "bg-success",
                          else: "bg-warning"
                        )
                      ]}
                      style={"width: #{trunc((@brain_metrics[:embedding_coverage] || 0.0) * 100)}%"}
                    >
                    </div>
                  </div>
                  <div
                    :if={(@brain_metrics[:embedding_coverage] || 0.0) < 0.9}
                    class="text-xs text-warning mt-0.5"
                  >
                    {gettext("Below 90%")}
                  </div>
                </div>
              </div>

              <%!-- Relations by type --%>
              <div class="flex items-center gap-3">
                <div class="shrink-0 size-10 rounded-lg flex items-center justify-center bg-secondary/10">
                  <.icon name="hero-share" class="size-5 text-secondary" />
                </div>
                <div class="min-w-0">
                  <div class="text-xl font-bold tabular-nums leading-tight">
                    {relations_total(@brain_metrics[:relations_by_type])}
                  </div>
                  <div class="text-caption">{gettext("Relations")}</div>
                  <div class="text-xs text-base-content/60 mt-0.5">
                    {gettext("semantic: %{n}",
                      n: (@brain_metrics[:relations_by_type] || %{})["semantic"] || 0
                    )} · {gettext("related: %{n}",
                      n: (@brain_metrics[:relations_by_type] || %{})["related"] || 0
                    )} · {gettext("embeds: %{n}",
                      n: (@brain_metrics[:relations_by_type] || %{})["embeds"] || 0
                    )}
                  </div>
                </div>
              </div>

              <%!-- Agents --%>
              <div class="flex items-center gap-3">
                <div class="shrink-0 size-10 rounded-lg flex items-center justify-center bg-primary/10">
                  <.icon name="hero-user-group" class="size-5 text-primary" />
                </div>
                <div class="min-w-0">
                  <div class="text-xl font-bold tabular-nums leading-tight">
                    {(@brain_metrics[:agents] || %{})[:sessions_this_week] || 0}
                  </div>
                  <div class="text-caption">{gettext("Agents")}</div>
                  <div class="text-xs text-base-content/60 mt-0.5">
                    {gettext("%{n} tokens",
                      n: (@brain_metrics[:agents] || %{})[:tokens_this_week] || 0
                    )}
                  </div>
                </div>
              </div>
            </div>

            <%!-- Daily note CTA --%>
            <div
              :if={@daily_note_status in [:missing, :empty]}
              class="flex items-center justify-between p-3 rounded-xl bg-base-200"
            >
              <div class="flex items-center gap-2">
                <.icon name="hero-pencil-square" class="size-5 text-primary" />
                <span class="text-sm">{gettext("No daily note for today yet.")}</span>
              </div>
              <button
                phx-click="open_daily_note"
                class="btn btn-primary btn-sm transition-colors active:scale-95"
              >
                {gettext("Open today's note")}
              </button>
            </div>
            <div
              :if={@daily_note_status == :exists}
              class="flex items-center justify-between p-3 rounded-xl bg-base-200"
            >
              <div class="flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                <span class="text-sm">{gettext("Today's daily note is ready.")}</span>
              </div>
              <.link
                navigate={"/notes/daily-#{Date.to_iso8601(Date.utc_today())}"}
                class="btn btn-ghost btn-sm transition-colors active:scale-95"
              >
                {gettext("Open today's note")}
              </.link>
            </div>
          </div>

          <%!-- Communities section --%>
          <div :if={@community_summaries != []} class="mt-8">
            <h2 class="text-title mb-4">{gettext("Knowledge Communities")}</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <div
                :for={summary <- @community_summaries}
                class="surface-2 rounded-lg p-4"
              >
                <div class="flex items-center gap-2 mb-2">
                  <span class="text-xs font-mono text-primary">
                    {gettext("Community %{id}", id: summary.community_id)}
                  </span>
                  <span class="text-xs text-base-content/40">
                    {gettext("· %{count} pages", count: summary.page_count)}
                  </span>
                </div>
                <p class="text-sm text-base-content/70 line-clamp-3">{summary.summary}</p>
              </div>
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <%!-- Pages by type --%>
            <div class="lg:col-span-1 space-y-8">
              <div class="surface-2 p-5 rounded-2xl">
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
                class="surface-2 p-5 rounded-2xl"
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
              <div class="surface-2 p-5 rounded-2xl">
                <div class="flex items-center justify-between">
                  <h2 class="text-heading">{gettext("Recently Updated")}</h2>
                  <.link navigate={~p"/graph"} class="text-sm text-primary hover:underline">
                    {gettext("View all")}
                  </.link>
                </div>
                <div class="space-y-1 mt-4">
                  <.link
                    :for={page <- @stats[:recent] || []}
                    navigate={page_path(page)}
                    class="flex items-center gap-3 p-2.5 rounded-xl hover:bg-base-200 transition cursor-pointer"
                  >
                    <div class="shrink-0 size-9 rounded-lg flex items-center justify-center bg-primary/10">
                      <.icon
                        name={PageTypes.icon(page.page_type)}
                        class="size-4 text-primary"
                      />
                    </div>
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
              <div class="surface-2 p-5 rounded-2xl">
                <div class="flex items-center justify-between">
                  <h2 class="text-heading">{gettext("Quick Access")}</h2>
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 mt-4">
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

    {stats, brain_metrics, daily_note_status, community_summaries} =
      if context do
        metrics = Brain.metrics(context.id)

        daily_note_status =
          if Settings.get("daily_note_enabled") do
            compute_daily_note_status(context.id)
          else
            :disabled
          end

        community_summaries =
          try do
            Dran.Graph.CommunitySummaries.list_summaries(context.id)
          rescue
            _ -> []
          catch
            _, _ -> []
          end

        {Brain.stats(context.id), metrics, daily_note_status, community_summaries}
      else
        {%{}, %{}, :disabled, []}
      end

    {:ok,
     assign(socket,
       context: context,
       stats: stats,
       brain_metrics: brain_metrics,
       daily_note_status: daily_note_status,
       community_summaries: community_summaries,
       kanban_columns: @kanban_columns,
       nav_groups: @nav_groups,
       page_title: gettext("Dashboard")
     )}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("open_daily_note", _params, socket) do
    if socket.assigns.context do
      {:ok, _page} = Brain.ensure_daily_note(socket.assigns.context.id)
      slug = "daily-" <> Date.to_iso8601(Date.utc_today())
      {:noreply, push_navigate(socket, to: "/notes/#{slug}")}
    else
      {:noreply, socket}
    end
  end

  defp compute_daily_note_status(context_id) do
    slug = "daily-" <> Date.to_iso8601(Date.utc_today())

    case Brain.get_page_by_slug(slug, context_id) do
      nil -> :missing
      %{body: body} -> if body == "", do: :empty, else: :exists
    end
  end

  # ── Components ──

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "text-base-content"

  defp metric_card(assigns) do
    ~H"""
    <div class="surface-2 lift p-5 flex items-center gap-4 rounded-2xl">
      <div class={[
        "shrink-0 size-11 rounded-xl flex items-center justify-center",
        bg_for_color(@color)
      ]}>
        <.icon name={@icon} class={["size-5", @color]} />
      </div>
      <div class="min-w-0">
        <div class="text-2xl font-bold tabular-nums leading-tight">{@value}</div>
        <div class="text-caption mt-0.5">{@label}</div>
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
      <div class="flex-1 h-1 rounded-full bg-base-200 overflow-hidden">
        <div
          class="h-full rounded-full bg-primary transition-all"
          style={"width: #{pct(@count, @total)}%"}
        >
        </div>
      </div>
      <span class="text-sm font-semibold text-base-content/70 w-8 text-right tabular-nums">{@count}</span>
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
      class={[
        "surface-2 lift p-4 flex items-center gap-3 rounded-2xl",
        "border border-base-content/10 hover:border-primary/50",
        "transition-colors active:scale-95"
      ]}
    >
      <div class="shrink-0 size-10 rounded-xl flex items-center justify-center bg-primary/10">
        <.icon name={@icon} class="size-5 text-primary" />
      </div>
      <div class="min-w-0 flex-1">
        <div class="text-sm font-medium truncate">{@label}</div>
        <div class="text-caption">{gettext("%{count} pages", count: @count)}</div>
      </div>
      <.icon name="hero-chevron-right" class="size-4 text-base-content/30 shrink-0" />
    </.link>
    """
  end

  # ── Helpers ──

  defp greeting do
    hour = DateTime.utc_now().hour

    cond do
      hour < 6 -> gettext("Good night")
      hour < 12 -> gettext("Good morning")
      hour < 20 -> gettext("Good afternoon")
      true -> gettext("Good evening")
    end
  end

  defp format_today do
    Calendar.strftime(Date.utc_today(), "%A, %B %d, %Y")
  end

  defp pct(count, total) when total > 0, do: trunc(count / total * 100)
  defp pct(_count, _total), do: 0

  defp delta_label(this_week, last_week) do
    diff = this_week - last_week

    if diff > 0 do
      "+#{diff}"
    else
      "#{diff}"
    end
  end

  defp relations_total(relations_by_type) when is_map(relations_by_type) do
    relations_by_type
    |> Map.values()
    |> Enum.sum()
  end

  defp relations_total(_), do: 0

  defp page_path(%Dran.Brain.Page{} = page) do
    "/#{PageTypes.path(page.page_type)}/#{page.slug}"
  end

  defp page_path(_), do: "#"

  defp sort_by_type(by_type) do
    type_order = ~w(note concept entity reference goal plan todo query project)

    by_type
    |> Enum.filter(fn {type, _count} -> Map.has_key?(PageTypes.all(), type) end)
    |> Enum.sort_by(fn {type, _count} ->
      idx = Enum.find_index(type_order, &(&1 == type))
      idx || 99
    end)
  end
end
