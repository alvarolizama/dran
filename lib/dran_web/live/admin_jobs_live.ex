defmodule DranWeb.AdminJobsLive do
  @moduledoc """
  Global scheduled jobs (owner-only): the 5 Quantum crons with per-job toggle,
  "Run now", and last-run report badges. Moved verbatim from the old
  SettingsLive jobs section.
  """

  use DranWeb, :live_view

  import DranWeb.Admin

  alias Dran.Jobs
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Jobs"), workspace_slug: nil)
      |> assign(running_jobs: MapSet.new())
      |> assign_jobs()

    {:ok, socket}
  end

  defp assign_jobs(socket) do
    assign(socket, jobs: Jobs.list())
  end

  @impl true
  def handle_event("toggle_job", %{"key" => key}, socket) do
    case job_key_from_param(key) do
      {:ok, key} ->
        Jobs.set_enabled(key, not Jobs.enabled?(key))
        {:noreply, assign_jobs(socket)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_job", %{"key" => key}, socket) do
    with {:ok, key} <- job_key_from_param(key),
         false <- MapSet.member?(socket.assigns.running_jobs, key) do
      parent = self()

      Task.start(fn ->
        result = Jobs.run_now(key)
        send(parent, {:job_run_done, key, result})
      end)

      {:noreply, assign(socket, running_jobs: MapSet.put(socket.assigns.running_jobs, key))}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:job_run_done, key, {:ok, _report}}, socket) do
    socket =
      socket
      |> assign(running_jobs: MapSet.delete(socket.assigns.running_jobs, key))
      |> assign_jobs()
      |> put_flash(:info, gettext("Job completado: %{label}", label: job_label(key)))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:job_run_done, key, {:error, _reason}}, socket) do
    socket =
      socket
      |> assign(running_jobs: MapSet.delete(socket.assigns.running_jobs, key))
      |> assign_jobs()
      |> put_flash(:error, gettext("Job falló: %{label}", label: job_label(key)))

    {:noreply, socket}
  end

  # Validates a phx-value-key param against the job registry — never casts
  # arbitrary strings to atoms.
  defp job_key_from_param(param) when is_binary(param) do
    case Enum.find(Jobs.list_keys(), &(Atom.to_string(&1) == param)) do
      nil -> :error
      key -> {:ok, key}
    end
  end

  defp job_key_from_param(_), do: :error

  defp job_label(key) do
    case Jobs.get(key) do
      %{label: label} -> label
      nil -> to_string(key)
    end
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
          <div>
            <h1 class="text-title">{gettext("Jobs")}</h1>
            <p class="text-caption mt-0.5">
              {gettext(
                "Activa o desactiva los jobs recurrentes del cerebro. El toggle afecta solo las corridas programadas — \"Correr ahora\" siempre ejecuta."
              )}
            </p>
          </div>

          <.jobs_section jobs={@jobs} running_jobs={@running_jobs} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Jobs panel ──────────────────────────────────────────────────────────────

  attr :jobs, :list, required: true
  attr :running_jobs, :any, required: true

  defp jobs_section(assigns) do
    ~H"""
    <.section
      title={gettext("Jobs programados")}
      icon="hero-clock"
      caption={
        gettext(
          "Activa o desactiva los jobs recurrentes del cerebro. El toggle afecta solo las corridas programadas — \"Correr ahora\" siempre ejecuta."
        )
      }
    >
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Job")}</th>
              <th>{gettext("Schedule")}</th>
              <th>{gettext("Activo")}</th>
              <th>{gettext("Último run")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={job <- @jobs} id={"job-row-#{job.key}"}>
              <td>
                <div class="font-medium">{job.label}</div>
                <div class="text-xs text-base-content/50 max-w-xs">{job.description}</div>
              </td>
              <td>
                <code class="text-xs font-mono text-base-content/60">{job.schedule}</code>
              </td>
              <td>
                <input
                  type="checkbox"
                  id={"job-toggle-#{job.key}"}
                  checked={job.enabled?}
                  phx-click="toggle_job"
                  phx-value-key={job.key}
                  class="toggle toggle-sm toggle-primary"
                />
              </td>
              <td>
                <%= if job.last_run do %>
                  <div class="flex items-center gap-2 flex-wrap">
                    <.job_status_badge status={job.last_run.status} />
                    <.link
                      navigate={"/reports/#{job.last_run.slug}"}
                      class="link link-hover text-xs text-base-content/70"
                    >
                      {relative_time(job.last_run.at)}
                    </.link>
                    <span class="text-xs text-base-content/50">
                      {format_duration(job.last_run.duration_ms)}
                    </span>
                  </div>
                <% else %>
                  <span class="badge badge-ghost badge-sm">{gettext("Nunca")}</span>
                <% end %>
              </td>
              <td>
                <% running = MapSet.member?(@running_jobs, job.key) %>
                <button
                  type="button"
                  id={"job-run-#{job.key}"}
                  phx-click="run_job"
                  phx-value-key={job.key}
                  disabled={running}
                  class={[
                    "btn btn-xs gap-2 transition-all duration-150",
                    running && "btn-ghost opacity-60",
                    !running && "btn-ghost hover:bg-primary/10"
                  ]}
                >
                  <.icon
                    name={if running, do: "hero-arrow-path", else: "hero-bolt"}
                    class={"size-4 #{if running, do: "animate-spin", else: ""}"}
                  />
                  {if running, do: gettext("Corriendo…"), else: gettext("Correr ahora")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.section>
    """
  end

  attr :status, :string, required: true

  defp job_status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @status == "ok" && "badge-success",
      @status == "error" && "badge-error",
      @status not in ["ok", "error"] && "badge-ghost"
    ]}>
      {@status}
    </span>
    """
  end

  # Compact duration for job run reports: "450 ms" under a second, "1.2 s" above.
  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms} ms"
  defp format_duration(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)} s"

  # Relative time for the jobs panel ("justo ahora", "hace 3 h"…). Same msgids
  # as ActivityLive so the existing translations are reused.
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
