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

  `height` decides what the card does with the viewport: `fill` (default, the
  §C7.2 shell) stretches it to the viewport — the form of a big resource, where
  the editor grows with the screen; `auto` lets it measure its content and caps
  it at the viewport (`max-h`), so a short form — one field — is a short modal
  instead of a full-screen box with the field floating at the top. With `auto`
  a body taller than the viewport still scrolls inside the shell.
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
  attr :height, :string, default: "fill", values: ["fill", "auto"]
  slot :header
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
          height_class(@height),
          @max_w
        ]}
      >
        <%!-- Header: `flex-wrap` porque en pantallas angostas el control del
        header (el destino) baja de línea en vez de desbordar el modal. --%>
        <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 px-5 py-3.5 border-b border-base-300 shrink-0">
          <div class="flex items-center gap-2.5 min-w-0">
            <span
              :if={@pill}
              class={["text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0", @pill_class]}
            >
              {@pill}
            </span>
            <h3 class="text-base font-semibold truncate">{@title}</h3>
          </div>
          <%!-- El slot `header` es para un control que vive junto a la ✕ — el
          destino del recurso. Queda FUERA del `<form>` del body, así que sus
          inputs lo apuntan con el atributo HTML `form={@form_id}` (el mismo
          truco del botón Guardar del footer). --%>
          <div
            id={"#{@id}-header-actions"}
            class="flex items-center gap-2 shrink-0 min-w-0"
          >
            {render_slot(@header)}
            <button
              type="button"
              phx-click={@on_close}
              class="btn btn-ghost btn-xs btn-circle shrink-0"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
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

  # El alto del shell. `fill` (default, §C7.2): el modal casi full-screen de los
  # forms grandes, donde el editor crece con la pantalla. `auto`: el modal mide
  # lo que mide su contenido y sólo se acota al viewport (con el scroll adentro
  # del cuerpo), que es lo que quiere un form de un campo — antes quedaba
  # estirado a pantalla completa con el campo flotando arriba.
  defp height_class("auto"), do: "max-h-[calc(100vh-3rem)] sm:max-h-[calc(100vh-4rem)]"
  defp height_class(_fill), do: "h-[calc(100vh-3rem)] sm:h-[calc(100vh-4rem)]"

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
  attr :resolve_embeds, :boolean, default: false
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
        resolve_embeds={@resolve_embeds}
        save_status={@save_status}
        toolbar={@toolbar}
        hidden_field={@hidden_field}
        min_height={@min_height}
      />
    </div>
    """
  end

  @doc """
  Header of a resource LIST — the standard every collection surface shares.

  Title on the left (`text-title`), actions on the right, and the primary CTA
  («New») last. The CTA opens the create modal through URL state: pass
  `new_path` (`"?new=true"`) and it renders the standard patch link, or
  `new_event` when the surface owns the event (`phx-click`).

  Extra actions (a smart-collection link, an archived toggle) go in the
  `actions` slot, which renders BEFORE the CTA — the same order pages uses.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :new_path, :string, default: nil
  attr :new_event, :string, default: nil
  attr :new_id, :string, default: nil
  attr :new_label, :string, default: nil
  attr :new_testid, :string, default: nil
  slot :actions

  def resource_list_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
      <div class="min-w-0">
        <h1 class="text-title">{@title}</h1>
        <p :if={@subtitle} class="text-caption mt-1">{@subtitle}</p>
      </div>
      <div class="flex gap-2">
        {render_slot(@actions)}
        <.link
          :if={@new_path && !@new_event}
          patch={@new_path}
          id={@new_id}
          class="btn btn-primary btn-sm"
          data-testid={@new_testid}
        >
          <.icon name="hero-plus" class="w-4 h-4" /> {@new_label || gettext("New")}
        </.link>
        <button
          :if={@new_event}
          type="button"
          phx-click={@new_event}
          id={@new_id}
          class="btn btn-primary btn-sm"
          data-testid={@new_testid}
        >
          <.icon name="hero-plus" class="w-4 h-4" /> {@new_label || gettext("New")}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The standard EMPTY STATE of a list: the circle with the type icon, the title,
  the description and the CTA that opens the create modal (`?new=true`).

  `data-testid="empty-state"` is the stable hook — the caller decides WHEN it
  renders (a stream is not enumerable, so the parent tracks the count).
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :cta, :string, default: nil
  attr :new_path, :string, default: nil

  attr :navigate, :string,
    default: nil,
    doc:
      "cuando la superficie no tiene modal de alta (`?new=true`), el CTA va a otra ruta con `navigate`"

  def resource_empty_state(assigns) do
    ~H"""
    <div data-testid="empty-state" class="py-20 text-center space-y-4">
      <div class="flex justify-center">
        <div class="size-20 rounded-full bg-base-200 flex items-center justify-center">
          <.icon name={@icon} class="size-10 text-base-content/40" />
        </div>
      </div>
      <div class="space-y-1">
        <h3 class="text-lg font-semibold">{@title}</h3>
        <p :if={@description} class="text-sm text-base-content/50">{@description}</p>
      </div>
      <.link
        :if={@navigate}
        navigate={@navigate}
        class="btn btn-primary btn-sm transition hover:scale-105 active:scale-95"
      >
        <.icon name="hero-arrow-right" class="w-4 h-4" /> {@cta || gettext("New")}
      </.link>
      <.link
        :if={!@navigate}
        patch={@new_path}
        class="btn btn-primary btn-sm transition hover:scale-105 active:scale-95"
      >
        <.icon name="hero-plus" class="w-4 h-4" /> {@cta || gettext("New")}
      </.link>
    </div>
    """
  end

  @doc """
  The standard CARD of a resource list: `surface-2 lift` shell, icon tile,
  title link, type badge, summary, and a footer row (left slot + right slot
  with the meta date and the actions).

  Pages' cards and goals/plans' cards ARE this component — one molde, so a
  change here lands in every collection.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true

  attr :href, :string,
    default: nil,
    doc:
      "la ruta del detalle; `nil` deja la ficha SIN link (una entidad que no tiene página propia)"

  attr :badge, :string, default: nil
  attr :badge_class, :string, default: "bg-base-300 text-base-content/60"
  attr :summary, :string, default: nil
  attr :meta, :string, default: nil
  attr :testid, :string, default: nil
  attr :id, :string, default: nil

  attr :progress, :map,
    default: nil,
    doc: "progreso derivado (%{done:, total:, percent:}); el chip lo lee"

  attr :due_on, :any, default: nil, doc: "vencimiento (%Date{}); se pinta en rojo si ya pasó"
  attr :overdue?, :boolean, default: false
  attr :visibility, :string, default: nil, doc: "el destino; la píldora se oculta en privado"

  slot :footer
  slot :footer_actions
  slot :actions

  def resource_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="surface-2 lift hover:border-primary/40 p-4 rounded-xl"
      data-testid={@testid}
    >
      <div class="flex items-center gap-3">
        <span class="size-8 rounded-md bg-primary/10 flex items-center justify-center">
          <.icon name={@icon} class="size-4 text-primary" />
        </span>
        <.link
          :if={@href}
          navigate={@href}
          class="font-medium leading-snug flex-1 hover:text-primary transition-colors"
        >
          {@title}
        </.link>
        <span :if={!@href} class="font-medium leading-snug flex-1 truncate">
          {@title}
        </span>
        <span
          :if={@badge}
          class={["text-[11px] font-medium px-2 py-0.5 rounded-full", @badge_class]}
        >
          {@badge}
        </span>
        {render_slot(@actions)}
      </div>
      <p :if={@summary} class="text-sm text-base-content/60 line-clamp-2 mt-2">
        {@summary}
      </p>
      <div
        :if={@footer != [] || @meta || @progress || @due_on || @visibility}
        class="flex items-center justify-between gap-3 mt-2"
      >
        <div class="flex flex-wrap items-center gap-1.5 min-w-0">
          <.progress_chip :if={@progress} progress={@progress} />
          <.due_chip :if={@due_on} due_on={@due_on} overdue?={@overdue?} />
          <.resource_visibility_pill visibility={@visibility} id={@id && "#{@id}-visibility"} />
          {render_slot(@footer)}
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <span :if={@meta} class="text-caption">{@meta}</span>
          {render_slot(@footer_actions)}
        </div>
      </div>
    </div>
    """
  end

  # ── Las fichas del molde ───────────────────────────────────────────────────
  #
  # Progreso, vencimiento y destino son las que TODO listado muestra: si cada
  # superficie las pintara por su cuenta, goals y plans volverían a divergir
  # (goal con horizonte, plan con progreso). Viven acá, en el molde.
  attr :progress, :map, required: true

  defp progress_chip(assigns) do
    ~H"""
    <span
      data-chip="progress"
      class="inline-flex items-center gap-1.5 text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300/60 text-base-content/60"
      title={gettext("Progress")}
    >
      <span class="w-10 h-1 rounded-full bg-base-300 overflow-hidden">
        <span class="block h-1 rounded-full bg-primary" style={"width: #{@progress.percent}%"}></span>
      </span>
      {@progress.done}/{@progress.total}
    </span>
    """
  end

  attr :due_on, :any, required: true, doc: "%Date{} del vencimiento"
  attr :overdue?, :boolean, default: false

  defp due_chip(assigns) do
    ~H"""
    <span
      data-chip="due"
      class={[
        "inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full",
        if(@overdue?, do: "bg-red-100 text-red-700", else: "bg-base-300/60 text-base-content/60")
      ]}
      title={gettext("Due on")}
    >
      <.icon name="hero-calendar" class="size-3" />
      {Calendar.strftime(@due_on, "%b %d")}
    </span>
    """
  end

  @doc """
  ¿El recurso está vencido?

  Vencido = tiene fecha pasada y NO está cerrado: un goal o un plan `done`
  (o `archived`) no se pinta en rojo, ya no se persigue.
  """
  def overdue?(%{status: status, due_on: %Date{} = due_on}) do
    status not in ~w(done archived) and Date.compare(due_on, Date.utc_today()) == :lt
  end

  def overdue?(_), do: false

  @doc """
  La etiqueta humana de un estado de goal/plan. `on_hold` es «On hold», no
  «On_hold»: los estados son los mismos en las dos tablas, así que la
  traducción también.
  """
  def status_label("on_hold"), do: gettext("On hold")
  def status_label(status), do: status |> to_string() |> String.capitalize()

  @doc "El color del pill de estado — el mismo en la tarjeta y en el detalle."
  def status_class(status) when status in ~w(active done), do: "bg-green-100 text-green-700"
  def status_class("draft"), do: "bg-base-200 text-base-content/70"
  def status_class("on_hold"), do: "bg-yellow-100 text-yellow-700"
  def status_class(_), do: "bg-base-300 text-base-content/60"

  @doc """
  El sello de «actualizado» del pie de la tarjeta — el mismo texto en toda
  lista (`Updated · Oct 03`), no una fecha suelta que hay que interpretar.
  """
  def updated_meta(%DateTime{} = at),
    do: gettext("Updated") <> " · " <> Calendar.strftime(at, "%b %d")

  def updated_meta(_), do: nil

  @doc """
  Las opciones del filtro de orden — el mismo juego en toda lista, derivadas de
  `Dran.ListOrder.orders/0` (el vocabulario que el contexto entiende).
  """
  def order_options do
    labels = %{
      "due" => gettext("Due first"),
      "updated" => gettext("Recently updated"),
      "title" => gettext("Title A-Z")
    }

    Enum.map(Dran.ListOrder.orders(), &{&1, labels[&1]})
  end

  @doc """
  La barra de filtros de un índice — el MISMO molde en /goals y /plans.

  El estado vive en la URL (como los filtros del board): el form dispara
  `phx-change="filter"` y la LiveView responde con un `push_patch`. Acá no se
  valida nada: un valor fuera de `@statuses`/`@orders` lo descarta el caller
  (`filters_from/1`), que es quien conoce el vocabulario.
  """
  attr :prefix, :string, required: true, doc: "prefijo de los ids: goals, plans"
  attr :status, :string, default: nil
  attr :statuses, :list, required: true, doc: "pares {valor, etiqueta}"

  attr :status_param, :string,
    default: "status",
    doc:
      "nombre del campo del primer filtro en la URL: goals/plans filtran por `status` y skills por `visibility` (el destino)"

  attr :status_all_label, :string,
    default: nil,
    doc: "la opción «todos»; el default es «All statuses»"

  attr :status_aria, :string, default: nil, doc: "aria-label del primer select"

  attr :order, :string, required: true
  attr :orders, :list, required: true, doc: "pares {valor, etiqueta}"

  attr :total, :integer,
    default: nil,
    doc: "filas que devolvió el filtro (sólo para decir «sin resultados»)"

  def resource_filters(assigns) do
    ~H"""
    <form id={"#{@prefix}-filters"} phx-change="filter" class="flex flex-wrap items-center gap-2 mb-4">
      <select
        name={@status_param}
        id={"#{@prefix}-#{@status_param}-filter"}
        class="select select-sm select-bordered"
        aria-label={@status_aria || gettext("Filter by status")}
      >
        <option value="" selected={is_nil(@status)}>
          {@status_all_label || gettext("All statuses")}
        </option>
        <option :for={{value, label} <- @statuses} value={value} selected={@status == value}>
          {label}
        </option>
      </select>

      <select
        name="order"
        id={"#{@prefix}-order-filter"}
        class="select select-sm select-bordered"
        aria-label={gettext("Order by")}
      >
        <option :for={{value, label} <- @orders} value={value} selected={@order == value}>
          {label}
        </option>
      </select>

      <%!-- El vacío por FILTRO no es el vacío de la colección: sin resultados
      se dice qué pasa y cómo volver, no se ofrece crear. --%>
      <span :if={@status && @total == 0} class="text-caption text-base-content/50">
        {gettext("No matches for this filter.")}
      </span>
    </form>
    """
  end

  # ── El destino (scope): UN control y UNA píldora ───────────────────────────
  #
  # El destino de un recurso (quién puede leerlo) se declara y se muestra con
  # estos componentes en TODAS las superficies — pages, goals, plans y memory.
  # El vocabulario de la fila es `private | public | shared`, y el control lo
  # declara con el nombre de campo del form que lo monta (pages:
  # `page[visibility]`, goals: `goal[visibility]`, …).

  @doc "The three levels of the destination, translated."
  def visibility_label("public"), do: gettext("Public")
  def visibility_label("shared"), do: gettext("Shared")
  def visibility_label("private"), do: gettext("Private")
  def visibility_label(other), do: other

  @doc """
  La etiqueta de un horizonte de goal. El vocabulario es cerrado
  (`Dran.Goals.Goal.horizons/0`) y en pantalla va TRADUCIDO, nunca el valor
  crudo de la columna.
  """
  def horizon_label("someday"), do: gettext("Someday")
  def horizon_label("day"), do: gettext("Day")
  def horizon_label("week"), do: gettext("Week")
  def horizon_label("month"), do: gettext("Month")
  def horizon_label("quarter"), do: gettext("Quarter")
  def horizon_label("year"), do: gettext("Year")
  def horizon_label(other), do: other

  @doc "The icon of a level: a lock, the globe, or the group."
  def scope_icon("public"), do: "hero-globe-alt"
  def scope_icon("shared"), do: "hero-user-group"
  def scope_icon(_), do: "hero-lock-closed"

  @doc """
  The destination CONTROL: three buttons (private / public / shared), the hidden
  input the form submits, and the hidden radios that carry the value.

  Field name and id come from `@form[:visibility]`, so each surface keeps its own
  param (`page[visibility]`, `goal[visibility]`, …); `id` overrides the picker's
  DOM id, which defaults to `<field_id>-picker`.
  """
  attr :form, :any, required: true
  attr :id, :string, default: nil
  attr :label, :string, default: nil

  attr :field_id, :string,
    default: nil,
    doc:
      "id DOM base del control cuando la MISMA página monta varios (una tarjeta por recurso): los radios y el wrapper lo heredan en vez de repetir el id derivado del form"

  attr :form_id, :string,
    default: nil,
    doc: "id del `<form>` cuando el control vive FUERA de él (el header del modal)"

  attr :compact, :boolean,
    default: false,
    doc: "sin rótulo ni leyenda: sólo los tres pills (para el header del modal)"

  def resource_scope_field(assigns) do
    ~H"""
    <div>
      <span :if={!@compact} class="block text-sm font-medium text-base-content/70 mb-1.5">
        {@label || gettext("Visibility")}
      </span>
      <div
        class="flex flex-wrap gap-2"
        id={@id || "#{@field_id || @form[:visibility].id}-picker"}
        phx-update="ignore"
        title={if @compact, do: gettext("Who can read it"), else: nil}
      >
        <%!-- El radio VIVE DENTRO de su label: cliquear el pill lo marca (HTML
        puro) y el estado activo lo pinta el CSS con `has-[:checked]`, sin JS y
        sin round-trip. El wrapper sigue con `phx-update="ignore"` porque los
        forms de pages re-renderizan al validar: sin él, el servidor pisaría la
        elección del usuario a cada tecla. --%>
        <label
          :for={level <- ~w(private public shared)}
          class="flex items-center gap-1.5 px-3 py-1.5 text-sm rounded-lg border cursor-pointer transition-colors duration-150 border-base-300 text-base-content/70 hover:bg-base-200/50 has-[:checked]:border-primary has-[:checked]:bg-primary/10 has-[:checked]:text-primary has-[:checked]:font-medium"
        >
          <input
            type="radio"
            id={"#{@field_id || @form[:visibility].id}-#{level}"}
            name={@form[:visibility].name}
            value={level}
            checked={Phoenix.HTML.Form.input_value(@form, :visibility) == level}
            form={@form_id}
            class="sr-only"
          />
          <.icon name={scope_icon(level)} class="size-3.5" />
          {visibility_label(level)}
        </label>
      </div>
      <p :if={!@compact} class="text-xs text-base-content/50 mt-1.5">
        {gettext(
          "Private: only you. Public: everyone on this instance. Shared: only the people you invite."
        )}
      </p>
    </div>
    """
  end

  @doc """
  The destination PILL of a detail view: icon + translated label, and NOTHING
  when the level is `private` (the default is not announced). The raw column
  value is never printed.
  """
  attr :visibility, :string, default: nil
  attr :id, :string, default: nil
  attr :testid, :string, default: nil

  attr :inherited, :boolean,
    default: false,
    doc:
      "el destino no es de ESTE recurso sino el que hereda de su contenedor (una task, del goal): se marca para que nadie lo lea como propio"

  def resource_visibility_pill(assigns) do
    ~H"""
    <span
      :if={@visibility && @visibility != "private"}
      id={@id}
      data-testid={@testid}
      data-inherited={to_string(@inherited)}
      class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300/60 text-base-content/60"
      title={if(@inherited, do: gettext("Inherited from its goal"), else: gettext("Item visibility"))}
    >
      <.icon name={scope_icon(@visibility)} class="size-3" />
      {visibility_label(@visibility)}
      <span :if={@inherited} class="text-[10px] text-base-content/45">
        · {gettext("inherited")}
      </span>
    </span>
    """
  end

  @doc """
  El panel de PÁGINAS RELACIONADAS de un contenedor de trabajo (goal o plan).

  Dos fuentes, nunca mezcladas: las relaciones reales del grafo y —sólo si no
  hay ninguna— el fallback semántico (`Dran.Related`). La FUENTE se declara en
  el panel: la lectura no es una caja negra. El alta es EXPLÍCITA (el picker de
  abajo) y nunca automática.
  """
  attr :id, :string, required: true
  attr :related, :map, required: true
  attr :candidates, :list, default: []
  attr :workspace, :map, default: nil
  attr :picker_event, :string, default: "link_related"

  attr :embedded, :boolean,
    default: false,
    doc:
      "dentro de un `.sidebar_section` (el título lo pone la sección: acá sólo queda el badge de la FUENTE, que nunca se esconde)"

  def related_panel(assigns) do
    ~H"""
    <div id={@id} class={[not @embedded && "surface-2 rounded-xl p-4"]}>
      <div class={[
        "flex items-center gap-2",
        @embedded && "justify-end mb-2",
        not @embedded && "justify-between mb-3"
      ]}>
        <h3 :if={not @embedded} class="text-sm font-semibold flex items-center gap-2">
          <.icon name="hero-link" class="size-4 text-primary" /> {gettext("Related pages")}
        </h3>
        <span
          id={"#{@id}-source"}
          class="text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-200 text-base-content/60"
        >
          {related_source_label(@related.source)}
        </span>
      </div>

      <p :if={@related.pages == []} class="text-sm text-base-content/40 py-2">
        {gettext("No related pages yet.")}
      </p>

      <ul class="space-y-1.5">
        <li :for={page <- @related.pages} id={"#{@id}-page-#{page.id}"}>
          <.link
            navigate={page_href(@workspace, page)}
            class="flex items-center gap-2 text-sm py-1.5 px-2 rounded-lg hover:bg-base-200/60 transition"
          >
            <.icon name="hero-document-text" class="size-4 shrink-0 text-base-content/40" />
            <span class="flex-1 min-w-0 truncate">{page.title}</span>
            <span class="text-[11px] text-base-content/40 shrink-0">{page.page_type}</span>
          </.link>
        </li>
      </ul>

      <%!-- El alta es EXPLÍCITA: un picker con las páginas legibles que todavía
      no están vinculadas. El sidebar nunca crea una relación solo. --%>
      <form
        :if={@candidates != []}
        id={"#{@id}-link-form"}
        phx-submit={@picker_event}
        class="flex gap-2 mt-3"
      >
        <select
          name="page_id"
          id={"#{@id}-link-select"}
          class="select select-sm flex-1 rounded-lg border-base-300 bg-base-100"
          aria-label={gettext("Page")}
        >
          <option value="">{gettext("Link a page…")}</option>
          <option :for={page <- @candidates} value={page.id}>{page.title}</option>
        </select>
        <button type="submit" id={"#{@id}-link"} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="size-4" /> {gettext("Link")}
        </button>
      </form>
    </div>
    """
  end

  @doc """
  El bloque COLAPSABLE del aside del detalle: el `<details>` con el chevron, el
  título en versalitas y el cuerpo con su propia densidad (`body_class`).

  Es el molde que comparten el detalle de página y los de goal y plan. Antes
  estaba copiado cinco veces en `PageComponents`, así que un cambio de forma
  había que hacerlo cinco veces (o se hacía en una y las otras divergían).
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :open, :boolean, default: false
  attr :body_class, :string, default: "space-y-3 mt-2"
  slot :inner_block, required: true

  def sidebar_section(assigns) do
    ~H"""
    <details id={@id} class="group surface-2 rounded-lg p-4" open={@open}>
      <summary class="flex items-center gap-2 cursor-pointer select-none">
        <.icon
          name="hero-chevron-right"
          class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
        />
        <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
          {@title}
        </h3>
      </summary>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
    </details>
    """
  end

  @doc "La fuente de una lista de relacionadas, traducida (nunca el átomo crudo)."
  def related_source_label(:relations), do: gettext("From the graph")
  def related_source_label(:semantic), do: gettext("Suggested")
  def related_source_label(_), do: gettext("None")

  # La ruta de una página depende del tipo (un tipo custom declara su `path`),
  # así que el href sale del workspace, no del nombre del tipo.
  defp page_href(%{} = workspace, page) do
    "/" <> Dran.Workspace.page_type_path(workspace, page.page_type) <> "/" <> page.slug
  end

  defp page_href(_workspace, page), do: "/#{page.page_type}/#{page.slug}"
end
