defmodule DranWeb.TaskComponents do
  @moduledoc """
  El modal y el form de una task — UNO para las cuatro superficies.

  La task se edita igual en el board y en el detalle del goal; lo que cambia es
  qué puede ofrecer cada superficie, y eso llega por atributo:

    - `goal_options` — el selector de contenedor. SÓLO el alta del board lo pasa:
      ahí el goal es la decisión de dónde nace la task. El detalle del goal ya
      tiene el suyo (es la ruta) y la edición no la mueve de goal.
    - `task` — la fila en edición: monta `task_id` + `lock_version` (el RMW del
      checklist los exige).
    - `checklist` — el editor de pasos: SÓLO la edición. El alta nace sin pasos.
    - `on_delete` — el botón destructivo del footer (board y detalle del goal).

  El form es `to_form/1` (del changeset en la edición, de un mapa en el alta) y
  los campos van con `<.input>`: el mismo molde que pages/goals/plans. Los ids
  son `"<prefix>-<campo>"`, así cada superficie conserva su ancla estable sin
  duplicar markup.

  El CUERPO (`body`) va con el editor markdown compartido
  (`markdown_body_field`, el mismo de goals y plans): el contenido de una task se
  escribe con el editor de la casa, no con un textarea propio. El form lo manda
  como `task[body]` y el submit lo guarda con el resto del contenido.
  """

  use Phoenix.Component
  use Gettext, backend: DranWeb.Gettext

  import DranWeb.CoreComponents, only: [icon: 1, input: 1]
  import DranWeb.MarkdownEditorComponents, only: [checklist_editor: 1]
  import DranWeb.ResourceComponents, only: [markdown_body_field: 1, resource_modal: 1]

  @doc """
  El modal completo de una task (alta o edición), con el form adentro.

  `submit` es el evento que recibe el submit; `prefix` da los ids de los campos
  y `task` (sólo en edición) los hidden `task_id`/`lock_version`.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_close, :string, required: true
  attr :form, :any, required: true
  attr :form_id, :string, required: true
  attr :prefix, :string, required: true
  attr :submit, :string, required: true
  attr :submit_label, :string, required: true
  attr :workspace_id, :string, required: true, doc: "para el editor markdown (wikilinks/uploads)"
  attr :statuses, :list, required: true, doc: "pares {etiqueta, valor}"
  attr :priorities, :list, required: true
  attr :task, :map, default: nil, doc: "la fila en edición; nil = alta"
  attr :goal_options, :list, default: nil, doc: "pares {título, id}; nil = sin selector"
  attr :checklist, :any, default: nil, doc: "valor del editor de pasos; nil = sin editor"
  attr :on_delete, :string, default: nil, doc: "evento del borrado; nil = sin botón"

  def task_modal(assigns) do
    ~H"""
    <.resource_modal
      id={@id}
      title={@title}
      pill="TASK"
      on_close={@on_close}
      form_id={@form_id}
      submit_label={@submit_label}
      cancel_label={gettext("Cancel")}
      max_w="max-w-2xl"
    >
      <:left :if={@on_delete}>
        <button
          type="button"
          id={"#{@prefix}-delete"}
          phx-click={@on_delete}
          phx-value-task_id={@task.id}
          data-confirm={gettext("Delete this task?")}
          class="btn btn-ghost btn-sm text-error"
        >
          <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
        </button>
      </:left>

      <.task_form
        form={@form}
        id={@form_id}
        prefix={@prefix}
        submit={@submit}
        workspace_id={@workspace_id}
        statuses={@statuses}
        priorities={@priorities}
        task={@task}
        goal_options={@goal_options}
        checklist={@checklist}
      />
    </.resource_modal>
    """
  end

  @doc """
  Los campos de una task: título · [goal] · estado · prioridad · fecha ·
  [pasos]. El orden es el del alta en todas las superficies.
  """
  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :prefix, :string, required: true
  attr :submit, :string, required: true
  attr :workspace_id, :string, required: true
  attr :statuses, :list, required: true
  attr :priorities, :list, required: true
  attr :task, :map, default: nil
  attr :goal_options, :list, default: nil
  attr :checklist, :any, default: nil

  def task_form(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit={@submit} class="space-y-5">
      <%!-- La fila en edición viaja por hidden: el RMW del checklist necesita la
      versión con la que se abrió el modal. --%>
      <input :if={@task} type="hidden" name="task_id" value={@task.id} />
      <input :if={@task} type="hidden" name="lock_version" value={@task.lock_version} />

      <.input
        field={@form[:title]}
        type="text"
        id={"#{@prefix}-title"}
        label={gettext("Title")}
        required
      />

      <%!-- El cuerpo: el MISMO editor markdown de goals y plans (sin autosave:
      en un modal se guarda con el submit, como ellos). --%>
      <.markdown_body_field
        id={"#{@prefix}-editor"}
        body={to_string(@form[:body].value || "")}
        workspace_id={@workspace_id}
        hidden_field="task[body]"
        autosave={false}
        label={gettext("Body")}
      />

      <%!-- El contenedor: sólo donde es una decisión (el alta del board). El
      selector ofrece los goals legibles; vacío = bandeja. --%>
      <.input
        :if={@goal_options}
        field={@form[:goal_id]}
        type="select"
        id={"#{@prefix}-goal-select"}
        label={gettext("Goal")}
        prompt={gettext("Owner inbox")}
        options={@goal_options}
      />

      <div class="grid grid-cols-2 gap-4">
        <.input
          field={@form[:status]}
          type="select"
          id={"#{@prefix}-status"}
          label={gettext("Status")}
          options={@statuses}
        />
        <.input
          field={@form[:priority]}
          type="select"
          id={"#{@prefix}-priority"}
          label={gettext("Priority")}
          prompt={gettext("No priority")}
          options={@priorities}
        />
      </div>

      <.input
        field={@form[:due_date]}
        type="date"
        id={"#{@prefix}-due"}
        label={gettext("Due on")}
      />

      <%!-- Los pasos: la edición los ofrece (una task nueva nace sin pasos) y el
      array se guarda por su puerta (RMW + lock_version). --%>
      <div :if={!is_nil(@checklist)} class="border-t border-base-300 pt-5">
        <h3 class="text-sm font-semibold text-base-content/70 mb-3">{gettext("Steps")}</h3>
        <.checklist_editor id={"#{@prefix}-checklist"} name="checklist" value={@checklist} />
        <p class="mt-1.5 text-xs leading-snug text-base-content/50">
          {gettext("Ordered steps. Checking one does not create a task.")}
        </p>
      </div>
    </.form>
    """
  end
end
