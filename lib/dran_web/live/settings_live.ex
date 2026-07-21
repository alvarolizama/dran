defmodule DranWeb.SettingsLive do
  @moduledoc """
  Settings page showing an editable "Brain tuning" section backed by
  `Dran.Settings`, an editable "Modelos" section for per-purpose model
  overrides (also backed by `Dran.Settings`), followed by read-only
  environment configuration (agents, inference API, Firecrawl, and uploads).
  """

  use DranWeb, :live_view

  alias Dran.Inference.Client
  alias Dran.Inference.Config
  alias Dran.Settings
  alias DranWeb.Plugs.Auth

  # Purposes shown in the "Modelos" card. Each entry is:
  #   {settings_key, env_getter, label_gettext_fn, description_gettext_fn}
  # `env_getter` returns the env-only default (bypassing DB overrides) so the
  # UI can mark that option as "(env)". Kept as a function (not a module
  # attribute) because it contains anonymous fns which cannot be escaped.
  defp model_purposes do
    [
      {"model_chat", &Config.env_chat_model/0, fn -> gettext("Chat / agentes") end,
       fn ->
         gettext("Model used for chat completions, agent reasoning, and title generation.")
       end},
      {"model_embedding", &Config.env_embedding_model/0, fn -> gettext("Embeddings") end,
       fn -> gettext("Model used to vectorize page bodies for semantic search and relations.") end},
      {"model_rerank", &Config.env_rerank_model/0, fn -> gettext("Re-ranking") end,
       fn ->
         gettext("Model used to re-rank semantic search results by relevance to the query.")
       end},
      {"model_markitdown", &Config.env_markitdown_model/0,
       fn -> gettext("Extracción de documentos") end,
       fn ->
         gettext(
           "Model used to convert attached files (PDF, Office) into markdown for ingestion."
         )
       end},
      {"model_asr", &Config.env_asr_model/0, fn -> gettext("Transcripción de audio") end,
       fn -> gettext("Model used to transcribe audio attachments into text.") end},
      {"model_vision", &Config.env_vision_model/0, fn -> gettext("Visión") end,
       fn -> gettext("Model used to describe images attached to pages (multimodal vision).") end}
    ]
  end

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "settings", page_title: gettext("Settings"))
      |> assign(inference_test: nil)
      |> assign_brain_form()
      |> assign_models()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # -- Inference connection test ---------------------------------------------

  # -- Brain tuning form ------------------------------------------------------

  @brain_keys ~w(agent_max_pages daily_note_enabled)
  @advanced_keys ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long)

  defp assign_brain_form(socket) do
    values =
      Settings.all()
      |> Map.take(@brain_keys ++ @advanced_keys)

    assign(socket, brain_form: to_form(values, as: :settings))
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    casts = %{
      "semantic_threshold_short" => &cast_float/1,
      "semantic_threshold_mid" => &cast_float/1,
      "semantic_threshold_long" => &cast_float/1,
      "agent_max_pages" => &cast_int/1,
      "daily_note_enabled" => &cast_bool/1
    }

    for key <- @brain_keys ++ @advanced_keys do
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

  @impl true
  def handle_event("save_models", %{"models" => params}, socket) do
    for {key, _env_fn, _label, _desc} <- model_purposes() do
      raw = Map.get(params, key, "")
      value = if raw == "", do: nil, else: raw
      Settings.put(key, value)
    end

    socket =
      socket
      |> assign_models()
      |> put_flash(:info, gettext("Settings saved"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_context", %{"danger" => %{"confirmation" => confirmation}}, socket) do
    expected = socket.assigns.context_slug || ""

    if confirmation == expected do
      context = Dran.Brain.get_context_by_slug(socket.assigns.context_slug)

      case Dran.Brain.reset_context(context.id) do
        {:ok, counts} ->
          socket =
            socket
            |> put_flash(
              :info,
              gettext(
                "Brain reset: deleted %{pages} pages, %{relations} relations, %{versions} versions, %{logs} logs.",
                pages: counts.pages,
                relations: counts.relations,
                versions: counts.versions,
                logs: counts.logs
              )
            )
            |> push_navigate(to: ~p"/")

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not reset brain. Check the logs."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Confirmation text does not match the context slug."))}
    end
  end

  # -- Inference connection test ---------------------------------------------

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

  # -- Models section ----------------------------------------------------------

  # Fetches the available model ids from the inference API once on mount.
  # Stores `{:ok, ids}` or `{:error, reason}` so the UI can show a note when
  # the API is unavailable. Also builds the current-values map (Settings
  # override or env default) per purpose.
  defp assign_models(socket) do
    models =
      case Client.models() do
        {:ok, list} when is_list(list) ->
          ids = list |> Enum.map(&extract_model_id/1) |> Enum.reject(&is_nil/1)
          {:ok, ids}

        {:error, _} = err ->
          err
      end

    current =
      model_purposes()
      |> Enum.map(fn {key, env_fn, _label, _desc} ->
        {key, current_model_value(key, env_fn)}
      end)
      |> Map.new()

    assign(socket, models_result: models, model_values: current)
  end

  defp extract_model_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_model_id(%{id: id}) when is_binary(id), do: id
  defp extract_model_id(_), do: nil

  # Effective value for a purpose: Settings override if set, else env default.
  defp current_model_value(key, env_fn) do
    case read_setting_safe(key) do
      nil -> env_fn.()
      "" -> env_fn.()
      value -> value
    end
  end

  defp read_setting_safe(key) do
    Settings.get(key)
  rescue
    _ -> nil
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
        <div class="w-full p-6 space-y-8">
          <%!-- Page header --%>
          <div>
            <h1 class="text-title">{gettext("Settings")}</h1>
            <p class="text-caption mt-1">
              {gettext("Personalize your brain and review the environment configuration.")}
            </p>
          </div>

          <%!-- Editable brain tuning form (FIRST) --%>
          <.brain_tuning_section form={@brain_form} />

          <%!-- Editable model overrides (SECOND) --%>
          <.models_section
            models_result={@models_result}
            model_values={@model_values}
          />

          <%!-- Read-only environment sections --%>
          <div class="space-y-6">
            <div>
              <h2 class="text-heading">{gettext("Entorno")}</h2>
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
                label={gettext("Vision model")}
                env="DRAN_INFERENCE_VISION_MODEL"
                description={
                  gettext(
                    "Effective model for image description (web override or env default). See “Modelos” above to override."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">{Config.vision_model()}</code>
              </.config_row>
              <.config_row
                label={gettext("ASR model")}
                env="DRAN_INFERENCE_ASR_MODEL"
                description={
                  gettext(
                    "Effective model for audio transcription (web override or env default). See “Modelos” above to override."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">{Config.asr_model()}</code>
              </.config_row>
              <.config_row
                label={gettext("MarkItDown model")}
                env="DRAN_INFERENCE_MARKITDOWN_MODEL"
                description={
                  gettext(
                    "Effective model for document-to-markdown conversion (web override or env default). See “Modelos” above to override."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">
                  {Config.markitdown_model() || "—"}
                </code>
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
              subtitle={gettext("Autonomous research and ingest agents")}
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
              icon="hero-globe-alt"
              title={gettext("Firecrawl")}
              subtitle={gettext("Web search and scraping")}
            >
              <.config_row
                label={gettext("Status")}
                env="FIRECRAWL_API_KEY"
                description={
                  gettext(
                    "Whether Firecrawl web search and scraping is configured. Read-only — set via environment variable."
                  )
                }
              >
                <.status_badge active={Dran.Firecrawl.enabled?()} />
              </.config_row>
              <.config_row
                label={gettext("API Key")}
                env="FIRECRAWL_API_KEY"
                description={gettext("Firecrawl API key. Read-only — set via environment variable.")}
              >
                <span class="text-sm text-base-content/60">
                  {if Dran.Firecrawl.enabled?(), do: "••••••••", else: "—"}
                </span>
              </.config_row>
              <.config_row
                label={gettext("Base URL")}
                description={
                  gettext(
                    "Firecrawl API base URL. Read-only — hardcoded to the official Firecrawl endpoint."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">https://api.firecrawl.dev/v1</code>
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

          <%!-- Danger zone — destructive operations --%>
          <.danger_zone_section context_slug={@context_slug} />
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
        <%!-- Agent limits --%>
        <div class="space-y-2">
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
            {gettext("Agent limits")}
          </h3>
          <div class="space-y-4">
            <div>
              <.input
                field={@form[:agent_max_pages]}
                type="number"
                label={gettext("Max pages per run")}
              />
              <p class="text-xs text-base-content/60 mt-1.5">
                {gettext(
                  "Maximum number of pages the autonomous research and ingest agents will create in a single run. Higher values mean longer runs and more content per run. Default: 10."
                )}
              </p>
            </div>
            <div>
              <.input
                field={@form[:daily_note_enabled]}
                type="checkbox"
                label={gettext("Daily note enabled")}
              />
              <p class="text-xs text-base-content/60 mt-1.5">
                {gettext(
                  "When enabled, the daily-note agent generates a summary page each day with what changed in the brain (via the Quantum scheduler). Turn off to disable automatic daily notes."
                )}
              </p>
            </div>
          </div>
        </div>

        <%!-- Advanced: semantic thresholds --%>
        <details class="group rounded-xl border border-base-content/10 px-4 py-3">
          <summary class="flex items-center gap-2 cursor-pointer select-none">
            <.icon
              name="hero-chevron-right"
              class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
            />
            <.icon name="hero-adjustments-horizontal" class="size-4 text-base-content/40" />
            <span class="text-sm font-semibold text-base-content/70">
              {gettext("Avanzado")}
            </span>
          </summary>
          <div class="mt-4 space-y-2">
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
            <p class="text-xs text-base-content/60">
              {gettext(
                "Minimum cosine similarity (0.0–1.0) required for a semantic relation between pages to be created or kept. Higher values produce fewer, stronger relations. Applied by text length bucket (short/mid/long body)."
              )}
            </p>
          </div>
        </details>

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

  attr :models_result, :any, required: true
  attr :model_values, :map, required: true

  defp models_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-cpu-chip" class="size-4 text-primary" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading">{gettext("Modelos")}</h2>
          <p class="text-caption mt-0.5">
            {gettext(
              "Override the model used for each purpose. Leave as “Por defecto (env)” to use the environment default."
            )}
          </p>
        </div>
      </header>

      <.form
        for={to_form(%{}, as: :models)}
        id="models-form"
        phx-submit="save_models"
        class="px-5 py-5 space-y-5"
      >
        <p :if={match?({:error, _}, @models_result)} class="text-xs text-base-content/60">
          {gettext(
            "API no disponible — los modelos no pueden listarse. Aún puedes escribir un override manual, o revisa DRAN_INFERENCE_API_URL."
          )}
        </p>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <%= for {key, env_fn, label_fn, desc_fn} <- model_purposes() do %>
            <% current = Map.fetch!(@model_values, key) %>
            <% options = model_options(@models_result, env_fn, current) %>
            <div>
              <.input
                id={"models_#{key}"}
                name={"models[#{key}]"}
                type="select"
                label={label_fn.()}
                options={options}
                value={current}
                prompt={gettext("Por defecto (env)")}
              />
              <p class="text-xs text-base-content/60 mt-1.5">
                {desc_fn.()}
              </p>
            </div>
          <% end %>
        </div>

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

  # Builds the <option> list for a purpose's select.
  # - The env default model (if present in the fetched list) is annotated " (env)".
  # - If the env default is NOT in the fetched list, it's still shown (so the
  #   current effective value is always selectable) with the " (env)" suffix.
  # - If the current value isn't in the env-or-fetched set, it's appended too.
  defp model_options(models_result, env_fn, current) do
    env_default = env_fn.()

    fetched =
      case models_result do
        {:ok, ids} -> ids
        _ -> []
      end

    # Start with fetched ids; ensure env_default and current are present.
    ids =
      fetched
      |> maybe_prepend(env_default)
      |> maybe_prepend(current)
      |> Enum.uniq()

    Enum.map(ids, fn id ->
      label = if id == env_default, do: "#{id} (env)", else: id
      {label, id}
    end)
  end

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, ""), do: list

  defp maybe_prepend(list, value) do
    if value in list, do: list, else: [value | list]
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

  attr :context_slug, :string, required: true

  defp danger_zone_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden border border-error/20">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-error/20">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-error/10">
          <.icon name="hero-exclamation-triangle" class="size-4 text-error" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading text-error">{gettext("Zona de peligro")}</h2>
          <p class="text-caption mt-0.5">
            {gettext("Operaciones destructivas e irreversibles.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5 space-y-4">
        <div>
          <h3 class="text-sm font-semibold text-base-content/80">
            {gettext("Borrar todo el contenido")}
          </h3>
          <p class="text-xs text-base-content/60 mt-1">
            {gettext(
              "Elimina todas las páginas, relaciones, versiones y registros de actividad del contexto actual. El contexto en sí se conserva. Esta acción no se puede deshacer."
            )}
          </p>
        </div>

        <.form
          for={to_form(%{}, as: :danger)}
          id="reset-context-form"
          phx-submit="reset_context"
          class="space-y-3"
        >
          <div>
            <label class="text-xs text-base-content/60 mb-1 block">
              {gettext("Para confirmar, escribe el slug del contexto:")}
              <code class="ml-1 font-mono text-error">{@context_slug}</code>
            </label>
            <.input
              field={to_form(%{}, as: :danger)[:confirmation]}
              type="text"
              placeholder={@context_slug}
              class="w-full"
            />
          </div>
          <button
            type="submit"
            data-confirm={
              gettext(
                "¿Estás seguro? Esto borrará TODO el contenido del contexto. No se puede deshacer."
              )
            }
            class="btn btn-error btn-sm"
          >
            <.icon name="hero-trash" class="size-4" />
            {gettext("Borrar todo el contenido")}
          </button>
        </.form>
      </div>
    </section>
    """
  end
end
