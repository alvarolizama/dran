defmodule DranWeb.JourneyLive do
  @moduledoc """
  LiveView for the Journey timeline — pages created over time.

  Shows a bar chart of brain activity by period (day/month/year),
  colored by dominant page type, with a cumulative sparkline.
  """
  use DranWeb, :live_view

  alias Dran.Journey
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    journey =
      if context do
        Journey.timeline(context.id)
      else
        Journey.empty_payload()
      end

    {:ok,
     assign(socket,
       context: context,
       journey: journey,
       type_colors: Journey.type_colors(),
       active_nav: "journey",
       page_title: gettext("Trayectoria")
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-6">
          <.page_header />
          <.stats_row :if={@journey.total > 0} stats={@journey.stats} />
          <.empty_journey_state :if={@journey.total == 0} />
          <.timeline_chart
            :if={@journey.total > 0}
            buckets={@journey.buckets}
            trajectory={@journey.trajectory}
            type_colors={@type_colors}
            axis={@journey.axis}
          />
          <.type_legend :if={@journey.total > 0} by_type={@journey.stats.by_type} type_colors={@type_colors} />
          <.creator_legend :if={@journey.total > 0} by_creator={@journey.stats.by_creator} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Components ──────────────────────────────────────────────────────────────

  defp page_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-title">{gettext("Trayectoria")}</h1>
        <p class="text-caption mt-1">
          {gettext("Crecimiento de tu segundo cerebro en el tiempo")}
        </p>
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true

  defp stats_row(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <.stat_card
        label={gettext("Total páginas")}
        value={@stats.total_pages}
        icon="hero-document-duplicate"
        color="text-primary"
      />
      <.stat_card
        label={gettext("Tipos")}
        value={map_size(@stats.by_type)}
        icon="hero-tag"
        color="text-secondary"
      />
      <.stat_card
        label={gettext("Período pico")}
        value={@stats.busiest_period || "—"}
        icon="hero-fire"
        color="text-warning"
        small={true}
      />
      <.stat_card
        label={gettext("Páginas pico")}
        value={@stats.busiest_count}
        icon="hero-chart-bar"
        color="text-info"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "text-base-content"
  attr :small, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <div class="surface-2 lift p-4 flex items-center gap-3 rounded-xl">
      <div class={["shrink-0 size-9 rounded-lg flex items-center justify-center", bg_for(@color)]}>
        <.icon name={@icon} class={["size-4", @color]} />
      </div>
      <div class="min-w-0">
        <div class={["font-bold tabular-nums leading-tight truncate", @small && "text-base", !@small && "text-xl"]}>
          {@value}
        </div>
        <div class="text-caption">{@label}</div>
      </div>
    </div>
    """
  end

  defp bg_for("text-primary"), do: "bg-primary/10"
  defp bg_for("text-secondary"), do: "bg-secondary/10"
  defp bg_for("text-accent"), do: "bg-accent/10"
  defp bg_for("text-info"), do: "bg-info/10"
  defp bg_for("text-success"), do: "bg-success/10"
  defp bg_for("text-warning"), do: "bg-warning/10"
  defp bg_for(_), do: "bg-base-200"

  attr :buckets, :list, required: true
  attr :trajectory, :list, required: true
  attr :type_colors, :map, required: true
  attr :axis, :map, required: true

  defp timeline_chart(assigns) do
    max_total = assigns.buckets |> Enum.map(& &1.total) |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(max_total: max_total)
      |> assign(sparkline_path: build_sparkline(assigns.trajectory))

    ~H"""
    <div class="surface-2 p-5 rounded-2xl space-y-3">
      <div class="space-y-1.5">
        <div
          :for={bucket <- @buckets}
          class="flex items-center gap-2 group"
        >
          <span class="text-xs text-base-content/50 w-16 text-right tabular-nums shrink-0">
            {bucket.label}
          </span>
          <div class="flex-1 flex items-center gap-1">
            <div
              class="h-5 rounded-sm transition-all duration-300 group-hover:brightness-110"
              style={"width: #{bucket_width(bucket.total, @max_total)}%; background-color: #{Map.get(@type_colors, bucket.dominant_type, "#666")}"}
            >
            </div>
            <span class="text-xs font-medium tabular-nums text-base-content/70 w-6 text-right">
              {bucket.total}
            </span>
          </div>
        </div>
      </div>

      <%!-- Sparkline --%>
      <div :if={@trajectory != []} class="pt-2 border-t border-base-300">
        <svg viewBox="0 0 200 30" class="w-full h-8" preserveAspectRatio="none">
          <polyline
            points={@sparkline_path}
            fill="none"
            stroke="currentColor"
            class="text-primary/40"
            stroke-width="1.5"
          />
        </svg>
      </div>

      <%!-- Axis --%>
      <div :if={@axis.start != ""} class="flex justify-between text-[10px] text-base-content/40">
        <span>{@axis.start}</span>
        <span>{@axis.end}</span>
      </div>
    </div>
    """
  end

  defp bucket_width(total, max_total) when max_total > 0 do
    round(total / max_total * 100)
  end
  defp bucket_width(_, _), do: 0

  defp build_sparkline([]), do: ""

  defp build_sparkline(trajectory) do
    max_val = Enum.max(trajectory)
    width = 200
    height = 28
    n = length(trajectory)

    trajectory
    |> Enum.with_index()
    |> Enum.map(fn {val, i} ->
      x = if n > 1, do: i / (n - 1) * width, else: 0
      y = if max_val > 0, do: height - val / max_val * height, else: height
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  attr :by_type, :map, required: true
  attr :type_colors, :map, required: true

  defp type_legend(assigns) do
    sorted =
      assigns.by_type
      |> Enum.sort_by(fn {_, v} -> -v end)
      |> Enum.map(fn {type, count} -> {type, count, Map.get(assigns.type_colors, type, "#666")} end)

    assigns = assign(assigns, sorted: sorted)

    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <span class="text-caption text-base-content/50">{gettext("Tipos:")}</span>
      <span
        :for={{type, count, color} <- @sorted}
        class="inline-flex items-center gap-1.5 text-xs"
      >
        <span class="size-2.5 rounded-full" style={"background-color: #{color}"}></span>
        <span class="text-base-content/70">{type}</span>
        <span class="text-base-content/40 font-mono">{count}</span>
      </span>
    </div>
    """
  end

  attr :by_creator, :map, required: true

  defp creator_legend(assigns) do
    sorted = Enum.sort_by(assigns.by_creator, fn {_, v} -> -v end)
    assigns = assign(assigns, sorted: sorted)

    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <span class="text-caption text-base-content/50">{gettext("Creadores:")}</span>
      <span
        :for={{creator, count} <- @sorted}
        class="inline-flex items-center gap-1.5 text-xs"
      >
        <.icon name={if creator == "agent", do: "hero-cpu-chip", else: "hero-user"} class="size-3.5 text-base-content/50" />
        <span class="text-base-content/70">{creator}</span>
        <span class="text-base-content/40 font-mono">{count}</span>
      </span>
    </div>
    """
  end

  defp empty_journey_state(assigns) do
    ~H"""
    <div class="surface-2 p-12 rounded-2xl text-center space-y-4">
      <div class="size-16 rounded-full bg-base-200 flex items-center justify-center mx-auto">
        <.icon name="hero-map" class="size-8 text-base-content/30" />
      </div>
      <div>
        <h3 class="text-heading">{gettext("Sin páginas aún")}</h3>
        <p class="text-caption mt-1">{gettext("Crea algunas páginas para ver la trayectoria de tu cerebro.")}</p>
      </div>
    </div>
    """
  end
end
