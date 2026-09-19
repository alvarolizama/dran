defmodule DranWeb.AdminSystemLive do
  @moduledoc """
  Instance configuration + monitoring (owner-only):

    * Monitoreo — DB size, table count, disk, BEAM memory, uptime and process
      counts, refreshed on demand.
    * Instancia — editable: default workspace slug/name and the legacy admin
      API token (Settings keys, persisted in DB).
    * Entorno — read-only inference/workers/uploads config loaded from env
      vars at startup, plus an inference connection test button.
  """

  use DranWeb, :live_view

  import DranWeb.Admin

  alias Dran.Inference.Client
  alias Dran.Inference.Config
  alias Dran.Knowledge
  alias Dran.Settings
  alias DranWeb.Plugs.Auth

  @slug_format ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin_system", page_title: gettext("Sistema"), workspace_slug: nil)
      |> assign(inference_test: nil)
      |> assign(monitoring: nil)
      |> assign_instance_form()

    {:ok, socket}
  end

  # ── Instance settings (Settings-backed, editable) ─────────────────────────

  defp assign_instance_form(socket) do
    assign(
      socket,
      instance_form:
        to_form(
          %{
            "default_workspace_slug" => setting_or_empty("default_workspace_slug"),
            "default_workspace_name" => setting_or_empty("default_workspace_name"),
            "api_token" => setting_or_empty("api_token")
          },
          as: :instance
        )
    )
  end

  defp setting_or_empty(key) do
    case Settings.get(key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  # ── Instance settings events ───────────────────────────────────────────────

  @impl true
  def handle_event("save_instance", %{"instance" => params}, socket) do
    slug = normalize(params["default_workspace_slug"])
    name = normalize(params["default_workspace_name"])
    token = normalize(params["api_token"])

    cond do
      slug != "" and not Regex.match?(@slug_format, slug) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Invalid slug: use lowercase letters, digits and hyphens.")
         )}

      true ->
        put_or_delete("default_workspace_slug", slug)
        put_or_delete("default_workspace_name", name)
        put_or_delete("api_token", token)

        # Mirror the release setup behaviour: when a default workspace is
        # explicitly configured, make sure it actually exists (first-run).
        maybe_create_default_workspace(slug, name)

        {:noreply,
         socket
         |> assign_instance_form()
         |> put_flash(:info, gettext("Instance configuration saved."))}
    end
  end

  @impl true
  def handle_event("generate_token", _params, socket) do
    token = Dran.Auth.generate_token()
    Settings.put("api_token", token)

    {:noreply,
     socket
     |> assign_instance_form()
     |> push_event("copy_to_clipboard", %{text: token})
     |> put_flash(:info, gettext("Token generated and copied to the clipboard."))}
  end

  @impl true
  def handle_event("refresh_monitoring", _params, socket) do
    {:noreply, assign(socket, monitoring: collect_monitoring())}
  end

  @impl true
  def handle_event("test_inference", _params, socket) do
    pid = self()

    Task.start(fn ->
      result = Client.ping()
      send(pid, {:inference_test_result, result})
    end)

    {:noreply, assign(socket, inference_test: :testing)}
  end

  @impl true
  def handle_info({:inference_test_result, result}, socket) do
    {:noreply, assign(socket, inference_test: result)}
  end

  # ── Instance settings helpers ──────────────────────────────────────────────

  defp put_or_delete(key, ""), do: Settings.delete(key)

  defp put_or_delete(key, value), do: Settings.put(key, value)

  defp maybe_create_default_workspace("", _name), do: :ok

  defp maybe_create_default_workspace(slug, name) do
    if is_nil(Knowledge.get_workspace_by_slug(slug)) do
      {:ok, _ws} = Knowledge.create_workspace(%{name: name_or_slug(name, slug), slug: slug})
    end

    :ok
  end

  defp name_or_slug("", slug), do: String.capitalize(slug)
  defp name_or_slug(name, _slug), do: name

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      user={@user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
      nav={:instance}
    >
      <div class="w-full">
        <div class="w-full space-y-6">
          <div>
            <h1 class="text-title">{gettext("Sistema")}</h1>
            <p class="text-caption mt-0.5">
              {gettext("Monitoring, instance configuration and environment.")}
            </p>
          </div>

          <.monitoring_widgets monitoring={@monitoring} />

          <.section
            title={gettext("Instance")}
            icon="hero-adjustments-horizontal"
            caption={gettext("Default workspace and API admin token — persisted in the database.")}
          >
            <.form
              for={@instance_form}
              id="instance-form"
              phx-submit="save_instance"
              class="px-5 py-5 space-y-5"
            >
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@instance_form[:default_workspace_slug]}
                  type="text"
                  label={gettext("Default workspace (slug)")}
                  placeholder="personal"
                />
                <.input
                  field={@instance_form[:default_workspace_name]}
                  type="text"
                  label={gettext("Default workspace (name)")}
                  placeholder="Personal"
                />
              </div>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Workspace used when a user has no workspace of their own and no active session. Created on save if it does not exist. Blank = \"personal\"."
                )}
              </p>

              <div class="border-t border-base-content/10 pt-4">
                <.input
                  field={@instance_form[:api_token]}
                  type="text"
                  label={gettext("API admin token")}
                  placeholder={gettext("(blank = disabled)")}
                />
                <p class="text-xs text-base-content/60 mt-1.5">
                  {gettext(
                    "Legacy bearer for the API with full-owner access. Blank = disabled; per-user tokens keep working."
                  )}
                </p>
                <button
                  type="button"
                  phx-click="generate_token"
                  class="btn btn-xs btn-ghost hover:bg-primary/10 mt-2 gap-1.5"
                >
                  <.icon name="hero-key" class="size-3.5" />
                  {gettext("Generate token")}
                </button>
              </div>

              <div class="flex justify-end">
                <button type="submit" class="btn btn-primary btn-sm">
                  {gettext("Save")}
                </button>
              </div>
            </.form>
          </.section>

          <.config_section
            icon="hero-cpu-chip"
            title={gettext("Inference API")}
            subtitle={gettext("LLM, embeddings")}
          >
            <.config_row
              label={gettext("Status")}
              env="DRAN_INFERENCE_API_URL"
              description={
                gettext(
                  "Whether the inference API is configured. Read-only — set via environment variable."
                )
              }
            >
              <div class="flex items-center gap-3 flex-wrap">
                <.inference_status_badge
                  test={@inference_test}
                  configured={Config.enabled?()}
                />
                <button
                  phx-click="test_inference"
                  disabled={@inference_test == :testing}
                  class={[
                    "btn btn-xs gap-2 transition-all duration-150",
                    @inference_test == :testing && "btn-ghost opacity-60",
                    @inference_test != :testing && "btn-ghost hover:bg-primary/10"
                  ]}
                >
                  <.icon
                    name={if @inference_test == :testing, do: "hero-arrow-path", else: "hero-bolt"}
                    class={"size-4 #{if @inference_test == :testing, do: "animate-spin", else: ""}"}
                  />
                  {if @inference_test == :testing,
                    do: gettext("Testing..."),
                    else: gettext("Test connection")}
                </button>
              </div>
            </.config_row>
            <.config_row
              label={gettext("API URL")}
              env="DRAN_INFERENCE_API_URL"
              description={
                gettext(
                  "Base URL of the OpenAI-compatible inference server. Read-only — set via environment variable."
                )
              }
            >
              <code class="text-sm font-mono text-primary">
                {Config.base_url() || "—"}
              </code>
            </.config_row>
            <.config_row
              label={gettext("API Key")}
              env="DRAN_INFERENCE_API_KEY"
              description={
                gettext(
                  "Bearer token sent to the inference API. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">
                {if Config.api_key(), do: "••••••••", else: "—"}
              </span>
            </.config_row>
            <.config_row
              label={gettext("Chat model")}
              description={
                gettext("Effective model for chat and workers. Configure in Admin → Models.")
              }
            >
              <code class="text-sm font-mono text-primary">
                {Config.chat_model() || "—"}
              </code>
            </.config_row>
            <.config_row
              label={gettext("Embedding model")}
              description={gettext("Effective model for embeddings. Configure in Admin → Models.")}
            >
              <code class="text-sm font-mono text-primary">
                {Config.embedding_model() || "—"}
              </code>
            </.config_row>
            <.config_row
              label={gettext("Embedding dimensions")}
              description={
                gettext(
                  "Vector dimensionality returned by the embedding model. Read-only — fixed at 1024."
                )
              }
            >
              <span class="text-sm text-base-content/60">{Config.embedding_dimensions()}</span>
            </.config_row>
            <.config_row
              label={gettext("Embedding body limit")}
              env="DRAN_EMBEDDING_BODY_LIMIT"
              description={
                gettext(
                  "Maximum text length (in characters) sent to the embedding API per call. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">
                {Config.embedding_body_limit()} {gettext("chars")}
              </span>
            </.config_row>
            <.config_row
              label={gettext("Request timeout")}
              env="DRAN_INFERENCE_TIMEOUT"
              description={
                gettext(
                  "HTTP timeout for inference API requests, in milliseconds. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">{Config.timeout()} {gettext("ms")}</span>
            </.config_row>
          </.config_section>

          <.config_section
            icon="hero-bolt"
            title={gettext("Workers")}
            subtitle={gettext("Autonomous workers")}
          >
            <.config_row
              label={gettext("Max steps")}
              env="WORKER_MAX_STEPS"
              description={
                gettext(
                  "Maximum number of steps an autonomous worker can take in a single run. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :worker_max_steps, 150)}
              </span>
            </.config_row>
            <.config_row
              label={gettext("Per-step timeout")}
              env="WORKER_PER_STEP_TIMEOUT"
              description={
                gettext(
                  "Maximum wall-clock time per worker step, in milliseconds. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :worker_per_step_timeout, 120_000)} {gettext("ms")}
              </span>
            </.config_row>
          </.config_section>

          <.config_section
            icon="hero-paper-clip"
            title={gettext("Uploads")}
            subtitle={gettext("File attachment storage")}
          >
            <.config_row
              label={gettext("Directory")}
              env="UPLOADS_DIR"
              description={
                gettext(
                  "Filesystem directory where uploaded attachments are stored. Read-only — set via environment variable."
                )
              }
            >
              <code class="text-sm font-mono text-primary">
                {Application.get_env(:dran, :uploads, [])
                |> Keyword.get(:dir, "priv/static/uploads")}
              </code>
            </.config_row>
            <.config_row
              label={gettext("Max file size")}
              env="UPLOADS_MAX_SIZE"
              description={
                gettext(
                  "Maximum allowed size for a single uploaded file. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :uploads, [])
                |> Keyword.get(:max_size, 104_857_600)
                |> format_bytes()}
              </span>
            </.config_row>
          </.config_section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Monitoring components ──────────────────────────────────────────────────

  attr :monitoring, :map, default: nil

  defp monitoring_widgets(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <.monitor_card :for={card <- monitor_cards(@monitoring)} card={card} />
      </div>
      <div class="flex justify-end">
        <button
          phx-click="refresh_monitoring"
          class="btn btn-xs btn-ghost hover:bg-primary/10 gap-1.5"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
          {gettext("Refresh")}
        </button>
      </div>
    </div>
    """
  end

  attr :card, :map, required: true

  defp monitor_card(assigns) do
    ~H"""
    <div class="surface-2 rounded-2xl px-4 py-3.5 flex items-start gap-3">
      <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
        <.icon name={@card.icon} class="size-4 text-primary" />
      </div>
      <div class="min-w-0">
        <p class="text-xs text-base-content/50 truncate">{@card.label}</p>
        <p class="text-lg font-semibold leading-tight truncate">{@card.value}</p>
        <p :if={@card.sub} class="text-xs text-base-content/50 truncate">{@card.sub}</p>
      </div>
    </div>
    """
  end

  defp monitor_cards(nil) do
    [
      %{label: gettext("Database"), value: "—", sub: nil, icon: "hero-circle-stack"},
      %{label: gettext("Disk"), value: "—", sub: nil, icon: "hero-server"},
      %{label: gettext("BEAM memory"), value: "—", sub: nil, icon: "hero-cpu-chip"},
      %{label: gettext("Uptime"), value: "—", sub: nil, icon: "hero-clock"}
    ]
  end

  defp monitor_cards(m) do
    [
      %{
        label: gettext("Database"),
        value: m.db_size,
        sub: ngettext("%{count} table", "%{count} tables", m.table_count),
        icon: "hero-circle-stack"
      },
      %{
        label: gettext("Disk"),
        value: m.disk_free,
        sub: gettext("%{percent}% used · %{total}", percent: m.disk_percent, total: m.disk_total),
        icon: "hero-server"
      },
      %{
        label: gettext("BEAM memory"),
        value: m.memory_used,
        sub: "#{m.memory_percent}% de #{m.memory_total}",
        icon: "hero-cpu-chip"
      },
      %{
        label: gettext("Uptime"),
        value: m.uptime,
        sub: "#{m.process_count} procesos · #{m.schedulers} schedulers",
        icon: "hero-clock"
      }
    ]
  end

  defp collect_monitoring do
    disk = disk_stat()
    mem_used = :erlang.memory(:processes) + :erlang.memory(:ets)
    mem_total = :erlang.memory(:total)

    %{
      db_size: format_bytes(db_size_bytes()),
      table_count: table_count(),
      disk_free: format_bytes(disk.free),
      disk_total: format_bytes(disk.total),
      disk_percent: disk.used_percent,
      memory_used: format_bytes(mem_used),
      memory_total: format_bytes(mem_total),
      memory_percent: percent(mem_used, mem_total),
      uptime: format_uptime(),
      process_count: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  defp db_size_bytes do
    case Dran.Repo.query!("SELECT pg_database_size(current_database())") do
      %{rows: [[bytes]]} when is_integer(bytes) -> bytes
      _ -> 0
    end
  end

  defp table_count do
    case Dran.Repo.query!(
           "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'"
         ) do
      %{rows: [[n]]} when is_integer(n) -> n
      _ -> 0
    end
  end

  # :disksup (os_mon) reports [{mount, total_kb, used_percent, free...}].
  # Falls back to zeros when unavailable (e.g. exotic platforms).
  defp disk_stat do
    case :disksup.get_disk_data() do
      [{_mount, total_kb, used_percent, _} | _] when is_integer(total_kb) ->
        total = total_kb * 1024
        used = div(total * used_percent, 100)
        %{total: total, used: used, free: max(total - used, 0), used_percent: used_percent}

      _ ->
        %{total: 0, used: 0, free: 0, used_percent: 0}
    end
  end

  defp percent(_part, 0), do: 0

  defp percent(part, whole), do: min(div(part * 100, whole), 100)

  defp format_uptime do
    {ms, _} = :erlang.statistics(:wall_clock)
    sec = div(ms, 1000)
    days = div(sec, 86_400)
    hours = div(rem(sec, 86_400), 3600)
    minutes = div(rem(sec, 3600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp normalize(nil), do: ""
  defp normalize(v) when is_binary(v), do: String.trim(v)
  defp normalize(_), do: ""

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  # ── Environment section components ─────────────────────────────────────────

  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp config_section(assigns) do
    ~H"""
    <.section title={@title} icon={@icon} caption={@subtitle}>
      <div class="divide-y divide-base-content/10">
        {render_slot(@inner_block)}
      </div>
    </.section>
    """
  end

  attr :label, :string, required: true
  attr :env, :string, default: nil
  attr :description, :string, default: nil
  slot :inner_block, required: true

  defp config_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between px-5 py-3 gap-4">
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class="text-sm text-base-content/70 shrink-0">{@label}</span>
          <code :if={@env} class="text-xs font-mono text-base-content/40 truncate">
            {@env}
          </code>
        </div>
        <p :if={@description} class="text-xs text-base-content/60 mt-1">
          {@description}
        </p>
      </div>
      <div class="shrink-0 text-right pt-0.5">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :test, :any, default: nil
  attr :configured, :boolean, default: false

  defp inference_status_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-2 flex-wrap">
      <%= cond do %>
        <% @test == :testing -> %>
          <span class="loading loading-dots loading-xs text-info"></span>
          <span class="text-info text-xs font-medium">{gettext("Testing...")}</span>
        <% match?({:ok, _}, @test) -> %>
          <% {:ok, r} = @test %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-success/15 text-success">
            <.icon name="hero-check-circle" class="size-3" />
            {gettext("Responde")}
          </span>
          <span class="text-xs text-base-content/50">
            {r.latency_ms}ms · {r.models} {gettext("modelos")}
          </span>
        <% match?({:error, _}, @test) -> %>
          <% {:error, reason} = @test %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-error/15 text-error">
            <.icon name="hero-x-circle" class="size-3" />
            {gettext("Offline")}
          </span>
          <span class="text-xs text-error/70">
            {format_inference_error(reason)}
          </span>
        <% @configured -> %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-info/15 text-info">
            <.icon name="hero-server" class="size-3" />
            {gettext("Configured")}
          </span>
        <% true -> %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-base-200 text-base-content/50">
            <.icon name="hero-x-mark" class="size-3" />
            {gettext("Not configured")}
          </span>
      <% end %>
    </div>
    """
  end

  defp format_inference_error(:not_configured), do: gettext("API not configured")

  defp format_inference_error(%Req.TransportError{reason: reason}) do
    case reason do
      :econnrefused -> gettext("Connection refused — the server is not responding")
      :timeout -> gettext("Timeout — the server took too long")
      :nxdomain -> gettext("Domain not resolved")
      _ -> gettext("TransportError: %{detail}", detail: inspect(reason))
    end
  end

  defp format_inference_error({:http_error, status, _body}) do
    gettext("HTTP %{status}", status: status)
  end

  defp format_inference_error(reason), do: inspect(reason)
end
