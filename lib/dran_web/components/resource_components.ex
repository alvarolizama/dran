defmodule DranWeb.ResourceComponents do
  @moduledoc """
  Shared shell components for resource (page) create & edit.

  The resource pattern: create and edit are dedicated pages — `/new` and
  `/:id?edit=true` — assembled from these pieces so every resource looks
  and behaves the same:

    - `resource_header` — back link, icon, title, subtitle, action buttons
    - `form_actions` — the cancel/submit row
    - `markdown_body_field` — labelled Tiptap body editor (Mermaid included)
    - `resource_modal` — near-full-screen create/edit modal shell
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext

  import DranWeb.CoreComponents, only: [icon: 1]
  import DranWeb.MarkdownEditorComponents, only: [markdown_editor: 1]

  @doc """
  Full-screen-ish modal shell for resource create & edit.

  Layout (approved mockup): header (type pill + title + ✕), a two-column
  body — main content (default slot) + right metadata sidebar (`sidebar`
  slot) — and a footer with destructive actions on the left (`left` slot)
  and Cancel + Save on the right.

  Closes via the ✕ button, ESC or click-away, all firing `on_close`
  (typically a `push_patch` back to the base URL). The save button lives
  OUTSIDE the `<.form>` (in the footer) and targets it via the standard
  HTML `form=` attribute, so `form_id` must match the form's DOM id.

  The overlay is fixed and near-full-screen (small inset) — the underlying
  page stays mounted underneath.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :pill, :string, default: nil
  attr :pill_class, :string, default: "bg-primary/10 text-primary"
  attr :on_close, :string, required: true
  attr :form_id, :string, default: nil
  attr :submit_label, :string, default: nil
  attr :submit_disabled, :boolean, default: false
  attr :cancel_label, :string, default: nil
  attr :max_w, :string, default: "max-w-5xl"
  slot :sidebar
  slot :left
  slot :inner_block, required: true

  def resource_modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-overlay"}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 sm:p-6"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div
        id={@id}
        role="dialog"
        aria-modal="true"
        phx-click-away={@on_close}
        class={[
          "card bg-base-100 border border-base-300 shadow-2xl w-full flex flex-col overflow-hidden",
          "h-[calc(100vh-3rem)] sm:h-[calc(100vh-4rem)]",
          @max_w
        ]}
      >
        <%!-- Header --%>
        <div class="flex items-center justify-between px-5 py-3.5 border-b border-base-300 shrink-0">
          <div class="flex items-center gap-2.5 min-w-0">
            <span
              :if={@pill}
              class={["text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0", @pill_class]}
            >
              {@pill}
            </span>
            <h3 class="text-base font-semibold truncate">{@title}</h3>
          </div>
          <button
            type="button"
            phx-click={@on_close}
            class="btn btn-ghost btn-xs btn-circle shrink-0"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <%!-- Body: main + sidebar --%>
        <div class="flex-1 min-h-0 flex overflow-hidden">
          <div class="flex-1 min-w-0 overflow-y-auto p-6">
            {render_slot(@inner_block)}
          </div>
          <aside
            :if={@sidebar != []}
            class="hidden md:flex md:flex-col w-80 lg:w-96 shrink-0 border-l border-base-300 bg-base-200/40 overflow-y-auto p-5 gap-4"
          >
            <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              {gettext("Details")}
            </h4>
            {render_slot(@sidebar)}
          </aside>
        </div>

        <%!-- Footer --%>
        <div class="flex items-center justify-between px-5 py-3 border-t border-base-300 shrink-0">
          <div class="flex items-center gap-2">{render_slot(@left)}</div>
          <div class="flex items-center gap-2">
            <button type="button" phx-click={@on_close} class="btn btn-ghost btn-sm">
              {@cancel_label || gettext("Cancel")}
            </button>
            <button
              :if={@form_id}
              type="submit"
              form={@form_id}
              class="btn btn-primary btn-sm"
              disabled={@submit_disabled}
            >
              {@submit_label || gettext("Save")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Header shell for a resource page: optional back link, icon + title,
  optional subtitle, and an actions slot (Edit/View/Back buttons).
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: nil
  attr :back_label, :string, default: nil
  attr :back_href, :string, default: nil
  slot :actions

  def resource_header(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 mb-6">
      <div class="min-w-0 flex-1">
        <div
          :if={@back_href}
          class="flex items-center gap-1.5 text-caption text-base-content/50 mb-1"
        >
          <.link navigate={@back_href} class="hover:underline">
            {@back_label || gettext("Back")}
          </.link>
        </div>
        <h1 class="text-title flex items-center gap-2 break-words">
          <.icon :if={@icon} name={@icon} class="size-6 text-primary shrink-0" />
          {@title}
        </h1>
        <p :if={@subtitle} class="text-caption text-base-content/60 mt-1">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex gap-2 shrink-0">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  The cancel/submit row. Cancel is a link when `cancel_path` is set (create
  forms) or a button firing `cancel_event` when that is set (edit forms
  that toggle back to view mode). `left` slot holds extra buttons (archive,
  delete) on the opposite side.
  """
  attr :submit_label, :string, required: true
  attr :submit_icon, :string, default: nil
  attr :submit_testid, :string, default: nil
  attr :submit_disabled, :boolean, default: false
  attr :cancel_path, :string, default: nil
  attr :cancel_event, :string, default: nil
  attr :cancel_label, :string, default: nil
  slot :left

  def form_actions(assigns) do
    ~H"""
    <div class="flex items-center justify-between pt-2">
      <div class="flex items-center gap-2">{render_slot(@left)}</div>
      <div class="flex items-center gap-2">
        <%= if @cancel_event do %>
          <button type="button" phx-click={@cancel_event} class="btn btn-ghost btn-sm">
            {@cancel_label || gettext("Cancel")}
          </button>
        <% end %>
        <%= if @cancel_path do %>
          <.link navigate={@cancel_path} class="btn btn-ghost btn-sm">
            {@cancel_label || gettext("Cancel")}
          </.link>
        <% end %>
        <button
          type="submit"
          class="btn btn-primary btn-sm"
          disabled={@submit_disabled}
          data-testid={@submit_testid}
        >
          <.icon :if={@submit_icon} name={@submit_icon} class="size-4" />
          {@submit_label}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Labelled Tiptap body field — the standard content editor for every
  resource (Markdown bidirectional + Mermaid NodeView via the shared
  `.MarkdownEditor` hook). Autosave defaults to off: the resource pattern
  saves through the form's submit.
  """
  attr :id, :string, required: true
  attr :body, :string, required: true
  attr :workspace_id, :string, required: true
  attr :hidden_field, :string, default: "page[body]"
  attr :label, :string, default: nil
  attr :autosave, :boolean, default: false
  attr :save_status, :string, default: "idle"
  attr :toolbar, :boolean, default: true
  attr :min_height, :string, default: nil

  def markdown_body_field(assigns) do
    ~H"""
    <div>
      <span class="label mb-1 block text-xs text-base-content/60">
        {@label || gettext("Body")}
      </span>
      <.markdown_editor
        id={@id}
        body={@body}
        workspace_id={@workspace_id}
        autosave={@autosave}
        save_status={@save_status}
        toolbar={@toolbar}
        hidden_field={@hidden_field}
        min_height={@min_height}
      />
    </div>
    """
  end

  @doc """
  Labelled `<select>` — the canonical select for the app: daisyUI `.select`
  styling, small size, required `<label>` wrapper so the whole control is
  clickable. Use this for every bare `<select>` in templates.

  Options come pre-rendered; `selected` must already be set on each
  option. `phx-change` etc. go through `{@rest}`.
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(phx-change phx-value-* data-*)
  slot :inner_block, required: true

  def resource_select(assigns) do
    ~H"""
    <label class="block">
      <span class="text-xs text-base-content/60">{@label}</span>
      <select
        id={@id}
        name={@name}
        class={["select select-sm select-bordered w-full mt-1", @class]}
        {@rest}
      >
        {render_slot(@inner_block)}
      </select>
    </label>
    """
  end
end
