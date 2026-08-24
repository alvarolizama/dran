defmodule DranWeb.ReportLive do
  @moduledoc """
  LiveView for report pages: detail view only.

  Reports are second-citizen entities in their own table — created by the
  system (jobs, system output), never via the web UI. They are viewable
  here at `/reports/:slug`.
  """

  use DranWeb, :live_view

  alias Dran.Reports
  alias DranWeb.Plugs.Auth

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
      <div :if={@live_action == :show} class="p-6 overflow-y-auto w-full">
        <div class="max-w-4xl mx-auto space-y-6">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2 mb-2 text-caption">
                <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-purple-100 text-purple-700">
                  <.icon name="hero-document-chart-bar" class="size-3" />
                  {gettext("Report")}
                </span>
                <code class="font-mono text-caption text-base-content/60">{@report.slug}</code>
                <span
                  :if={@report.report_type}
                  class="px-2 py-0.5 text-xs rounded-full bg-base-300 text-base-content/70"
                >
                  {String.capitalize(@report.report_type)}
                </span>
              </div>
              <h1 class="text-title break-words">{@report.title}</h1>
            </div>
            <div class="flex gap-2 shrink-0">
              <.link navigate={~p"/#{@workspace_slug}/activity"} class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
              </.link>
            </div>
          </div>

          <div class="prose prose-base dark:prose-invert">
            {render_markdown(@report.body || "", [])}
          </div>

          <p class="text-xs text-base-content/40">
            {gettext("Reports are system-generated and do not participate in clusters.")}
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, session, socket) do
    # The URL slug wins over the session (see Plugs.Auth.assign_to_socket/3).
    {socket, context} = Auth.assign_to_socket(socket, session, params)

    if context && connected?(socket) do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    {:ok,
     assign(socket,
       context: context,
       active_nav: "activity",
       report: nil
     )}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    {socket, context} = Auth.resolve_workspace(socket, params)

    if context do
      case Reports.get_report_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/activity")}

        report ->
          {:noreply,
           assign(socket,
             report: report,
             page_title: report.title
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/activity")}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/activity")}
  end

  # ── PubSub: real-time update when a report changes ──

  @impl true
  def handle_info({:page_changed, _action, changed_report}, socket) do
    if socket.assigns[:report] && socket.assigns.report.id == changed_report.id do
      report = Reports.get_report(changed_report.id)

      if report do
        {:noreply, assign(socket, report: report)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
