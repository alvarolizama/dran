defmodule DranWeb.SettingsLive do
  @moduledoc """
  Settings page showing the current configuration of models,
  agents, inference API, Firecrawl, and uploads — plus an editable
  "Brain tuning" section backed by `Dran.Settings`.
  """

  use DranWeb, :live_view

  alias Dran.Inference.Config
  alias Dran.Settings
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "settings", page_title: gettext("Settings"))
      |> assign_brain_form()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # -- Brain tuning form ------------------------------------------------------

  @brain_keys ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long
                 agent_max_pages agent_max_sources research_lang daily_note_enabled)

  defp assign_brain_form(socket) do
    values =
      Settings.all()
      |> Map.take(@brain_keys)

    assign(socket, brain_form: to_form(values, as: :settings))
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    casts = %{
      "semantic_threshold_short" => &cast_float/1,
      "semantic_threshold_mid" => &cast_float/1,
      "semantic_threshold_long" => &cast_float/1,
      "agent_max_pages" => &cast_int/1,
      "agent_max_sources" => &cast_int/1,
      "research_lang" => &to_string/1,
      "daily_note_enabled" => &cast_bool/1
    }

    for key <- @brain_keys do
      raw = Map.get(params, key, "")
      cast = Map.fetch!(casts, key)
      Settings.put(key, cast.(raw))
    end

    socket =
      socket
      |> assign_brain_form()
      |> put_flash(:info, gettext("Settings saved"))

    {:noreply, socket}
  end

  defp cast_float(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp cast_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> nil
    end
  end

  # `value="true"` is sent for a checked checkbox; the hidden `value="false"`
  # companion is sent when unchecked. Phoenix's checkbox input emits both
  # (hidden first), so the boolean string is the final parsed value.
  defp cast_bool("true"), do: true
  defp cast_bool(_), do: false

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
        <div class="w-full p-6 space-y-8 max-w-5xl mx-auto">
          <%!-- Page header --%>
          <div>
            <h1 class="text-title">{gettext("Settings")}</h1>
            <p class="text-caption mt-1">
              {gettext(
                "Current configuration. Values are read from environment variables at startup."
              )}
            </p>
          </div>

          <%!-- Read-only configuration sections --%>
          <.config_section
            icon="hero-cpu-chip"
            title={gettext("Inference API")}
            subtitle={gettext("LLM, embeddings, and reranking")}
          >
            <.config_row label={gettext("Status")} env="DRAN_INFERENCE_API_URL">
              <.status_badge active={Config.enabled?()} />
            </.config_row>
            <.config_row label={gettext("API URL")} env="DRAN_INFERENCE_API_URL">
              <code class="text-sm font-mono text-primary">
                {Config.base_url() || "—"}
              </code>
            </.config_row>
            <.config_row label={gettext("API Key")} env="DRAN_INFERENCE_API_KEY">
              <span class="text-sm text-base-content/60">
                {if Config.api_key(), do: "••••••••", else: "—"}
              </span>
            </.config_row>
            <.config_row label={gettext("Chat model")} env="DRAN_INFERENCE_CHAT_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.chat_model() || "—"}
              </code>
            </.config_row>
            <.config_row label={gettext("Embedding model")} env="DRAN_INFERENCE_EMBEDDING_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.embedding_model() || "—"}
              </code>
            </.config_row>
            <.config_row label={gettext("Embedding dimensions")}>
              <span class="text-sm text-base-content/60">{Config.embedding_dimensions()}</span>
            </.config_row>
            <.config_row label={gettext("Embedding body limit")} env="DRAN_EMBEDDING_BODY_LIMIT">
              <span class="text-sm text-base-content/60">
                {Config.embedding_body_limit()} {gettext("chars")}
              </span>
            </.config_row>
            <.config_row label={gettext("Rerank model")} env="DRAN_INFERENCE_RERANK_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.rerank_model() || "—"}
              </code>
            </.config_row>
            <.config_row label={gettext("Rerank enabled")} env="DRAN_INFERENCE_USE_RERANK">
              <.status_badge active={Config.use_rerank?()} />
            </.config_row>
            <.config_row label={gettext("Vision model")} env="DRAN_INFERENCE_VISION_MODEL">
              <code class="text-sm font-mono text-primary">{Config.vision_model()}</code>
            </.config_row>
            <.config_row label={gettext("ASR model")} env="DRAN_INFERENCE_ASR_MODEL">
              <code class="text-sm font-mono text-primary">{Config.asr_model()}</code>
            </.config_row>
            <.config_row label={gettext("MarkItDown model")} env="DRAN_INFERENCE_MARKITDOWN_MODEL">
              <code class="text-sm font-mono text-primary">
                {Config.markitdown_model() || "—"}
              </code>
            </.config_row>
            <.config_row label={gettext("Request timeout")} env="DRAN_INFERENCE_TIMEOUT">
              <span class="text-sm text-base-content/60">{Config.timeout()} {gettext("ms")}</span>
            </.config_row>
          </.config_section>

          <.config_section
            icon="hero-bolt"
            title={gettext("Agents")}
            subtitle={gettext("Autonomous research and ingest agents")}
          >
            <.config_row label={gettext("Max steps")} env="AGENT_MAX_STEPS">
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :agent_max_steps, 150)}
              </span>
            </.config_row>
            <.config_row label={gettext("Per-step timeout")} env="AGENT_PER_STEP_TIMEOUT">
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :agent_per_step_timeout, 120_000)} {gettext("ms")}
              </span>
            </.config_row>
          </.config_section>

          <%!-- Editable brain tuning form --%>
          <.brain_tuning_section form={@brain_form} />

          <.config_section
            icon="hero-globe-alt"
            title={gettext("Firecrawl")}
            subtitle={gettext("Web search and scraping")}
          >
            <.config_row label={gettext("Status")} env="FIRECRAWL_API_KEY">
              <.status_badge active={Dran.Firecrawl.enabled?()} />
            </.config_row>
            <.config_row label={gettext("API Key")} env="FIRECRAWL_API_KEY">
              <span class="text-sm text-base-content/60">
                {if Dran.Firecrawl.enabled?(), do: "••••••••", else: "—"}
              </span>
            </.config_row>
            <.config_row label={gettext("Base URL")}>
              <code class="text-sm font-mono text-primary">https://api.firecrawl.dev/v1</code>
            </.config_row>
          </.config_section>

          <.config_section
            icon="hero-paper-clip"
            title={gettext("Uploads")}
            subtitle={gettext("File attachment storage")}
          >
            <.config_row label={gettext("Directory")} env="UPLOADS_DIR">
              <code class="text-sm font-mono text-primary">
                {Application.get_env(:dran, :uploads, []) |> Keyword.get(:dir, "priv/static/uploads")}
              </code>
            </.config_row>
            <.config_row label={gettext("Max file size")} env="UPLOADS_MAX_SIZE">
              <span class="text-sm text-base-content/60">
                {Application.get_env(:dran, :uploads, [])
                |> Keyword.get(:max_size, 104_857_600)
                |> format_bytes()}
              </span>
            </.config_row>
          </.config_section>

          <%!-- Footnote / how to change env vars --%>
          <div class="surface-1 p-4 flex items-start gap-3">
            <.icon name="hero-information-circle" class="size-5 text-base-content/40 shrink-0 mt-0.5" />
            <p class="text-caption">
              {gettext(
                "To change these settings, set the corresponding environment variables and restart the application."
              )}
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- View components --------------------------------------------------------

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
  slot :inner_block, required: true

  defp config_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-5 py-3 gap-4">
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

  attr :form, :any, required: true

  defp brain_tuning_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-accent/10">
          <.icon name="hero-adjustments-horizontal" class="size-4 text-accent" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading">{gettext("Brain tuning")}</h2>
          <p class="text-caption mt-0.5">
            {gettext("Semantic thresholds, agent limits, and research preferences")}
          </p>
        </div>
      </header>

      <.form
        for={@form}
        id="brain-tuning-form"
        phx-submit="save"
        class="px-5 py-5 space-y-5"
      >
        <%!-- Thresholds group --%>
        <div class="space-y-2">
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
            {gettext("Semantic thresholds")}
          </h3>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <.input
              field={@form[:semantic_threshold_short]}
              type="number"
              step="0.01"
              label={gettext("Short")}
            />
            <.input
              field={@form[:semantic_threshold_mid]}
              type="number"
              step="0.01"
              label={gettext("Mid")}
            />
            <.input
              field={@form[:semantic_threshold_long]}
              type="number"
              step="0.01"
              label={gettext("Long")}
            />
          </div>
          <p class="text-caption">
            {gettext("Minimum similarity (0.0–1.0) for a relation to be considered semantic.")}
          </p>
        </div>

        <%!-- Agent limits --%>
        <div class="space-y-2">
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
            {gettext("Agent limits")}
          </h3>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:agent_max_pages]}
              type="number"
              label={gettext("Max pages per run")}
            />
            <.input
              field={@form[:agent_max_sources]}
              type="number"
              label={gettext("Max sources per run")}
            />
          </div>
          <p class="text-caption">
            {gettext("Upper bounds for autonomous research and ingest agents.")}
          </p>
        </div>

        <%!-- Research preferences --%>
        <div class="space-y-2">
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
            {gettext("Research preferences")}
          </h3>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 items-start">
            <.input
              field={@form[:research_lang]}
              type="select"
              label={gettext("Research language")}
              options={[{"Español", "es"}, {"English", "en"}]}
            />
            <.input
              field={@form[:daily_note_enabled]}
              type="checkbox"
              label={gettext("Daily note enabled")}
            />
          </div>
          <p class="text-caption">
            {gettext("Language for agent-generated content and daily-note automation.")}
          </p>
        </div>

        <%!-- Save row --%>
        <div class="flex justify-end pt-3 border-t border-base-content/10">
          <button
            type="submit"
            class="btn btn-primary btn-sm transition-colors active:scale-95"
            phx-disable-with={gettext("Saving…")}
          >
            <.icon name="hero-check" class="size-4" />
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </section>
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
