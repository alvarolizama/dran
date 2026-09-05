defmodule DranWeb.WorkflowsLive do
  @moduledoc """
  Workflows — index + execution view over the workflows model (2026-09).

  Index (`/workflows`): one card per workflow — title, status
  (draft/active/archived), kind (evergreen/one_shot), steps count and its
  in-flight sessions (progress + abort). Each card has a "Nueva sesión"
  form that opens a session (`Dran.Executions.open_session/2`) with an
  optional label.

  Show (`/workflows/:slug`): the DAG of the workflow's steps laid out in
  topological columns (`Dran.Contracts.levels/1`), the sessions panel
  (status, label, started/finished, progress) and the runs of the
  selected session with status chip and `progress["phase"]`.
  """

  use DranWeb, :live_view

  alias Dran.{Contracts, Executions, Goals, Workflows}
  alias DranWeb.ListPagination

  # The create-workflow modal's selects/`selected` options read the current
  # form values via Phoenix.HTML.Form.input_value/2 (pages/task/goal modals
  # import it through their form components — this LiveView builds its own).
  import Phoenix.HTML.Form, only: [input_value: 2]

  @impl true
  def mount(params, session, socket) do
    {socket, context} = DranWeb.Plugs.Auth.assign_to_socket(socket, session, params)

    case context do
      nil ->
        # Unresolvable workspace (bad slug) — the template needs context
        # assigns; redirect instead of rendering with nils.
        {:ok, push_navigate(socket, to: ~p"/")}

      context ->
        if connected?(socket) do
          # Session/run changes broadcast on the workspace topic
          # (Dran.Executions.broadcast_session_change/broadcast_run_change).
          Phoenix.PubSub.subscribe(Dran.PubSub, "workspace:#{context.id}")
        end

        {:ok,
         socket
         |> assign(
           context: context,
           active_nav: "workflows",
           workflow: nil,
           selected_session: nil,
           # Resource modal state — `?new=true` on the index opens the
           # create modal (pages/goals pattern: URL state, not a page).
           modal_open: false,
           form: nil,
           # Step modal (show only) — same URL-state pattern (`?new_step=true`
           # / `?step=<id>`); assigned in apply_show.
           step_modal: nil,
           step_form: nil
         )}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = assign(socket, params: params)

    socket =
      case socket.assigns.live_action do
        :index -> apply_index(socket, socket.assigns.context)
        :show -> apply_show(socket, socket.assigns.context, params)
      end

    {:noreply, socket}
  end

  # ── Loaders ───────────────────────────────────────────────────────────────

  defp apply_index(socket, nil), do: socket

  defp apply_index(socket, context) do
    params = Map.get(socket.assigns, :params, %{})
    kind_filters = kinds_from_params(params)
    status_filters = statuses_from_params(params)

    workflows =
      context.id
      |> Workflows.list_workflows(kind: kind_filters, status: status_filters)
      |> Enum.map(&workflow_summary/1)

    # Archived list always loaded — the "Archived" toggle only renders when
    # there is something archived (pages pattern). The status filter does not
    # apply here: the archived view owns archived items exclusively.
    archived_workflows =
      context.id
      |> Workflows.list_workflows(kind: kind_filters, archived: true)
      |> Enum.map(&workflow_summary/1)

    # Create-modal state — `?new=true` opens the modal (pages/goals pattern).
    modal_open = params["new"] == "true"

    form =
      if modal_open do
        to_form(Workflows.change_workflow(%Dran.Workflow{}), as: :workflow)
      else
        socket.assigns[:form]
      end

    assign(
      socket,
      Map.merge(
        %{
          workflows: workflows,
          archived_workflows: archived_workflows,
          kind_filters: kind_filters,
          status_filters: status_filters,
          workflow_kinds: Dran.Workflow.kinds(),
          status_options: List.delete(Dran.Workflow.statuses(), "archived"),
          kind_menu_open: socket.assigns[:kind_menu_open] || false,
          status_menu_open: socket.assigns[:status_menu_open] || false,
          modal_open: modal_open,
          form: form,
          goal_tree: Goals.flattened_tree(context.id),
          page_title: gettext("Workflows")
        },
        ListPagination.default_assigns()
      )
    )
  end

  # `?kind=evergreen,one_shot` URL-state filter (comma list, pages pattern) —
  # unknown values are dropped; an empty result means no filter.
  defp kinds_from_params(%{"kind" => raw}) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in ["evergreen", "one_shot"]))
  end

  defp kinds_from_params(_params), do: []

  # `?status=draft,active` URL-state filter (comma list, pages pattern) —
  # unknown values dropped; empty means no filter.
  defp statuses_from_params(%{"status" => raw}) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in ["draft", "active"]))
  end

  defp statuses_from_params(_params), do: []

  # One card payload: definition slice (workflow + steps count) and live
  # slice (in-flight sessions with their run progress).
  defp workflow_summary(workflow) do
    active_sessions =
      workflow
      |> Executions.list_sessions()
      |> Enum.filter(&(&1.status == "in_flight"))
      |> Enum.map(fn session -> {session, Executions.session_progress(session)} end)

    %{
      workflow: workflow,
      steps_count: length(Workflows.list_steps(workflow)),
      active_sessions: active_sessions
    }
  end

  defp apply_show(socket, nil, _params), do: socket

  defp apply_show(socket, context, %{"slug" => slug} = params) do
    case Workflows.get_workflow_by_slug(slug, context.id) do
      nil ->
        socket
        |> assign(page_title: gettext("Workflows"))
        |> push_patch(to: ~p"/#{socket.assigns[:workspace_slug]}/workflows")

      workflow ->
        socket
        |> assign(workflow: workflow, page_title: workflow.title)
        |> assign(
          kind_filters: kinds_from_params(params),
          status_filters: statuses_from_params(params),
          show_archived: false,
          kind_menu_open: false,
          status_menu_open: false,
          modal_open: false,
          form: nil,
          # Reset on every URL navigation — errors that live INSIDE the modal
          # (delete guard, contract JSON) must never leak to the next open.
          step_delete_error: nil,
          contract_lint: nil,
          visible_count: 12,
          archived_visible_count: 12
        )
        # One list_steps query shared by the modal state (after_step_id)
        # and load_show (DAG/levels/edges) — loaded ONCE here.
        |> then(fn socket ->
          steps_preloaded = Workflows.list_steps(workflow)

          socket
          |> assign(step_modal_state(workflow, params, steps_preloaded))
          |> load_show(workflow, params, steps_preloaded)
        end)
    end
  end

  # Legacy callers (session events, reload_current) refetch fresh; the
  # mount path passes the steps it already loaded for step_modal_state.
  defp load_show(socket, workflow, params), do: load_show(socket, workflow, params, nil)

  defp load_show(socket, workflow, params, nil),
    do: load_show(socket, workflow, params, Workflows.list_steps(workflow))

  defp load_show(socket, workflow, params, steps) do
    levels = Contracts.levels(steps)
    positions = step_positions(steps, levels)
    steps_by_id = Map.new(steps, &{&1.id, &1})
    step_ids = Enum.map(steps, & &1.id)

    # Graph edges for the SVG view — {dependent_id, prereq_id}.
    edges = Contracts.dependency_edges(step_ids, :step)

    # Definition-layer readiness: only steps with zero prerequisites are
    # ready here (steps have no board status).
    dep_info = Contracts.dependency_states(step_ids, :step)

    # Newest first — `{session, progress}` pairs, one progress query each.
    sessions =
      workflow
      |> Executions.list_sessions()
      |> Enum.map(fn session -> {session, Executions.session_progress(session)} end)

    selected =
      case params["session"] do
        id when is_binary(id) and id != "" ->
          Enum.find(sessions, fn {session, _progress} -> session.id == id end)

        _ ->
          nil
      end || List.first(sessions)

    {selected_session, selected_progress} =
      case selected do
        {session, progress} -> {session, progress}
        nil -> {nil, nil}
      end

    runs =
      case selected_session do
        nil -> []
        session -> Executions.list_runs(session)
      end

    # Steps of the selected session with a PASSED run — colors DAG edges.
    passed_step_ids =
      runs
      |> Enum.filter(&(&1.status == "passed"))
      |> MapSet.new(& &1.step_id)

    # Run titles: frozen snapshot first (the session's truth), live step
    # as fallback.
    snap_titles =
      case selected_session do
        %{snapshot: snapshot} ->
          snapshot
          |> Map.get("steps", [])
          |> List.wrap()
          |> Map.new(fn s -> {s["id"], s["title"]} end)

        _ ->
          %{}
      end

    # Live edges touching the step being edited (modal "Conexiones"
    # section): {outgoing, incoming} step structs, workspace-preloaded.
    {outgoing_deps, incoming_deps} =
      case Map.get(socket.assigns, :step_modal) do
        %{mode: :edit, step: %Dran.Step{} = step} ->
          step_connections(steps, step)

        _ ->
          {[], []}
      end

    assign(socket,
      steps: steps,
      levels: levels,
      positions: positions,
      steps_by_id: steps_by_id,
      edges: edges,
      dep_info: dep_info,
      sessions: sessions,
      selected_session: selected_session,
      session_progress: selected_progress,
      run_views: run_views(snap_titles, steps_by_id, runs),
      passed_step_ids: passed_step_ids,
      outgoing_deps: outgoing_deps,
      incoming_deps: incoming_deps
    )
  end

  # Live `depends_on` edges of `step` among THIS workflow's steps, resolved
  # to structs for the modal's connections list: {prereqs, dependents}.
  defp step_connections(steps, step) do
    step_ids = Enum.map(steps, & &1.id)
    ids = MapSet.new(step_ids)

    # The FULL workflow id list, not [step.id]: dependency_edges resolves
    # edges against the workspace's step graph and filters to ids present
    # in the list — a one-element list drops every edge.
    edges =
      Contracts.dependency_edges(step_ids, :step)
      |> Enum.filter(fn {dep, pre} -> MapSet.member?(ids, dep) and MapSet.member?(ids, pre) end)

    steps_by_id = Map.new(steps, &{&1.id, &1})

    # `s = Map.get(...)` doubles as a filter: nil (edge to a step outside
    # this workflow) drops out of the comprehension.
    outgoing =
      for {dep_id, prereq_id} <- edges,
          dep_id == step.id,
          s = Map.get(steps_by_id, prereq_id) do
        s
      end

    incoming =
      for {dep_id, prereq_id} <- edges,
          prereq_id == step.id,
          s = Map.get(steps_by_id, dep_id) do
        s
      end

    {outgoing, incoming}
  end

  defp run_views(_snap_titles, _steps_by_id, []), do: []

  defp run_views(snap_titles, steps_by_id, runs) do
    Enum.map(runs, fn run ->
      title =
        Map.get(snap_titles, run.step_id) ||
          case Map.get(steps_by_id, run.step_id) do
            %{title: title} -> title
            _ -> gettext("Step")
          end

      %{run: run, title: title}
    end)
  end

  # ── Step modal (show) — URL state: `?new_step=true` / `?step=<id>` ────────

  # Builds the modal state from URL params, pages/workflow-modal pattern:
  # no live state to desync — the URL is the single source of truth. A step
  # id that does not resolve (deleted elsewhere, forged id, bad UUID) simply
  # renders no modal.
  defp step_modal_state(%Dran.Workflow{} = workflow, params, steps) do
    cond do
      params["new_step"] == "true" ->
        changeset =
          %Dran.Step{workspace_id: workflow.workspace_id, workflow_id: workflow.id}
          |> Workflows.change_step()

        %{
          step_modal: %{
            mode: :new,
            step: nil,
            # "Después de" (create only): the workflow's last step by manual
            # order (position); nil when the workflow has no steps yet.
            after_step_id: last_step_id(steps),
            # Canvas create-at-point (?new_step=true&pos_x=&pos_y=): the
            # step is born with meta.pos at the double-clicked spot.
            create_pos: create_pos_from_params(params)
          },
          step_form: to_form(changeset, as: :step)
        }

      step_id = step_id_or_nil(params["step"]) ->
        case fetch_workflow_step(step_id, workflow.workspace_id) do
          %Dran.Step{} = step ->
            %{
              step_modal: %{mode: :edit, step: step, after_step_id: nil},
              step_form: to_form(Workflows.change_step(step), as: :step)
            }

          nil ->
            %{step_modal: nil, step_form: nil}
        end

      true ->
        %{step_modal: nil, step_form: nil}
    end
  end

  defp step_id_or_nil(id) when is_binary(id) and id != "", do: id
  defp step_id_or_nil(_), do: nil

  # Last step by the manual order (position); ties/nils → last by insertion.
  defp last_step_id([]), do: nil

  defp last_step_id(steps) do
    steps
    |> Enum.max_by(fn s -> {s.position || 0, s.inserted_at} end)
    |> Map.fetch!(:id)
  end

  # Row-level workspace authorization (fetch_workspace_workflow pattern):
  # URL ids are client-forgeable — a step of another workspace must never
  # open in the modal.
  defp fetch_workflow_step(id, workspace_id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Workflows.get_step!(uuid) do
          %Dran.Step{workspace_id: ^workspace_id} = step -> step
          _other -> nil
        end

      :error ->
        nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  # ── Events ────────────────────────────────────────────────────────────────

  # "Nueva sesión" — opens a session with an optional label. The workflow
  # id arrives via phx-value on the form (server-rendered, not forgeable
  # params from the input).
  @impl true
  def handle_event("open_session", %{"workflow-id" => workflow_id} = params, socket) do
    label =
      case params["label"] do
        label when is_binary(label) and label != "" -> label
        _ -> nil
      end

    workflow = fetch_workspace_workflow(workflow_id, socket.assigns.context)

    case workflow do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Workflow no encontrado."))}

      %Dran.Workflow{} = workflow ->
        case Executions.open_session(workflow, label: label) do
          {:ok, session} ->
            socket =
              socket
              |> put_flash(:info, gettext("Sesión abierta."))
              |> reload_after_change(workflow, session.id)

            {:noreply, socket}

          {:error, :workflow_has_no_steps} ->
            {:noreply,
             put_flash(socket, :error, gettext("El workflow no tiene steps: añade al menos uno."))}

          {:error, :workflow_archived} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("El workflow está archivado: no puede abrir sesiones.")
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("No se pudo abrir la sesión."))}
        end
    end
  end

  def handle_event("abort_session", %{"session-id" => session_id}, socket) do
    case fetch_workspace_session(session_id, socket.assigns.context) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sesión no encontrada."))}

      session ->
        case Executions.abort_session(session) do
          {:ok, _closed} ->
            socket =
              socket
              |> put_flash(:info, gettext("Sesión abortada."))
              |> reload_current()

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("No se pudo abortar la sesión."))}
        end
    end
  end

  # Click on a session row patches `?session=<id>` — selection is URL
  # state, deep-linkable.
  def handle_event("select_session", %{"session-id" => session_id}, socket) do
    ws = socket.assigns[:workspace_slug]

    {:noreply,
     push_patch(
       socket,
       to: ~p"/#{ws}/workflows/#{socket.assigns.workflow.slug}?session=#{session_id}"
     )}
  end

  # ── Workflow lifecycle (archive / unarchive / create) ─────────────────────

  # Archive from the index or the show header — refuses workflows with
  # in-flight sessions (guard in the context, surfaces a flash).
  def handle_event("archive_workflow", %{"workflow-id" => workflow_id}, socket) do
    workflow = fetch_workspace_workflow(workflow_id, socket.assigns.context)

    case workflow do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Workflow no encontrado."))}

      workflow ->
        case Workflows.archive_workflow(workflow) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, gettext("Workflow archivado."))
              |> reload_after_change(workflow, nil)

            {:noreply, socket}

          {:error, :has_open_sessions} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("No se puede archivar: tiene sesiones en ejecución.")
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("No se pudo archivar el workflow."))}
        end
    end
  end

  # Unarchive from the archived list (or the show header of an archived
  # workflow) — status returns to draft.
  def handle_event("unarchive_workflow", %{"workflow-id" => workflow_id}, socket) do
    workflow = fetch_workspace_workflow(workflow_id, socket.assigns.context)

    case workflow do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Workflow no encontrado."))}

      workflow ->
        case Workflows.unarchive_workflow(workflow) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, gettext("Workflow restaurado."))
              |> reload_after_change(workflow, nil)

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("No se pudo restaurar el workflow."))}
        end
    end
  end

  # ── Kind filter + archived toggle + pagination (pages pattern) ──────────

  # Multi-select: add or remove one kind from the URL selection and
  # push_patch — handle_params re-runs the filtered query.
  def handle_event("toggle_kind", %{"kind" => kind}, socket) do
    current = socket.assigns[:kind_filters] || []
    kind_filters = if kind in current, do: List.delete(current, kind), else: current ++ [kind]

    {:noreply,
     push_patch(socket,
       to:
         filters_path(
           socket.assigns[:workspace_slug],
           kind_filters,
           socket.assigns[:status_filters]
         )
     )}
  end

  def handle_event("toggle_status", %{"status" => status}, socket) do
    current = socket.assigns[:status_filters] || []

    status_filters =
      if status in current, do: List.delete(current, status), else: current ++ [status]

    {:noreply,
     push_patch(socket,
       to:
         filters_path(
           socket.assigns[:workspace_slug],
           socket.assigns[:kind_filters],
           status_filters
         )
     )}
  end

  def handle_event("clear_filters", _params, socket),
    do: {:noreply, push_patch(socket, to: filters_path(socket.assigns[:workspace_slug], [], []))}

  def handle_event("toggle_kind_menu", _params, socket),
    do: {:noreply, assign(socket, kind_menu_open: not socket.assigns[:kind_menu_open])}

  def handle_event("toggle_status_menu", _params, socket),
    do: {:noreply, assign(socket, status_menu_open: not socket.assigns[:status_menu_open])}

  # Archived view — pagination state, not URL (pages pattern): the toggle
  # only flips which list the template renders. Filter menus are closed here
  # so they don't resurface open when returning to the active view (the
  # dropdowns only render there).
  def handle_event("toggle_archived", _params, socket) do
    socket =
      socket
      |> ListPagination.handle_toggle_archived()
      |> assign(kind_menu_open: false, status_menu_open: false)

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket),
    do: {:noreply, ListPagination.handle_load_more(socket)}

  def handle_event("load_more_archived", _params, socket),
    do: {:noreply, ListPagination.handle_load_more_archived(socket)}

  # ── Create-workflow modal (?new=true) ────────────────────────────────────

  def handle_event("validate_workflow", %{"workflow" => params}, socket) do
    changeset =
      %Dran.Workflow{workspace_id: socket.assigns.context.id}
      |> Workflows.change_workflow(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :workflow))}
  end

  def handle_event("save_workflow", %{"workflow" => params}, socket) do
    context = socket.assigns.context

    # Slug auto-derives from title when absent (goal_live pattern).
    attrs =
      %{
        "title" => String.trim(params["title"] || ""),
        "body" => params["body"] || "",
        "kind" => params["kind"],
        "status" => params["status"] || "active",
        "goal_id" => goal_id_or_nil(params["goal_id"]),
        "workspace_id" => context.id
      }
      |> ensure_workflow_slug()

    case Workflows.create_workflow(attrs) do
      {:ok, workflow} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Workflow creado."))
         |> push_patch(to: ~p"/#{socket.assigns[:workspace_slug]}/workflows/#{workflow.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :workflow))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("No se pudo crear el workflow."))}
    end
  end

  def handle_event("close_workflow_modal", _params, socket) do
    # Preserve active kind filters when closing back to the list (pages).
    {:noreply,
     push_patch(
       socket,
       to:
         filters_path(
           socket.assigns[:workspace_slug],
           socket.assigns[:kind_filters] || [],
           socket.assigns[:status_filters] || []
         )
     )}
  end

  # ── Step modal events (?new_step=true / ?step=<id>) ───────────────────────

  # Opens the modal by patching the URL — URL state is the single source of
  # truth (pages/goals/workflow-modal pattern).
  def handle_event("open_step_modal", %{"mode" => "new"}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         show_path(socket.assigns[:workspace_slug], socket.assigns.workflow.slug) <>
           "?new_step=true"
     )}
  end

  def handle_event("open_step_modal", %{"mode" => "edit", "step-id" => step_id}, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         show_path(socket.assigns[:workspace_slug], socket.assigns.workflow.slug) <>
           "?step=#{step_id}"
     )}
  end

  def handle_event("validate_step", %{"step" => params}, socket) do
    # Same whitelist as save (SEC-006): validate only form-owned fields —
    # workspace_id/workflow_id/position are server-owned.
    changeset =
      step_for_mode(socket)
      |> Workflows.change_step(Map.take(params, ["title", "slug", "body"]))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(step_form: to_form(changeset, as: :step))
     |> assign(contract_lint: contract_feedback(params))}
  end

  def handle_event("save_step", %{"step" => step_params} = all_params, socket) do
    # A forged phx-submit (or a race with a patch that closed the modal)
    # arrives with no modal open → flash, never a MatchError crash. Every
    # other canvas handler authorizes ids via fetch_workflow_step; this one
    # guards the modal state itself.
    case Map.get(socket.assigns, :step_modal) do
      %{mode: mode, step: step} ->
        save_step(mode, step, step_params, all_params, socket)

      _ ->
        {:noreply, put_flash(socket, :error, gettext("No hay ningún step abierto para guardar."))}
    end
  end

  def handle_event("delete_step", %{"step-id" => step_id}, socket) do
    case fetch_workflow_step(step_id, socket.assigns.workflow.workspace_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Step no encontrado."))}

      step ->
        case Workflows.delete_step(step) do
          {:ok, _step} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Step eliminado."))
             |> push_patch(
               to: show_path(socket.assigns[:workspace_slug], socket.assigns.workflow.slug)
             )}

          {:error, reason} when reason in [:has_open_runs, :referenced_by_open_session] ->
            # The modal stays open; it covers the page's flash group, so the
            # guard error renders INSIDE the modal footer instead.
            {:noreply,
             assign(
               socket,
               step_delete_error:
                 gettext(
                   "No se puede eliminar: tiene runs abiertos o pertenece al snapshot de una sesión en curso."
                 )
             )}
        end
    end
  end

  def handle_event("close_step_modal", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: show_path(socket.assigns[:workspace_slug], socket.assigns.workflow.slug)
     )}
  end

  # ── Step modal (edit): connections — break a depends_on edge ─────────────

  # Both ids arrive via phx-value (forgeable) → authorize against the
  # workspace AND this workflow, same as the canvas remove path. The edge is
  # whichever direction exists between the step and the other one.
  def handle_event(
        "remove_step_dependency",
        %{"step-id" => step_id, "other-id" => other_id},
        socket
      ) do
    ws_id = socket.assigns.workflow.workspace_id

    with %Dran.Step{} = step <- fetch_workflow_step(step_id, ws_id),
         %Dran.Step{} = other <- fetch_workflow_step(other_id, ws_id),
         :ok <- ensure_same_workflow(step, other, socket.assigns.workflow),
         # The edge is whichever direction exists (outgoing or incoming);
         # remove_dependency deletes step→other only, so a 0-count on the
         # first order falls back to the inverse edge other→step.
         {:ok, _} <-
           (case Contracts.remove_dependency(step, other) do
              {:ok, 0} -> Contracts.remove_dependency(other, step)
              ok -> ok
            end) do
      {:noreply, reload_current(socket)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("No se pudo quitar la conexión."))}
    end
  end

  # ── Canvas editor (free layout + port-to-port edges) ─────────────────────

  # Drag-end of a card: persist `meta.pos`. Cosmetic by design — a failed
  # save never aborts anything and is silent; the client already moved the
  # card on its grid. The first drag materializes the whole workflow into
  # the free layout so the canvas is all-or-nothing (positions or levels).
  def handle_event("move_step", %{"step-id" => step_id, "x" => x, "y" => y}, socket) do
    with %Dran.Step{} = step <-
           fetch_workflow_step(step_id, socket.assigns.workflow.workspace_id),
         {x, ""} <- Integer.parse(to_string(x)),
         {y, ""} <- Integer.parse(to_string(y)),
         true <- x >= 0 and y >= 0 do
      # The rendered layout (levels or free) with the card moved — always
      # complete, so the first drag materializes the whole workflow into
      # the free layout. Assign is kept in sync so consecutive drags
      # between reloads never write a stale position back.
      positions = Map.put(socket.assigns.positions, step.id, {x, y})

      case Workflows.persist_positions(socket.assigns.workflow, positions) do
        {:ok, _} -> {:noreply, assign(socket, :positions, positions)}
        {:error, _} -> {:noreply, socket}
      end
    else
      _ -> :error
    end

    {:noreply, socket}
  end

  # Drop of a port-to-port connection: prereq → dependent `depends_on`.
  # Cycle/self guards live in Contracts.add_dependency; both ids are
  # authorized against the workspace AND this workflow (forgeable params).
  def handle_event("connect_steps", %{"dependent-id" => dep_id, "prereq-id" => pre_id}, socket) do
    with %Dran.Step{} = dependent <-
           fetch_workflow_step(dep_id, socket.assigns.workflow.workspace_id),
         %Dran.Step{} = prereq <-
           fetch_workflow_step(pre_id, socket.assigns.workflow.workspace_id),
         :ok <- ensure_same_workflow(dependent, prereq, socket.assigns.workflow) do
      case Contracts.add_dependency(dependent, prereq) do
        {:ok, _} ->
          {:noreply, reload_current(socket)}

        {:error, :cycle} ->
          {:noreply,
           put_flash(socket, :error, gettext("La conexión cerraría un ciclo de dependencias."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("No se pudo conectar los steps."))}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Step no encontrado."))}
    end
  end

  # ✕ on an edge hover: delete the `depends_on` relation.
  def handle_event(
        "remove_dependency",
        %{"dependent-id" => dep_id, "prereq-id" => pre_id},
        socket
      ) do
    with %Dran.Step{} = dependent <-
           fetch_workflow_step(dep_id, socket.assigns.workflow.workspace_id),
         %Dran.Step{} = prereq <-
           fetch_workflow_step(pre_id, socket.assigns.workflow.workspace_id),
         :ok <- ensure_same_workflow(dependent, prereq, socket.assigns.workflow),
         {:ok, _} <- Contracts.remove_dependency(dependent, prereq) do
      {:noreply, reload_current(socket)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("No se pudo quitar la dependencia."))}
    end
  end

  # Menú de arista — "Agregar step": crea un step NUEVO en medio de la
  # arista (A → nuevo → B) partiendo la conexión original en una transacción
  # (rollback total si algo falla).
  def handle_event(
        "edge_add_step",
        %{"dependent-id" => dep_id, "prereq-id" => pre_id},
        socket
      ) do
    with %Dran.Step{} = dependent <-
           fetch_workflow_step(dep_id, socket.assigns.workflow.workspace_id),
         %Dran.Step{} = prereq <-
           fetch_workflow_step(pre_id, socket.assigns.workflow.workspace_id),
         :ok <- ensure_same_workflow(dependent, prereq, socket.assigns.workflow) do
      case Workflows.insert_step_between(socket.assigns.workflow, dependent, prereq, %{
             "title" => gettext("Nuevo paso")
           }) do
        {:ok, _} ->
          {:noreply, reload_current(socket)}

        {:error, :missing_edge} ->
          {:noreply, put_flash(socket, :error, gettext("La conexión ya no existe."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("No se pudo crear el step."))}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Step no encontrado."))}
    end
  end

  # Menú de arista — "Linkear step…": mete un step YA EXISTENTE del
  # workflow en medio de la arista. Guard de self-edge en Workflows; el
  # picker del hook solo ofrece steps del workflow, pero los params son
  # forgeables → authorize ambos endpoints aquí.
  def handle_event(
        "link_step_between",
        %{"dependent-id" => dep_id, "prereq-id" => pre_id, "middle-id" => mid_id},
        socket
      ) do
    with %Dran.Step{} = dependent <-
           fetch_workflow_step(dep_id, socket.assigns.workflow.workspace_id),
         %Dran.Step{} = prereq <-
           fetch_workflow_step(pre_id, socket.assigns.workflow.workspace_id),
         %Dran.Step{} = middle <-
           fetch_workflow_step(mid_id, socket.assigns.workflow.workspace_id),
         :ok <- ensure_same_workflow(dependent, prereq, socket.assigns.workflow),
         :ok <- ensure_same_workflow(middle, prereq, socket.assigns.workflow),
         :ok <- ensure_same_workflow(middle, dependent, socket.assigns.workflow) do
      case Workflows.link_step_between(dependent, prereq, middle) do
        {:ok, _} ->
          {:noreply, reload_current(socket)}

        {:error, :invalid} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("El step intermedio no puede ser un extremo de la conexión.")
           )}

        {:error, :cycle} ->
          {:noreply,
           put_flash(socket, :error, gettext("La conexión cerraría un ciclo de dependencias."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("No se pudo linkear el step."))}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Step no encontrado."))}
    end
  end

  # ⌗ control: drop every saved position → back to the topological layout.
  def handle_event("repack_layout", _params, socket) do
    case Workflows.repack_layout(socket.assigns.workflow) do
      {:ok, _} ->
        {:noreply, reload_current(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("No se pudo reordenar el canvas."))}
    end
  end

  # Double-click on empty canvas: open the new-step modal carrying the
  # clicked coordinates so the created step is born at that canvas spot.
  def handle_event("new_step_at", %{"x" => x, "y" => y}, socket) do
    with {x, ""} <- Integer.parse(to_string(x)),
         {y, ""} <- Integer.parse(to_string(y)) do
      # Center the card on the clicked point.
      x = max(x - div(node_w(), 2), 0)
      y = max(y - div(node_h(), 2), 0)

      {:noreply,
       push_patch(
         socket,
         to:
           show_path(socket.assigns[:workspace_slug], socket.assigns.workflow.slug) <>
             "?new_step=true&pos_x=#{x}&pos_y=#{y}"
       )}
    else
      _ ->
        {:noreply, socket}
    end
  end

  # Create carries the "después de" edge inside the SAME transaction
  # (create_step/3 `:after_step_id`) — a failed edge rolls the step back,
  # so the UI never reports success for a placement that did not happen.
  defp create_or_update(:new, _step, attrs, workflow, all_params) do
    opts =
      case after_step_id(all_params, workflow) do
        {:ok, prereq_id} -> [after_step_id: prereq_id]
        :error -> []
      end

    Workflows.create_step(workflow, attrs, opts)
  end

  defp create_or_update(:edit, step, attrs, _workflow, _all_params),
    do: Workflows.update_step(step, attrs)

  # Body of "save_step" — extracted so the handle_event can guard a forged
  # submit with no modal open (step_modal: nil) without a MatchError crash.
  defp save_step(mode, step, step_params, all_params, socket) do
    attrs =
      step_params
      |> step_attrs_from_params(socket.assigns.workflow)
      |> maybe_put_create_pos(socket.assigns[:step_modal])
      |> maybe_put_contract(step_params, step)

    with {:ok, _step} <-
           create_or_update(mode, step, attrs, socket.assigns.workflow, all_params) do
      {:noreply,
       socket
       |> put_flash(:info, step_flash(mode))
       |> push_patch(to: show_path(socket.assigns[:workspace_slug], socket.assigns.workflow.slug))}
    else
      {:error, %Ecto.Changeset{} = failed_cs} ->
        # Errors from DB constraints arrive with a non-:validate action and,
        # for the composite unique (workspace_id, slug), attached to
        # :workspace_id — a field that is not on the form. Revalidate with
        # the submitted params and re-attach the constraint error to the
        # visible :slug field so used_input? exposes it in the modal.
        constraint_errors =
          failed_cs.errors
          |> Keyword.take([:slug, :workspace_id])
          |> Enum.map(fn
            {:workspace_id, msg_opts} -> {:slug, msg_opts}
            other -> other
          end)

        revalidated =
          step_for_mode(socket)
          |> Workflows.change_step(step_params)
          |> Map.replace!(:action, :validate)
          |> Map.update!(:errors, fn errors ->
            Enum.uniq_by(constraint_errors ++ errors, &elem(&1, 0))
          end)

        {:noreply, assign(socket, step_form: to_form(revalidated, as: :step))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("No se pudo guardar el step."))}
    end
  end

  # `?pos_x=&pos_y=` from the canvas double-click (new_step_at) — the spot
  # where the new step will be born. Garbage or negative → nil (levels).
  defp create_pos_from_params(%{"pos_x" => px, "pos_y" => py}) do
    with {x, ""} <- Integer.parse(to_string(px)),
         {y, ""} <- Integer.parse(to_string(py)),
         true <- x >= 0 and y >= 0 do
      {x, y}
    else
      _ -> nil
    end
  end

  defp create_pos_from_params(_), do: nil

  # Create with a canvas birth position: meta.pos rides along the same
  # changeset (validate/save whitelist untouched — pos comes from modal
  # state, not from form params).
  defp maybe_put_create_pos(attrs, %{mode: :new, create_pos: {x, y}}) do
    meta = Map.put(attrs["meta"] || %{}, "pos", %{"x" => x, "y" => y})
    Map.put(attrs, "meta", meta)
  end

  defp maybe_put_create_pos(attrs, _), do: attrs

  # Canvas connect/remove params are forgeable — both endpoints must belong
  # to THIS workflow (workspace authorization already happened in
  # fetch_workflow_step; cross-workspace is still rejected downstream).
  defp ensure_same_workflow(
         %Dran.Step{workflow_id: wid},
         %Dran.Step{workflow_id: wid},
         _workflow
       ),
       do: :ok

  defp ensure_same_workflow(_, _, _), do: {:error, :cross_workflow}

  # The checked "después de" prereq, authorized against BOTH workspace and
  # workflow (the checkbox only offers this workflow's steps, but the param
  # is forgeable — a cross-workflow edge would poison dependency_states).
  defp after_step_id(all_params, %Dran.Workflow{} = workflow) do
    case all_params["new_step"]["after"] do
      after_id when is_binary(after_id) and after_id != "" ->
        case fetch_workflow_step(after_id, workflow.workspace_id) do
          %Dran.Step{workflow_id: step_workflow_id, id: step_id}
          when step_workflow_id == workflow.id ->
            {:ok, step_id}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # ── Step contract (`meta["contract"]`) — edit + lint feedback ─────────────

  # JSON textarea params → `meta["contract"]`, merged over the step's
  # CURRENT meta (Repo re-read: the modal's struct can be stale — canvas
  # writes `meta.pos` after the modal opened). Merge-first keeps
  # `meta.pos` alive. Blank textarea = drop the contract (explicit erasure).
  # Unparseable JSON or a non-object NEVER touches the stored contract —
  # validate_step already showed the error next to the textarea; saving
  # must not silently destroy the previous brief.
  defp maybe_put_contract(attrs, %{"contract_json" => raw}, step)
       when is_binary(raw) do
    # The step's meta as persisted NOW (the modal's struct predates any
    # canvas move_step): merge over the live meta, not attrs["meta"] which
    # starts empty on every save.
    live_meta =
      case Dran.Workflows.get_step!(step.id) do
        %Dran.Step{meta: meta} -> meta || %{}
        _ -> %{}
      end

    case String.trim(raw) do
      "" ->
        Map.put(attrs, "meta", Map.delete(live_meta, "contract"))

      json ->
        case Jason.decode(json) do
          {:ok, contract} when is_map(contract) ->
            Map.put(attrs, "meta", Map.put(live_meta, "contract", contract))

          _other ->
            attrs
        end
    end
  end

  defp maybe_put_contract(attrs, _params, _step), do: attrs

  # Live JSON feedback while typing (validate_step): parse + lint. Never
  # blocks the form — the error surfaces next to the textarea; a valid
  # contract that fails lint (funnel, verbs) says why.
  defp contract_feedback(params) do
    raw = params["contract_json"] || ""

    cond do
      not is_binary(raw) -> :empty
      String.trim(raw) == "" -> :empty
      true -> decode_and_lint(raw)
    end
  end

  defp decode_and_lint(raw) do
    case Jason.decode(raw) do
      {:ok, contract} when is_map(contract) ->
        case Contracts.lint_contract(contract) do
          {:ok, _warnings} ->
            {:ok, gettext("Contrato válido.")}

          {:error, errors} ->
            # lint_contract prepends each check, so the list is
            # reverse-checked (graph first, intent last). Reverse to report
            # the most fundamental error (intent → status → claims → …).
            {:invalid, lint_message(Enum.reverse(errors))}
        end

      {:ok, _other} ->
        {:invalid, gettext("El JSON debe ser un objeto.")}

      {:error, %Jason.DecodeError{} = e} ->
        {:invalid, gettext("JSON inválido") <> " — #{Exception.message(e)}"}
    end
  end

  # Human message for lint errors (closed vocabulary of Dran.Contracts).
  defp lint_message([:intent | _]), do: gettext("Falta \"intent\".")
  defp lint_message([:status | _]), do: gettext("\"status\" debe ser draft, active o superseded.")
  defp lint_message([:claims | _]), do: gettext("Claims: lista de {id, claim, verify} no vacíos.")
  defp lint_message([:gates | _]), do: gettext("Gates: lista de {name, cmd, expect} no vacíos.")
  defp lint_message([:graph_nodes | _]), do: gettext("El graph necesita al menos un nodo.")

  defp lint_message([:graph_verbs | _]),
    do: gettext("Verbos válidos: READ, EDIT, CREATE, RUN, VERIFY, ASK.")

  defp lint_message([:graph_funnel | _]),
    do: gettext("El grafo debe alcanzar un nodo VERIFY (funnel de verificación).")

  defp lint_message([:graph | _]), do: gettext("Graph inválido: {nodes: [], edges: []}.")
  defp lint_message(_), do: gettext("El contrato no pasa el lint.")

  defp contract_json(%Dran.Step{meta: %{"contract" => contract}}) when is_map(contract),
    do: Jason.encode!(contract, pretty: true)

  defp contract_json(_), do: ""

  # The struct the form validates against: the existing step on edit, a
  # scope-pinned new step on create.
  defp step_for_mode(socket) do
    case socket.assigns.step_modal do
      %{mode: :edit, step: %Dran.Step{} = step} ->
        step

      _ ->
        %Dran.Step{
          workspace_id: socket.assigns.workflow.workspace_id,
          workflow_id: socket.assigns.workflow.id
        }
    end
  end

  # Modal form params → step attrs. `meta` y `position` no son campos del
  # modal: update los conserva (el changeset solo castea lo enviado), create
  # los defaultea (%{} / max+100).
  defp step_attrs_from_params(params, workflow) do
    %{
      "title" => String.trim(params["title"] || ""),
      "body" => params["body"] || ""
    }
    |> maybe_put_step_slug(params, workflow)
    |> Map.put("workspace_id", workflow.workspace_id)
  end

  # Slug auto-deriva del título cuando el usuario no lo escribe (goal_live
  # pattern): en create Y en edit, campo vacío = slugify(title).
  defp maybe_put_step_slug(attrs, params, %Dran.Workflow{} = _workflow) do
    case String.trim(params["slug"] || "") do
      "" -> Map.put(attrs, "slug", Dran.Slug.slugify(attrs["title"]))
      slug -> Map.put(attrs, "slug", slug)
    end
  end

  defp step_flash(:new), do: gettext("Step creado.")
  defp step_flash(:edit), do: gettext("Step actualizado.")

  # Title of a step for the "después de" checkbox label.
  defp step_title(steps_by_id, step_id) when is_map(steps_by_id) and is_binary(step_id) do
    case Map.fetch(steps_by_id, step_id) do
      {:ok, %Dran.Step{title: title}} -> title
      _ -> "?"
    end
  end

  defp step_title(_, _), do: "?"

  defp show_path(workspace_slug, workflow_slug) do
    ~p"/#{workspace_slug}/workflows/#{workflow_slug}"
  end

  defp goal_id_or_nil(id) when is_binary(id) and id != "", do: id
  defp goal_id_or_nil(_), do: nil

  # Slug auto-derives from title when the user didn't provide one (goal_live
  # pattern with Dran.Slug).
  defp ensure_workflow_slug(%{"slug" => slug} = attrs) when is_binary(slug) and slug != "",
    do: attrs

  defp ensure_workflow_slug(%{"title" => title} = attrs) when is_binary(title) and title != "",
    do: Map.put(attrs, "slug", Dran.Slug.slugify(title))

  defp ensure_workflow_slug(attrs), do: attrs

  # Index list path with both filters preserved (pages pattern): shareable,
  # deep-linkable filtered views. `suffix` appends "?new=true" for the modal;
  # joins segments with "&" so no second "?" ever leaks into the query.
  defp filters_path(workspace_slug, kind_filters, status_filters, suffix \\ "") do
    path = "/#{workspace_slug}/workflows"

    params =
      [
        if(kind_filters == [], do: nil, else: "kind=#{Enum.join(kind_filters, ",")}"),
        if(status_filters == [], do: nil, else: "status=#{Enum.join(status_filters, ",")}")
      ]
      |> Enum.reject(&is_nil/1)

    case {params, suffix} do
      {[], ""} -> path
      {[], "?" <> _} -> path <> suffix
      {_, ""} -> path <> "?" <> Enum.join(params, "&")
      {_, "?" <> rest} -> path <> "?" <> Enum.join(params, "&") <> "&" <> rest
    end
  end

  # Row-level workspace authorization (review finding #2): phx-value ids
  # are client-forgeable — the board already rejects foreign workspaces
  # this way (fetch_board_task pattern); executions must not reincide.
  defp fetch_workspace_workflow(id, %Dran.Workspace{} = context) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Workflows.get_workflow!(uuid) do
          %Dran.Workflow{workspace_id: ws_id} = wf when ws_id == context.id -> wf
          _other -> nil
        end

      :error ->
        nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp fetch_workspace_session(id, %Dran.Workspace{} = context) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Executions.get_session!(uuid) do
          %Dran.WorkflowSession{workspace_id: ws_id} = s when ws_id == context.id -> s
          _other -> nil
        end

      :error ->
        nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp reload_after_change(socket, workflow, session_id) do
    case socket.assigns.live_action do
      :index -> apply_index(socket, socket.assigns.context)
      :show -> load_show(socket, workflow, %{"session" => session_id})
    end
  end

  defp reload_current(socket) do
    case socket.assigns.live_action do
      :index ->
        if socket.assigns.context, do: apply_index(socket, socket.assigns.context), else: socket

      :show ->
        if socket.assigns.workflow do
          selected_id =
            case socket.assigns[:selected_session] do
              %{id: id} -> id
              _ -> nil
            end

          load_show(socket, socket.assigns.workflow, %{"session" => selected_id})
        else
          socket
        end
    end
  end

  # ── PubSub: sessions/runs changed elsewhere (MCP, API, other tab) ─────────
  # Progress reports (:run_changed :progress) are NOT handled — agents
  # report phase progress every few seconds and a full reload per report
  # is stop-the-world (review finding #8). The runs panel refreshes on
  # selection change and on start/close events.
  @impl true
  def handle_info({:session_changed, _action, _session}, socket),
    do: {:noreply, reload_current(socket)}

  # Workflow archived/unarchived elsewhere (other tab, MCP future) — index
  # reloads lists, show reloads the workflow (status badge changes).
  def handle_info({:workflow_changed, _action, _workflow}, socket),
    do: {:noreply, reload_current(socket)}

  def handle_info({:run_changed, action, _run}, socket)
      when action in [:started, :closed, :created],
      do: {:noreply, reload_current(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Chips and labels ──────────────────────────────────────────────────────

  @doc false
  def workflow_chip("active"), do: "badge-success"
  def workflow_chip("draft"), do: "badge-ghost"
  def workflow_chip("archived"), do: "badge-warning"
  def workflow_chip(_), do: "badge-ghost"

  @doc false
  def session_chip("in_flight"), do: "badge-primary"
  def session_chip("passed"), do: "badge-success"
  def session_chip("failed"), do: "badge-error"
  def session_chip("aborted"), do: "badge-warning"
  def session_chip(_), do: "badge-ghost"

  @doc false
  def run_chip("pending"), do: "badge-ghost"
  def run_chip("in_flight"), do: "badge-primary"
  def run_chip("passed"), do: "badge-success"
  def run_chip("failed"), do: "badge-error"
  def run_chip("skipped"), do: "badge-warning"
  def run_chip(_), do: "badge-ghost"

  @doc false
  def status_label(nil), do: ""

  def status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc false
  def kind_label("evergreen"), do: gettext("Evergreen")
  def kind_label("one_shot"), do: gettext("One shot")
  def kind_label(_), do: ""

  # Finished runs (passed + failed + skipped) over total.
  @doc false
  def session_pct(%{total: total}) when total in [0, nil], do: 0

  def session_pct(%{total: total, passed: passed, failed: failed, skipped: skipped}) do
    div((passed + failed + skipped) * 100, total)
  end

  @doc false
  def progress_label(%{total: total, passed: passed, failed: failed, skipped: skipped}),
    do: "#{passed + failed + skipped}/#{total}"

  def progress_label(_), do: "0/0"

  # ── Template helpers ──────────────────────────────────────────────────────

  defp ready_steps(steps, dep_info) do
    Enum.filter(steps, fn step ->
      match?(%{ready: true}, Map.get(dep_info, step.id))
    end)
  end

  defp blocked_steps(steps, dep_info) do
    Enum.filter(steps, fn step ->
      match?(%{ready: false}, Map.get(dep_info, step.id))
    end)
  end

  defp blocked_count(step, %{dep_info: dep_info}) do
    case Map.get(dep_info, step.id) do
      %{blocked_count: n} -> n
      _ -> 0
    end
  end

  defp step_has_passed?(passed_step_ids, step_id), do: MapSet.member?(passed_step_ids, step_id)

  defp run_phase(%{progress: %{"phase" => phase}}) when is_binary(phase) and phase != "",
    do: phase

  defp run_phase(_), do: nil

  defp format_dt(nil), do: ""

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")

  defp format_dt(_), do: ""

  # ── Graph layout (pure helpers for the SVG DAG) ─────────────────────────
  #
  # Levels → columns. Every step is positioned in a virtual grid:
  #   column = level index, row = index within the level.
  # Node cards are ~220px wide × ~96px tall with fixed gaps; the SVG is
  # drawn inset by one node so edges run between card edges.

  @node_w 220
  @node_h 96
  @gap_x 48
  @gap_y 20

  @doc false
  def node_w, do: @node_w

  @doc false
  def node_h, do: @node_h

  # `{step_id => {x, y}}` for the whole workflow: saved canvas positions
  # (`meta["pos"]`) when every step has one, topological levels otherwise —
  # all-or-nothing, so a partially dragged workflow never makes cards jump
  # between the two layouts on reload.
  @doc false
  def step_positions([], _levels), do: %{}

  def step_positions(steps, levels) do
    if Enum.all?(steps, &free_position?/1) do
      Map.new(steps, fn step ->
        pos = step.meta["pos"]
        {step.id, {pos["x"], pos["y"]}}
      end)
    else
      layout_positions(levels)
    end
  end

  # `{step_id => {x, y}}` for the classic levels layout — also what a
  # free-layout workflow materializes from on its first drag.
  @doc false
  def layout_positions(levels) when is_list(levels) do
    levels
    |> Enum.with_index()
    |> Enum.flat_map(fn {level, level_idx} ->
      level
      |> Enum.with_index()
      |> Enum.map(fn {step_id, row_idx} -> {step_id, {node_x(level_idx), node_y(row_idx)}} end)
    end)
    |> Map.new()
  end

  defp free_position?(%{meta: %{"pos" => %{"x" => x, "y" => y}}})
       when is_integer(x) and is_integer(y),
       do: true

  defp free_position?(_), do: false

  @doc false
  def graph_width(positions) when is_map(positions) do
    max_x = positions |> Map.values() |> Enum.map(fn {x, _} -> x end) |> Enum.max(fn -> 0 end)
    max(600, max_x + @node_w + @gap_x)
  end

  @doc false
  def graph_height(positions) when is_map(positions) do
    max_y = positions |> Map.values() |> Enum.map(fn {_, y} -> y end) |> Enum.max(fn -> 0 end)
    max(240, max_y + @node_h + @gap_y)
  end

  @doc false
  def node_position(positions, step_id) do
    Map.get(positions, step_id, {0, 0})
  end

  defp node_x(level_idx), do: level_idx * (@node_w + @gap_x) + @gap_x
  defp node_y(row_idx), do: row_idx * (@node_h + @gap_y) + @gap_y

  @doc false
  def graph_edges(edges, positions, passed_step_ids \\ MapSet.new()) do
    # `edges` come from `dependency_edges(step_ids, :step)` as
    # `{dependent_id, prereq_id}` (a step depends_on its prereq). The arrow
    # flows prereq → dependent: the prereq is the source/output, the
    # dependent the target/input. An edge is "done" (solid/success) when
    # the selected session has a PASSED run of the prereq step.
    Enum.map(edges, fn {dependent_id, prereq_id} ->
      {px, py} = node_position(positions, prereq_id)
      {dx, dy} = node_position(positions, dependent_id)

      # Output port (prereq): right edge, vertically centered.
      x1 = px + @node_w
      y1 = py + @node_h / 2

      # Input port (dependent): left edge, vertically centered.
      x2 = dx
      y2 = dy + @node_h / 2

      # Same-row edges spanning an intermediate column arc downward into the
      # empty gap band instead of cutting through cards in that row.
      sag =
        if dy == py and x2 - x1 > @node_w + @gap_x do
          (@node_h + @gap_y) * 0.7
        else
          0
        end

      c1x = x1 + (x2 - x1) * 0.3
      c1y = y1 + sag
      c2x = x2 - (x2 - x1) * 0.3
      c2y = y2 + sag

      path = "M #{x1} #{y1} C #{c1x} #{c1y}, #{c2x} #{c2y}, #{x2} #{y2}"

      {dependent_id,
       %{
         path: path,
         dependent_id: dependent_id,
         prereq_id: prereq_id,
         x1: x1,
         y1: y1,
         x2: x2,
         y2: y2,
         done: MapSet.member?(passed_step_ids, prereq_id)
       }}
    end)
  end

  @doc """
  One input port and one output port per card: `%{step_id => %{out: | in: %{x, y, done}}}`.
  Out = right edge center, In = left edge center. Since every edge from a source
  shares the same right-center point and every edge into a target shares the same
  left-center point, the ports are deduplicated per card (not per edge).
  """
  def graph_ports(edges, positions) do
    Enum.reduce(edges, %{}, fn {_dep_id, e}, acc ->
      {px, py} = node_position(positions, e.prereq_id)
      {dx, dy} = node_position(positions, e.dependent_id)

      acc
      |> Map.update(
        e.prereq_id,
        %{out: %{x: px + @node_w, y: py + @node_h / 2, done: e.done}, in: nil},
        fn p -> %{p | out: %{x: px + @node_w, y: py + @node_h / 2, done: e.done}} end
      )
      |> Map.update(
        e.dependent_id,
        %{out: nil, in: %{x: dx, y: dy + @node_h / 2, done: e.done}},
        fn p -> %{p | in: %{x: dx, y: dy + @node_h / 2, done: e.done}} end
      )
    end)
  end

  @doc false
  def graph_nodes(steps, positions) do
    for step <- steps, {x, y} = Map.get(positions, step.id), do: {step, x, y}
  end
end
