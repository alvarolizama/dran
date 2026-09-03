defmodule DranWeb.ActivityLive do
  @moduledoc """
  LiveView for the activity feed — a real-time log of brain actions
  (page.create, page.update, page.delete) in the active context.

  Shows the last 50 entries, newest first. Subscribes to the
  "brain:<workspace_id>" PubSub topic so new page actions appear live
  at the top of the list.
  """

  use DranWeb, :live_view

  alias Dran.Knowledge
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(params, session, socket) do
    # The URL slug wins over the session (see Plugs.Auth.assign_to_socket/3).
    {socket, context} = Auth.assign_to_socket(socket, session, params)

    if context do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    entries =
      if context do
        Knowledge.list_log(workspace_id: context.id, limit: 50)
      else
        []
      end

    {:ok,
     assign(socket,
       context: context,
       entries: entries,
       active_nav: "activity",
       page_title: gettext("Activity")
     )}
  end

  @impl true
  def handle_info({:page_changed, _action, _page}, socket) do
    # A page changed — reload the log to pick up the new entry created by
    # Knowledge.create_page / update_page / delete_page (which log before broadcast).
    context = socket.assigns.context

    entries =
      if context do
        Knowledge.list_log(workspace_id: context.id, limit: 50)
      else
        []
      end

    {:noreply, assign(socket, entries: entries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-6">
          <.header_section workspace={@workspace} />

          <.action_legend :if={legend_actions(@entries) != []} actions={legend_actions(@entries)} />

          <.timeline :if={@entries != []} entries={@entries} />

          <.empty_state
            :if={@entries == []}
            icon="hero-clock"
            title={gettext("No activity yet")}
            caption={gettext("Create or edit a page to see it here.")}
            class="surface-2 rounded-2xl"
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Render-only components ─────────────────────────────────────────────────

  attr :workspace, :any, default: nil

  defp header_section(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-title">{gettext("Activity")}</h1>
        <p class="text-caption mt-1">
          {gettext("Recent changes in %{name}", name: context_name(@workspace))}
        </p>
      </div>
      <div class="flex items-center gap-1.5 text-caption">
        <span class="size-2 rounded-full bg-success animate-pulse"></span>
        {gettext("Live")}
      </div>
    </div>
    """
  end

  attr :actions, :list, required: true

  defp action_legend(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <span class="text-caption text-base-content/50 mr-1">{gettext("Types:")}</span>
      <span
        :for={{action, count} <- @actions}
        class="inline-flex items-center gap-1.5 px-2 py-1 text-xs rounded-full bg-base-200/60 border border-base-300"
      >
        <.icon
          name={action_icon(action)}
          class={["size-3.5", icon_color(action)]}
        />
        <span class="text-base-content/70">{action_label(action)}</span>
        <span class="text-base-content/40 font-mono">{count}</span>
      </span>
    </div>
    """
  end

  attr :entries, :list, required: true

  defp timeline(assigns) do
    ~H"""
    <ol class="relative" role="list" aria-label={gettext("Activity timeline")}>
      <span
        aria-hidden="true"
        class="absolute left-[15px] top-2 bottom-2 w-px bg-gradient-to-b from-base-300 via-base-300 to-transparent"
      />
      <.timeline_entry :for={entry <- @entries} entry={entry} />
    </ol>
    """
  end

  attr :entry, Dran.Log, required: true

  defp timeline_entry(assigns) do
    ~H"""
    <li class="relative flex items-start gap-4 pl-0 pb-5 last:pb-0">
      <div class="relative z-10 shrink-0">
        <div class={[
          "size-8 rounded-full flex items-center justify-center ring-4 ring-base-100",
          icon_bg(@entry.action)
        ]}>
          <.icon
            name={action_icon(@entry.action)}
            class={["size-4", icon_color(@entry.action)]}
          />
        </div>
      </div>

      <div class="min-w-0 flex-1 pt-0.5">
        <div class="flex items-baseline justify-between gap-3 flex-wrap">
          <div class="flex items-baseline gap-2 flex-wrap min-w-0">
            <span class="text-sm font-medium">
              {action_label(@entry.action)}
            </span>

            <.link
              :if={@entry.subject && page_path_for(@entry)}
              navigate={page_path_for(@entry)}
              class="text-sm text-primary/80 hover:text-primary hover:underline underline-offset-2 decoration-primary/40 truncate transition-colors"
            >
              {@entry.subject}
            </.link>

            <span
              :if={@entry.subject && !page_path_for(@entry)}
              class="text-sm text-base-content/70 truncate font-mono"
            >
              {@entry.subject}
            </span>
          </div>

          <span
            class="shrink-0 text-caption text-base-content/50 flex items-center gap-1"
            title={absolute_timestamp(@entry.inserted_at)}
          >
            <.icon name="hero-clock" class="size-3" />
            {relative_time(@entry.inserted_at)}
          </span>
        </div>

        <div :if={detail_badge(@entry)} class="mt-1">
          <span class="inline-flex items-center text-[11px] font-medium px-1.5 py-0.5 rounded bg-base-200 text-base-content/60">
            {detail_badge(@entry)}
          </span>
        </div>
      </div>
    </li>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp context_name(%Dran.Workspace{name: name}), do: name
  defp context_name(_), do: gettext("this context")

  defp action_icon("page.create"), do: "hero-plus-circle"
  defp action_icon("page.update"), do: "hero-pencil"
  defp action_icon("page.delete"), do: "hero-trash"
  defp action_icon("page.archive"), do: "hero-archive-box"
  defp action_icon("page.unarchive"), do: "hero-arrow-up-on-square"
  defp action_icon("worker"), do: "hero-cpu-chip"
  defp action_icon("worker." <> _), do: "hero-cpu-chip"
  defp action_icon(_), do: "hero-bolt"

  defp icon_bg("page.create"), do: "bg-success/15"
  defp icon_bg("page.update"), do: "bg-info/15"
  defp icon_bg("page.delete"), do: "bg-error/15"
  defp icon_bg("page.archive"), do: "bg-warning/15"
  defp icon_bg("page.unarchive"), do: "bg-success/15"
  defp icon_bg("worker"), do: "bg-accent/15"
  defp icon_bg("worker." <> _), do: "bg-accent/15"
  defp icon_bg(_), do: "bg-base-content/10"

  defp icon_color("page.create"), do: "text-success"
  defp icon_color("page.update"), do: "text-info"
  defp icon_color("page.delete"), do: "text-error"
  defp icon_color("page.archive"), do: "text-warning"
  defp icon_color("page.unarchive"), do: "text-success"
  defp icon_color("worker"), do: "text-accent"
  defp icon_color("worker." <> _), do: "text-accent"
  defp icon_color(_), do: "text-base-content/60"

  defp action_label("page.create"), do: gettext("Created")
  defp action_label("page.update"), do: gettext("Updated")
  defp action_label("page.delete"), do: gettext("Deleted")
  defp action_label("page.archive"), do: gettext("Archived")
  defp action_label("page.unarchive"), do: gettext("Unarchived")
  defp action_label("worker"), do: gettext("Worker")
  defp action_label("worker." <> _rest), do: gettext("Worker")
  defp action_label(other), do: humanize_action(other)

  defp humanize_action(action) when is_binary(action) do
    action
    |> String.split(".")
    |> case do
      [entity, verb] ->
        verb =
          verb
          |> String.replace("_", " ")
          |> String.capitalize()

        "#{verb} #{String.capitalize(entity)}"

      _ ->
        action |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp page_path_for(%Dran.Log{action: "page.delete"}), do: nil
  defp page_path_for(%Dran.Log{action: "page.archive"}), do: nil

  defp page_path_for(%Dran.Log{action: "page." <> _rest, subject: slug})
       when is_binary(slug) do
    "/notes/#{slug}"
  end

  defp page_path_for(_), do: nil

  defp detail_badge(%Dran.Log{action: "page.create", details: %{"page_type" => type}})
       when is_binary(type) do
    gettext("type: %{type}", type: type)
  end

  defp detail_badge(%Dran.Log{action: "page.update", details: %{"version" => version}}) do
    gettext("v%{version}", version: version)
  end

  defp detail_badge(_), do: nil

  # Derive the distinct action types present in the entries, paired with their
  # counts. Used to render the legend row above the timeline. Returns a list
  # ordered by first appearance (entries are newest-first, so types appear
  # in the order they were first seen).
  defp legend_actions(entries) do
    {order, counts} =
      Enum.reduce(entries, {[], %{}}, fn entry, {order, counts} ->
        action = normalize_action_for_legend(entry.action)
        new_counts = Map.update(counts, action, 1, &(&1 + 1))
        new_order = if action in order, do: order, else: order ++ [action]
        {new_order, new_counts}
      end)

    Enum.map(order, fn action -> {action, Map.get(counts, action, 0)} end)
  end

  # Group worker.* actions under a single "worker" legend entry so the legend
  # stays compact even if many distinct worker sub-actions appear.
  defp normalize_action_for_legend("worker." <> _), do: "worker"
  defp normalize_action_for_legend(other), do: other

  # Absolute ISO-8601 timestamp used for the `title` tooltip on relative times.
  # Works for both DateTime (has timezone) and NaiveDateTime (no timezone).
  defp absolute_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp absolute_timestamp(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp absolute_timestamp(_), do: ""

  defp relative_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)
    relative_time_from_seconds(diff)
  end

  defp relative_time(%NaiveDateTime{} = ndt) do
    {:ok, dt} = DateTime.from_naive(ndt, "Etc/UTC")
    relative_time(dt)
  end

  defp relative_time(_), do: ""

  defp relative_time_from_seconds(sec) when sec < 60, do: gettext("just now")

  defp relative_time_from_seconds(sec) when sec < 3600,
    do: gettext("%{n}m ago", n: div(sec, 60))

  defp relative_time_from_seconds(sec) when sec < 86_400,
    do: gettext("%{n}h ago", n: div(sec, 3600))

  defp relative_time_from_seconds(sec) when sec < 604_800,
    do: gettext("%{n}d ago", n: div(sec, 86_400))

  defp relative_time_from_seconds(sec) when sec < 2_592_000,
    do: gettext("%{n}w ago", n: div(sec, 604_800))

  defp relative_time_from_seconds(sec),
    do: gettext("%{n}mo ago", n: div(sec, 2_592_000))
end
