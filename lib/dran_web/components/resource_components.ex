defmodule DranWeb.ResourceComponents do
  @moduledoc """
  Shared shell components for resource (goal / task / page) create & edit.

  The resource pattern: create and edit are dedicated pages — `/new` and
  `/:id?edit=true` — assembled from these pieces so every resource looks
  and behaves the same:

    - `resource_header` — back link, icon, title, subtitle, action buttons
    - `form_actions` — the cancel/submit row
    - `markdown_body_field` — labelled Tiptap body editor (Mermaid included)
    - `goal_options` / `actor_options` — flattened option lists for selects
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext

  import DranWeb.CoreComponents, only: [icon: 1]
  import DranWeb.MarkdownEditorComponents, only: [markdown_editor: 1]

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
        <button type="submit" class="btn btn-primary btn-sm" disabled={@submit_disabled}>
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
  attr :toolbar, :boolean, default: true
  attr :min_height, :string, default: "220px"

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
        toolbar={@toolbar}
        hidden_field={@hidden_field}
        min_height={@min_height}
      />
    </div>
    """
  end

  @doc """
  Flattened, indented `<option>` list for goal selects — works at any
  hierarchy depth (a native `<optgroup>` cannot nest). `tree` comes from
  `Dran.Goals.flattened_tree/1` (`[{goal, depth}]`).
  """
  attr :tree, :list, required: true
  attr :selected_id, :string, required: true

  def goal_options(assigns) do
    ~H"""
    <option :for={{goal, depth} <- @tree} value={goal.id} selected={@selected_id == goal.id}>
      {String.duplicate("—", depth + 1)} {goal.title}
    </option>
    """
  end

  @doc """
  Flat `<option>` list of assignee actors (agent + user), labelled via
  `Dran.Actors.Actor.label/1`.
  """
  attr :actors, :list, required: true
  attr :selected_id, :string, required: true

  def actor_options(assigns) do
    ~H"""
    <option :for={actor <- @actors} value={actor.id} selected={@selected_id == actor.id}>
      {Dran.Actors.Actor.label(actor)}
    </option>
    """
  end
end
