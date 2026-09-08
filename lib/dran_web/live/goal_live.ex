defmodule DranWeb.GoalLive do
  @moduledoc "LiveView for goals: index list + detail view with create/edit."

  use DranWeb, :live_view

  alias Dran.Goals
  alias Dran.Goals.Goal
  alias Dran.Workflows
  alias DranWeb.Plugs.Auth

  # ──────────────────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
    >
      <div :if={@live_action == :show} class="p-6 overflow-y-auto w-full">
        <%!-- Main column + right sidebar (checklist + workflows). The 20rem
             sidebar column always renders on the goal detail. --%>
        <div class="grid grid-cols-1 lg:grid-cols-[1fr_20rem] lg:gap-6">
          <div class="space-y-6 min-w-0">
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2 mb-2 text-caption">
                  <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-green-100 text-green-700">
                    <.icon name="hero-flag" class="size-3" />
                    {gettext("Goal")}
                  </span>
                  <span
                    :if={@goal.status}
                    class={"px-2 py-0.5 text-xs rounded-full " <> goal_status_class(@goal)}
                  >
                    {String.capitalize(@goal.status)}
                  </span>
                </div>
                <h1 class="text-title break-words">{@goal.title}</h1>
                <p :if={@goal.summary} class="text-sm text-base-content/60 mt-1">
                  {@goal.summary}
                </p>
              </div>
              <div class="flex gap-2 shrink-0">
                <.link navigate={~p"/#{@workspace_slug}/goals"} class="btn btn-ghost btn-sm">
                  <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
                </.link>
                <.link
                  :if={not @editing}
                  patch={~p"/#{@workspace_slug}/goals/#{@goal.slug}?edit=true"}
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
                </.link>
              </div>
            </div>

            <%!-- Body (edit happens in the modal overlay) --%>
            <div
              :if={@goal.body != nil and @goal.body != ""}
              class="prose prose-base dark:prose-invert max-w-none"
            >
              {render_markdown(@goal.body, [])}
            </div>
          </div>

          <aside class="space-y-4 lg:border-l lg:border-base-300 lg:pl-6">
            <%!-- Checklist — lightweight sub-items on the goal itself --%>
            <div id="goal-checklist" class="surface-2 rounded-xl p-4">
              <h3 class="text-sm font-semibold flex items-center gap-2 mb-3">
                <.icon name="hero-check-circle" class="size-4 text-primary" />
                {gettext("Checklist")}
                <span class="badge badge-sm badge-ghost">
                  {checklist_badge(@goal)}
                </span>
              </h3>

              <ul
                :if={@goal.checklist != []}
                id="goal-checklist-items"
                class="space-y-1"
              >
                <li
                  :for={{item, index} <- Enum.with_index(@goal.checklist)}
                  id={"goal-checklist-item-#{index}"}
                  class="flex items-center gap-2 group"
                >
                  <button
                    type="button"
                    phx-click="toggle_checklist_item"
                    phx-value-index={index}
                    class={[
                      "shrink-0 size-4 rounded border flex items-center justify-center transition",
                      if(item["done"],
                        do: "bg-primary border-primary text-primary-content",
                        else: "border-base-300 hover:border-primary/60"
                      )
                    ]}
                    aria-label={gettext("Toggle item")}
                  >
                    <.icon
                      :if={item["done"]}
                      name="hero-check"
                      class="size-3"
                    />
                  </button>
                  <span class={[
                    "flex-1 min-w-0 text-sm break-words",
                    item["done"] && "line-through text-base-content/40"
                  ]}>
                    {item["text"]}
                  </span>
                  <button
                    type="button"
                    phx-click="remove_checklist_item"
                    phx-value-index={index}
                    class="shrink-0 opacity-0 group-hover:opacity-100 text-base-content/40 hover:text-error transition"
                    aria-label={gettext("Remove item")}
                  >
                    <.icon name="hero-x-mark" class="size-3.5" />
                  </button>
                </li>
              </ul>

              <p :if={@goal.checklist == []} class="text-xs text-base-content/40">
                {gettext("Sin ítems todavía.")}
              </p>

              <.form
                for={@checklist_form}
                id="goal-checklist-form"
                phx-submit="add_checklist_item"
                class="mt-3 flex gap-2"
              >
                <input
                  type="text"
                  name="checklist[text]"
                  placeholder={gettext("Agregar ítem…")}
                  class="input input-sm input-bordered flex-1 min-w-0"
                />
                <button
                  type="submit"
                  class="btn btn-sm btn-ghost shrink-0"
                  aria-label={gettext("Add item")}
                >
                  <.icon name="hero-plus" class="size-4" />
                </button>
              </.form>
            </div>

            <%!-- Linked workflows — read-only list, execution layer --%>
            <div :if={@workflows != []} id="goal-workflows" class="surface-2 rounded-xl p-4">
              <h3 class="text-sm font-semibold flex items-center gap-2 mb-3">
                <.icon name="hero-bolt" class="size-4 text-primary" />
                {gettext("Workflows vinculados")}
                <span class="badge badge-sm badge-ghost">{length(@workflows)}</span>
              </h3>
              <ul class="space-y-1.5">
                <li :for={workflow <- @workflows}>
                  <.link
                    navigate={~p"/#{@workspace_slug}/workflows/#{workflow.slug}"}
                    class="flex items-center gap-2 text-sm py-1.5 px-2 rounded-lg hover:bg-base-200/60 transition"
                  >
                    <.icon name="hero-bolt" class="size-4 shrink-0 text-base-content/40" />
                    <span class="flex-1 min-w-0 truncate">{workflow.title}</span>
                    <span class={["badge badge-xs shrink-0", workflow_badge_class(workflow)]}>
                      {String.capitalize(workflow.status)}
                    </span>
                    <span class="badge badge-ghost badge-xs shrink-0">{workflow.kind}</span>
                  </.link>
                </li>
              </ul>
            </div>
          </aside>
        </div>
      </div>

      <div :if={@live_action == :index} class="p-6 overflow-y-auto w-full">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-title">{gettext("Goals")}</h1>
          <.link
            patch={~p"/#{@workspace_slug}/goals?new=true"}
            class="btn btn-primary btn-sm"
            data-testid="goals-new-goal"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Goal")}
          </.link>
        </div>

        <div :if={@goals == []} class="text-center py-12">
          <div class="text-base-content/40">
            <.icon name="hero-flag" class="size-12 mx-auto mb-3" />
            <p class="text-sm">{gettext("No goals yet.")}</p>
          </div>
        </div>

        <div class="space-y-2">
          <.link
            :for={goal <- @goals}
            navigate={~p"/#{@workspace_slug}/goals/#{goal.slug}"}
            class="flex items-center gap-3 p-3 rounded-xl border border-base-300 hover:bg-base-200 transition cursor-pointer"
          >
            <.icon name="hero-flag" class="size-5 text-green-500 shrink-0" />
            <div class="min-w-0 flex-1">
              <div class="font-medium text-sm truncate">{goal.title}</div>
              <div :if={goal.summary} class="text-xs text-base-content/60 mt-0.5 truncate">
                {goal.summary}
              </div>
            </div>
          </.link>
        </div>
      </div>

      <.resource_modal
        :if={@modal_form}
        id="goal-resource-modal"
        title={(@modal_goal && @modal_goal.title) || gettext("New Goal")}
        pill={(@modal_goal && "GOAL") || "NEW GOAL"}
        pill_class={
          (@modal_goal && "bg-green-100 text-green-700") || "bg-green-500/15 text-green-600"
        }
        on_close="close_goal_modal"
        form_id="goal-modal-form"
        submit_label={(@modal_goal && gettext("Save changes")) || gettext("Create Goal")}
      >
        <.goal_form_fields
          id="goal-modal-form"
          goal={@modal_goal || %Goal{}}
          changeset={@modal_form}
          workspace_id={(@modal_goal && @modal_goal.workspace_id) || (@context && @context.id)}
        />
      </.resource_modal>
    </Layouts.app>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def mount(params, session, socket) do
    # The URL slug wins over the session (see Plugs.Auth.assign_to_socket/3).
    {socket, context} = Auth.assign_to_socket(socket, session, params)

    if context && connected?(socket) do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
      # Session/run changes broadcast on the workspace topic (keeps the
      # linked-workflows list in sync).
      Phoenix.PubSub.subscribe(Dran.PubSub, "workspace:#{context.id}")
    end

    {:ok,
     assign(socket,
       context: context,
       editing: false,
       save_status: "idle",
       active_nav: "goals",
       workflows: [],
       # Resource modal state — `?new=true` on the index opens create,
       # `?edit=true` on the show opens edit. Rendered via
       # `<.resource_modal>` (DranWeb.ResourceComponents).
       modal_goal: nil,
       modal_form: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {socket, context} = Auth.resolve_workspace(socket, params)

    socket = assign(socket, params: params, context: context)
    socket = apply_action(socket, socket.assigns.live_action, params)

    {:noreply, open_modal_from_params(socket, params)}
  end

  # `?edit=true` on the show page opens the edit modal over the detail.
  defp open_modal_from_params(%{assigns: %{live_action: :show, goal: %Goal{} = goal}} = socket, %{
         "edit" => "true"
       }) do
    assign(socket,
      editing: true,
      modal_goal: goal,
      modal_form: to_form(Goals.change_goal(goal), as: :goal)
    )
  end

  # `?new=true` (index or any action) opens the create modal.
  defp open_modal_from_params(socket, %{"new" => "true"}) do
    assign(socket,
      modal_goal: nil,
      modal_form: to_form(Goals.change_goal(%Goal{}), as: :goal)
    )
  end

  defp open_modal_from_params(socket, _params), do: clear_modal(socket)

  defp clear_modal(socket) do
    assign(socket, modal_goal: nil, modal_form: nil)
  end

  defp apply_action(socket, :index, _params) do
    goals =
      if socket.assigns.context do
        Goals.list_goals(socket.assigns.context.id)
      else
        []
      end

    assign(socket, goals: goals, editing: false, page_title: gettext("Goals"))
  end

  defp apply_action(socket, :show, %{"slug" => slug} = params) do
    context = socket.assigns.context

    if context do
      case Goals.get_goal_by_slug(slug, context.id) do
        nil ->
          push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/goals")

        goal ->
          form = Goals.change_goal(goal) |> to_form(as: :goal)

          assign(socket,
            goal: goal,
            form: form,
            checklist_form: to_form(%{}, as: :checklist),
            workflows: Workflows.list_by_goal(goal),
            editing: Map.get(params, "edit") == "true",
            page_title: goal.title
          )
      end
    else
      push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/goals")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events — goal resource modal (create + edit)
  # ──────────────────────────────────────────────────────────────────────────

  # ── Checklist (goal sub-items, sidebar) ──

  @impl true

  def handle_event("add_checklist_item", %{"checklist" => %{"text" => text}}, socket) do
    case Goals.add_checklist_item(socket.assigns.goal, text) do
      {:ok, goal} ->
        {:noreply, assign(socket, goal: goal, checklist_form: to_form(%{}, as: :checklist))}

      {:error, :empty_text} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_checklist_item", %{"index" => index}, socket) do
    index = String.to_integer(index)

    case Goals.toggle_checklist_item(socket.assigns.goal, index) do
      {:ok, goal} -> {:noreply, assign(socket, goal: goal)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("remove_checklist_item", %{"index" => index}, socket) do
    index = String.to_integer(index)

    case Goals.remove_checklist_item(socket.assigns.goal, index) do
      {:ok, goal} -> {:noreply, assign(socket, goal: goal)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("validate_goal", %{"goal" => params}, socket) do
    goal = socket.assigns.modal_goal || %Goal{}
    changeset = Goals.change_goal(goal, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, modal_form: to_form(changeset, as: :goal))}
  end

  def handle_event("save_goal", %{"goal" => params}, socket) do
    context = socket.assigns.context
    ws_slug = socket.assigns[:workspace_slug]

    # Whitelist + server-side identity (SEC-006 pattern).
    # Raw params NEVER reach the changeset: fields like workspace_id,
    # created_by, updated_by, archived, parent_goal_id are forgeable and
    # must be owned by the server (SEC-006 pattern).
    attrs = %{
      "title" => String.trim(params["title"] || ""),
      "summary" => params["summary"],
      "body" => params["body"] || "",
      "status" => params["status"]
    }

    result =
      case socket.assigns.modal_goal do
        nil ->
          if context do
            attrs =
              attrs
              |> Map.put("workspace_id", context.id)
              |> Map.put("created_by", session_identity_goal(socket))

            Goals.create_goal(attrs)
          else
            {:error, :no_context}
          end

        goal ->
          attrs = Map.put(attrs, "updated_by", session_identity_goal(socket))
          Goals.update_goal(goal, attrs)
      end

    case result do
      {:ok, _goal} ->
        # Create → close back to the list (the new goal is already there).
        # Update → close back to the detail page (without ?edit=true).
        to =
          case socket.assigns do
            %{live_action: :show, goal: %Goal{slug: slug}} -> ~p"/#{ws_slug}/goals/#{slug}"
            _ -> ~p"/#{ws_slug}/goals"
          end

        {:noreply,
         socket
         |> put_flash(:info, gettext("Goal saved."))
         |> push_patch(to: to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, modal_form: to_form(changeset, as: :goal))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save goal."))}
    end
  end

  def handle_event("close_goal_modal", _params, socket) do
    ws_slug = socket.assigns[:workspace_slug]

    to =
      case socket.assigns do
        %{live_action: :show, goal: %Goal{slug: slug}} -> ~p"/#{ws_slug}/goals/#{slug}"
        _ -> ~p"/#{ws_slug}/goals"
      end

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("delete", _params, socket) do
    goal = socket.assigns.goal

    case Goals.delete_goal(goal) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Goal deleted."))
         |> push_navigate(to: ~p"/#{socket.assigns[:workspace_slug]}/goals")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete goal."))}
    end
  end

  # ── Helpers ──

  # Web session identity for attribution: the logged-in user's email,
  # resolved through Dran.Auth.resolve_created_by/1 (falls back to "system"
  # when no user).
  defp session_identity_goal(socket) do
    Dran.Auth.resolve_created_by(%{email: socket.assigns[:current_user]})
  end

  # "done/total" for the checklist badge — "3/7", or "0" when empty.
  defp checklist_badge(%Goal{} = goal) do
    {done, total} = Goals.checklist_progress(goal)
    if total == 0, do: "0", else: "#{done}/#{total}"
  end

  defp goal_status_class(%Goal{status: "active"}), do: "bg-green-100 text-green-700"
  defp goal_status_class(%Goal{status: "draft"}), do: "bg-base-200 text-base-content/70"
  defp goal_status_class(%Goal{status: "on_hold"}), do: "bg-yellow-100 text-yellow-700"
  defp goal_status_class(%Goal{status: "done"}), do: "bg-green-100 text-green-700"
  defp goal_status_class(_), do: "bg-base-300 text-base-content/60"

  defp workflow_badge_class(%{status: "active"}), do: "bg-green-100 text-green-700"
  defp workflow_badge_class(%{status: "draft"}), do: "bg-base-200 text-base-content/70"
  defp workflow_badge_class(%{status: "archived"}), do: "bg-yellow-100 text-yellow-700"
  defp workflow_badge_class(_), do: "bg-base-300 text-base-content/60"

  # ── PubSub: real-time update when a goal changes ──

  @impl true
  def handle_info({:page_changed, _action, changed_goal}, socket) do
    if socket.assigns[:goal] && socket.assigns.goal.id == changed_goal.id do
      goal = Goals.get_goal(changed_goal.id)

      if goal do
        form = Goals.change_goal(goal) |> to_form(as: :goal)
        {:noreply, assign(socket, goal: goal, form: form)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Sessions/runs of a workflow linked to the shown goal changed — keep the
  # linked-workflows list in sync (list is read-only; only membership/status
  # can change → full reload).
  def handle_info({:session_changed, _action, _session}, socket) do
    case socket.assigns[:goal] do
      nil -> {:noreply, socket}
      goal -> {:noreply, assign(socket, workflows: Workflows.list_by_goal(goal))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
