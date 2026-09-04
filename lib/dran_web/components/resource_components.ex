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
    - `resource_modal` — near-full-screen create/edit modal shell
    - `task_form_fields` — task create/edit form for the modal
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext

  import DranWeb.CoreComponents, only: [icon: 1, input: 1]
  import DranWeb.MarkdownEditorComponents, only: [markdown_editor: 1]
  import Phoenix.HTML.Form, only: [input_value: 2]

  alias Dran.Task

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

  Options come pre-rendered (use `<.goal_options>` / `<.actor_options>` for
  hierarchical and actor lists); `selected` must already be set on each
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

  @doc """
  Task form for the resource modal — main column (title + body editor) and
  the metadata sidebar (status / assignee / priority / goal / due date).

  One `<.form>` spans BOTH columns (title/body in main, the sidebar fields
  are its selects too) — a single submit carries everything. The editor
  runs WITHOUT toolbar (approved mockup): markdown syntax + shortcuts,
  autosave off, hidden field synced on submit via the MarkdownEditor hook.

  - `task` — the struct (new tasks pass `%Task{}` with defaults applied)
  - `changeset` — form source; `form_id` must match the modal footer button
  - `goal_tree` / `actors` — flattened goal tree + managed actors
  """
  attr :id, :string, required: true
  attr :task, :map, required: true
  attr :changeset, :any, required: true
  attr :workspace_id, :string, required: true
  attr :goal_tree, :list, required: true
  attr :actors, :list, required: true
  attr :goal_id, :string, required: true
  attr :editor_min_height, :string, default: "320px"

  def task_form_fields(assigns) do
    %Task{} = task = assigns.task
    editor_id = "task-editor-modal-#{task.id || "new"}"

    assigns =
      assigns
      |> assign(:editor_id, editor_id)
      |> assign(:form, to_form(assigns.changeset, as: :task))

    ~H"""
    <.form
      id={@id}
      for={@form}
      phx-change="validate_task"
      phx-submit="save_task"
      class="grid grid-cols-1 lg:grid-cols-[1fr_20rem] lg:gap-6"
    >
      <div class="min-w-0 space-y-4">
        <.input
          field={@form[:title]}
          type="text"
          label={gettext("Title")}
          placeholder={gettext("Task title…")}
          class="text-lg font-medium"
          autofocus
        />

        <div>
          <span class="label mb-1 block text-xs text-base-content/60">{gettext("Content")}</span>
          <.markdown_editor
            id={@editor_id}
            body={@task.body || ""}
            workspace_id={@workspace_id}
            autosave={false}
            toolbar={false}
            hidden_field="task[body]"
            min_height={@editor_min_height}
          />
        </div>
      </div>

      <aside class="space-y-4 lg:border-l lg:border-base-300 lg:pl-6">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          {gettext("Details")}
        </h4>

        <.resource_select name="task[status]" label={gettext("Status")}>
          <%= for s <- Task.statuses() do %>
            <option value={s} selected={status_selected(@form, s)}>{status_label(s)}</option>
          <% end %>
        </.resource_select>

        <.resource_select name="task[assignee_actor_id]" label={gettext("Assignee")}>
          <option value="" selected={is_nil(input_value(@form, :assignee_actor_id))}>
            {gettext("unassigned")}
          </option>
          <.actor_options actors={@actors} selected_id={input_value(@form, :assignee_actor_id)} />
        </.resource_select>

        <.resource_select name="task[priority]" label={gettext("Priority")}>
          <option value="" selected={is_nil(input_value(@form, :priority))}>
            {gettext("none")}
          </option>
          <%= for p <- Task.priorities() do %>
            <option value={p} selected={input_value(@form, :priority) == p}>{p}</option>
          <% end %>
        </.resource_select>

        <.resource_select name="task[goal_id]" label={gettext("Goal")}>
          <option value="" selected={is_nil(@goal_id)}>{gettext("no goal")}</option>
          <.goal_options tree={@goal_tree} selected_id={@goal_id} />
        </.resource_select>

        <label class="block">
          <span class="text-xs text-base-content/60">{gettext("Due date")}</span>
          <input
            type="date"
            name="task[due_date]"
            value={due_date_value(@task)}
            class="mt-1 w-full text-sm px-2 py-2 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none"
          />
        </label>
      </aside>
    </.form>
    """
  end

  defp status_selected(form, status) do
    case Phoenix.HTML.Form.input_value(form, :status) do
      nil -> status == "backlog"
      val -> to_string(val) == status
    end
  end

  defp status_label("backlog"), do: gettext("Backlog")
  defp status_label("todo"), do: gettext("To Do")
  defp status_label("in_progress"), do: gettext("In Progress")
  defp status_label("done"), do: gettext("Done")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label(other), do: other

  defp due_date_value(%Task{due_date: %Date{} = d}), do: Date.to_iso8601(d)
  defp due_date_value(_), do: ""

  @doc """
  Goal form for the resource modal — same two-column contract as
  `task_form_fields`: main column (title, description, body editor) and
  metadata sidebar (status).

  - `goal` — the struct (`%Goal{}` for create)
  - `changeset` — form source; id must match the modal footer button
  """
  attr :id, :string, required: true
  attr :goal, :map, required: true
  attr :changeset, :any, required: true
  attr :workspace_id, :string, required: true
  attr :editor_min_height, :string, default: "320px"

  def goal_form_fields(assigns) do
    editor_id = "goal-editor-modal-#{assigns.goal.id || "new"}"

    assigns =
      assigns
      |> assign(:editor_id, editor_id)
      |> assign(:form, to_form(assigns.changeset, as: :goal))

    ~H"""
    <.form
      id={@id}
      for={@form}
      phx-change="validate_goal"
      phx-submit="save_goal"
      class="grid grid-cols-1 lg:grid-cols-[1fr_20rem] lg:gap-6"
    >
      <div class="min-w-0 space-y-4">
        <.input
          field={@form[:title]}
          type="text"
          label={gettext("Title")}
          placeholder={gettext("Goal title…")}
          class="text-lg font-medium"
          autofocus
        />

        <.input
          field={@form[:summary]}
          type="textarea"
          label={gettext("Summary")}
          rows={2}
        />

        <div>
          <span class="label mb-1 block text-xs text-base-content/60">{gettext("Content")}</span>
          <.markdown_editor
            id={@editor_id}
            body={@goal.body || ""}
            workspace_id={@workspace_id}
            autosave={false}
            toolbar={false}
            hidden_field="goal[body]"
            min_height={@editor_min_height}
          />
        </div>
      </div>

      <aside class="space-y-4 lg:border-l lg:border-base-300 lg:pl-6">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          {gettext("Details")}
        </h4>

        <.resource_select name="goal[status]" label={gettext("Status")}>
          <option value="active" selected={input_value(@form, :status) == "active"}>Active</option>
          <option value="draft" selected={input_value(@form, :status) == "draft"}>Draft</option>
          <option value="on_hold" selected={input_value(@form, :status) == "on_hold"}>
            On Hold
          </option>
          <option value="done" selected={input_value(@form, :status) == "done"}>Done</option>
        </.resource_select>
      </aside>
    </.form>
    """
  end

  @doc """
  Build task attrs from modal form params — THE single mapping shared by
  create and edit (board modal, TaskLive, anywhere else). Empty selects =
  clear (unassign / no priority / no due date / detach goal via
  `Tasks.set_goal/2`).

  Returns `%{attrs: attrs, goal_id: goal_id | nil}` — call
  `Tasks.create_task/1` (or `update_task`) with `attrs`, then
  `Tasks.set_goal/2` when `goal_id` is present. Callers inject identity
  fields themselves (`created_by` / `updated_by` / `workspace_id`).
  """
  def task_attrs_from_params(params) when is_map(params) do
    attrs = %{
      "title" => String.trim(params["title"] || ""),
      "body" => params["body"] || ""
    }

    attrs =
      case params["status"] do
        s when is_binary(s) ->
          if s in Task.statuses(), do: Map.put(attrs, "status", s), else: attrs

        _ ->
          attrs
      end

    attrs =
      case params["assignee_actor_id"] do
        aid when is_binary(aid) and aid != "" -> Map.put(attrs, "assignee_actor_id", aid)
        _ -> Map.put(attrs, "assignee_actor_id", nil)
      end

    attrs =
      case params["priority"] do
        p when p in ~w(low medium high urgent) -> Map.put(attrs, "priority", p)
        _ -> Map.put(attrs, "priority", nil)
      end

    attrs =
      case params["due_date"] do
        date when is_binary(date) and date != "" -> Map.put(attrs, "due_date", date)
        _ -> Map.put(attrs, "due_date", nil)
      end

    goal_id =
      case params["goal_id"] do
        g when is_binary(g) and g != "" -> g
        _ -> nil
      end

    %{attrs: attrs, goal_id: goal_id}
  end
end
