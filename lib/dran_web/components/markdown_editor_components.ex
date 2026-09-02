defmodule DranWeb.MarkdownEditorComponents do
  @moduledoc """
  Shared function components for the TipTap-based markdown editor.

  The editor is rendered via the `.MarkdownEditor` JS hook (see
  `assets/js/hooks/markdown_editor.js`) which mounts a TipTap editor
  with bidirectional Markdown support and custom wikilink/embed nodes.
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext
  import DranWeb.CoreComponents, only: [icon: 1, input: 1]

  @doc """
  Renders the markdown editor with a toolbar and a TipTap mount point.

  ## Assigns

  - `:id` (required) — unique DOM id for the editor mount container.
  - `:body` (required) — the initial markdown body.
  - `:workspace_id` (required) — used to scope wikilink/embed resolution and uploads.
  - `:upload` (optional) — a `Phoenix.LiveView.UploadConfig` for file uploads.
  - `:save_status` (optional) — `"saving" | "saved" | "idle"` for the indicator.
  - `:autosave` (optional, default `true`) — when `false`, the editor does not
    emit debounced `body_change` autosave events and the status indicator is
    hidden. Use `false` for new-page forms (nothing exists to autosave yet).
  - `:toolbar` (optional, default `true`) — render the formatting toolbar.
    Use `false` for compact embeds (e.g. the task detail panel): the editor
    stays fully functional, formatting is just keyboard/markdown-driven.
  - `:hidden_field` (optional, default `"page[body]"`) — name of the hidden
    input the hook syncs the markdown into on submit. Change it for forms
    that are not `page[...]` (e.g. `"task[body]"`).
  - `:min_height` (optional, default `nil`) — CSS min-height for the mount
    (e.g. `"220px"`). Defaults to the class-level `min-h-[300px]`.
  - `class` (optional) — extra classes for the outer container.
  """
  attr :id, :string, required: true
  attr :body, :string, required: true
  attr :workspace_id, :string, required: true
  attr :save_status, :string, default: "idle"
  attr :autosave, :boolean, default: true
  attr :toolbar, :boolean, default: true
  attr :hidden_field, :string, default: "page[body]"
  attr :min_height, :string, default: nil
  attr :class, :string, default: ""

  def markdown_editor(assigns) do
    ~H"""
    <div
      id={"editor-wrapper-#{@id}"}
      class={["md-editor flex flex-col rounded-lg border border-base-300 overflow-hidden", @class]}
    >
      <.editor_toolbar :if={@toolbar} id={@id} />
      <.editor_status :if={@autosave} status={@save_status} />

      <div
        id={@id}
        phx-hook="MarkdownEditor"
        phx-update="ignore"
        class="md-editor-mount flex-1 min-h-[300px] bg-base-100 overflow-y-auto"
        style={@min_height && "min-height: #{@min_height};"}
        data-body={@body}
        data-context-id={@workspace_id}
        data-autosave={to_string(@autosave)}
        data-hidden-field={@hidden_field}
      >
        <div
          class="tiptap-content prose prose-base dark:prose-invert max-w-none"
          data-placeholder="Escribe algo… o usa / para comandos"
        >
        </div>
      </div>
      <input type="hidden" name={@hidden_field} value={@body} />
    </div>
    """
  end

  attr :status, :string, required: true

  defp editor_status(assigns) do
    ~H"""
    <div class="editor-status flex items-center justify-end gap-2 px-3 py-1 text-xs text-base-content/40 bg-base-200/50 border-b border-base-300">
      <%= cond do %>
        <% @status == "saving" -> %>
          <span class="flex items-center gap-1">
            <span class="inline-block w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span>
            Guardando…
          </span>
        <% @status == "saved" -> %>
          <span class="flex items-center gap-1 text-green-500">
            <.icon name="hero-check" class="w-3 h-3" /> Guardado
          </span>
        <% true -> %>
          <span></span>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true

  defp editor_toolbar(assigns) do
    ~H"""
    <div
      class="editor-toolbar flex flex-wrap items-center gap-1 p-2"
      data-testid="editor-toolbar"
    >
      <.tb_btn id={@id} cmd="bold" icon="hero-bold" label="B" testid="tb-bold" />
      <.tb_btn id={@id} cmd="italic" icon="hero-italic" label="I" testid="tb-italic" />
      <.tb_btn id={@id} cmd="strike" icon="hero-strikethrough" label="S" />
      <.tb_btn id={@id} cmd="code" icon="hero-code-bracket" label="<>" />
      <div class="tb-separator" aria-hidden="true"></div>
      <.tb_btn id={@id} cmd="h1" icon="hero-hashtag" label="H1" />
      <.tb_btn id={@id} cmd="h2" icon="hero-hashtag" label="H2" />
      <.tb_btn id={@id} cmd="h3" icon="hero-hashtag" label="H3" />
      <div class="tb-separator" aria-hidden="true"></div>
      <.tb_btn id={@id} cmd="bulletList" icon="hero-list-bullet" label="" />
      <.tb_btn id={@id} cmd="orderedList" icon="hero-numbered-list" label="" />
      <.tb_btn id={@id} cmd="blockquote" icon="hero-chat-bubble-left" label="" />
      <.tb_btn id={@id} cmd="codeBlock" icon="hero-code-bracket-square" label="" />
      <div class="tb-separator" aria-hidden="true"></div>
      <.tb_btn id={@id} cmd="link" icon="hero-link" label="" testid="tb-link" />
      <.tb_btn id={@id} cmd="wikilink" icon="hero-link" label="[[]]" />
      <.tb_btn id={@id} cmd="embed" icon="hero-photo" label="![]" />
      <.tb_btn id={@id} cmd="table" icon="hero-table-cells" label="" />
      <div class="tb-separator" aria-hidden="true"></div>
      <.tb_btn id={@id} cmd="mermaid" icon="hero-chart-bar-square" label="" />
      <div class="tb-separator" aria-hidden="true"></div>
      <.tb_btn id={@id} cmd="undo" icon="hero-arrow-uturn-left" label="" />
      <.tb_btn id={@id} cmd="redo" icon="hero-arrow-uturn-right" label="" />
      <div class="tb-separator ml-auto" aria-hidden="true"></div>
      <button
        type="button"
        class="tb-btn inline-flex items-center gap-1.5 min-w-7 h-7 px-2 rounded text-sm text-base-content/70 hover:bg-base-300 hover:text-base-content active:scale-95 transition"
        data-editor={@id}
        data-cmd="toggleMode"
        title={gettext("Toggle WYSIWYG / Markdown")}
      >
        <.icon name="hero-code-bracket" class="w-4 h-4" />
        <span class="text-xs font-mono">MD</span>
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :cmd, :string, required: true
  attr :icon, :string, default: nil
  attr :label, :string, default: ""
  attr :testid, :string, default: nil

  defp tb_btn(assigns) do
    ~H"""
    <button
      type="button"
      class="tb-btn inline-flex items-center justify-center min-w-7 h-7 px-1.5 rounded text-sm text-base-content/70 hover:bg-base-300 hover:text-base-content active:scale-95 transition"
      data-editor={@id}
      data-cmd={@cmd}
      data-testid={@testid}
      title={@cmd}
    >
      <%= if @icon && @icon != "" do %>
        <.icon name={@icon} class="w-4 h-4" />
      <% end %>
      <%= if @label && @label != "" do %>
        <span class="text-xs font-mono">{@label}</span>
      <% end %>
    </button>
    """
  end

  @doc """
  Renders type-specific metadata fields (selects, date pickers, text inputs)
  based on the page type.

  ## Assigns

  - `:page_type` (required) — the page type slug (e.g. "note", "todo").
  - `:meta` (optional, default `%{}`) — the current meta map (persisted values).
  - `:form` (optional) — a `Phoenix.HTML.Form` from the parent `<.form>`. When
    present, conditional fields react in real time to `phx-change` re-renders:
    the renderer reads the "live" value of a field from the form params before
    falling back to `@meta`.

  ## Tuple shapes

  `Dran.PageMeta.meta_fields_for/1` returns tuples of variable arity:

      {:date, "due_date", "Due date"}
      {:select, "kind", "Kind", [{"Idea", "idea"}, ...]}
      {:date, "due_date", "Due date", condition: {:kind, "reminder"}}
      {:select, "kind", "Kind", options, placeholder: "…", condition: {:kind, "reminder"}}

  The renderer normalises all of these to `{type, key, label, opts}` where
  `opts` is always a keyword list. The only special key is `:condition`, a
  `{field, expected_value}` tuple that hides the field unless `meta[field]`
  (or the live form value) equals `expected_value`.
  """
  attr :page_type, :string, required: true
  attr :meta, :map, default: %{}
  attr :form, :any, default: nil
  attr :workspace_id, :any, required: true

  def meta_fields(assigns) do
    raw_fields = Dran.PageMeta.meta_fields_for(assigns.page_type)
    fields = Enum.map(raw_fields, &normalise_meta_field/1)

    {link_fields, plain_fields} =
      Enum.split_with(fields, fn {type, _, _, _} -> type == :slug_select end)

    assigns =
      assigns
      |> assign(:fields, plain_fields)
      |> assign(:link_fields, link_fields)

    ~H"""
    <div :if={@fields != [] or @link_fields != []} class="space-y-4">
      <div :if={@fields != []} class="text-sm font-semibold text-base-content/70">
        {gettext("Metadata")}
      </div>
      <div :if={@link_fields != []} class="space-y-2">
        <div class="flex items-center gap-1.5 text-sm font-semibold text-base-content/70">
          <.icon name="hero-link" class="size-4 text-base-content/40" />
          {gettext("Vincular a…")}
        </div>
        <div class="grid grid-cols-1 gap-4">
          <%= for {type, key, label, opts} <- @link_fields do %>
            <% value = meta_value(@meta, @form, key) %>
            <.meta_field_input
              type={type}
              key={key}
              label={label}
              opts={opts}
              value={value}
              workspace_id={@workspace_id}
            />
          <% end %>
        </div>
      </div>
      <div class="grid grid-cols-1 gap-4">
        <%= for {type, key, label, opts} <- @fields do %>
          <% value = meta_value(@meta, @form, key) %>
          <% visible? =
            is_nil(Keyword.get(opts, :condition)) or condition_met?(opts[:condition], @meta, @form) %>
          <%= if visible? do %>
            <.meta_field_input
              type={type}
              key={key}
              label={label}
              opts={opts}
              value={value}
              workspace_id={@workspace_id}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :opts, :list, default: []
  attr :value, :any, default: nil
  attr :workspace_id, :any, default: nil

  defp meta_field_input(assigns) do
    ~H"""
    <%= case @type do %>
      <% :select -> %>
        <% options = Keyword.get(@opts, :options, []) %>
        <.input
          type="select"
          name={"page[meta][#{@key}]"}
          value={@value}
          options={options}
          prompt={gettext("Ninguno")}
          label={@label}
        />
      <% :slug_select -> %>
        <% slug_type = Keyword.get(@opts, :type) %>
        <% pages =
          if @workspace_id do
            Dran.Knowledge.list_pages(workspace_id: @workspace_id, type: slug_type)
          else
            []
          end %>
        <% options = Enum.map(pages, fn p -> {p.title, p.slug} end) %>
        <% prompt =
          case slug_type do
            "project" -> gettext("Sin proyecto")
            "goal" -> gettext("Sin objetivo")
            "plan" -> gettext("Sin plan")
            _ -> gettext("Ninguno")
          end %>
        <.input
          type="select"
          name={"page[meta][#{@key}]"}
          value={@value}
          options={options}
          prompt={prompt}
          label={@label}
        />
      <% :date -> %>
        <.input type="date" name={"page[meta][#{@key}]"} value={@value} label={@label} />
      <% :number -> %>
        <.input
          type="number"
          name={"page[meta][#{@key}]"}
          value={@value}
          label={@label}
          step={@opts[:step]}
          min={@opts[:min]}
          max={@opts[:max]}
        />
      <% :text -> %>
        <% placeholder = Keyword.get(@opts, :placeholder) %>
        <.input
          type="text"
          name={"page[meta][#{@key}]"}
          value={@value}
          placeholder={placeholder || @label}
          label={@label}
        />
      <% :props -> %>
        <div class="form-control">
          <label class="label">
            <span class="label-text">{@label}</span>
            <span class="label-text-alt text-base-content/50">key / value</span>
          </label>
          <.props_editor id={"page-meta-props-#{@key}"} name={"page[meta][#{@key}]"} value={@value} />
          <p class="mt-1.5 text-xs leading-snug text-base-content/50">
            {gettext("Key-value custom metadata. Empty = none.")}
          </p>
        </div>
    <% end %>
    """
  end

  # ── Props key/value editor ────────────────────────────────────────────
  #
  # Replaces the raw JSON textarea for `:props` meta fields: rows of key/value
  # inputs plus an add button. A hidden input carries the canonical JSON object,
  # so form submits keep working unchanged — the server receives the same JSON
  # string under `page[meta][props]` and normalises it to a map in
  # `Dran.Knowledge` (create/update). Non-string values (numbers, booleans,
  # nested objects) survive round-trips untouched: the hook only stringifies
  # values the user actually edits.
  #
  # Purely client-side via a colocated hook — no server round-trips.

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""

  def props_editor(assigns) do
    rows = props_rows(assigns.value)
    json = if rows == [], do: "", else: assigns.value |> props_map() |> Jason.encode!()

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:json, json)

    ~H"""
    <div id={@id} phx-hook=".PropsEditor" data-props-editor>
      <div class="flex flex-col gap-1.5" data-props-rows>
        <div :for={{key, value} <- @rows} class="flex items-center gap-1.5" data-prop-row>
          <input
            type="text"
            data-prop-key
            value={key}
            placeholder={gettext("Key")}
            autocomplete="off"
            spellcheck="false"
            class="min-w-0 flex-1 rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 font-mono text-sm focus:outline-none focus:ring-1 focus:ring-primary"
          />
          <span class="select-none text-base-content/30" aria-hidden="true">=</span>
          <input
            type="text"
            data-prop-value
            value={value}
            placeholder={gettext("Value")}
            autocomplete="off"
            spellcheck="false"
            class="min-w-0 flex-[1.4] rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 font-mono text-sm focus:outline-none focus:ring-1 focus:ring-primary"
          />
          <button
            type="button"
            data-prop-remove
            aria-label={gettext("Remove property")}
            class="btn btn-ghost btn-xs btn-square shrink-0 text-base-content/40 hover:text-error"
          >
            ×
          </button>
        </div>
      </div>
      <button
        type="button"
        data-prop-add
        class="mt-1.5 w-full rounded-lg border border-dashed border-base-300 py-1.5 text-sm text-base-content/50 transition-colors hover:border-primary hover:text-primary"
      >
        + {gettext("Add property")}
      </button>
      <input type="hidden" name={@name} value={@json} data-props-value />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PropsEditor">
        export default {
          mounted() {
            const root = this.el;
            const hidden = root.querySelector("[data-props-value]");
            const rowsEl = root.querySelector("[data-props-rows]");

            // Rows the user never touched keep their original typed value
            // (number, boolean, nested object) instead of being stringified.
            const typed = new WeakMap();

            let initial = {};
            try {
              initial = JSON.parse(hidden.value || "{}");
            } catch (_e) {
              initial = {};
            }

            rowsEl.querySelectorAll("[data-prop-row]").forEach((row) => {
              const key = row.querySelector("[data-prop-key]").value;
              if (Object.prototype.hasOwnProperty.call(initial, key)) {
                typed.set(row, { key: key, value: initial[key] });
              }
            });

            const renderValue = (v) =>
              typeof v === "string" ? v : JSON.stringify(v);

            const entries = () => {
              const out = [];
              rowsEl.querySelectorAll("[data-prop-row]").forEach((row) => {
                const key = row.querySelector("[data-prop-key]").value.trim();
                if (key.length === 0) return;
                const valueInput = row.querySelector("[data-prop-value]");
                const orig = typed.get(row);
                let value = valueInput.value;
                if (orig && orig.key === key && renderValue(orig.value) === valueInput.value) {
                  value = orig.value;
                }
                out.push([key, value]);
              });
              return out;
            };

            const sync = () => {
              const obj = {};
              entries().forEach(([k, v]) => {
                obj[k] = v;
              });
              hidden.value = Object.keys(obj).length > 0 ? JSON.stringify(obj) : "";
            };

            const buildRow = (key = "", value = "") => {
              const div = document.createElement("div");
              div.className = "flex items-center gap-1.5";
              div.dataset.propRow = "";

              const keyInput = document.createElement("input");
              keyInput.type = "text";
              keyInput.dataset.propKey = "";
              keyInput.value = key;
              keyInput.placeholder = keyInput.dataset.placeholder || "";
              keyInput.autocomplete = "off";
              keyInput.spellcheck = false;
              keyInput.className =
                "min-w-0 flex-1 rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 font-mono text-sm focus:outline-none focus:ring-1 focus:ring-primary";

              const sep = document.createElement("span");
              sep.className = "select-none text-base-content/30";
              sep.setAttribute("aria-hidden", "true");
              sep.textContent = "=";

              const valueInput = document.createElement("input");
              valueInput.type = "text";
              valueInput.dataset.propValue = "";
              valueInput.value = value;
              valueInput.placeholder = valueInput.dataset.placeholder || "";
              valueInput.autocomplete = "off";
              valueInput.spellcheck = false;
              valueInput.className =
                "min-w-0 flex-[1.4] rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 font-mono text-sm focus:outline-none focus:ring-1 focus:ring-primary";

              const btn = document.createElement("button");
              btn.type = "button";
              btn.dataset.propRemove = "";
              btn.className =
                "btn btn-ghost btn-xs btn-square shrink-0 text-base-content/40 hover:text-error";
              btn.textContent = "×";

              div.appendChild(keyInput);
              div.appendChild(sep);
              div.appendChild(valueInput);
              div.appendChild(btn);
              return div;
            };

            // Copy placeholders from the server-rendered rows so dynamically
            // added rows speak the same language as the initial ones.
            const firstKey = rowsEl.querySelector("[data-prop-key]");
            const firstValue = rowsEl.querySelector("[data-prop-value]");
            if (firstKey) buildRow.keyPlaceholder = firstKey.placeholder;
            if (firstValue) buildRow.valuePlaceholder = firstValue.placeholder;
            const placeholders = {
              key: firstKey ? firstKey.placeholder : "Key",
              value: firstValue ? firstValue.placeholder : "Value",
            };

            const addRow = (key = "", value = "") => {
              const row = buildRow(key, value);
              row.querySelector("[data-prop-key]").placeholder = placeholders.key;
              row.querySelector("[data-prop-value]").placeholder = placeholders.value;
              rowsEl.appendChild(row);
              row.querySelector("[data-prop-key]").focus();
              sync();
            };

            rowsEl.addEventListener("input", sync);

            rowsEl.addEventListener("keydown", (e) => {
              if (e.key !== "Enter") return;
              e.preventDefault();
              const row = e.target.closest("[data-prop-row]");
              if (e.target.matches("[data-prop-key]")) {
                row.querySelector("[data-prop-value]").focus();
              } else {
                addRow();
              }
            });

            rowsEl.addEventListener("click", (e) => {
              const btn = e.target.closest("[data-prop-remove]");
              if (btn) {
                btn.closest("[data-prop-row]").remove();
                sync();
              }
            });

            root.querySelector("[data-prop-add]").addEventListener("click", () => addRow());
          }
        };
      </script>
    </div>
    """
  end

  # Rows for the initial server render. Accepts the persisted map, a JSON
  # string (live form value mid-edit), or anything else (→ no rows). Nested or
  # non-string values are JSON-encoded for display; the hidden input keeps the
  # original map so types survive unless the user edits them.
  defp props_rows(value), do: value |> props_map() |> Enum.map(&format_prop_row/1)

  defp props_map(value) when is_map(value) and not is_struct(value) do
    value |> Enum.take(50) |> Map.new()
  end

  defp props_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> props_map(decoded)
      _ -> %{}
    end
  end

  defp props_map(_), do: %{}

  defp format_prop_row({key, value}) when is_binary(value), do: {to_string(key), value}
  defp format_prop_row({key, value}), do: {to_string(key), Jason.encode!(value)}

  # ── Tuple normalisation ───────────────────────────────────────────────────
  #
  # `meta_fields_for/1` returns tuples of variable arity. We normalise every
  # shape to a canonical `{type, key, label, opts}` where `opts` is always a
  # keyword list (possibly empty). The supported shapes are:
  #
  #   * `{:type, key, label}`                                → opts = []
  #   * `{:type, key, label, keyword_opts}`                  → opts as-is
  #   * `{:type, key, label, options_list}`                  → opts = [options: options_list]
  #   * `{:type, key, label, options_list, keyword_opts}`    → opts merged
  #
  # The `:select` type historically carries its option list as the 4th element;
  # we preserve that under `opts[:options]` so the renderer has a single place
  # to look. Unknown opts (placeholder, step, min, max, condition, …) are
  # passed through untouched — only `:condition` is treated specially below.
  defp normalise_meta_field({type, key, label})
       when is_atom(type) and is_binary(key) and is_binary(label) do
    {type, key, label, []}
  end

  defp normalise_meta_field({type, key, label, opts})
       when is_atom(type) and is_binary(key) and is_binary(label) and is_list(opts) do
    # The 4th element is a list. It may be a keyword list of opts (e.g.
    # `condition: {:kind, "reminder"}`) or a select options list (list of
    # `{String, String}` tuples). Disambiguate by inspecting the first element.
    if keyword_list?(opts) do
      {type, key, label, opts}
    else
      {type, key, label, [options: opts]}
    end
  end

  defp normalise_meta_field({type, key, label, options, extra_opts})
       when is_atom(type) and is_binary(key) and is_binary(label) and
              is_list(options) and is_list(extra_opts) do
    # 5-arity: options list + trailing keyword opts.
    merged = Keyword.merge([options: options], extra_opts)
    {type, key, label, merged}
  end

  # A keyword list is a list of 2-tuples whose first element is an atom.
  # A select options list is a list of 2-tuples whose first element is a
  # binary. This distinction is what lets us tell the two apart without
  # relying on field count alone.
  defp keyword_list?([]), do: true

  defp keyword_list?([{k, _} | _]) when is_atom(k), do: true

  defp keyword_list?(_), do: false

  # ── Condition evaluation ──────────────────────────────────────────────────
  #
  # A field with `condition: {field, expected}` is only rendered when the
  # current value of `field` equals `expected`. The value is resolved in this
  # order:
  #
  #   1. Live form params — when the parent `<.form phx-change="…">` re-renders
  #      the component, the form carries the latest user input under
  #      `page[meta][field]`. This gives real-time reactivity: changing the
  #      `kind` select immediately shows/hides conditional fields without a
  #      save round-trip.
  #   2. Persisted `@meta` map — fallback for the initial render before any
  #      change event has fired, or when no `:form` assign is passed.
  #
  # `@meta` may use either atom or string keys; we check both. Malformed
  # conditions (anything that isn't a 2-tuple) fail open — the field stays
  # visible — so a bad condition never silently hides user data.
  defp condition_met?({field, expected}, meta, form) do
    meta_value(meta, form, field) == expected
  end

  defp condition_met?(_, _meta, _form), do: true

  # ── Value resolution ──────────────────────────────────────────────────────
  #
  # Resolve the current value of a meta field, preferring the live form value
  # over the persisted meta. `@meta` may carry atom or string keys.
  defp meta_value(meta, form, key) when is_atom(key) do
    live = live_form_value(form, key)

    if live != nil and live != "" do
      live
    else
      Map.get(meta, key) || Map.get(meta, to_string(key)) || ""
    end
  end

  defp meta_value(meta, form, key) when is_binary(key) do
    live = live_form_value(form, key)

    if live != nil and live != "" do
      live
    else
      Map.get(meta, key) || Map.get(meta, String.to_existing_atom(key)) || ""
    end
  end

  # Extract the live value of a meta field from a `Phoenix.HTML.Form`'s params.
  # Meta fields are submitted under `page[meta][key]`, so the form params (when
  # built from a changeset via `to_form/2`) will carry them under a nested
  # "meta" map. We coerce the key to its string form for lookup.
  defp live_form_value(nil, _key), do: nil

  defp live_form_value(%Phoenix.HTML.Form{params: params}, key) when is_map(params) do
    meta_params = Map.get(params, "meta") || Map.get(params, :meta) || %{}
    str_key = to_string(key)
    Map.get(meta_params, str_key) || Map.get(meta_params, key)
  end

  defp live_form_value(_form, _key), do: nil

  @doc """
  Tag input with badge chips. Typing + Enter/comma adds a chip; Backspace on
  an empty input removes the last chip; the × button removes a chip. A hidden
  input keeps the canonical comma-separated value so plain form submits work
  unchanged (the server keeps receiving `"uno,dos"` in the `:name` param).

  Purely client-side via a colocated hook — no server round-trips.

  ## Assigns

  - `:id` (required) — unique DOM id prefix.
  - `:name` (required) — form field name carried by the hidden input.
  - `:value` — comma-separated string or list of current tags.
  - `:label` — field label.
  - `:placeholder` — input placeholder.
  - `:suggestions` — list of existing tags for datalist autocomplete.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :label, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :suggestions, :list, default: []

  def tag_input(assigns) do
    tags =
      case assigns.value do
        list when is_list(list) -> list
        str when is_binary(str) -> String.split(str, ",", trim: true) |> Enum.map(&String.trim/1)
        _ -> []
      end

    assigns =
      assigns
      |> assign(:tags, tags)
      |> assign(:placeholder, assigns.placeholder || gettext("Add tag…"))
      |> assign(:label, assigns.label || gettext("Tags"))

    ~H"""
    <div id={@id} phx-hook=".TagInput" data-tag-input>
      <label for={"#{@id}-input"} class="label mb-1 block text-sm font-medium text-base-content/70">
        {@label}
      </label>
      <div class="flex flex-wrap items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-2.5 py-2 transition-colors focus-within:ring-1 focus-within:ring-primary">
        <span
          :for={tag <- @tags}
          data-tag-chip={tag}
          class="inline-flex items-center gap-1 rounded-full bg-primary/10 text-primary text-xs px-2.5 py-1"
        >
          {tag}
          <button
            type="button"
            data-tag-remove={tag}
            aria-label={gettext("Remove tag %{tag}", tag: tag)}
            class="hover:text-primary/60 transition-colors"
          >
            ×
          </button>
        </span>
        <input
          id={"#{@id}-input"}
          type="text"
          data-tag-field
          list={"#{@id}-suggestions"}
          placeholder={if @tags == [], do: @placeholder, else: ""}
          autocomplete="off"
          class="flex-1 min-w-24 bg-transparent text-sm focus:outline-none placeholder:text-base-content/40"
        />
      </div>
      <datalist id={"#{@id}-suggestions"}>
        <option :for={s <- @suggestions} value={s} />
      </datalist>
      <input type="hidden" name={@name} value={Enum.join(@tags, ",")} data-tag-value />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TagInput">
        export default {
          mounted() {
            const root = this.el;
            const field = root.querySelector("[data-tag-field]");
            const hidden = root.querySelector("[data-tag-value]");

            const tags = () =>
              hidden.value.split(",").map((t) => t.trim()).filter((t) => t.length > 0);

            const chip = (tag) => {
              const span = document.createElement("span");
              span.dataset.tagChip = tag;
              span.className =
                "inline-flex items-center gap-1 rounded-full bg-primary/10 text-primary text-xs px-2.5 py-1";
              span.textContent = tag;
              const btn = document.createElement("button");
              btn.type = "button";
              btn.dataset.tagRemove = tag;
              btn.className = "hover:text-primary/60 transition-colors";
              btn.textContent = "×";
              span.appendChild(document.createTextNode(" "));
              span.appendChild(btn);
              return span;
            };

            const sync = (next) => {
              hidden.value = next.join(",");
              root.querySelectorAll("[data-tag-chip]").forEach((el) => el.remove());
              next.forEach((tag) => field.before(chip(tag)));
              field.placeholder = next.length === 0 ? field.dataset.placeholder || "" : "";
            };

            field.dataset.placeholder = field.placeholder;

            field.addEventListener("keydown", (e) => {
              if (e.key === "Enter" || e.key === ",") {
                e.preventDefault();
                const tag = field.value.trim().replace(/,+$/, "");
                if (tag.length > 0 && !tags().includes(tag)) {
                  sync([...tags(), tag]);
                }
                field.value = "";
              } else if (e.key === "Backspace" && field.value === "") {
                const current = tags();
                if (current.length > 0) sync(current.slice(0, -1));
              }
            });

            root.addEventListener("click", (e) => {
              const btn = e.target.closest("[data-tag-remove]");
              if (btn) {
                sync(tags().filter((t) => t !== btn.dataset.tagRemove));
              }
            });
          }
        };
      </script>
    </div>
    """
  end
end
