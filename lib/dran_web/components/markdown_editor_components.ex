defmodule DranWeb.MarkdownEditorComponents do
  @moduledoc """
  Shared function components for the TipTap-based markdown editor.

  The editor is rendered via the `.MarkdownEditor` JS hook (see
  `assets/js/hooks/markdown_editor.js`) which mounts a TipTap editor
  with bidirectional Markdown support and custom wikilink/embed nodes.
  """

  use Phoenix.Component
  import DranWeb.CoreComponents, only: [icon: 1]

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
      class="tb-btn inline-flex items-center justify-center min-w-7 h-7 px-1.5 rounded text-sm text-base-content/70 hover:bg-base-300 hover:text-base-content transition"
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
  based on the page type. Reads from `@form[:meta_kind]`, `@form[:meta_horizon]`,
  etc. — the LiveView must expose these as form fields.
  """
  attr :page_type, :string, required: true
  attr :meta, :map, default: %{}

  def meta_fields(assigns) do
    fields = Dran.Brain.PageMeta.meta_fields_for(assigns.page_type)
    assigns = assign(assigns, :fields, fields)

    ~H"""
    <div :if={@fields != []} class="space-y-4">
      <div class="text-sm font-semibold text-base-content/70">Metadata</div>
      <div class="grid grid-cols-2 gap-4">
        <%= for {type, key, label, opts} <- @fields do %>
          <% value = Map.get(@meta, key) || Map.get(@meta, to_string(key)) || "" %>
          <%= case type do %>
            <% :select -> %>
              <div>
                <span class="block text-sm font-medium text-base-content/70 mb-1.5">{label}</span>
                <select
                  name={"page[meta][#{key}]"}
                  class="select select-bordered w-full text-sm rounded-lg border-base-300 bg-base-100"
                >
                  <option value=""></option>
                  <%= for {opt_label, opt_val} <- opts do %>
                    <option value={opt_val} selected={value == opt_val}>{opt_label}</option>
                  <% end %>
                </select>
              </div>
            <% :date -> %>
              <div>
                <span class="block text-sm font-medium text-base-content/70 mb-1.5">{label}</span>
                <input
                  type="date"
                  name={"page[meta][#{key}]"}
                  value={value}
                  class="input input-bordered w-full text-sm rounded-lg border-base-300 bg-base-100"
                />
              </div>
            <% :text -> %>
              <div>
                <span class="block text-sm font-medium text-base-content/70 mb-1.5">{label}</span>
                <input
                  type="text"
                  name={"page[meta][#{key}]"}
                  value={value}
                  placeholder={label}
                  class="input input-bordered w-full text-sm rounded-lg border-base-300 bg-base-100"
                />
              </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
