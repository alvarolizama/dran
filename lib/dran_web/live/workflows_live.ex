defmodule DranWeb.WorkflowsLive do
  @moduledoc """
  Workflows — goal-level execution view.

  Index (`/workflows`): three tabs.
  - Resumen: one card per goal that has at least one contract task
    (contracts count, running, ready, stale).
  - En ejecución: live list of in_progress contract tasks.
  - Cola: contract tasks that are ready (deps satisfied) — the pull queue.

  Show (`/workflows/:goal_slug`): the DAG of the goal's tasks laid out in
  topological columns (`Dran.Contracts.levels/1`) plus the
  Sigue / En ejecución / Bloqueadas panels.
  """

  use DranWeb, :live_view

  alias Dran.{Contracts, Goals, Task, Tasks}

  defp list_all_tasks(workspace_id), do: Tasks.list_tasks(workspace_id: workspace_id)

  @tabs ~w(resumen ejecucion cola)

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
          Phoenix.PubSub.subscribe(Dran.PubSub, "workspace:#{context.id}")
          Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
        end

        {:ok,
         socket
         |> assign(
           context: context,
           active_nav: "workflows",
           tab: "resumen",
           goal: nil,
           tasks: []
         )}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = assign(socket, params: params)

    socket =
      case socket.assigns.live_action do
        :index -> apply_index(socket, socket.assigns.context, params)
        :show -> apply_show(socket, socket.assigns.context, params)
      end

    {:noreply, socket}
  end

  defp apply_index(socket, nil, _params), do: socket

  defp apply_index(socket, context, params) do
    tab =
      case params["tab"] do
        t when t in @tabs -> t
        _ -> "resumen"
      end

    goal_filter =
      case params["goal"] do
        g when is_binary(g) and g != "" -> g
        _ -> nil
      end

    socket
    |> assign(goal_filter: goal_filter, page_title: gettext("Workflows"))
    |> load_index(context)
    |> assign(tab: tab)
  end

  defp apply_show(socket, nil, _params), do: socket

  defp apply_show(socket, context, %{"slug" => slug} = params) do
    case Goals.get_goal_by_slug(slug, context.id) do
      nil ->
        socket
        |> assign(page_title: gettext("Workflows"))
        |> push_patch(to: ~p"/#{socket.assigns[:workspace_slug]}/workflows")

      goal ->
        socket
        |> assign(goal: goal, page_title: goal.title)
        |> load_show(goal)
        |> open_contract_modal(params["contract"])
    end
  end

  # ── Loaders ───────────────────────────────────────────────────────────────

  defp load_index(socket, context) do
    all = list_all_tasks(context.id)
    dep_info = Contracts.dependency_states(Enum.map(all, & &1.id))

    workflows = workflow_summaries(context.id, dep_info)

    running =
      all
      |> Enum.filter(&(&1.status == "in_progress" and Contracts.contract?(&1)))
      |> preload_actors()
      |> add_goal_badge(context.id)

    queue =
      all
      |> Enum.filter(fn t ->
        t.status == "todo" and Contracts.contract?(t) and dep_info[t.id][:ready]
      end)
      |> preload_actors()
      |> add_goal_badge(context.id)

    # Roll-up set computed once — descendants of the selected goal (same
    # semantics as the board's goal filter).
    visible_goal_ids = visible_goal_ids(socket.assigns[:goal_filter], context.id)

    assign(socket,
      workflows: workflows,
      running: filter_by_goal(running, visible_goal_ids),
      queue: filter_by_goal(queue, visible_goal_ids),
      goal_options: Goals.flattened_tree(context.id),
      dep_info: dep_info,
      page_title: gettext("Workflows")
    )
  end

  defp load_show(socket, goal) do
    tasks = Tasks.list_tasks_for_goal(goal)
    contract_tasks = Enum.filter(tasks, &Contracts.contract?/1)
    task_ids = Enum.map(tasks, & &1.id)
    goals_by_task = Tasks.list_linked_goals_by_ids(task_ids, goal.workspace_id)

    levels = Contracts.levels(tasks)

    # Batch dependency state — 2 queries for the whole goal, no per-task
    # queries in template panels.
    dep_info = Contracts.dependency_states(task_ids)

    # Graph edges for the SVG view — {source_id, target_id}.
    edges = Contracts.dependency_edges(task_ids)

    socket
    |> assign(
      tasks: tasks,
      contract_tasks: contract_tasks,
      goals_by_task: goals_by_task,
      levels: levels,
      dep_info: dep_info,
      edges: edges,
      modal_task: nil,
      modal_contract: nil,
      page_title: goal.title
    )
  end

  # ── Contract viewer modal ──────────────────────────────────────────────────
  # Click on a DAG card patches `?contract=<task_id>`; handle_params opens the
  # modal. Closing pops the param. Modal state is URL state — deep-linkable.

  @impl true
  def handle_event("show_contract", %{"task-id" => task_id}, socket) do
    ws = socket.assigns[:workspace_slug]

    {:noreply,
     push_patch(socket, to: ~p"/#{ws}/workflows/#{socket.assigns.goal.slug}?contract=#{task_id}")}
  end

  def handle_event("set_goal_filter", %{"goal" => goal_id}, socket) do
    tab = socket.assigns.tab
    ws = socket.assigns.context.slug

    patch =
      if goal_id in [nil, ""],
        do: ~p"/#{ws}/workflows?tab=#{tab}",
        else: ~p"/#{ws}/workflows?tab=#{tab}&goal=#{goal_id}"

    {:noreply, push_patch(socket, to: patch)}
  end

  def handle_event("close_contract", _params, socket) do
    ws = socket.assigns[:workspace_slug]
    {:noreply, push_patch(socket, to: ~p"/#{ws}/workflows/#{socket.assigns.goal.slug}")}
  end

  defp open_contract_modal(socket, task_id) when is_binary(task_id) do
    task = Enum.find(socket.assigns.tasks, &(&1.id == task_id))
    contract = if task, do: task.meta["contract"], else: nil
    assign(socket, modal_task: task, modal_contract: contract)
  end

  defp open_contract_modal(socket, _), do: assign(socket, modal_task: nil, modal_contract: nil)

  # ── Summary computation ───────────────────────────────────────────────────

  @doc false
  def workflow_summaries(workspace_id, dep_info \\ %{}) do
    # All non-archived tasks of the workspace with a contract (in-memory
    # filter over the jsonb meta — contract tasks are the minority).
    all =
      workspace_id
      |> list_all_tasks()
      |> Enum.filter(&Contracts.contract?/1)

    tasks_by_goal = group_tasks_by_goal(all, workspace_id)

    Enum.map(tasks_by_goal, fn {goal, tasks} ->
      %{
        goal: goal,
        total: length(tasks),
        running: length(Enum.filter(tasks, &(&1.status == "in_progress"))),
        ready:
          Enum.count(tasks, fn t ->
            case Map.get(dep_info, t.id) do
              %{ready: r} -> r
              nil -> true
            end
          end),
        drafts: length(Enum.filter(tasks, &(&1.meta["contract"]["status"] == "draft"))),
        stale: length(Enum.filter(tasks, &Contracts.stale?/1))
      }
    end)
    |> Enum.sort_by(fn %{goal: g} -> g.title end)
  end

  defp group_tasks_by_goal(tasks, workspace_id) do
    goals_by_task =
      tasks
      |> Enum.map(& &1.id)
      |> Tasks.list_linked_goals_by_ids(workspace_id)

    # Tasks with no linked goal fall into a synthetic bucket so they are
    # still visible in the summary ("Sin goal").
    by_goal =
      Enum.reduce(tasks, %{}, fn task, acc ->
        goal =
          case goals_by_task[task.id] do
            [%Dran.Goal{} = g | _] -> g
            _ -> nil
          end

        key = goal || :no_goal
        Map.update(acc, key, [task], &[task | &1])
      end)

    Enum.map(by_goal, fn
      {goal, ts} when is_struct(goal) -> {goal, ts}
      {:no_goal, ts} -> {%{title: gettext("Sin goal"), id: nil, health: nil}, ts}
    end)
  end

  defp add_goal_badge(tasks, workspace_id) do
    goals_by_task = Tasks.list_linked_goals_by_ids(Enum.map(tasks, & &1.id), workspace_id)

    Enum.map(tasks, fn task ->
      goal =
        case Map.get(goals_by_task, task.id, []) do
          [goal | _] -> Map.take(goal, [:id, :title, :slug])
          [] -> nil
        end

      task
      |> Map.put(:goal_badge, goal)
      |> Map.put(:goal_title, goal && goal.title)
    end)
  end

  # Goal filter for the "En ejecución" and "Cola" tabs. `visible_goal_ids` holds
  # the selected goal id PLUS all its descendants (roll-up, board semantics);
  # nil = no filter.
  defp filter_by_goal(tasks, nil), do: tasks

  defp filter_by_goal(tasks, %MapSet{} = visible_goal_ids) do
    Enum.filter(tasks, fn t ->
      case t.goal_badge do
        %{id: id} -> MapSet.member?(visible_goal_ids, to_string(id))
        _ -> false
      end
    end)
  end

  # Selected goal + ALL its descendants at any depth, as strings (option ids
  # and relation ids both come as strings). Cycle-safe via
  # `Goals.descendant_ids/2`; the goal itself is included by the caller.
  defp visible_goal_ids(nil, _workspace_id), do: nil

  defp visible_goal_ids(goal_id, workspace_id) do
    workspace_id
    |> Goals.flattened_tree()
    |> Enum.map(&elem(&1, 0))
    |> then(&Goals.descendant_ids(goal_id, &1))
    |> MapSet.new(&to_string/1)
    |> MapSet.put(to_string(goal_id))
  end

  defp preload_actors(tasks), do: Dran.Repo.preload(tasks, :assignee_actor)

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:task_changed, _action, _task}, socket) do
    reload(socket)
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload(socket) do
    if socket.assigns.context do
      socket =
        case socket.assigns.live_action do
          :index ->
            load_index(socket, socket.assigns.context)

          :show ->
            if socket.assigns.goal, do: load_show(socket, socket.assigns.goal), else: socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Helpers for the DAG view ──────────────────────────────────────────────

  @doc false
  def status_dot("done"), do: "bg-green-500"
  def status_dot("cancelled"), do: "bg-red-400"
  def status_dot("in_progress"), do: "bg-primary"
  def status_dot("todo"), do: "bg-sky-500"
  def status_dot(_), do: "bg-base-content/30"

  @doc false
  def edge_class(%{status: s}) when s in ~w(done cancelled), do: "border-success"
  def edge_class(_), do: "border-base-content/20 border-dashed"

  # ── Template helpers ──────────────────────────────────────────────────────

  defp tab_label("resumen"), do: gettext("Resumen")
  defp tab_label("ejecucion"), do: gettext("En ejecución")
  defp tab_label("cola"), do: gettext("Cola")

  defp contract_chip(%Task{meta: %{"contract" => %{"status" => "draft"}}}), do: "draft"

  defp contract_chip(%Task{meta: %{"contract" => %{"version" => v}}}) when is_integer(v),
    do: "v#{v}"

  defp contract_chip(%Task{meta: %{"contract" => %{"version" => v}}}) when is_binary(v),
    do: "v#{v}"

  defp contract_chip(_), do: nil

  defp blocked_label(%Task{id: id}, %{dep_info: dep_info}) do
    case Map.get(dep_info, id) do
      %{ready: true} -> nil
      %{blocked_count: n} -> gettext("espera %{count} dep(s)", count: n)
      nil -> nil
    end
  end

  defp ready_tasks(tasks, dep_info) do
    Enum.filter(tasks, fn t ->
      t.status == "todo" and match?(%{ready: true}, Map.get(dep_info, t.id))
    end)
  end

  defp running_tasks(tasks), do: Enum.filter(tasks, &(&1.status == "in_progress"))

  defp blocked_tasks(tasks, dep_info) do
    Enum.filter(tasks, fn t ->
      t.status == "todo" and match?(%{ready: false}, Map.get(dep_info, t.id))
    end)
  end

  # ── Graph layout (pure helpers for the SVG DAG) ─────────────────────────
  #
  # Levels → columns. Every task is positioned in a virtual grid:
  #   column = level index, row = index within the level.
  # Node cards are ~220px wide × ~92px tall with 28px gaps; the SVG is
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
  def node_position(levels, task_id) do
    Enum.with_index(levels, fn level, level_idx ->
      case Enum.find_index(level, &(&1 == task_id)) do
        nil -> nil
        row_idx -> {level_idx, row_idx}
      end
    end)
    |> Enum.find(& &1)
    |> case do
      nil ->
        {0, 0}

      {level_idx, row_idx} ->
        x = level_idx * (@node_w + @gap_x) + @gap_x
        y = row_idx * (@node_h + @gap_y) + @gap_y
        {x, y}
    end
  end

  @doc false
  def graph_edges(edges, levels, tasks_by_id) do
    # `edges` come from `dependency_edges/1` as `{dependent_id, prereq_id}`
    # (a task depends_on its prereq). For an execution DAG the arrow must flow
    # prereq → dependent, so we draw the edge with the prereq as source/output
    # and the dependent as target/input.
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

      prereq = Map.get(tasks_by_id, prereq_id)
      dependent = Map.get(tasks_by_id, dependent_id)

      done? =
        match?(%{status: s} when s in ~w(done cancelled), prereq) and
          (dependent == nil or dependent.status in ~w(done cancelled))

      {dependent_id,
       %{
         path: path,
         dependent_id: dependent_id,
         prereq_id: prereq_id,
         x1: x1,
         y1: y1,
         x2: x2,
         y2: y2,
         done: done?
       }}
    end)
  end

  @doc false
  def status_label(nil), do: ""

  def status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  One input port and one output port per card: `%{task_id => %{out: | in: %{x, y, done}}}`.
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
  def graph_tasks(levels, tasks) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})

    nodes =
      Enum.flat_map(levels, fn level ->
        Enum.map(level, fn task_id ->
          task = Map.get(tasks_by_id, task_id)
          {x, y} = node_position(levels, task_id)
          {task, x, y}
        end)
      end)
      |> Enum.reject(fn {task, _, _} -> is_nil(task) end)

    {nodes, tasks_by_id}
  end
end
