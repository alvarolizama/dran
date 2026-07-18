defmodule DranWeb.PlanLive do
  @moduledoc "LiveView for plan pages: index list + detail view with inline editing."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.Plugs.Auth

  @page_type "plan"
  @tabs [{"content", gettext("Content")}, {"graph", gettext("Graph")}]

  @impl true
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
          compare_version={@compare_version}
          logs={@logs}
          context_slug={@context_slug}
          rendered_body={@rendered_body}
        >
          <:actions>
            <.link navigate={~p"/plans"} class="btn btn-primary btn-sm"><.icon
              name="hero-arrow-left"
              class="size-4"
            /> {gettext("Back")}</.link>
            <button :if={not @editing} phx-click="toggle_edit" class="btn btn-primary btn-sm"><.icon
              name="hero-pencil"
              class="size-4"
            /> {gettext("Edit")}</button>
            <button :if={@editing} phx-click="save_page" class="btn btn-success btn-sm"><.icon
              name="hero-check"
              class="size-4"
            /> {gettext("Save")}</button>
            <button :if={@editing} phx-click="cancel_edit" class="btn btn-ghost btn-sm"><.icon
              name="hero-x-mark"
              class="size-4"
            /> {gettext("Cancel")}</button>
          </:actions>
          <:tabs>
            <.tabs_bar tabs={@tabs} active_tab={@active_tab} />
            <div :if={@active_tab == "content"} class="space-y-6">
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
                      label={gettext("Title")}
                      placeholder={gettext("Enter a title…")}
                      class="text-lg font-medium"
                    />
                    <div class="grid grid-cols-2 gap-4">
                      <.input
                        field={@form[:slug]}
                        type="text"
                        placeholder={gettext("slug")}
                        class="w-full"
                        phx-blur="field_change"
                      />
                      <.input
                        field={@form[:summary]}
                        type="text"
                        placeholder={gettext("Summary (optional)")}
                        class="w-full"
                      />
                    </div>
                    <.input
                      field={@form[:tags]}
                      type="text"
                      placeholder={gettext("Tags (comma separated)")}
                      class="w-full"
                    />
                    <.meta_fields page_type={@page_type} meta={@page.meta} />
                    <.markdown_editor
                      id="plan-editor"
                      body={@page.body}
                      context_id={@context_id}
                      save_status={@save_status}
                    />
                    <div class="flex justify-end gap-2 pt-2">
                      <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">{gettext(
                        "Cancel"
                      )}</button>
                      <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
                    </div>
                  </div>
                </.form>
              <% else %>
                <div class="prose prose-base dark:prose-invert max-w-none">
                  {@rendered_body}
                </div>
                <div class="border-t border-base-300 pt-4">
                  <h3 class="text-sm font-semibold text-base-content/60 mb-2">
                    {gettext("Changelog")}
                  </h3>
                  <div class="space-y-1">
                    <div :for={version <- @versions} class="text-sm text-base-content/60">
                      {gettext("v%{version} — %{date} by %{author}",
                        version: version.version,
                        date: format_date(version.inserted_at),
                        author: version.changed_by || gettext("system")
                      )}
                    </div>
                    <p :if={@versions == []} class="text-sm text-base-content/40">
                      {gettext("No version history yet.")}
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
            <div :if={@active_tab == "graph"}>
              <.page_graph id="plan-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
            </div>
          </:tabs>
        </.page_detail>
      </div>
      <div :if={@live_action != :show}>
        <div class="p-6 pb-0">
          <form id="plan-filters" phx-change="filter" class="flex flex-wrap items-end gap-2 mb-4">
            <div class="fieldset mb-0">
              <label
                for="plan-filter-goal"
                class="block text-xs font-medium text-base-content/60 mb-1"
              >
                {gettext("Goal")}
              </label>
              <select
                id="plan-filter-goal"
                name="filter_goal"
                class="select select-sm select-bordered"
              >
                <option value="">{gettext("All goals")}</option>
                <option value="none" selected={@filter_goal == "none"}>{gettext("No goal")}</option>
                <option :for={goal <- @goals} value={goal.slug} selected={@filter_goal == goal.slug}>
                  {goal.title}
                </option>
              </select>
            </div>

            <div class="fieldset mb-0">
              <label
                for="plan-filter-status"
                class="block text-xs font-medium text-base-content/60 mb-1"
              >
                {gettext("Status")}
              </label>
              <select
                id="plan-filter-status"
                name="filter_status"
                class="select select-sm select-bordered"
              >
                <option value="">{gettext("All statuses")}</option>
                <option
                  :for={{label, value} <- @status_options}
                  value={value}
                  selected={@filter_status == value}
                >
                  {label}
                </option>
              </select>
            </div>

            <div class="fieldset mb-0 flex-1 min-w-40">
              <label
                for="plan-filter-query"
                class="block text-xs font-medium text-base-content/60 mb-1"
              >
                {gettext("Search")}
              </label>
              <input
                id="plan-filter-query"
                name="filter_query"
                type="search"
                value={@filter_query}
                placeholder={gettext("Filter by title...")}
                class="input input-sm input-bordered w-full"
                phx-debounce="300"
              />
            </div>

            <button
              :if={@filter_goal != "" or @filter_status != "" or @filter_query != ""}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="clear_filters"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Clear filters")}
            </button>
          </form>
        </div>
        <.page_list pages={@filtered_pages} page_type={@page_type} context_slug={@context_slug} />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      if context,
        do:
          allow_upload(socket, :file,
            accept:
              ~w(image/* video/* audio/* application/pdf text/plain text/markdown text/csv text/html application/json application/zip),
            max_file_size: Dran.Uploads.max_size(),
            auto_upload: true,
            progress: &handle_progress/3
          ),
        else: socket

    {:ok,
     assign(socket,
       context: context,
       page_type: @page_type,
       tabs: @tabs,
       active_tab: "content",
       editing: false,
       save_status: "idle",
       goals: [],
       status_options: plan_status_options(),
       filter_goal: "",
       filter_status: "",
       filter_query: "",
       filtered_pages: []
     )}
  end

  defp plan_status_options do
    Enum.map(Dran.Brain.PageMeta.plan_statuses(), &{String.capitalize(&1), &1})
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/plans")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)
          editing = Map.get(params, "edit") == "true"
          form = if editing, do: Brain.change_page(page) |> to_form(as: :page), else: nil

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
             active_tab: "content",
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             editing: editing,
             form: form,
             context_id: context.id,
             save_status: "idle",
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/plans")}
    end
  end

  def handle_params(_params, _url, socket) do
    if socket.assigns.context do
      context_id = socket.assigns.context.id
      pages = Brain.list_pages(context_id: context_id, type: @page_type)
      goals = Brain.list_goals(context_id)

      {:noreply,
       assign(socket,
         pages: pages,
         goals: goals,
         page_title: gettext("Plans")
       )
       |> assign_filtered_pages()}
    else
      {:noreply,
       assign(socket,
         pages: [],
         goals: [],
         page_title: gettext("Plans")
       )
       |> assign_filtered_pages()}
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket), do: {:noreply, switch_tab(socket, tab)}

  def handle_event("node_click", %{"slug" => slug}, socket),
    do: {:noreply, node_click(socket, slug)}

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket),
    do: {:noreply, node_drag(socket, id, x, y)}

  def handle_event("show_page", %{"slug" => slug}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/plans/#{slug}")}

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     assign(socket,
       filter_goal: params["filter_goal"] || "",
       filter_status: params["filter_status"] || "",
       filter_query: params["filter_query"] || ""
     )
     |> assign_filtered_pages()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     assign(socket, filter_goal: "", filter_status: "", filter_query: "")
     |> assign_filtered_pages()}
  end

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/plans/new")}

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

  # ── Filtering ──

  defp assign_filtered_pages(socket) do
    assign(socket, filtered_pages: filtered_pages(socket.assigns))
  end

  defp filtered_pages(assigns) do
    assigns.pages
    |> filter_pages_by_goal(assigns.filter_goal)
    |> filter_pages_by_status(assigns.filter_status)
    |> filter_pages_by_query(assigns.filter_query)
  end

  defp filter_pages_by_goal(pages, ""), do: pages

  defp filter_pages_by_goal(pages, "none") do
    Enum.filter(pages, fn page ->
      slug = (page.meta || %{})["goal_slug"]
      slug in [nil, ""]
    end)
  end

  defp filter_pages_by_goal(pages, goal_slug) do
    Enum.filter(pages, fn page ->
      (page.meta || %{})["goal_slug"] == goal_slug
    end)
  end

  defp filter_pages_by_status(pages, ""), do: pages

  defp filter_pages_by_status(pages, status) do
    Enum.filter(pages, fn page ->
      (page.meta || %{})["status"] == status
    end)
  end

  defp filter_pages_by_query(pages, ""), do: pages

  defp filter_pages_by_query(pages, query) do
    q = query |> String.downcase() |> String.trim()

    if q == "",
      do: pages,
      else:
        Enum.filter(pages, fn page ->
          String.downcase(page.title || "") =~ q
        end)
  end
end
