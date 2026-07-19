defmodule DranWeb.GoalLive do
  @moduledoc "LiveView for goal pages: index list + detail view with sub-page tabs."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @page_type "goal"

  @goal_tabs [
    {"overview", "Overview"},
    {"notes", "Notes"},
    {"concepts", "Concepts"},
    {"entities", "Entities"},
    {"todos", "Todos"},
    {"plans", "Plans"},
    {"artifacts", "Artifacts"},
    {"references", "References"},
    {"graph", "Graph"}
  ]

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div :if={@live_action == :show}>
        <.page_detail
          page={@page}
          relations={@relations}
          versions={@versions}
          compare_version={@compare_version}
          logs={@logs}
          context_slug={@context_slug}
          rendered_body={@rendered_body}
        >
          <:actions>
            <.link navigate={~p"/goals"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
            <button :if={not @editing} phx-click="toggle_edit" class="btn btn-primary btn-sm">
              <.icon name="hero-pencil" class="size-4" /> Edit
            </button>
            <button :if={@editing} phx-click="save_page" class="btn btn-success btn-sm">
              <.icon name="hero-check" class="size-4" /> Save
            </button>
            <button :if={@editing} phx-click="cancel_edit" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="size-4" /> Cancel
            </button>
          </:actions>

          <:tabs>
            <div class="border-b border-base-300 mb-4">
              <div class="flex gap-1">
                <button
                  :for={{tab, label} <- @goal_tabs}
                  phx-click="switch_tab"
                  phx-value-tab={tab}
                  class={
                    "px-3 py-2 text-sm font-medium border-b-2 " <>
                      if @active_tab == tab,
                        do: "border-primary text-primary",
                        else:
                          "border-transparent text-base-content/60 hover:text-base-content"
                  }
                >
                  {label}
                </button>
              </div>
            </div>

            <div :if={@active_tab == "overview"}>
              <%= if @editing do %>
                <.page_edit_form
                  form={@form}
                  page={@page}
                  page_type={@page_type}
                  context_id={@context_id}
                  save_status={@save_status}
                  editor_id="goal-editor"
                />
              <% else %>
                <%!-- Panel de metricas del goal --%>
                <div class="grid grid-cols-3 gap-4 mb-4 p-4 rounded-lg bg-base-200/50 border border-base-300">
                  <div>
                    <div class="text-xs text-base-content/60 uppercase">Metric</div>
                    <div class="font-medium">{meta_get(@page.meta, "metric") || "—"}</div>
                  </div>
                  <div>
                    <div class="text-xs text-base-content/60 uppercase">Current / Target</div>
                    <div class="font-medium">
                      {format_value(meta_get(@page.meta, "current_value"))} / {format_value(
                        meta_get(@page.meta, "target_value")
                      )}
                      <span class="text-xs text-base-content/60">{meta_get(@page.meta, "unit")}</span>
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-base-content/60 uppercase">Progress</div>
                    <div class="flex items-center gap-2">
                      <div class="flex-1 bg-base-300 rounded-full h-2 overflow-hidden">
                        <div class="bg-primary h-full" style={"width: #{progress_percent(@page)}%"}>
                        </div>
                      </div>
                      <span class="text-sm font-medium">{progress_percent(@page)}%</span>
                    </div>
                  </div>
                </div>
                <div class="prose prose-base dark:prose-invert max-w-none">
                  {@rendered_body}
                </div>
              <% end %>
            </div>

            <div :if={@active_tab == "notes"}>
              <div :for={note <- @goal_notes} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(note)}
                    class="font-medium text-primary hover:underline"
                  >
                    {note.title}
                  </.link>
                </div>
                <div :if={note.summary} class="text-xs text-base-content/60 mt-1">
                  {note.summary}
                </div>
              </div>
              <p :if={@goal_notes == []} class="text-sm text-base-content/40">
                No notes linked to this goal.
              </p>
            </div>

            <div :if={@active_tab == "concepts"}>
              <div :for={concept <- @goal_concepts} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(concept)}
                    class="font-medium text-primary hover:underline"
                  >
                    {concept.title}
                  </.link>
                </div>
                <div :if={concept.summary} class="text-xs text-base-content/60 mt-1">
                  {concept.summary}
                </div>
              </div>
              <p :if={@goal_concepts == []} class="text-sm text-base-content/40">
                No concepts linked to this goal.
              </p>
            </div>

            <div :if={@active_tab == "entities"}>
              <div :for={entity <- @goal_entities} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(entity)}
                    class="font-medium text-primary hover:underline"
                  >
                    {entity.title}
                  </.link>
                </div>
                <div :if={entity.summary} class="text-xs text-base-content/60 mt-1">
                  {entity.summary}
                </div>
              </div>
              <p :if={@goal_entities == []} class="text-sm text-base-content/40">
                No entities linked to this goal.
              </p>
            </div>

            <%!-- Todos: lista simple con link a kanban global --%>
            <div :if={@active_tab == "todos"}>
              <div class="flex items-center justify-between mb-3">
                <span class="text-sm text-base-content/60">{length(@goal_todos)} todos linked</span>
                <.link navigate={~p"/kanban?goal=#{@page.slug}"} class="btn btn-ghost btn-xs">
                  Open in Kanban →
                </.link>
              </div>
              <div :for={todo <- @goal_todos} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(todo)}
                    class="font-medium text-primary hover:underline"
                  >
                    {todo.title}
                  </.link>
                  <span class={"px-2 py-0.5 text-xs rounded " <> kanban_status_class(todo)}>
                    {String.capitalize(kanban_status(todo))}
                  </span>
                </div>
                <div :if={todo.summary} class="text-xs text-base-content/60 mt-1">{todo.summary}</div>
              </div>
              <p :if={@goal_todos == []} class="text-sm text-base-content/40">
                No todos linked to this goal.
              </p>
            </div>

            <div :if={@active_tab == "plans"}>
              <div :for={plan <- @goal_plans} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(plan)}
                    class="font-medium text-primary hover:underline"
                  >
                    {plan.title}
                  </.link>
                  <span class="px-2 py-0.5 text-xs rounded bg-base-300 text-base-content/70">
                    {meta_get(plan.meta, "horizon")}
                  </span>
                </div>
                <div :if={meta_get(plan.meta, "status")} class="text-xs text-base-content/60 mt-1">
                  Status: {meta_get(plan.meta, "status")}
                </div>
              </div>
              <p :if={@goal_plans == []} class="text-sm text-base-content/40">
                No plans linked to this goal.
              </p>
            </div>

            <div :if={@active_tab == "artifacts"}>
              <div
                :for={artifact <- @goal_artifacts}
                class="p-3 rounded-lg border border-base-300 mb-2"
              >
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(artifact)}
                    class="font-medium text-primary hover:underline"
                  >
                    {artifact.title}
                  </.link>
                  <span class="px-2 py-0.5 text-xs rounded bg-base-300 text-base-content/70">
                    {meta_get(artifact.meta, "kind")}
                  </span>
                </div>
                <div
                  :if={meta_get(artifact.meta, "filename")}
                  class="text-xs text-base-content/60 mt-1"
                >
                  {meta_get(artifact.meta, "filename")}
                </div>
              </div>
              <p :if={@goal_artifacts == []} class="text-sm text-base-content/40">
                No artifacts linked to this goal.
              </p>
            </div>

            <div :if={@active_tab == "references"}>
              <div
                :for={reference <- @goal_references}
                class="p-3 rounded-lg border border-base-300 mb-2"
              >
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(reference)}
                    class="font-medium text-primary hover:underline"
                  >
                    {reference.title}
                  </.link>
                  <span class="px-2 py-0.5 text-xs rounded bg-base-300 text-base-content/70">
                    {meta_get(reference.meta, "kind")}
                  </span>
                </div>
                <div
                  :if={meta_get(reference.meta, "source_url")}
                  class="text-xs text-base-content/60 mt-1"
                >
                  <a
                    href={meta_get(reference.meta, "source_url")}
                    class="text-primary hover:underline"
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    {meta_get(reference.meta, "source_url")}
                  </a>
                </div>
              </div>
              <p :if={@goal_references == []} class="text-sm text-base-content/40">
                No references linked to this goal.
              </p>
            </div>

            <div :if={@active_tab == "graph"}>
              <.page_graph id="goal-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
            </div>
          </:tabs>
        </.page_detail>
      </div><div :if={@live_action != :show}>
        <.page_list
          pages={@pages}
          archived_pages={@archived_pages}
          archived_filter={@archived_filter}
          page_type={@page_type}
          context_slug={@context_slug}
        />
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      if context do
        allow_upload(
          socket,
          :file,
          accept:
            ~w(image/* video/* audio/* application/pdf text/plain text/markdown text/csv text/html application/json application/zip),
          max_file_size: Dran.Uploads.max_size(),
          auto_upload: true,
          progress: &handle_progress/3
        )
      else
        socket
      end

    {:ok,
     assign(socket,
       context: context,
       page_type: @page_type,
       goal_tabs: @goal_tabs,
       active_tab: "overview",
       editing: false,
       save_status: "idle",
       active_nav: "goals"
     )}
  end

  def handle_params(%{"slug" => slug} = _params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/goals")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)

          goal_todos =
            Brain.list_pages(
              context_id: context.id,
              type: "todo",
              include_body: false,
              limit: 500
            )
            |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == page.slug end)

          goal_notes =
            Brain.list_pages(
              context_id: context.id,
              type: "note",
              include_body: false,
              limit: 500
            )
            |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == page.slug end)

          goal_concepts =
            Brain.list_pages(
              context_id: context.id,
              type: "concept",
              include_body: false,
              limit: 500
            )
            |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == page.slug end)

          goal_entities =
            Brain.list_pages(
              context_id: context.id,
              type: "entity",
              include_body: false,
              limit: 500
            )
            |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == page.slug end)

          goal_plans =
            Brain.list_pages(
              context_id: context.id,
              type: "plan",
              include_body: false,
              limit: 500
            )
            |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == page.slug end)

          goal_artifacts =
            Brain.list_pages(
              context_id: context.id,
              type: "artifact",
              include_body: false,
              limit: 500
            )
            |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == page.slug end)

          goal_references =
            Brain.list_pages(
              context_id: context.id,
              type: "reference",
              include_body: false,
              limit: 500
            )
            |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == page.slug end)

          rendered_body =
            render_markdown(page.body,
              context_id: page.context_id,
              inline_links: Map.get(page.meta || %{}, "inline_links", [])
            )

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             compare_version: nil,
             logs: logs,
             page_title: page.title,
             active_tab: "overview",
             goal_todos: goal_todos,
             goal_notes: goal_notes,
             goal_concepts: goal_concepts,
             goal_entities: goal_entities,
             goal_plans: goal_plans,
             goal_artifacts: goal_artifacts,
             goal_references: goal_references,
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/goals")}
    end
  end

  def handle_params(_params, _url, socket) do
    {pages, archived_pages} =
      if socket.assigns.context do
        {Brain.list_pages(context_id: socket.assigns.context.id, type: @page_type),
         Brain.list_pages(
           context_id: socket.assigns.context.id,
           type: @page_type,
           archived: true,
           limit: 200
         )}
      else
        {[], []}
      end

    {:noreply,
     assign(socket,
       pages: pages,
       archived_pages: archived_pages,
       archived_filter: "all",
       page_title: "Goals"
     )}
  end

  def handle_event("filter_archived", %{"type" => type}, socket) do
    {:noreply, assign(socket, archived_filter: type)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("node_click", %{"slug" => slug}, socket) do
    {:noreply, node_click(socket, slug)}
  end

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket) do
    {:noreply, node_drag(socket, id, x, y)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/todos/#{slug}")}
  end

  def handle_event("new_page", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/goals/new")}
  end

  def handle_event("archive_page", p, s), do: PageEdit.handle_event("archive_page", p, s)
  def handle_event("unarchive_page", p, s), do: PageEdit.handle_event("unarchive_page", p, s)
  def handle_event("toggle_edit", p, s), do: PageEdit.handle_event("toggle_edit", p, s)
  def handle_event("cancel_edit", p, s), do: PageEdit.handle_event("cancel_edit", p, s)
  def handle_event("validate_page", p, s), do: PageEdit.handle_event("validate_page", p, s)
  def handle_event("save_page", p, s), do: PageEdit.handle_event("save_page", p, s)
  def handle_event("body_change", p, s), do: PageEdit.handle_event("body_change", p, s)
  def handle_event("field_change", p, s), do: PageEdit.handle_event("field_change", p, s)
  def handle_event("request_upload", p, s), do: PageEdit.handle_event("request_upload", p, s)
  def handle_event("upload_complete", p, s), do: PageEdit.handle_event("upload_complete", p, s)

  # ── Version comparison ──

  def handle_event("compare_version", params, socket),
    do: DranWeb.VersionCompare.handle_event("compare_version", params, socket)

  def handle_event("clear_compare", params, socket),
    do: DranWeb.VersionCompare.handle_event("clear_compare", params, socket)

  defp handle_progress(:file, _entry, socket), do: {:noreply, socket}

  # ── Helpers ──

  # nil-safe access into a page's `meta` map (string keys, as persisted in JSONB).
  defp meta_get(meta, key), do: get_in(meta, [key])

  # ── Goal metric helpers (§6.3) ──

  defp progress_percent(page) do
    case meta_get(page.meta, "progress") do
      nil ->
        # Derive from current/target if no explicit progress.
        case {meta_get(page.meta, "current_value"), meta_get(page.meta, "target_value")} do
          {nil, _} ->
            0

          {_, nil} ->
            0

          {cur, tgt} when is_number(cur) and is_number(tgt) and tgt != 0 ->
            round(cur / tgt * 100) |> max(0) |> min(100)

          _ ->
            0
        end

      v when is_number(v) ->
        # Treat as percentage if > 1, else as fraction in [0, 1].
        if v > 1, do: round(v) |> max(0) |> min(100), else: round(v * 100) |> max(0) |> min(100)

      v when is_binary(v) ->
        case Float.parse(v) do
          {f, _} when f > 1 -> round(f) |> max(0) |> min(100)
          {f, _} -> round(f * 100) |> max(0) |> min(100)
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp format_value(nil), do: "—"
  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp format_value(v), do: to_string(v)

  # ── Kanban status helpers (for the simple Todos list) ──

  defp kanban_status(page) do
    case meta_get(page.meta, "kanban_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  defp kanban_status_class(page) do
    case kanban_status(page) do
      "this_week" -> "bg-blue-100 text-blue-700"
      "today" -> "bg-amber-100 text-amber-700"
      "in_progress" -> "bg-purple-100 text-purple-700"
      "done" -> "bg-green-100 text-green-700"
      "cancelled" -> "bg-red-100 text-red-700"
      _ -> "bg-base-300 text-base-content/70"
    end
  end
end
