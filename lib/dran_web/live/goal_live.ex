defmodule DranWeb.GoalLive do
  @moduledoc "LiveView for goal pages: index list + detail view with sub-page tabs."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @page_type "goal"

  @kanban_columns [
    {"backlog", "Backlog", "bg-base-300"},
    {"this_week", "This Week", "bg-blue-500/20 text-blue-700"},
    {"today", "Today", "bg-amber-500/20 text-amber-700"},
    {"in_progress", "In Progress", "bg-purple-500/20 text-purple-700"},
    {"done", "Done", "bg-green-500/20 text-green-700"},
    {"cancelled", "Cancelled", "bg-red-500/20 text-red-700"}
  ]

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
    >
      <div :if={@live_action == :show}>
        <.page_detail
          page={@page}
          relations={@relations}
          versions={@versions}
          logs={@logs}
          context_slug={@context_slug}
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
                <.form
                  for={@form}
                  id="page-edit-form"
                  phx-change="validate_page"
                  phx-submit="save_page"
                >
                  <div class="space-y-5">
                    <.input
                      field={@form[:title]}
                      type="text"
                      label="Title"
                      placeholder="Enter a title…"
                      class="text-lg font-medium"
                    />
                    <div class="grid grid-cols-2 gap-4">
                      <.input
                        field={@form[:slug]}
                        type="text"
                        label="Slug"
                        placeholder="slug"
                        class="w-full font-mono text-sm"
                      />
                      <.input
                        field={@form[:summary]}
                        type="text"
                        label="Summary"
                        placeholder="One-line description"
                        class="w-full text-sm"
                      />
                    </div>
                    <.input
                      field={@form[:tags]}
                      type="text"
                      label="Tags"
                      placeholder="comma, separated, tags"
                      class="w-full text-sm"
                    />
                    <.meta_fields page_type={@page_type} meta={@page.meta || %{}} />
                    <.markdown_editor
                      id="goal-editor"
                      body={@page.body}
                      context_id={@context_id}
                      save_status={@save_status}
                    />
                    <div class="flex justify-end gap-2 pt-2 border-t border-base-300">
                      <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
                      <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    </div>
                  </div>
                </.form>
              <% else %>
                <div class="prose prose-base dark:prose-invert max-w-none">
                  {render_markdown(@page.body,
                    context_id: @page.context_id,
                    inline_links: Map.get(@page.meta || %{}, "inline_links", [])
                  )}
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

            <div :if={@active_tab == "todos"}>
              <div
                class="flex gap-4 overflow-x-auto pb-4"
                phx-hook=".GoalKanban"
                id={"goal-kanban-#{@page.slug}"}
              >
                <div
                  :for={{status, label, badge_class} <- @kanban_columns}
                  data-kanban-status={status}
                  class="w-64 shrink-0 flex flex-col rounded-lg bg-base-200/40 border border-base-300"
                >
                  <div class="flex items-center justify-between px-3 py-2 border-b border-base-300">
                    <span class="text-sm font-semibold">{label}</span>
                    <span class={"px-2 py-0.5 text-xs rounded-full " <> badge_class}>
                      {goal_column_count(@goal_todos, status)}
                    </span>
                  </div>
                  <div class="p-2 space-y-2 min-h-[120px] flex-1 overflow-y-auto">
                    <div
                      :for={todo <- goal_column_items(@goal_todos, status)}
                      data-kanban-slug={todo.slug}
                      draggable="true"
                      phx-click="show_page"
                      phx-value-slug={todo.slug}
                      class="p-3 rounded-lg bg-base-100 border border-base-300 shadow-sm cursor-grab hover:shadow-md hover:border-primary/40 active:cursor-grabbing transition"
                    >
                      <div class="font-medium text-sm break-words">{todo.title}</div>
                      <div class="flex flex-wrap items-center gap-1.5 mt-2">
                        <span class={"px-1.5 py-0.5 text-[11px] rounded " <> goal_priority_class(todo)}>
                          {goal_priority_label(todo)}
                        </span>
                      </div>
                      <div :if={goal_due_date(todo)} class={goal_due_date_class(goal_overdue?(todo))}>
                        <.icon name="hero-calendar-days" class="size-3.5" /> {goal_format_due(
                          goal_due_date(todo)
                        )}
                      </div>
                    </div>
                    <p
                      :if={goal_column_items(@goal_todos, status) == []}
                      class="text-xs text-base-content/30 text-center py-4"
                    >
                      Empty
                    </p>
                  </div>
                </div>
              </div>
              <p :if={@goal_todos == []} class="text-sm text-base-content/40 mt-4">
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
        <.page_list pages={@pages} page_type={@page_type} context_slug={@context_slug} />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".GoalKanban">
        export default {
          mounted() {
            this.draggedSlug = null;
            const board = this.el;

            board.addEventListener("dragstart", (e) => {
              const card = e.target.closest("[data-kanban-slug]");
              if (card) {
                this.draggedSlug = card.dataset.kanbanSlug;
                e.dataTransfer.effectAllowed = "move";
              }
            });

            board.addEventListener("dragover", (e) => {
              if (e.target.closest("[data-kanban-status]")) {
                e.preventDefault();
                e.dataTransfer.dropEffect = "move";
              }
            });

            board.addEventListener("drop", (e) => {
              const col = e.target.closest("[data-kanban-status]");
              if (col !== null && this.draggedSlug !== null) {
                e.preventDefault();
                this.pushEvent("move_todo", {
                  slug: this.draggedSlug,
                  target_status: col.dataset.kanbanStatus
                });
              }
              this.draggedSlug = null;
            });

            board.addEventListener("dragend", () => {
              this.draggedSlug = null;
            });
          }
        }
      </script>
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
       kanban_columns: @kanban_columns,
       active_tab: "overview",
       editing: false,
       save_status: "idle"
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

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
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
             graph_edges: graph_edges
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/goals")}
    end
  end

  def handle_params(_params, _url, socket) do
    pages =
      if socket.assigns.context do
        Brain.list_pages(context_id: socket.assigns.context.id, type: @page_type)
      else
        []
      end

    {:noreply, assign(socket, pages: pages, page_title: "Goals")}
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

  def handle_event("move_todo", %{"slug" => slug, "target_status" => status}, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Todo not found.")}

        todo ->
          new_meta = Map.put(todo.meta || %{}, "kanban_status", status)

          case Brain.update_page(todo, %{"meta" => new_meta}) do
            {:ok, _updated} ->
              goal_slug = socket.assigns.page.slug

              goal_todos =
                Brain.list_pages(
                  context_id: context.id,
                  type: "todo",
                  limit: 500,
                  include_body: false
                )
                |> Enum.filter(fn p -> meta_get(p.meta, "goal_slug") == goal_slug end)

              {:noreply, assign(socket, goal_todos: goal_todos)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Could not update todo status.")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_page", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/goals/new")}
  end

  def handle_event("toggle_edit", p, s), do: PageEdit.handle_event("toggle_edit", p, s)
  def handle_event("cancel_edit", p, s), do: PageEdit.handle_event("cancel_edit", p, s)
  def handle_event("validate_page", p, s), do: PageEdit.handle_event("validate_page", p, s)
  def handle_event("save_page", p, s), do: PageEdit.handle_event("save_page", p, s)
  def handle_event("body_change", p, s), do: PageEdit.handle_event("body_change", p, s)
  def handle_event("field_change", p, s), do: PageEdit.handle_event("field_change", p, s)
  def handle_event("request_upload", p, s), do: PageEdit.handle_event("request_upload", p, s)
  def handle_event("upload_complete", p, s), do: PageEdit.handle_event("upload_complete", p, s)

  defp handle_progress(:file, _entry, socket), do: {:noreply, socket}

  # ── Helpers ──

  # nil-safe access into a page's `meta` map (string keys, as persisted in JSONB).
  defp meta_get(meta, key), do: get_in(meta, [key])

  # ── Kanban helpers ──

  defp goal_kanban_status(page) do
    case meta_get(page.meta, "kanban_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  defp goal_column_items(todos, status) do
    Enum.filter(todos, fn t -> goal_kanban_status(t) == status end)
  end

  defp goal_column_count(todos, status) do
    Enum.count(todos, fn t -> goal_kanban_status(t) == status end)
  end

  defp goal_priority(page) do
    case meta_get(page.meta, "priority") do
      s when is_binary(s) and s != "" -> s
      _ -> "medium"
    end
  end

  defp goal_priority_label(page) do
    case goal_priority(page) do
      "urgent" -> "Urgent"
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      other -> other |> to_string() |> String.capitalize()
    end
  end

  defp goal_priority_class(page) do
    case goal_priority(page) do
      "urgent" -> "bg-red-100 text-red-700"
      "high" -> "bg-orange-100 text-orange-700"
      "medium" -> "bg-blue-100 text-blue-700"
      "low" -> "bg-gray-100 text-gray-600"
      _ -> "bg-gray-100 text-gray-600"
    end
  end

  defp goal_due_date(page), do: meta_get(page.meta, "due_date")

  defp goal_overdue?(page) do
    case goal_due_date(page) do
      s when is_binary(s) and s != "" ->
        case Date.from_iso8601(s) do
          {:ok, d} -> Date.compare(d, Date.utc_today()) == :lt
          _ -> false
        end

      _ ->
        false
    end
  end

  defp goal_format_due(nil), do: ""
  defp goal_format_due(""), do: ""

  defp goal_format_due(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> Calendar.strftime(d, "%b %d")
      _ -> s
    end
  end

  defp goal_due_date_class(true),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-red-600 font-medium"

  defp goal_due_date_class(false),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-base-content/60"
end
