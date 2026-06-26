defmodule DranWeb.SettingsLive do
  @moduledoc """
  Read-only settings page showing the current configuration of models,
  agents, inference API, Firecrawl, and uploads.
  """

  use DranWeb, :live_view

  alias Dran.Inference.Config
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    {:ok, assign(socket, active_nav: "settings", page_title: "Settings")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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
      <div class="p-6 overflow-y-auto w-full">
        <div class="w-full space-y-6">
          <div>
            <h1 class="text-2xl font-bold">Settings</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Current configuration. Values are read from environment variables
              at startup.
            </p>
          </div>

          <.config_section title="Inference API" subtitle="LLM, embeddings, and reranking">
            <.config_row label="Status" env="DRAN_INFERENCE_API_URL">
              <.status_badge active={Config.enabled?()} />
            </.config_row>
            <.config_row label="API URL" env="DRAN_INFERENCE_API_URL">
              <code class="text-sm font-mono text-primary">
                {Config.base_url() || "—"}
              </code>
            </.config_row>
            <.config_row label="API Key" env="DRAN_INFERENCE_API_KEY">
              <span class="text-sm text-base-content/60">
                {if Config.api_key(), do: "••••••••", else: "—"}
              </span>
            </.config_row>
            <.config_row label="Chat model" env="DRAN_INFERENCE_CHAT_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.chat_model() || "—"}
              </code>
            </.config_row>
            <.config_row label="Embedding model" env="DRAN_INFERENCE_EMBEDDING_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.embedding_model() || "—"}
              </code>
            </.config_row>
            <.config_row label="Embedding dimensions">
              <span class="text-sm text-base-content/60">{Config.embedding_dimensions()}</span>
            </.config_row>
            <.config_row label="Embedding body limit" env="DRAN_EMBEDDING_BODY_LIMIT">
              <span class="text-sm text-base-content/60">
                {Config.embedding_body_limit()} chars
              </span>
            </.config_row>
            <.config_row label="Rerank model" env="DRAN_INFERENCE_RERANK_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.rerank_model() || "—"}
              </code>
            </.config_row>
            <.config_row label="Rerank enabled" env="DRAN_INFERENCE_USE_RERANK">
              <.status_badge active={Config.use_rerank?()} />
            </.config_row>
            <.config_row label="Vision model" env="DRAN_INFERENCE_VISION_MODEL">
              <code class="text-sm font-mono text-primary">{Config.vision_model()}</code>
            </.config_row>
            <.config_row label="ASR model" env="DRAN_INFERENCE_ASR_MODEL">
              <code class="text-sm font-mono text-primary">{Config.asr_model()}</code>
            </.config_row>
            <.config_row label="MarkItDown model" env="DRAN_INFERENCE_MARKITDOWN_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.markitdown_model() || "—"}
              </code>
            </.config_row>
            <.config_row label="Request timeout" env="DRAN_INFERENCE_TIMEOUT">
              <span class="text-sm text-base-content/60">{Config.timeout()} ms</span>
            </.config_row>
          </.config_section>

          <.config_section title="Agents" subtitle="Autonomous research and ingest agents">
            <.config_row label="Max steps" env="AGENT_MAX_STEPS">
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :agent_max_steps, 150)}
              </span>
            </.config_row>
            <.config_row label="Per-step timeout" env="AGENT_PER_STEP_TIMEOUT">
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :agent_per_step_timeout, 120_000)} ms
              </span>
            </.config_row>
          </.config_section>

          <.config_section title="Firecrawl" subtitle="Web search and scraping">
            <.config_row label="Status" env="FIRECRAWL_API_KEY">
              <.status_badge active={Dran.Firecrawl.enabled?()} />
            </.config_row>
            <.config_row label="API Key" env="FIRECRAWL_API_KEY">
              <span class="text-sm text-base-content/60">
                {if Dran.Firecrawl.enabled?(), do: "••••••••", else: "—"}
              </span>
            </.config_row>
            <.config_row label="Base URL">
              <code class="text-sm font-mono text-primary">https://api.firecrawl.dev/v1</code>
            </.config_row>
          </.config_section>

          <.config_section title="Uploads" subtitle="File attachment storage">
            <.config_row label="Directory" env="UPLOADS_DIR">
              <code class="text-sm font-mono text-primary">
                {Application.get_env(:dran, :uploads, []) |> Keyword.get(:dir, "priv/static/uploads")}
              </code>
            </.config_row>
            <.config_row label="Max file size" env="UPLOADS_MAX_SIZE">
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :uploads, [])
                |> Keyword.get(:max_size, 104_857_600)
                |> format_bytes()}
              </span>
            </.config_row>
          </.config_section>

          <div class="text-xs text-base-content/40 pt-4 border-t border-base-300">
            <p>
              To change these settings, set the corresponding environment
              variables and restart the application.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp config_section(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 overflow-hidden">
      <div class="px-4 py-3 bg-base-200/50 border-b border-base-300">
        <h2 class="text-sm font-semibold">{@title}</h2>
        <p class="text-xs text-base-content/50 mt-0.5">{@subtitle}</p>
      </div>
      <div class="divide-y divide-base-300">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :env, :string, default: nil
  slot :inner_block, required: true

  defp config_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-4 py-2.5 gap-4">
      <div class="flex items-baseline gap-2 min-w-0">
        <span class="text-sm text-base-content/70 shrink-0">{@label}</span>
        <code :if={@env} class="text-xs font-mono text-base-content/40 truncate">
          {@env}
        </code>
      </div>
      <div class="shrink-0 text-right">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @active && "badge-success",
      !@active && "badge-ghost"
    ]}>
      {if @active, do: "Enabled", else: "Disabled"}
    </span>
    """
  end

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
