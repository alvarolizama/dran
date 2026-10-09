defmodule DranWeb.SkillLive do
  @moduledoc """
  Los skills en la web: lista, detalle y alta/edición/borrado.

  Un skill es una **entidad** con dueño y visibilidad propios (tabla `skills`),
  no un tipo de página: su categoría es `/skills` y su dirección es el `slug`,
  que es el identificador del wire y NO se renombra (renombrarlo rompe a quien
  lo tenga cargado).

  La UI sigue la ESTRUCTURA de pages (contrato de paridad UI/UX): el alta vive
  en un `<.resource_modal>` abierto por estado de URL (`?new=true`) con el
  destino en el `header` del modal — apuntado con el atributo HTML `form=` — y
  la edición ocurre EN el detalle con `?edit=true`. No existen las rutas
  `/skills/new` ni `/skills/:slug/edit`. El shell, el header, los filtros y el
  diálogo de compartir son los componentes compartidos.

  ## La lista es un catálogo

  Un skill no tiene progreso ni vencimiento: se compara por columnas (nombre,
  descripción, destino, versión, actualizado) en la tabla canónica de §T5, con
  el filtro de **destino** y el de orden viviendo en la URL (el default no se
  escribe). El vacío de la COLECCIÓN sólo aparece sin filtro puesto: con filtro
  y cero filas lo dice la barra.
  """

  use DranWeb, :live_view

  import DranWeb.ResourceComponents,
    only: [
      resource_modal: 1,
      resource_header: 1,
      resource_list_header: 1,
      resource_empty_state: 1,
      resource_filters: 1,
      resource_scope_field: 1,
      resource_visibility_pill: 1,
      can_manage_scope?: 2,
      form_actions: 1,
      markdown_body_field: 1,
      sidebar_section: 1,
      updated_meta: 1,
      visibility_label: 1
    ]

  alias Dran.Accounts
  alias Dran.Sharing
  alias Dran.Skills
  alias Dran.Skills.Skill
  alias DranWeb.Components.ShareDialog
  alias DranWeb.Plugs.Auth

  # El orden de la lista por default: el nombre es lo estable de un catálogo.
  # La URL lo OMITE (no hay `?order=name`).
  @default_order "name"

  # ──────────────────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(modal_open: Map.get(assigns, :modal_open, false))
      |> assign(editing: Map.get(assigns, :editing, false))
      |> assign(workspace_id: Map.get(assigns, :workspace_id, nil))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      user={@user}
      workspace_slug={@workspace_slug}
      active_nav={@active_nav}
    >
      <ShareDialog.share_dialog
        id="skill-share-dialog"
        open={@share_open || false}
        resource_type="skill"
        resource_id={@skill && @skill.id}
        shares={@shares || []}
        users={@share_users || []}
        groups={@share_groups || []}
      />

      <%!-- ── Índice: el catálogo. Header + filtros + tabla canónica + vacío. ── --%>
      <div :if={@live_action == :index} id="skills-index" class="p-6 overflow-y-auto w-full">
        <.resource_list_header
          title={gettext("Skills")}
          new_event="new_skill"
          new_id="skill-new"
          new_testid="new-skill-button"
        />

        <.resource_filters
          prefix="skills"
          status={@filters.visibility}
          statuses={@visibilities}
          status_param="visibility"
          status_all_label={gettext("All destinations")}
          status_aria={gettext("Filter by destination")}
          order={@filters.order}
          orders={@orders}
          total={@skill_count}
        />

        <%!-- El vacío de la COLECCIÓN es el que ofrece crear; con un filtro
        puesto, el «sin resultados» lo dice la barra de filtros. --%>
        <.resource_empty_state
          :if={@skill_count == 0 && is_nil(@filters.visibility)}
          icon="hero-academic-cap"
          title={gettext("No skills yet")}
          description={gettext("Write the instructions an agent should follow.")}
          cta={gettext("Create skill")}
          new_path={~p"/skills?new=true"}
        />

        <%!-- El contenedor del stream sigue montado (oculto si no hay nada): el
        vacío se decide por CONTADOR, no por colección — un stream no es
        enumerable. El `phx-update="stream"` va en el `<tbody>` para que las
        filas sean sus hijos DIRECTOS. --%>
        <div class={["surface-2 rounded-xl overflow-x-auto", @skill_count == 0 && "hidden"]}>
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Description")}</th>
                <th>{gettext("Destination")}</th>
                <th>{gettext("Version")}</th>
                <th>{gettext("Updated")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="skills" phx-update="stream">
              <tr :for={{dom_id, skill} <- @streams.skills} id={dom_id} class="hover">
                <td>
                  <.link
                    navigate={~p"/skills/#{skill.slug}"}
                    class="font-medium hover:text-primary transition-colors"
                  >
                    {skill.name}
                  </.link>
                  <%!-- El dueño edita su skill; la suite no vive en el catálogo. --%>
                </td>
                <td class="text-base-content/60 max-w-md">{skill.description}</td>
                <td>
                  <.resource_visibility_pill
                    visibility={skill.visibility}
                    always={true}
                    id={"skill-#{skill.id}-visibility"}
                  />
                </td>
                <td class="text-base-content/60">{"v#{skill.version}"}</td>
                <td class="text-caption">{updated_meta(skill.updated_at)}</td>
                <td class="text-right">
                  <.link
                    :if={skill.owner_user_id == @reader_id}
                    patch={~p"/skills/#{skill.slug}?edit=true"}
                    id={"skill-#{skill.id}-edit"}
                    class="btn btn-xs btn-ghost"
                    title={gettext("Edit")}
                  >
                    <.icon name="hero-pencil" class="size-3.5" />
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- ── Detalle: editar es `?edit=true` EN esta misma página. ── --%>
      <div :if={@live_action == :show && @skill} id="skill-detail" class="p-6 overflow-y-auto w-full">
        <.resource_header
          title={@skill.name}
          subtitle={@skill.description}
          icon="hero-academic-cap"
          back_href={~p"/skills"}
          back_label={gettext("Back")}
        >
          <:actions>
            <button
              :if={can_manage?(@skill, @user)}
              id="skill-share"
              phx-click="open_share"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-share" class="size-4" /> {gettext("Share")}
            </button>
            <.link
              :if={@editing}
              patch={~p"/skills/#{@skill.slug}"}
              id="skill-view"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-eye" class="size-4" /> {gettext("View")}
            </.link>
            <.link
              :if={not @editing && can_manage?(@skill, @user)}
              patch={~p"/skills/#{@skill.slug}?edit=true"}
              id="skill-edit"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
            </.link>
            <button
              :if={can_manage?(@skill, @user)}
              id="skill-delete"
              phx-click="delete_skill"
              data-confirm={gettext("Delete this skill?")}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
            </button>
          </:actions>
        </.resource_header>

        <div class="flex flex-wrap items-center gap-2 mb-4">
          <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-primary/10 text-primary">
            <.icon name="hero-academic-cap" class="size-3" /> {gettext("Skill")}
          </span>
          <span class="px-2 py-0.5 text-xs rounded-full bg-base-300 text-base-content/60">
            {"v#{@skill.version}"}
          </span>
          <.resource_visibility_pill visibility={@skill.visibility} id="skill-visibility-badge" />
        </div>

        <div class="flex flex-col lg:flex-row gap-6">
          <div class="flex-1 min-w-0 space-y-6">
            <%= if @editing do %>
              <div id="skill-edit-panel" class="surface-2 rounded-xl p-4">
                <.skill_form form={@form} editing={true} workspace_id={@workspace_id} />
              </div>
            <% else %>
              <div
                :if={@skill.body != nil and @skill.body != ""}
                id="skill-body"
                class="prose prose-base dark:prose-invert max-w-none"
              >
                {render_markdown(@skill.body, [])}
              </div>
            <% end %>
          </div>

          <%!-- El aside del molde: Metadata (slug, destino, versión, hash, dueño). --%>
          <aside id="skill-sidebar" class="lg:w-72 xl:w-80 shrink-0 space-y-4">
            <.sidebar_section
              id="skill-metadata"
              title={gettext("Metadata")}
              open
              body_class="divide-y divide-base-300/50 mt-2"
            >
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Slug")}</span>
                <span class="font-mono text-xs">{@skill.slug}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Version")}</span>
                <span class="font-medium">{"v#{@skill.version}"}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Content hash")}</span>
                <span id="skill-content-hash" class="font-mono text-[11px]">
                  {String.slice(@skill.content_hash || "", 0, 12)}
                </span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Visibility")}</span>
                <span id="skill-visibility-value">{visibility_label(@skill.visibility)}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Owner")}</span>
                <span>{owner_label(@skill)}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Updated")}</span>
                <span>{format_date(@skill.updated_at)}</span>
              </div>
            </.sidebar_section>

            <.sidebar_section id="skill-hash-section" title={gettext("Wire")} body_class="mt-2">
              <p class="text-xs leading-snug text-base-content/60">
                {gettext(
                  "An agent loads this skill through the dran_skill tool; the body travels framed with this slug, version and hash."
                )}
              </p>
              <pre
                id="skill-content-hash-full"
                phx-no-curly-interpolation
                class="mt-2 text-[11px] leading-relaxed whitespace-pre-wrap break-all bg-base-200/60 rounded-lg p-3"
              >{@skill.content_hash}</pre>
            </.sidebar_section>
          </aside>
        </div>
      </div>

      <%!-- ── Alta: el MISMO modal de pages, abierto por estado de URL. ── --%>
      <.resource_modal
        :if={@modal_open}
        id="skill-resource-modal"
        title={gettext("New skill")}
        pill={gettext("Skill")}
        on_close="close_skill_modal"
        form_id="skill-form"
        submit_label={gettext("Create")}
        cancel_label={gettext("Cancel")}
      >
        <%!-- El destino vive junto a la ✕: los radios apuntan al form del body
        con el atributo HTML `form` (el modal está fuera del `<form>`). El
        control va `compact` y el form se llama con `with_scope={false}` para no
        pintarlo dos veces. --%>
        <:header>
          <.resource_scope_field
            form={@form}
            id="skill-visibility-picker"
            form_id="skill-form"
            compact
          />
        </:header>

        <.skill_form
          form={@form}
          editing={false}
          workspace_id={@workspace_id}
          with_scope={false}
        />

        <:sidebar>
          <div class="space-y-3">
            <div class="flex justify-between gap-2 text-sm">
              <span class="text-base-content/60">{gettext("Slug")}</span>
              <span id="skill-sidebar-slug" class="font-mono text-xs">
                {to_string(@form[:name].value || "")}
              </span>
            </div>
            <div class="text-sm">
              <span class="text-base-content/60">{gettext("Destination")}</span>
              <p id="skill-sidebar-visibility" class="mt-1">
                {visibility_label(to_string(@form[:visibility].value || "private"))}
              </p>
            </div>
            <p class="text-xs leading-snug text-base-content/50">
              {gettext(
                "The name is the wire address: it is set once and never renamed. Editing changes the body, the description and the destination."
              )}
            </p>
          </div>
        </:sidebar>
      </.resource_modal>
    </Layouts.app>
    """
  end

  # El form del skill es UNO: el alta lo monta dentro del modal de pages y la
  # edición en el panel del detalle (`?edit=true`). El `name`/`slug` se declara
  # una vez — al editar no hay input: el slug es la dirección del wire.
  attr :form, :map, required: true
  attr :editing, :boolean, default: false
  attr :workspace_id, :string, default: nil

  attr :with_scope, :boolean,
    default: true,
    doc: "false cuando el modal ya muestra el destino en su header"

  defp skill_form(assigns) do
    ~H"""
    <.form for={@form} id="skill-form" phx-submit="save_skill" class="space-y-5">
      <%= if @editing do %>
        <div class="space-y-1">
          <span class="block text-xs text-base-content/60">{gettext("Name")}</span>
          <p id="skill-name-readonly" class="font-mono text-sm">{@form[:name].value}</p>
          <p class="text-xs text-base-content/50">
            {gettext("The name is the wire address: it is never renamed.")}
          </p>
        </div>
      <% else %>
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Name")}
          required
          maxlength={Dran.Skills.Skill.name_max()}
          pattern="^[a-z][a-z0-9_-]*$"
          hint={gettext("Lowercase letters, digits, dashes and underscores — e.g. weekly-review.")}
        />
      <% end %>

      <.input
        field={@form[:description]}
        type="text"
        label={gettext("Description")}
        required
        maxlength={Dran.Skills.Skill.description_max()}
        hint={gettext("Up to 60 characters — this is the line an agent sees in its index.")}
      />

      <.markdown_body_field
        id="skill-editor"
        body={to_string(@form[:body].value || "")}
        workspace_id={@workspace_id || ""}
        hidden_field="skill[body]"
        autosave={false}
        label={gettext("Instructions")}
      />

      <.resource_scope_field
        :if={@with_scope}
        form={@form}
        id="skill-visibility-field"
        field_id="skill-visibility-field"
      />

      <.form_actions
        :if={@editing}
        submit_label={gettext("Save skill")}
        submit_icon="hero-check"
        cancel_event="cancel_skill_edit"
      />
    </.form>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       context: context,
       active_nav: "skills",
       skill: nil,
       scope: nil,
       reader_id: Dran.Auth.resolve_owner_user_id(socket.assigns[:user]),
       form: new_skill_form(),
       filters: default_filters(),
       visibilities: visibilities(),
       orders: orders(),
       skill_count: 0,
       share_open: false,
       shares: [],
       share_users: [],
       share_groups: [],
       modal_open: false,
       editing: false,
       workspace_id: context && context.id
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # La lista: `?new=true` abre el modal del alta (estado de URL, no una ruta) y
  # `?visibility=`/`?order=` son los filtros.
  defp apply_action(socket, :index, params) do
    modal_open = params["new"] == "true"

    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        filters = filters_from(params)

        skills =
          Skills.list_skills(scope: scope, visibility: filters.visibility, order: filters.order)

        socket
        |> assign(
          page_title: gettext("Skills"),
          scope: scope,
          modal_open: modal_open,
          filters: filters,
          skill_count: length(skills),
          skill: nil,
          form: if(modal_open, do: new_skill_form(), else: socket.assigns[:form])
        )
        |> stream(:skills, skills, reset: true, dom_id: &"skill-row-#{&1.id}")
    end
  end

  # El detalle: `?edit=true` edita EN la página (patch), sin ruta `/edit`.
  defp apply_action(socket, :show, %{"slug" => slug} = params) do
    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        case Skills.get_skill(slug, scope: scope) do
          nil ->
            push_navigate(socket, to: ~p"/skills")

          skill ->
            # `?edit=true` es estado de URL, no autorización: quien no puede
            # administrar el skill no entra al panel de edición ni con la URL a
            # mano (y el submit lo vuelve a comprobar).
            editing = params["edit"] == "true" and can_manage?(skill, socket.assigns[:user])

            assign(socket,
              skill: skill,
              scope: scope,
              editing: editing,
              page_title: skill.name,
              form:
                if(editing,
                  do: to_form(Skills.change_skill(skill, %{})),
                  else: socket.assigns[:form]
                )
            )
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  # Abrir/cerrar el alta es URL state: `push_patch` (el LiveView no se remonta y
  # el stream de la lista sobrevive). Los filtros vigentes viajan en el patch.
  @impl true
  def handle_event("new_skill", _params, socket),
    do:
      {:noreply,
       push_patch(socket, to: skills_path(current_query(socket) |> Map.put("new", "true")))}

  def handle_event("close_skill_modal", _params, socket),
    do: {:noreply, push_patch(socket, to: skills_path(current_query(socket)))}

  # Los filtros viven en la URL: cambiar uno es un patch, no un assign suelto.
  def handle_event("filter", params, socket) do
    query =
      current_query(socket)
      |> Map.put("visibility", params["visibility"])
      |> Map.put("order", params["order"])

    {:noreply, push_patch(socket, to: skills_path(query))}
  end

  def handle_event("cancel_skill_edit", _params, %{assigns: %{skill: %Skill{} = skill}} = socket),
    do: {:noreply, push_patch(socket, to: ~p"/skills/#{skill.slug}")}

  def handle_event("cancel_skill_edit", _params, socket), do: {:noreply, socket}

  def handle_event("save_skill", %{"skill" => params}, socket) do
    case socket.assigns[:skill] do
      nil ->
        params
        |> Skills.create_skill(owner_user_id: socket.assigns[:reader_id])
        |> skill_form_result(socket)

      %Skill{} = skill ->
        # Editar no es leer: sólo el dueño (o quien administra el destino). El
        # formulario ya no se abre sin esto, pero un submit forjado no puede
        # saltárselo.
        if can_manage?(skill, socket.assigns[:user]) do
          skill
          |> Skills.update_skill(params)
          |> skill_form_result(socket)
        else
          {:noreply, put_flash(socket, :error, gettext("Only the owner can edit a skill."))}
        end
    end
  end

  def handle_event("delete_skill", _params, %{assigns: %{skill: %Skill{} = skill}} = socket) do
    if can_manage?(skill, socket.assigns[:user]) do
      case Skills.delete_skill(skill) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Skill deleted."))
           |> push_navigate(to: ~p"/skills")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete the skill."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Only the owner can delete a skill."))}
    end
  end

  def handle_event("delete_skill", _params, socket), do: {:noreply, socket}

  def handle_event("open_share", _params, %{assigns: %{skill: %Skill{} = skill}} = socket) do
    {:noreply,
     socket
     |> assign(:share_open, true)
     |> assign(:shares, Sharing.list_shares("skill", skill.id))
     |> assign(:share_users, Accounts.list_users())
     |> assign(:share_groups, Sharing.list_groups())}
  end

  def handle_event("open_share", _params, socket), do: {:noreply, socket}

  def handle_event("close_share", _params, socket),
    do: {:noreply, assign(socket, :share_open, false)}

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event(
        "share_with_user",
        %{"user_id" => user_id},
        %{assigns: %{skill: skill}} = socket
      )
      when user_id != "" and not is_nil(skill) do
    case Sharing.grant(skill, :skill, {:user, String.to_integer(user_id)}) do
      {:ok, :shared, updated} ->
        {:noreply,
         socket
         |> assign(skill: updated, shares: Sharing.list_shares("skill", skill.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_user", _params, socket), do: {:noreply, socket}

  def handle_event(
        "share_with_group",
        %{"group_id" => group_id},
        %{assigns: %{skill: skill}} = socket
      )
      when group_id != "" and not is_nil(skill) do
    case Sharing.grant(skill, :skill, {:group, String.to_integer(group_id)}) do
      {:ok, :shared, updated} ->
        {:noreply,
         socket
         |> assign(skill: updated, shares: Sharing.list_shares("skill", skill.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_group", _params, socket), do: {:noreply, socket}

  def handle_event("unshare", %{"id" => share_id}, %{assigns: %{skill: skill}} = socket)
      when not is_nil(skill) do
    :ok = Sharing.unshare(share_id)
    {:noreply, assign(socket, :shares, Sharing.list_shares("skill", skill.id))}
  end

  def handle_event("unshare", _params, socket), do: {:noreply, socket}

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp new_skill_form do
    to_form(Skills.change_skill(%Skill{}, %{"visibility" => "private"}))
  end

  # El resultado del form: el alta navega al detalle recién creado y la edición
  # sale del modo edición con un patch (el detalle no se remonta). Un rename
  # pedido desde la UI es un error explícito, no un descarte en silencio.
  defp skill_form_result({:ok, skill}, socket) do
    socket =
      socket
      |> put_flash(:info, saved_message(skill))
      |> assign(skill: skill, editing: false)

    if socket.assigns[:live_action] == :show do
      {:noreply, push_patch(socket, to: ~p"/skills/#{skill.slug}")}
    else
      {:noreply, push_navigate(socket, to: ~p"/skills/#{skill.slug}")}
    end
  end

  defp skill_form_result({:error, :rename}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The name is the wire address and cannot be renamed."))
     |> assign(form: to_form(Skills.change_skill(socket.assigns.skill, %{})))}
  end

  # `{:error, :rename}` no llega hasta acá: el form no ofrece slug ni nombre.
  defp skill_form_result({:error, %Ecto.Changeset{} = changeset}, socket),
    do: {:noreply, assign(socket, form: to_form(changeset))}

  defp skill_form_result({:error, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Could not save the skill."))}

  # El aviso de tamaño se dice en el MISMO flash del «guardado»: quien acaba de
  # escribir 84 K de instrucciones tiene que enterarse ahí y no en un reporte que
  # nadie abre. El skill SÍ se guardó — por eso es info y no error.
  defp saved_message(skill) do
    case Skills.warnings(skill) do
      [] ->
        gettext("Skill saved.")

      [%{chars: chars, soft_max: soft, hard_max: hard} | _] ->
        gettext(
          "Skill saved. The body is %{chars} chars, over the %{soft} comfort line: it no longer travels inline (the agent gets a pointer and reads it with read_file). Split it before %{hard}.",
          chars: chars,
          soft: soft,
          hard: hard
        )
    end
  end

  # El destino lo administra quien puede escribir: el DUEÑO (la misma regla que
  # goals y planes — `can_manage_scope?/2` de `DranWeb.ResourceComponents`, acá
  # vivía copiada).
  defp can_manage?(resource, user), do: can_manage_scope?(resource, user)

  # El dueño de una fila sin dueño es la instancia, no el código: la suite no
  # vive en la tabla.
  defp owner_label(%{owner_user_id: owner_id}), do: owner_label(owner_id)

  defp owner_label(nil), do: gettext("Instance")

  defp owner_label(user_id) when is_integer(user_id) do
    case Accounts.get_user(user_id) do
      nil -> gettext("Unknown")
      user -> user.name || user.email
    end
  end

  defp owner_label(_other), do: gettext("Unknown")

  defp reader_scope(socket) do
    case socket.assigns[:user] do
      nil -> nil
      user -> Dran.ContentVisibility.resolve(socket.assigns[:context], user, :skill)
    end
  end

  # ── Los filtros del índice ────────────────────────────────────────────────

  defp default_filters, do: %{visibility: nil, order: @default_order}

  # Lo que no está en el vocabulario se DESCARTA (un `?visibility=<basura>`
  # forjado no filtra ni rompe) y un `?order=` ausente cae al default.
  defp filters_from(params) do
    %{
      visibility: (params["visibility"] in Skill.visibilities() && params["visibility"]) || nil,
      order: (params["order"] in Skills.orders() && params["order"]) || @default_order
    }
  end

  # La query vigente del índice: es lo que se arrastra al abrir el alta y lo que
  # hace compartible un filtro.
  defp current_query(socket) do
    %{
      "visibility" => socket.assigns.filters.visibility,
      "order" => socket.assigns.filters.order,
      "new" => nil
    }
  end

  # La URL del índice con su query. Campos en orden FIJO y fuera lo vacío y el
  # default (`?order=name` no aparece nunca): la URL es estable y un test la
  # puede afirmar entera — el mismo molde que `plans_path/2`.
  @query_fields ~w(visibility order new)

  defp skills_path(query) do
    pairs =
      for field <- @query_fields,
          value = query[field],
          value not in [nil, ""],
          not (field == "order" and value == @default_order),
          do: {field, value}

    case URI.encode_query(pairs) do
      "" -> "/skills"
      qs -> "/skills?" <> qs
    end
  end

  defp visibilities do
    Enum.map(Skill.visibilities(), &{&1, visibility_label(&1)})
  end

  defp orders do
    labels = %{"name" => gettext("Name A-Z"), "updated" => gettext("Recently updated")}
    Enum.map(Skills.orders(), &{&1, labels[&1]})
  end
end
