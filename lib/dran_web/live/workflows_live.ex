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

  alias Dran.{Contracts, Executions, Workflows}

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
           selected_session: nil
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
    workflows =
      context.id
      |> Workflows.list_workflows()
      |> Enum.map(&workflow_summary/1)

    assign(socket, workflows: workflows, page_title: gettext("Workflows"))
  end

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
        |> load_show(workflow, params)
    end
  end

  defp load_show(socket, workflow, params) do
    steps = Workflows.list_steps(workflow)
    levels = Contracts.levels(steps)
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

    assign(socket,
      steps: steps,
      levels: levels,
      steps_by_id: steps_by_id,
      edges: edges,
      dep_info: dep_info,
      sessions: sessions,
      selected_session: selected_session,
      session_progress: selected_progress,
      run_views: run_views(snap_titles, steps_by_id, runs),
      passed_step_ids: passed_step_ids
    )
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

  @impl true
  def handle_info({:session_changed, _action, _session}, socket),
    do: {:noreply, reload_current(socket)}

  def handle_info({:run_changed, _action, _run}, socket),
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

  @doc false
  def graph_width(levels) when is_list(levels) do
    max(600, length(levels) * (@node_w + @gap_x) + @gap_x + @node_w)
  end

  @doc false
  def graph_height(levels) when is_list(levels) do
    max_rows = levels |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)
    max_rows * (@node_h + @gap_y) + @gap_y + @node_h
  end

  @doc false
  def node_position(levels, step_id) do
    Enum.with_index(levels, fn level, level_idx ->
      case Enum.find_index(level, &(&1 == step_id)) do
        nil -> nil
        row_idx -> {level_idx, row_idx}
      end
    end)
    |> Enum.find(& &1)
    |> case do
      nil ->
        {0, 0}

      {level_idx, row_idx} ->
        {node_x(level_idx), node_y(row_idx)}
    end
  end

  defp node_x(level_idx), do: level_idx * (@node_w + @gap_x) + @gap_x
  defp node_y(row_idx), do: row_idx * (@node_h + @gap_y) + @gap_y

  @doc false
  def graph_edges(edges, levels, passed_step_ids \\ MapSet.new()) do
    # `edges` come from `dependency_edges(step_ids, :step)` as
    # `{dependent_id, prereq_id}` (a step depends_on its prereq). The arrow
    # flows prereq → dependent: the prereq is the source/output, the
    # dependent the target/input. An edge is "done" (solid/success) when
    # the selected session has a PASSED run of the prereq step.
    Enum.map(edges, fn {dependent_id, prereq_id} ->
      {px, py} = node_position(levels, prereq_id)
      {dx, dy} = node_position(levels, dependent_id)

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
  def graph_ports(edges, levels) do
    Enum.reduce(edges, %{}, fn {_dep_id, e}, acc ->
      {px, py} = node_position(levels, e.prereq_id)
      {dx, dy} = node_position(levels, e.dependent_id)

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
  def graph_tasks(levels, steps) do
    steps_by_id = Map.new(steps, &{&1.id, &1})

    nodes =
      Enum.flat_map(levels, fn level ->
        Enum.map(level, fn step_id ->
          step = Map.get(steps_by_id, step_id)
          {x, y} = node_position(levels, step_id)
          {step, x, y}
        end)
      end)
      |> Enum.reject(fn {step, _, _} -> is_nil(step) end)

    {nodes, steps_by_id}
  end
end
