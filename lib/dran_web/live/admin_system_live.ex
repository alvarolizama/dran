defmodule DranWeb.AdminSystemLive do
  @moduledoc """
  Read-only system information (owner-only): the "Entorno" section showing
  inference, agents, and uploads configuration loaded from env vars at
  startup, plus an inference connection test button. Moved verbatim from the
  old SettingsLive "system" tab.
  """

  use DranWeb, :live_view

  alias Dran.Inference.Client
  alias Dran.Inference.Config
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Sistema"))
      |> assign(inference_test: nil)

    {:ok, socket}
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
            <h1 class="text-title">{gettext("Sistema")}</h1>
            <p class="text-caption mt-0.5">
              {gettext("Read-only — loaded from environment variables at startup.")}
            </p>
          </div>

          <.config_section
            icon="hero-cpu-chip"
            title={gettext("Inference API")}
            subtitle={gettext("LLM, embeddings, and reranking")}
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
                    do: gettext("Probando..."),
                    else: gettext("Probar conexión")}
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
              env="DRAN_INFERENCE_CHAT_MODEL"
              description={
                gettext(
                  "Effective model for chat and agents (web override or env default). See “Modelos” above to override."
                )
              }
            >
              <code class="text-sm font-mono text-primary">
                {Config.chat_model() || "—"}
              </code>
            </.config_row>
            <.config_row
              label={gettext("Embedding model")}
              env="DRAN_INFERENCE_EMBEDDING_MODEL"
              description={
                gettext(
                  "Effective model for embeddings (web override or env default). See “Modelos” above to override."
                )
              }
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
              label={gettext("Rerank model")}
              env="DRAN_INFERENCE_RERANK_MODEL"
              description={
                gettext(
                  "Effective model for re-ranking search results (web override or env default). See “Modelos” above to override."
                )
              }
            >
              <code class="text-sm font-mono text-primary">
                {Config.rerank_model() || "—"}
              </code>
            </.config_row>
            <.config_row
              label={gettext("Rerank enabled")}
              env="DRAN_INFERENCE_USE_RERANK"
              description={
                gettext(
                  "Whether semantic search results are re-ranked by relevance. Read-only — set via environment variable."
                )
              }
            >
              <.status_badge active={Config.use_rerank?()} />
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
            title={gettext("Agents")}
            subtitle={gettext("Autonomous agents")}
          >
            <.config_row
              label={gettext("Max steps")}
              env="AGENT_MAX_STEPS"
              description={
                gettext(
                  "Maximum number of steps an autonomous agent can take in a single run. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :agent_max_steps, 150)}
              </span>
            </.config_row>
            <.config_row
              label={gettext("Per-step timeout")}
              env="AGENT_PER_STEP_TIMEOUT"
              description={
                gettext(
                  "Maximum wall-clock time per agent step, in milliseconds. Read-only — set via environment variable."
                )
              }
            >
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :agent_per_step_timeout, 120_000)} {gettext("ms")}
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

  # -- Components ------------------------------------------------------------

  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp config_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div
          :if={@icon}
          class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10"
        >
          <.icon name={@icon} class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{@title}</h2>
          <p :if={@subtitle} class="text-caption mt-0.5">{@subtitle}</p>
        </div>
      </header>
      <div class="divide-y divide-base-content/10">
        {render_slot(@inner_block)}
      </div>
    </section>
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

  attr :active, :boolean, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full",
      @active && "bg-success/15 text-success",
      !@active && "bg-base-200 text-base-content/50"
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        @active && "bg-success",
        !@active && "bg-base-content/30"
      ]} />
      {if @active, do: gettext("Enabled"), else: gettext("Disabled")}
    </span>
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
          <span class="text-info text-xs font-medium">{gettext("Probando...")}</span>
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
            {gettext("Sin conexión")}
          </span>
          <span class="text-xs text-error/70">
            {format_inference_error(reason)}
          </span>
        <% @configured -> %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-info/15 text-info">
            <.icon name="hero-server" class="size-3" />
            {gettext("Configurada")}
          </span>
        <% true -> %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-base-200 text-base-content/50">
            <.icon name="hero-x-mark" class="size-3" />
            {gettext("No configurada")}
          </span>
      <% end %>
    </div>
    """
  end

  defp format_inference_error(:not_configured), do: gettext("API no configurada")

  defp format_inference_error(%Req.TransportError{reason: reason}) do
    case reason do
      :econnrefused -> gettext("Connection refused — el servidor no responde")
      :timeout -> gettext("Timeout — el servidor tardó demasiado")
      :nxdomain -> gettext("Dominio no resuelto")
      _ -> "TransportError: #{inspect(reason)}"
    end
  end

  defp format_inference_error({:http_error, status, _body}) do
    gettext("HTTP %{status}", status: status)
  end

  defp format_inference_error(reason), do: inspect(reason)

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"
end
