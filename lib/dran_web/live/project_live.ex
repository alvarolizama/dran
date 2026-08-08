defmodule DranWeb.ProjectLive do
  @moduledoc """
  LiveView for project pages: index list + detail view with sub-page tabs.

  Tabs: Overview (project dashboard — status, stat cards, linked items),
  Goals, Plans, Todos, Graph, Related.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.ListPagination
  alias DranWeb.Plugs.Auth

  @page_type "project"

  alias DranWeb.DisabledTypes

  @project_tabs [
    {"goals", gettext("Objetivos")},
    {"plans", gettext("Planes")},
    {"todos", gettext("Tareas")}
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
          content_hidden={@active_tab != "overview"}
          active_tab={@active_tab}
          editing={@editing}
        >
          <:actions>
            <.link navigate={~p"/graph/#{@page.slug}"} class="btn btn-ghost btn-sm">
              <.icon name="hero-share" class="size-4" /> {gettext("Graph")}
            </.link>
            <.link navigate={~p"/projects"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
            <.link navigate={~p"/kanban?project=#{@page.slug}"} class="btn btn-ghost btn-sm">
              <.icon name="hero-view-columns" class="size-4" /> View in Kanban
            </.link>
          </:actions>

          <:attributes>
            <.page_attributes
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              editor_id="project-editor"
            />
          </:attributes>

          <:extra_tabs>
            <button
              :for={{tab, label} <- @project_tabs}
              phx-click="switch_tab"
              phx-value-tab={tab}
              class={[
                "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
                @active_tab == tab && "border-primary text-primary",
                @active_tab != tab &&
                  "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
              ]}
            >
              {label}
            </button>
          </:extra_tabs>

          <:insights>
            <div class="space-y-4">
              <div :if={@community_summary} class="surface-2 rounded-lg p-4">
                <h3 class="text-sm font-semibold mb-2">{gettext("Community Context")}</h3>
                <p class="text-sm text-base-content/70">{@community_summary.summary}</p>
                <p class="text-xs text-base-content/40 mt-1">
                  {gettext("Community")} #{@community_summary.community_id} · {@community_summary.page_count} {gettext(
                    "pages"
                  )}
                </p>
              </div>
              <div
                :if={!@community_summary}
                class="text-sm text-base-content/40 text-center py-8"
              >
                {gettext("No community data yet. Run community summaries first.")}
              </div>
            </div>
          </:insights>

          <:tabs>
            <%!-- Overview: dashboard del proyecto — status, stats, relacionados --%>
            <div :if={@active_tab == "overview"}>
              <.page_edit_form
                form={@form}
                page={@page}
                page_type={@page_type}
                context_id={@context_id}
                save_status={@save_status}
                editor_id="project-editor"
              />
            </div>
          </:tabs>

          <:extra_content>
            <%!-- Todos: lista plana de todos los todos del project --%>
            <div :if={@active_tab == "todos"}>
              <div class="text-sm text-base-content/60 mb-3">
                {length(@project_todos)} todos linked
              </div>
              <div :for={todo <- @project_todos} class="p-3 rounded-lg border border-base-300 mb-2">
                <.link
                  navigate={PageTypes.page_show_path(todo)}
                  class="font-medium text-primary hover:underline"
                >
                  {todo.title}
                </.link>
                <div :if={todo.summary} class="text-xs text-base-content/60 mt-1">
                  {todo.summary}
                </div>
              </div>
              <p :if={@project_todos == []} class="text-sm text-base-content/40">
                No todos linked to this project.
              </p>
            </div>

            <%!-- Goals: lista con health badge --%>
            <div :if={@active_tab == "goals"}>
              <div :for={goal <- @project_goals} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(goal)}
                    class="font-medium text-primary hover:underline"
                  >
                    {goal.title}
                  </.link>
                  <span class={"px-2 py-0.5 text-xs rounded " <> health_class(goal)}>
                    {String.capitalize(meta_get(goal.meta, "health") || "—")}
                  </span>
                </div>
                <div :if={goal.summary} class="text-xs text-base-content/60 mt-1">
                  {goal.summary}
                </div>
              </div>
              <p :if={@project_goals == []} class="text-sm text-base-content/40">
                No goals linked to this project.
              </p>
            </div>

            <%!-- Plans: lista con status + horizon + due_date --%>
            <div :if={@active_tab == "plans"}>
              <div :for={plan <- @project_plans} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(plan)}
                    class="font-medium text-primary hover:underline"
                  >
                    {plan.title}
                  </.link>
                  <span class="px-2 py-0.5 text-xs rounded bg-base-300 text-base-content/70">
                    {String.capitalize(meta_get(plan.meta, "status") || "draft")}
                  </span>
                </div>
                <div class="text-xs text-base-content/60 mt-1 flex gap-3">
                  <span :if={meta_get(plan.meta, "horizon")}>
                    {String.capitalize(meta_get(plan.meta, "horizon"))}
                  </span>
                  <span :if={meta_get(plan.meta, "period")}>
                    {meta_get(plan.meta, "period")}
                  </span>
                  <span :if={meta_get(plan.meta, "due_date")}>
                    Due: {meta_get(plan.meta, "due_date")}
                  </span>
                </div>
              </div>
              <p :if={@project_plans == []} class="text-sm text-base-content/40">
                No plans linked to this project.
              </p>
            </div>
          </:extra_content>
        </.page_detail>
      </div>

      <div :if={@live_action != :show}>
        <.page_list
          pages={Enum.take(@pages, @visible_count)}
          archived_pages={
            if @show_archived, do: Enum.take(@archived_pages, @archived_visible_count), else: []
          }
          archived_filter={@archived_filter}
          page_type={@page_type}
          context_slug={@context_slug}
          show_archived={@show_archived}
          total_count={length(@pages)}
          total_archived={length(@archived_pages)}
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
       project_tabs: DisabledTypes.visible_tabs(@project_tabs, context),
       active_tab: "overview",
       editing: true,
       save_status: "idle",
       community_summary: nil,
       active_nav: "projects"
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    {socket, context} = Auth.resolve_context(socket, params)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/projects")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)

          form = Brain.change_page(page) |> to_form(as: :page)

          # Preserve active_tab across patch (e.g. when toggling edit mode)
          active_tab = Map.get(socket.assigns, :active_tab, "overview")

          # Sub-páginas vinculadas por meta["project_slug"] == page.slug.
          # Para todos/goals/plans usamos el filter SQL nativo de Brain.list_pages.
          project_todos =
            Brain.list_pages(
              context_id: context.id,
              type: "todo",
              project_slug: page.slug,
              include_body: false,
              limit: 500
            )

          project_goals =
            Brain.list_pages(
              context_id: context.id,
              type: "goal",
              project_slug: page.slug,
              include_body: false,
              limit: 500
            )

          project_plans =
            Brain.list_pages(
              context_id: context.id,
              type: "plan",
              project_slug: page.slug,
              include_body: false,
              limit: 500
            )

          # Para notes/concepts/entities/references cargamos por type y filtramos
          # en memoria por meta["project_slug"] (mismo patrón que goal_live.ex).
          project_notes = filter_by_project_slug(context.id, "note", page.slug)
          project_concepts = filter_by_project_slug(context.id, "concept", page.slug)
          project_entities = filter_by_project_slug(context.id, "entity", page.slug)
          project_references = filter_by_project_slug(context.id, "reference", page.slug)

          rendered_body =
            render_markdown(page.body,
              context_id: page.context_id,
              inline_links: Map.get(page.meta || %{}, "inline_links", [])
            )

          community_summary =
            try do
              case Dran.Graph.CommunitySummaries.get_summary_for_page(page.id) do
                {:ok, summary} -> summary
                _ -> nil
              end
            rescue
              _ -> nil
            end

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             compare_version: nil,
             logs: logs,
             page_title: page.title,
             active_tab: active_tab,
             context_id: context.id,
             community_summary: community_summary,
             project_todos: project_todos,
             project_goals: project_goals,
             project_plans: project_plans,
             project_notes: project_notes,
             project_concepts: project_concepts,
             project_entities: project_entities,
             project_references: project_references,
             rendered_body: rendered_body,
             editing: true,
             form: form,
             context: context,
             project_tabs: DisabledTypes.visible_tabs(@project_tabs, context),
             save_status: "idle"
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/projects")}
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
       visible_count: 30,
       show_archived: false,
       archived_visible_count: 30,
       page_title: "Projects"
     )}
  end

  def handle_event("filter_archived", %{"type" => type}, socket) do
    {:noreply, assign(socket, archived_filter: type)}
  end

  def handle_event("load_more", _params, socket),
    do: {:noreply, ListPagination.handle_load_more(socket)}

  def handle_event("toggle_archived", _params, socket),
    do: {:noreply, ListPagination.handle_toggle_archived(socket)}

  def handle_event("load_more_archived", _params, socket),
    do: {:noreply, ListPagination.handle_load_more_archived(socket)}

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects/#{slug}")}
  end

  def handle_event("change_status", %{"slug" => slug, "status" => status}, socket) do
    case update_page_meta(socket, slug, &Map.put(&1, "status", status)) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # Override archive_page so the card disappears from the index list.
  def handle_event("archive_page", %{"slug" => slug} = params, socket) do
    if socket.assigns.live_action == :show do
      PageEdit.handle_event("archive_page", params, socket)
    else
      context = socket.assigns.context

      case context && Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, socket}

        page ->
          case Brain.archive_page(page) do
            {:ok, _updated} ->
              pages = Enum.reject(socket.assigns.pages, &(&1.slug == slug))
              archived_pages = [page | socket.assigns[:archived_pages] || []]
              {:noreply, assign(socket, pages: pages, archived_pages: archived_pages)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Could not archive page."))}
          end
      end
    end
  end

  def handle_event("new_page", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects/new")}
  end

  def handle_event("delete_page", p, s), do: PageEdit.handle_event("delete_page", p, s)
  def handle_event("unarchive_page", p, s), do: PageEdit.handle_event("unarchive_page", p, s)
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
  # Matches the repo convention (goal_live.ex:621).
  defp meta_get(meta, key), do: get_in(meta, [key])

  # Updates a page's meta in the DB and replaces it in the `pages` assign list.
  defp update_page_meta(socket, slug, updater) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:error, put_flash(socket, :error, gettext("Page not found."))}

        page ->
          new_meta = updater.(page.meta || %{})

          case Brain.update_page(page, %{"meta" => new_meta}) do
            {:ok, updated} ->
              pages =
                Enum.map(socket.assigns.pages, fn p ->
                  if p.slug == slug, do: updated, else: p
                end)

              {:ok, assign(socket, pages: pages)}

            {:error, _} ->
              {:error, put_flash(socket, :error, gettext("Could not update page."))}
          end
      end
    else
      {:error, socket}
    end
  end

  # Carga páginas de un type y filtra en memoria por meta["project_slug"].
  defp filter_by_project_slug(context_id, type, project_slug) do
    Brain.list_pages(context_id: context_id, type: type, include_body: false, limit: 500)
    |> Enum.filter(fn p -> meta_get(p.meta, "project_slug") == project_slug end)
  end

  # ── Health badge helpers (for Goals list) ──

  defp health_class(page) do
    case meta_get(page.meta, "health") do
      "green" -> "bg-green-100 text-green-700"
      "yellow" -> "bg-yellow-100 text-yellow-700"
      "red" -> "bg-red-100 text-red-700"
      _ -> "bg-base-300 text-base-content/60"
    end
  end
end
