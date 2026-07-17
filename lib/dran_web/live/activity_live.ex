defmodule DranWeb.ActivityLive do
  @moduledoc """
  LiveView for the activity feed — a real-time log of brain actions
  (page.create, page.update, page.delete) in the active context.

  Shows the last 50 entries, newest first. Subscribes to the
  "brain:<context_id>" PubSub topic so new page actions appear live
  at the top of the list.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    if context do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    entries =
      if context do
        Brain.list_log(context_id: context.id, limit: 50)
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
    # Brain.create_page / update_page / delete_page (which log before broadcast).
    context = socket.assigns.context

    entries =
      if context do
        Brain.list_log(context_id: context.id, limit: 50)
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
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full max-w-4xl mx-auto p-6 space-y-6">
          <.header_section context={@context} />

          <div class="surface-2 divide-y divide-base-300">
            <.activity_entry :for={entry <- @entries} entry={entry} />

            <div :if={@entries == []} class="p-12 text-center">
              <div class="flex flex-col items-center gap-3">
                <div class="size-12 rounded-full bg-base-200 flex items-center justify-center">
                  <.icon name="hero-clock" class="size-6 text-base-content/40" />
                </div>
                <span class="text-caption">
                  {gettext("No activity yet. Create or edit a page to see it here.")}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :context, :any, default: nil

  defp header_section(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-title">{gettext("Activity")}</h1>
        <p class="text-caption mt-1">
          {gettext("Recent changes in %{name}", name: context_name(@context))}
        </p>
      </div>
      <div class="flex items-center gap-1.5 text-caption">
        <span class="size-2 rounded-full bg-success animate-pulse"></span>
        {gettext("Live")}
      </div>
    </div>
    """
  end

  attr :entry, Dran.Brain.Log, required: true

  defp activity_entry(assigns) do
    ~H"""
    <div class="flex items-start gap-3 p-4">
      <div class={["shrink-0 size-8 rounded-lg flex items-center justify-center", icon_bg(@entry.action)]}>
        <.icon name={action_icon(@entry.action)} class={["size-4", icon_color(@entry.action)]} />
      </div>

      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2 flex-wrap">
          <span class="text-sm font-medium">
            {action_label(@entry.action)}
          </span>

          <.link
            :if={@entry.subject && page_path_for(@entry)}
            navigate={page_path_for(@entry)}
            class="text-sm text-primary hover:underline truncate"
          >
            {@entry.subject}
          </.link>

          <span :if={@entry.subject && !page_path_for(@entry)} class="text-sm text-base-content/80 truncate">
            {@entry.subject}
          </span>
        </div>

        <div class="text-caption mt-0.5">
          {relative_time(@entry.inserted_at)}
          <span :if={detail_badge(@entry)}>
            · {detail_badge(@entry)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp context_name(%Dran.Brain.Context{name: name}), do: name
  defp context_name(_), do: gettext("this context")

  defp action_icon("page.create"), do: "hero-plus-circle"
  defp action_icon("page.update"), do: "hero-pencil-square"
  defp action_icon("page.delete"), do: "hero-trash"
  defp action_icon(_), do: "hero-clipboard-document-list"

  defp icon_bg("page.create"), do: "bg-success/10"
  defp icon_bg("page.update"), do: "bg-warning/10"
  defp icon_bg("page.delete"), do: "bg-error/10"
  defp icon_bg(_), do: "bg-base-content/10"

  defp icon_color("page.create"), do: "text-success"
  defp icon_color("page.update"), do: "text-warning"
  defp icon_color("page.delete"), do: "text-error"
  defp icon_color(_), do: "text-base-content/60"

  defp action_label("page.create"), do: gettext("Created")
  defp action_label("page.update"), do: gettext("Updated")
  defp action_label("page.delete"), do: gettext("Deleted")
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

  defp page_path_for(%Dran.Brain.Log{action: "page.delete"}), do: nil

  defp page_path_for(%Dran.Brain.Log{action: "page." <> _rest, subject: slug})
       when is_binary(slug) do
    "/notes/#{slug}"
  end

  defp page_path_for(_), do: nil

  defp detail_badge(%Dran.Brain.Log{action: "page.create", details: %{"page_type" => type}})
       when is_binary(type) do
    gettext("type: %{type}", type: type)
  end

  defp detail_badge(%Dran.Brain.Log{action: "page.update", details: %{"version" => version}}) do
    gettext("v%{version}", version: version)
  end

  defp detail_badge(_), do: nil

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
