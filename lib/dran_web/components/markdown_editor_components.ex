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
  - `:context_id` (required) — used to scope wikilink/embed resolution and uploads.
  - `:upload` (optional) — a `Phoenix.LiveView.UploadConfig` for file uploads.
  - `:save_status` (optional) — `"saving" | "saved" | "idle"` for the indicator.
  - `class` (optional) — extra classes for the outer container.
  """
  attr :id, :string, required: true
  attr :body, :string, required: true
  attr :context_id, :string, required: true
  attr :save_status, :string, default: "idle"
  attr :class, :string, default: ""

  def markdown_editor(assigns) do
    ~H"""
    <div
      id={"editor-wrapper-#{@id}"}
      class={["md-editor flex flex-col rounded-lg border border-base-300 overflow-hidden", @class]}
    >
      <.editor_toolbar id={@id} />
      <.editor_status status={@save_status} />

      <div
        id={@id}
        phx-hook="MarkdownEditor"
        phx-update="ignore"
        class="md-editor-mount flex-1 min-h-[300px] bg-base-100 overflow-y-auto"
        data-body={@body}
        data-context-id={@context_id}
      >
        <div
          class="tiptap-content prose prose-base dark:prose-invert max-w-none"
          data-placeholder="Escribe algo… o usa / para comandos"
        >
        </div>
      </div>
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
      <.tb_btn id={@id} cmd="orderedList" icon="hero-list-bullet" label="1." />
      <.tb_btn id={@id} cmd="blockquote" icon="hero-chat-bubble-left" label="" />
      <.tb_btn id={@id} cmd="codeBlock" icon="hero-code-bracket-square" label="" />
      <div class="tb-separator" aria-hidden="true"></div>
      <.tb_btn id={@id} cmd="link" icon="hero-link" label="" testid="tb-link" />
      <.tb_btn id={@id} cmd="wikilink" icon="hero-link" label="[[]]" />
      <.tb_btn id={@id} cmd="embed" icon="hero-photo" label="![]" />
      <.tb_btn id={@id} cmd="table" icon="hero-table" label="" />
      <div class="tb-separator" aria-hidden="true"></div>
      <.tb_btn id={@id} cmd="undo" icon="hero-arrow-uturn-left" label="" />
      <.tb_btn id={@id} cmd="redo" icon="hero-arrow-uturn-right" label="" />
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

  `Dran.Brain.PageMeta.meta_fields_for/1` returns tuples of variable arity:

      {:date, "due_date", "Due date"}
      {:select, "kind", "Kind", [{"Thought", "thought"}, ...]}
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
  attr :context_id, :any, required: true

  def meta_fields(assigns) do
    raw_fields = Dran.Brain.PageMeta.meta_fields_for(assigns.page_type)
    fields = Enum.map(raw_fields, &normalise_meta_field/1)
    {link_fields, plain_fields} = Enum.split_with(fields, fn {type, _, _, _} -> type == :slug_select end)

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
        <div class="grid grid-cols-2 gap-4">
          <%= for {type, key, label, opts} <- @link_fields do %>
            <% value = meta_value(@meta, @form, key) %>
            <.meta_field_input
              type={type}
              key={key}
              label={label}
              opts={opts}
              value={value}
              context_id={@context_id}
            />
          <% end %>
        </div>
      </div>
      <div class="grid grid-cols-2 gap-4">
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
              context_id={@context_id}
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
  attr :context_id, :any, default: nil

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
          prompt={gettext("None")}
          label={@label}
        />
      <% :slug_select -> %>
        <% slug_type = Keyword.get(@opts, :type) %>
        <% pages =
          if @context_id do
            Dran.Brain.list_pages(context_id: @context_id, type: slug_type)
          else
            []
          end %>
        <% options = Enum.map(pages, fn p -> {p.title, p.slug} end) %>
        <.input
          type="select"
          name={"page[meta][#{@key}]"}
          value={@value}
          options={options}
          prompt={gettext("None")}
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
    <% end %>
    """
  end

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
end
