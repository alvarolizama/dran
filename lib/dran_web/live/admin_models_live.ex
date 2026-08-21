defmodule DranWeb.AdminModelsLive do
  @moduledoc """
  Instance model configuration (owner-only): pick the model used for each
  purpose (chat, embeddings, reranking) from the provider's `/v1/models` list,
  with a per-model test button. Moved verbatim from the old SettingsLive
  "models" tab.
  """

  use DranWeb, :live_view

  alias Dran.Inference.Client
  alias Dran.Inference.Config
  alias Dran.Settings
  alias DranWeb.Plugs.Auth

  # Purposes shown in the "Modelos" card. Each entry is:
  #   {settings_key, label_gettext_fn, description_gettext_fn}
  # Models come exclusively from the provider's `/v1/models` list — there are
  # no env-var model defaults anymore.
  defp model_purposes do
    [
      {"model_chat", fn -> gettext("Chat / agentes") end,
       fn ->
         gettext("Model used for chat completions, agent reasoning, and title generation.")
       end},
      {"model_embedding", fn -> gettext("Embeddings") end,
       fn -> gettext("Model used to vectorize page bodies for semantic search and relations.") end},
      {"model_rerank", fn -> gettext("Re-ranking") end,
       fn ->
         gettext("Model used to re-rank semantic search results by relevance to the query.")
       end}
    ]
  end

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Modelos"))
      |> assign(model_test_status: %{})
      |> assign_models()

    {:ok, socket}
  end

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
      |> Enum.map(fn {key, _label, _desc} ->
        {key, current_model_value(key)}
      end)
      |> Map.new()

    assign(socket, models_result: models, model_values: current)
  end

  defp extract_model_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_model_id(%{id: id}) when is_binary(id), do: id
  defp extract_model_id(_), do: nil

  # Effective value for a purpose: the Settings override, if set. Models come
  # exclusively from the provider's model list — no env fallback.
  defp current_model_value(key) do
    case read_setting_safe(key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp read_setting_safe(key) do
    Settings.get(key)
  rescue
    _ -> nil
  end

  @impl true
  def handle_event("save_models", %{"models" => params}, socket) do
    for {key, _label, _desc} <- model_purposes() do
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
  def handle_event("test_model", %{"key" => key, "model" => model}, socket) do
    # The per-model test button posts via the .ModelTest hook (see template).
    with true <- test_model_key?(key),
         false <- Map.get(socket.assigns.model_test_status, key) == :testing do
      pid = self()

      Task.start(fn ->
        result = run_model_test(key, model)
        send(pid, {:model_test_done, key, result})
      end)

      status = Map.put(socket.assigns.model_test_status, key, :testing)
      {:noreply, assign(socket, model_test_status: status)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:model_test_done, key, result}, socket) do
    status = Map.put(socket.assigns.model_test_status, key, result)
    {:noreply, assign(socket, model_test_status: status)}
  end

  defp test_model_key?(key) do
    Enum.any?(model_purposes(), fn {k, _label, _desc} -> k == key end)
  end

  # Runs a real inference call against the given model. `model` is the raw
  # select value: "" resolves to the effective configured model.
  defp run_model_test(key, model) do
    model =
      case model do
        "" -> effective_model(key)
        nil -> effective_model(key)
        m -> m
      end

    start = System.monotonic_time(:millisecond)

    result =
      case key do
        "model_chat" ->
          Client.chat(%{
            "model" => model,
            "messages" => [%{"role" => "user", "content" => "Say OK"}],
            "max_tokens" => 5
          })

        "model_embedding" ->
          Client.embeddings(model, ["test"])

        "model_rerank" ->
          Client.rerank(model, "test", ["test doc"])

        _ ->
          {:error, :unknown_model_key}
      end

    case result do
      {:ok, _} -> {:ok, System.monotonic_time(:millisecond) - start}
      {:error, reason} -> {:error, reason}
    end
  end

  defp effective_model("model_chat"), do: Config.chat_model()
  defp effective_model("model_embedding"), do: Config.embedding_model()
  defp effective_model("model_rerank"), do: Config.rerank_model()
  defp effective_model(_), do: nil

  # Compact, human-readable reason for the UI.
  defp format_model_error({:http_error, status, _body}), do: "HTTP #{status}"
  defp format_model_error(%Req.TransportError{reason: reason}), do: inspect(reason)
  defp format_model_error(:not_configured), do: "inference no configurado"
  defp format_model_error(other), do: inspect(other)

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
            <h1 class="text-title">{gettext("Modelos")}</h1>
            <p class="text-caption mt-0.5">
              {gettext("Pick the model used for each purpose from the provider's model list.")}
            </p>
          </div>

          <.models_section
            models_result={@models_result}
            model_values={@model_values}
            model_test_status={@model_test_status}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Models section ────────────────────────────────────────────────────────

  attr :models_result, :any, required: true
  attr :model_values, :map, required: true
  attr :model_test_status, :map, required: true

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
            {gettext("Pick the model used for each purpose from the provider's model list.")}
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
          <%= for {key, label_fn, desc_fn} <- model_purposes() do %>
            <% current = Map.fetch!(@model_values, key) %>
            <% options = model_options(@models_result, current) %>
            <% test_status = Map.get(@model_test_status, key, nil) %>
            <div>
              <div class="flex items-end gap-2">
                <div class="flex-1">
                  <.input
                    id={"models_#{key}"}
                    name={"models[#{key}]"}
                    type="select"
                    label={label_fn.()}
                    options={options}
                    value={current}
                    prompt={gettext("Selecciona un modelo")}
                  />
                </div>
                <button
                  type="button"
                  id={"test_model_#{key}"}
                  phx-hook=".ModelTest"
                  data-model-key={key}
                  data-model-select={"models_#{key}"}
                  disabled={test_status == :testing}
                  class={[
                    "btn btn-xs gap-1.5 mb-1 transition-all duration-150 active:scale-95",
                    test_status == :testing && "btn-ghost opacity-60",
                    test_status != :testing && "btn-ghost hover:bg-primary/10"
                  ]}
                >
                  <.icon
                    name={if test_status == :testing, do: "hero-arrow-path", else: "hero-bolt"}
                    class={"size-3.5 #{if test_status == :testing, do: "animate-spin", else: ""}"}
                  />
                  {if test_status == :testing, do: gettext("Probando..."), else: gettext("Probar")}
                </button>
              </div>
              <p class="text-xs text-base-content/60 mt-1.5">
                {desc_fn.()}
              </p>
              <div
                :if={test_status != nil && test_status != :testing}
                class="mt-1.5 text-xs"
              >
                <span
                  :if={match?({:ok, _}, test_status)}
                  class="inline-flex items-center gap-1 text-success"
                >
                  <.icon name="hero-check-circle" class="size-3.5" />
                  {gettext("OK · %{ms} ms", ms: elem(test_status, 1))}
                </span>
                <span
                  :if={match?({:error, _}, test_status)}
                  class="inline-flex items-center gap-1 text-error"
                >
                  <.icon name="hero-x-circle" class="size-3.5" />
                  {gettext("Error: %{reason}", reason: format_model_error(elem(test_status, 1)))}
                </span>
              </div>
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

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ModelTest">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const selectId = this.el.dataset.modelSelect;
            const select = document.getElementById(selectId);
            const model = select ? select.value : "";
            this.pushEventTo(this.el, "test_model", {
              key: this.el.dataset.modelKey,
              model: model
            });
          });
        }
      }
    </script>
    """
  end

  # Builds the <option> list for a purpose's select.
  # - Starts with the models fetched from the provider's `/v1/models`.
  # - If the current saved value is not in that list, it's appended so the
  #   effective selection is always visible (e.g. provider removed the model).
  defp model_options(models_result, current) do
    fetched =
      case models_result do
        {:ok, ids} -> ids
        _ -> []
      end

    fetched
    |> maybe_prepend(current)
    |> Enum.uniq()
    |> Enum.map(fn id -> {id, id} end)
  end

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, ""), do: list

  defp maybe_prepend(list, value) do
    if value in list, do: list, else: [value | list]
  end
end
