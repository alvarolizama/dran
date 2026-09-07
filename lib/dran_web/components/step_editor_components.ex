defmodule DranWeb.StepEditorComponents do
  @moduledoc """
  Tabs + visual contract editor for the step modal in WorkflowsLive.

  Renders the modal's MAIN column: a client-side tab bar (Intent /
  Claims / Gates / Grafo / Contexto) whose state is owned by the
  `.StepModalTabs` JS hook (`assets/js/hooks/step_modal_tabs.js`) — a
  LiveView patch morphs the buttons, so the hook re-asserts the active
  tab in `updated()`.

  There is no Contenido tab: the step is contract-pure. `title` lives
  above the tabs, the brief is the contract (columns + embeds), and
  the Contexto tab edits `contract.context_snapshot` (pages/memories the
  agent reads before executing). `status` is a server-side column edited
  in the sidebar, NOT part of the contract JSON.

  The contract form never talks to the server directly: it serializes into
  the `step[contract_json]` textarea (same channel the raw-JSON path used),
  so `validate_step` lint feedback and `save_step` keep working unchanged.

  Row lists (`claims`, `gates`, `nodes`, `edges`, `ctx`) render EMPTY
  server-side; the rows are cloned client-side from sibling
  `<template data-tpl>` nodes and populated from the contract JSON. The
  server never renders row inputs, so a LiveView patch cannot fight the
  user's in-progress edits.

  The sidebar (`Details` / `Conexiones` aside) stays in the LiveView
  template, inside the same `<.form>` — a single submit still carries
  everything.
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext
  import DranWeb.CoreComponents, only: [icon: 1, input: 1]

  attr :id, :string, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :step, :any, default: nil

  def step_editor_tabs(assigns) do
    ~H"""
    <div id={@id} phx-hook="StepModalTabs" class="min-w-0">
      <%!-- Title — the only text field that stays server-rendered. The
           brief is the contract; there is no body. --%>
      <div class="mb-4">
        <.input
          field={@form[:title]}
          type="text"
          label={gettext("Title")}
          placeholder={gettext("Step title…")}
          class="text-lg font-medium"
          autofocus
        />
      </div>

      <%!-- Tab bar — client-side state, the hook re-asserts it after patches.
           data-testid="step-contract" en el panel del contrato: los tests lo
           usan para localizar el bloque (contrato + lint en vivo). --%>
      <div class="flex items-center gap-1 border-b border-base-300 mb-4" role="tablist">
        <button
          type="button"
          role="tab"
          data-tab="intent"
          aria-selected="true"
          class="px-3 py-2 text-sm font-medium border-b-2 border-primary text-primary transition-colors duration-150"
        >
          {gettext("Intent")}
        </button>
        <button
          type="button"
          role="tab"
          data-tab="claims"
          aria-selected="false"
          tabindex="-1"
          class="px-3 py-2 text-sm font-medium border-b-2 border-transparent text-base-content/55 transition-colors duration-150 hover:text-base-content"
        >
          {gettext("Claims")}
        </button>
        <button
          type="button"
          role="tab"
          data-tab="gates"
          aria-selected="false"
          tabindex="-1"
          class="px-3 py-2 text-sm font-medium border-b-2 border-transparent text-base-content/55 transition-colors duration-150 hover:text-base-content"
        >
          {gettext("Gates")}
        </button>
        <button
          type="button"
          role="tab"
          data-tab="grafo"
          aria-selected="false"
          tabindex="-1"
          class="px-3 py-2 text-sm font-medium border-b-2 border-transparent text-base-content/55 transition-colors duration-150 hover:text-base-content"
        >
          {gettext("Grafo")}
        </button>
        <button
          type="button"
          role="tab"
          data-tab="contexto"
          aria-selected="false"
          tabindex="-1"
          class="px-3 py-2 text-sm font-medium border-b-2 border-transparent text-base-content/55 transition-colors duration-150 hover:text-base-content"
        >
          {gettext("Contexto")}
        </button>
        <span class="flex-1"></span>
        <button
          type="button"
          data-toggle-json
          class="btn btn-ghost btn-xs font-mono shrink-0"
          title={gettext("Alternar entre editor visual y JSON crudo")}
        >
          {gettext("JSON")}
        </button>
      </div>

      <%!-- Visual body: el contenedor que el hook alterna contra el modo JSON
           (`visualBody.hidden`). Debe existir como UN solo elemento que envuelva
           los 5 paneles — el hook lo busca por `[data-visual-body]` y sin él
           `_wireVisual`/`_wireToggle`/`_buildFromJson` nunca corren (guard de
           mounted). No lleva phx-update="ignore": sus hijos sí, y morphdom
           respeta ignore a cualquier profundidad. --%>
      <div data-visual-body>
        <%!-- Panel: Intent (objective + status). phx-update="ignore" + id:
           el hook gestiona estos árboles client-side (filas clonadas de
           <template>); sin ignore, morphdom las descartaría en cada
           validate_step. Los botones de tab quedan fuera (server-owned). --%>
        <div id={"#{@id}-panel-intent"} data-panel="intent" phx-update="ignore">
          <div class="space-y-4">
            <label class="block">
              <span class="text-xs text-base-content/60">{gettext("Intent")}</span>
              <textarea
                data-cf="intent"
                rows="3"
                placeholder={gettext("Qué logra este paso…")}
                class="textarea textarea-bordered textarea-sm w-full mt-1 leading-snug resize-y"
              ></textarea>
            </label>
            <p class="text-xs text-base-content/50">
              {gettext("El objetivo del brief que lee el agente. El resto del contrato lo detalla.")}
            </p>
          </div>
        </div>

        <%!-- Panel: Claims --%>
        <div
          id={"#{@id}-panel-claims"}
          data-panel="claims"
          phx-update="ignore"
          hidden
          class="space-y-4"
        >
          <p class="text-xs text-base-content/50">
            {gettext(
              "Afirmaciones pre-registradas: id · claim · verify. Una que falla se refuta, no se reinterpreta."
            )}
          </p>
          <section class="space-y-1.5">
            <.section_header title={gettext("Claims")} hint={gettext("id · claim · verify")} />
            <div data-list="claims" class="space-y-2"></div>
            <template data-tpl="claims">
              <.claim_row />
            </template>
            <button type="button" data-add="claims" class="btn btn-ghost btn-xs text-primary">
              <.icon name="hero-plus" class="size-3.5" /> {gettext("Claim")}
            </button>
          </section>
        </div>

        <%!-- Panel: Gates --%>
        <div id={"#{@id}-panel-gates"} data-panel="gates" phx-update="ignore" hidden class="space-y-4">
          <p class="text-xs text-base-content/50">
            {gettext(
              "Criterio de done ejecutable: name · cmd · expect. El agente reporta gate_results al cerrar."
            )}
          </p>
          <section class="space-y-1.5">
            <.section_header title={gettext("Gates")} hint={gettext("name · cmd · expect")} />
            <div data-list="gates" class="space-y-2"></div>
            <template data-tpl="gates">
              <.gate_row />
            </template>
            <button type="button" data-add="gates" class="btn btn-ghost btn-xs text-primary">
              <.icon name="hero-plus" class="size-3.5" /> {gettext("Gate")}
            </button>
          </section>
        </div>

        <%!-- Panel: Grafo (plan interno del paso) — mini-canvas visual.
             El hook GraphCanvas (assets/js/hooks/graph_canvas_hook.js) gestiona
             el árbol client-side: nodos arrastrables, puertos, modal de edición.
             StepModalTabs alimenta/lee el canvas vía feed()/collect() y
             serializa a contract.graph en el textarea JSON. --%>
        <div id={"#{@id}-panel-grafo"} data-panel="grafo" phx-update="ignore" hidden class="space-y-3">
          <div class="flex items-center justify-between gap-2">
            <p class="text-xs text-base-content/50">
              {gettext(
                "Plan interno del paso: READ/EDIT/CREATE/RUN/VERIFY/ASK con funnel de verificación."
              )}
            </p>
            <span class="text-[10px] font-mono text-base-content/30 whitespace-nowrap">
              {gettext("doble clic = nodo · arrastra puertos = conectar · clic nodo = editar")}
            </span>
          </div>
          <div
            id={"#{@id}-gc-canvas"}
            data-graph-canvas
            phx-hook="GraphCanvas"
            class="relative h-[calc(100vh_-_27rem)] min-h-[12rem] rounded-xl border border-base-300 bg-base-200/40 overflow-hidden select-none"
          >
            <svg class="absolute inset-0 h-full w-full pointer-events-none"></svg>
            <div data-nodes class="absolute inset-0"></div>
            <p
              data-gc-empty
              class="pointer-events-none absolute inset-0 flex items-center justify-center text-sm text-base-content/40"
            >
              {gettext("Grafo vacío — doble clic para crear el primer nodo.")}
            </p>
            <%!-- Botones del canvas: overlay dentro del contenedor (el hook
                 GraphCanvas escucha clicks en this.el y los captura vía
                 [data-gc-add] / [data-gc-tidy]). --%>
            <div class="absolute top-2 right-2 z-20 flex items-center gap-1.5">
              <%!-- Re-layoutea TODO el grafo por niveles (ignora x/y guardados):
                   dos hijos de un mismo nodo quedan en fila horizontal y sus
                   dependientes siguen hacia abajo. --%>
              <button
                type="button"
                data-gc-tidy
                title={gettext("Reordenar el grafo por niveles")}
                class="inline-flex items-center gap-1 rounded-lg border border-base-300 bg-base-100 px-2 py-1 text-xs font-medium text-base-content/70 shadow-sm transition-colors duration-150 hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-squares-2x2" class="size-3.5" /> {gettext("Reordenar")}
              </button>
              <button
                type="button"
                data-gc-add
                title={gettext("Agregar nodo")}
                class="inline-flex items-center gap-1 rounded-lg border border-base-300 bg-base-100 px-2 py-1 text-xs font-medium text-base-content/70 shadow-sm transition-colors duration-150 hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-plus" class="size-3.5" /> {gettext("Nodo")}
              </button>
            </div>
          </div>
        </div>

        <%!-- Panel: Contexto (páginas + memories → contract.context_snapshot) --%>
        <div
          id={"#{@id}-panel-contexto"}
          data-panel="contexto"
          phx-update="ignore"
          hidden
          class="space-y-4"
        >
          <p class="text-xs text-base-content/50">
            {gettext(
              "Páginas y memories que el agente lee antes de ejecutar. Se congelan por sesión."
            )}
          </p>
          <div class="ctx-search relative">
            <input
              type="text"
              data-ctx-search
              placeholder={gettext("Buscar páginas o memories… (fuzzy + semántico)")}
              autocomplete="off"
              class="input input-bordered input-sm w-full mt-1"
            />
            <div
              data-ctx-dropdown
              class="absolute z-20 top-full left-0 right-0 mt-1 hidden max-h-56 overflow-auto rounded-lg border border-base-300 bg-base-200 shadow-lg"
            >
            </div>
          </div>

          <section class="space-y-1.5">
            <.section_header title={gettext("Contexto")} hint={gettext("context_snapshot")} />
            <div data-list="ctx" class="space-y-2"></div>
            <template data-tpl="ctx">
              <.ctx_row />
            </template>
            <p class="text-xs text-base-content/40">
              {gettext("Escribí para buscar; agregá desde el dropdown. Quitar con ✕.")}
            </p>
          </section>
        </div>
      </div>
      <%!-- cierra [data-visual-body] --%>

      <%!-- Raw JSON — the actual form field (single source of truth; the
           hook serializes the visual form into it on every keystroke).
           `hidden` va en el TEXTAREA, no en el div contenedor: el hook alterna
           `this.jsonEl.hidden`, y jsonEl ES el textarea — con hidden en el
           wrapper el modo JSON quedaba invisible aunque el toggle corriera.
           El wrapper conserva data-testid="step-contract" (los tests leen el
           contrato server-rendered desde ahí) y phx-update="ignore". --%>
      <div id={"#{@id}-json"} data-json-body phx-update="ignore" data-testid="step-contract">
        <textarea
          data-contract-json
          name="step[contract_json]"
          rows="14"
          phx-debounce="300"
          hidden
          class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed bg-base-100"
          placeholder={gettext("{\"intent\": \"...\"}")}
        >{contract_json(@step)}</textarea>
      </div>
    </div>
    """
  end

  # ── Sub-components ──────────────────────────────────────────────────────

  # Lint en vivo del contrato. Público: el step modal lo renderiza arriba del
  # sidebar (`<aside>` de Details/Conexiones en workflows_live.html.heex), no
  # al pie del editor — decisión de producto (feedback siempre visible).
  attr :lint, :any, required: true

  def contract_lint_feedback(assigns) do
    ~H"""
    <%= cond do %>
      <% match?({:ok, _}, @lint) -> %>
        <p class="text-xs text-success" data-testid="contract-lint-ok">
          <.icon name="hero-check-circle" class="size-3.5 inline-block align-text-bottom" />
          {elem(@lint, 1)}
        </p>
      <% match?({:invalid, _}, @lint) -> %>
        <p class="text-xs text-error" data-testid="contract-lint-error">
          <.icon name="hero-exclamation-circle" class="size-3.5 inline-block align-text-bottom" />
          {elem(@lint, 1)}
        </p>
      <% true -> %>
        <p class="text-xs text-base-content/40" data-testid="contract-lint-empty">
          {gettext("Vacío = sin contrato.")}
        </p>
    <% end %>
    """
  end

  defp section_header(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-2">
      <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
        {@title}
      </h4>
      <span :if={@hint} class="text-[10px] font-mono text-base-content/35">{@hint}</span>
    </div>
    """
  end

  defp claim_row(assigns) do
    ~H"""
    <div data-row class="rounded-lg border border-base-300 bg-base-200/30 p-2 space-y-1.5">
      <div class="flex items-center gap-1.5">
        <input
          type="text"
          data-cf="claim_id"
          placeholder="P1"
          class="input input-bordered input-xs w-16 font-mono"
        />
        <input
          type="text"
          data-cf="claim"
          placeholder={gettext("Afirmación…")}
          class="input input-bordered input-xs flex-1"
        />
        <.remove_button />
      </div>
      <input
        type="text"
        data-cf="verify"
        placeholder={gettext("cómo se verifica…")}
        class="input input-bordered input-xs w-full font-mono"
      />
    </div>
    """
  end

  defp gate_row(assigns) do
    ~H"""
    <div data-row class="rounded-lg border border-base-300 bg-base-200/30 p-2 space-y-1.5">
      <div class="flex items-center gap-1.5">
        <input
          type="text"
          data-cf="name"
          placeholder={gettext("nombre…")}
          class="input input-bordered input-xs flex-1"
        />
        <.remove_button />
      </div>
      <input
        type="text"
        data-cf="cmd"
        placeholder={gettext("comando…")}
        class="input input-bordered input-xs w-full font-mono"
      />
      <input
        type="text"
        data-cf="expect"
        placeholder={gettext("esperado…")}
        class="input input-bordered input-xs w-full"
      />
    </div>
    """
  end

  # Una entrada del context_snapshot: badge (PAGE/MEM) + id + why + quitar.
  defp ctx_row(assigns) do
    ~H"""
    <div data-row class="flex items-center gap-1.5">
      <span
        data-cf="ctx_type"
        class="badge badge-xs px-2 font-mono uppercase text-[9px] tracking-wider"
      ></span>
      <input
        type="text"
        data-cf="ctx_id"
        placeholder={gettext("id…")}
        class="input input-bordered input-xs flex-1 font-mono"
      />
      <input
        type="text"
        data-cf="ctx_why"
        placeholder={gettext("por qué…")}
        class="input input-bordered input-xs w-1/2"
      />
      <.remove_button />
    </div>
    """
  end

  defp remove_button(assigns) do
    ~H"""
    <button
      type="button"
      data-remove
      class="btn btn-ghost btn-xs text-base-content/40 hover:text-error px-1"
      title={gettext("Quitar")}
    >
      <.icon name="hero-x-mark" class="size-3.5" />
    </button>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # The JSON shape the visual editor parses — EDITABLE fields only.
  # `Dran.Contracts.contract_map/1` gives the full legacy shape; the
  # server-managed columns (status/version/history/fingerprint/model/
  # generated_by) are stripped: they live on the schema now, the JSON is
  # not their editor.
  @server_managed_keys ~w(status version history fingerprint model generated_by)

  defp contract_json(nil), do: ""

  defp contract_json(%Dran.Step{} = step) do
    case Dran.Contracts.contract_map(step) do
      nil ->
        ""

      contract ->
        contract
        |> Map.drop(@server_managed_keys)
        |> Jason.encode!(pretty: true)
    end
  end
end
