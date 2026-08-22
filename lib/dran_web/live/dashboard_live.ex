defmodule DranWeb.DashboardLive do
  @moduledoc """
  Dashboard — instance overview of workspaces and their metrics.

  Workspaces come first: the landing page at `/` is the workspace launcher,
  not a per-workspace brain report.

  - Instance owner (admin): sees every workspace, instance-level totals
    (workspaces, pages, users) and a "New workspace" button that opens the
    same creation modal as the admin area. The submit handler is guarded
    server-side by `can_create_workspace`.
  - Regular users: see only their accessible workspaces (memberships +
    public), a few metrics per workspace (pages, todo items, last update)
    and a direct link into each one. No create controls.
  - Empty instance: the owner gets a create-workspace CTA; other users get
    a "nothing assigned yet" state.
  """

  use DranWeb, :live_view

  alias Dran.Slug
  alias DranWeb.Plugs.Auth

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
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-8">
          <div class="flex items-center justify-between gap-4">
            <div class="space-y-1">
              <h1 class="text-title">{greeting()}</h1>
              <p class="text-caption">
                {format_today()} · {ngettext(
                  "%{count} workspace",
                  "%{count} workspaces",
                  @instance.total_workspaces
                )} · {ngettext("%{count} page", "%{count} pages", @instance.total_pages)}
              </p>
            </div>
            <button
              :if={@can_create_workspace}
              phx-click="open_context_modal"
              class="btn btn-primary btn-sm gap-1.5 transition-colors active:scale-95"
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("New workspace")}
            </button>
          </div>

          <div class="space-y-4">
            <h2 class="text-heading">
              {if @can_create_workspace, do: gettext("Workspaces"), else: gettext("Your workspaces")}
            </h2>

            <div
              :if={@workspaces == []}
              class="surface-2 p-12 rounded-2xl flex flex-col items-center gap-4 text-center"
            >
              <div class="size-14 rounded-full bg-base-200 flex items-center justify-center">
                <.icon
                  name={if @can_create_workspace, do: "hero-squares-2x2", else: "hero-lock-closed"}
                  class="size-7 text-base-content/40"
                />
              </div>
              <div class="space-y-1">
                <div class="font-semibold">
                  {if @can_create_workspace,
                    do: gettext("No workspaces yet"),
                    else: gettext("No workspaces assigned")}
                </div>
                <p class="text-caption max-w-md">
                  {if @can_create_workspace,
                    do: gettext("Create the first workspace to start building your second brain."),
                    else:
                      gettext(
                        "Ask the instance owner to add you to a workspace, or browse public workspaces from the Wiki."
                      )}
                </p>
              </div>
              <button
                :if={@can_create_workspace}
                phx-click="open_context_modal"
                class="btn btn-primary btn-sm gap-1.5 transition-colors active:scale-95"
              >
                <.icon name="hero-plus" class="size-4" />
                {gettext("New workspace")}
              </button>
            </div>

            <div :if={@workspaces != []} class="grid grid-cols-1 lg:grid-cols-2 gap-4">
              <.workspace_card
                :for={ws <- @workspaces}
                ws={ws}
                metrics={Map.get(@workspace_metrics, ws.id, %{pages: 0, todos: 0, last_updated: nil})}
                can_manage={@can_create_workspace or Map.get(ws, :role) in ~w(owner admin)}
              />
            </div>
          </div>
        </div>
      </div>

      <%!-- New workspace modal (owner-only) --%>
      <div
        :if={@show_workspace_modal}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      >
        <div
          class="card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg"
          phx-click-away="close_context_modal"
        >
          <div class="card-body">
            <div class="flex items-center justify-between mb-2">
              <h3 class="text-lg font-semibold">{gettext("New workspace")}</h3>
              <button phx-click="close_context_modal" class="btn btn-ghost btn-xs btn-circle">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <.form
              for={@new_workspace_form}
              id="context-form"
              phx-change="validate_context"
              phx-submit="create_workspace"
              class="space-y-4"
            >
              <.input
                field={@new_workspace_form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("e.g. Personal")}
                class="w-full"
                autofocus
              />

              <p class="text-caption">
                {gettext("Slug is generated automatically from the name:")}
                <code class="font-mono text-base-content/70">{@suggested_slug}</code>
              </p>

              <div class="flex justify-end gap-2 pt-1">
                <button type="button" phx-click="close_context_modal" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
                <button
                  type="submit"
                  class="btn btn-primary btn-sm transition-colors active:scale-95"
                  phx-disable-with={gettext("Creating…")}
                >
                  <.icon name="hero-plus" class="size-4" />
                  {gettext("Create")}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    is_owner = socket.assigns[:is_owner] || false

    socket =
      socket
      |> assign(
        can_create_workspace: is_owner,
        new_workspace_form:
          to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :context),
        show_workspace_modal: false,
        slug_touched: false,
        suggested_slug: "",
        active_nav: "dashboard",
        page_title: gettext("Dashboard"),
        # The dashboard is instance-level (not inside a workspace), so the
        # sidebar renders the global nav (Dashboard + Configuraciones) instead
        # of the workspace nav that assign_to_socket would otherwise leak in.
        workspace_slug: nil
      )
      |> reload_workspaces()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_context_modal", _params, socket) do
    {:noreply, assign(socket, show_workspace_modal: true)}
  end

  @impl true
  def handle_event("close_context_modal", _params, socket) do
    {:noreply, assign(socket, show_workspace_modal: false)}
  end

  @impl true
  def handle_event("validate_context", %{"context" => params} = event, socket) do
    # LiveView includes "_target" on form events; guard for tests or hand
    # crafted events that omit it.
    target = Map.get(event, "_target", [])
    name = params["name"] || ""
    slug_touched = socket.assigns[:slug_touched] || false || target == ["context", "slug"]

    params =
      if slug_touched do
        params
      else
        Map.put(params, "slug", Slug.slugify(name))
      end

    form = %Dran.Workspace{} |> Dran.Workspace.changeset(params) |> to_form(as: :context)

    {:noreply,
     assign(socket,
       new_workspace_form: form,
       slug_touched: slug_touched,
       suggested_slug: Slug.slugify(name)
     )}
  end

  @impl true
  def handle_event("create_workspace", %{"context" => params}, socket) do
    # Owner-only, enforced server-side (the button is hidden for everyone else).
    if socket.assigns[:can_create_workspace] do
      params =
        if is_nil(params["slug"]) or params["slug"] == "" do
          Map.put(params, "slug", Slug.slugify(params["name"] || ""))
        else
          params
        end

      case Dran.Knowledge.create_workspace(params) do
        {:ok, _workspace} ->
          {:noreply,
           socket
           |> reload_workspaces()
           |> assign_new_form()
           |> assign(show_workspace_modal: false, suggested_slug: "")
           |> put_flash(:info, gettext("Workspace created"))}

        {:error, changeset} ->
          {:noreply, assign(socket, new_workspace_form: to_form(changeset, as: :context))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Insufficient permissions"))}
    end
  end

  # ── Data ─────────────────────────────────────────────────────────────────

  defp reload_workspaces(socket) do
    is_owner = socket.assigns[:can_create_workspace] || false
    current_user = socket.assigns[:current_user]
    db_user = current_user && Dran.Accounts.get_user_by_email(current_user)

    workspaces =
      if is_owner do
        Dran.Knowledge.list_workspaces()
        |> Enum.map(&Map.put_new(&1, :role, "owner"))
      else
        (db_user && Dran.Accounts.accessible_workspaces(db_user)) || []
      end

    ws_metrics = workspace_metrics(workspaces)

    total_pages =
      ws_metrics
      |> Map.values()
      |> Enum.map(& &1.pages)
      |> Enum.sum()

    instance = %{
      total_workspaces: length(workspaces),
      total_pages: total_pages,
      total_users: if(is_owner, do: length(Dran.Accounts.list_users()), else: 0)
    }

    socket
    |> assign(
      workspaces: workspaces,
      workspace_metrics: ws_metrics,
      instance: instance
    )
  end

  defp assign_new_form(socket) do
    assign(socket,
      new_workspace_form: to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :context),
      slug_touched: false
    )
  end

  defp workspace_metrics([]), do: %{}

  defp workspace_metrics(workspaces) do
    import Ecto.Query

    ids = Enum.map(workspaces, & &1.id)

    page_counts =
      from(p in Dran.Page,
        where: p.workspace_id in ^ids and p.archived == false,
        group_by: p.workspace_id,
        select: {p.workspace_id, count(p.id)}
      )
      |> Dran.Repo.all()
      |> Map.new()

    todo_counts =
      from(p in Dran.Page,
        where: p.workspace_id in ^ids and p.archived == false and not is_nil(p.kanban_status),
        group_by: p.workspace_id,
        select: {p.workspace_id, count(p.id)}
      )
      |> Dran.Repo.all()
      |> Map.new()

    last_updated =
      from(p in Dran.Page,
        where: p.workspace_id in ^ids and p.archived == false,
        group_by: p.workspace_id,
        select: {p.workspace_id, max(p.updated_at)}
      )
      |> Dran.Repo.all()
      |> Map.new()

    Map.new(workspaces, fn ws ->
      {ws.id,
       %{
         pages: Map.get(page_counts, ws.id, 0),
         todos: Map.get(todo_counts, ws.id, 0),
         last_updated: Map.get(last_updated, ws.id)
       }}
    end)
  end

  # ── Components ───────────────────────────────────────────────────────────

  attr :ws, :map, required: true
  attr :metrics, :map, default: %{pages: 0, todos: 0, last_updated: nil}
  attr :can_manage, :boolean, default: false

  defp workspace_card(assigns) do
    ~H"""
    <div class="surface-2 lift p-5 rounded-2xl flex flex-col gap-4">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <h3 class="font-semibold text-base truncate">{@ws.name}</h3>
            <span :if={@ws.is_default} class="badge badge-primary badge-sm">{gettext("default")}</span>
          </div>
          <div class="flex flex-wrap items-center gap-2 mt-1">
            <code class="text-xs text-base-content/50 font-mono">{@ws.slug}</code>
            <.role_badge role={Map.get(@ws, :role, "owner")} />
            <span class="inline-flex items-center gap-1 text-xs text-base-content/60">
              <.icon
                name={if @ws.visibility == "public", do: "hero-globe-alt", else: "hero-lock-closed"}
                class="size-3"
              />
              {if @ws.visibility == "public", do: gettext("Public"), else: gettext("Private")}
            </span>
          </div>
        </div>
        <div class="flex gap-1.5 shrink-0">
          <.link
            :if={@can_manage}
            navigate={~p"/#{@ws.slug}/settings"}
            class="btn btn-ghost btn-xs"
            title={gettext("Workspace settings")}
          >
            <.icon name="hero-cog-6-tooth" class="size-4" />
          </.link>
          <.link navigate={~p"/#{@ws.slug}"} class="btn btn-primary btn-xs gap-1">
            {gettext("Open")}
            <.icon name="hero-arrow-right" class="size-3.5" />
          </.link>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-2 border-t border-base-300 pt-3">
        <div class="text-center">
          <div class="text-lg font-bold tabular-nums leading-tight">{@metrics.pages}</div>
          <div class="text-caption">{gettext("pages")}</div>
        </div>
        <div class="text-center">
          <div class="text-lg font-bold tabular-nums leading-tight">{@metrics.todos}</div>
          <div class="text-caption">{gettext("todos")}</div>
        </div>
        <div class="text-center">
          <div class="text-sm font-semibold tabular-nums leading-tight">
            {last_updated_label(@metrics.last_updated)}
          </div>
          <div class="text-caption">{gettext("updated")}</div>
        </div>
      </div>
    </div>
    """
  end

  attr :role, :string, required: true

  defp role_badge(assigns) do
    ~H"""
    <span class={[
      "px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide rounded-md",
      role_color(@role)
    ]}>
      {@role}
    </span>
    """
  end

  defp role_color("owner"), do: "bg-primary/15 text-primary"
  defp role_color("admin"), do: "bg-warning/15 text-warning"
  defp role_color("editor"), do: "bg-info/15 text-info"
  defp role_color(_), do: "bg-base-300 text-base-content/60"

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp greeting do
    hour = DateTime.utc_now().hour

    cond do
      hour < 6 -> gettext("Good night")
      hour < 12 -> gettext("Good morning")
      hour < 20 -> gettext("Good afternoon")
      true -> gettext("Good evening")
    end
  end

  defp format_today do
    Calendar.strftime(Date.utc_today(), "%A, %B %d, %Y")
  end

  defp last_updated_label(nil), do: "—"

  defp last_updated_label(%mod{} = dt) when mod in [DateTime, NaiveDateTime, Date] do
    Calendar.strftime(dt, "%b %d")
  end

  defp last_updated_label(other), do: to_string(other)
end
