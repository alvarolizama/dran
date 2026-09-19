defmodule DranWeb.DashboardLive do
  @moduledoc """
  Dashboard — instance overview of workspaces and their metrics.

  Workspaces come first: the landing page at `/` is the workspace launcher,
  not a per-workspace brain report.

  - Instance owner (admin): sees every workspace, instance-level totals
    (workspaces, pages, users) and a "New workspace" button that opens the
    same creation modal as the admin area. Their own workspaces (memberships)
    come first under "Your workspaces", and the rest of the instance — which
    they can reach only because they own it — under "Organization". The submit
    handler is guarded server-side by the `can_create_workspaces` permission.
  - Users granted `can_create_workspaces` (off by default, toggled from
    /admin/users): see only the workspaces they can access — their personal
    one first — plus the "New workspace" button. Workspaces they create are
    theirs (they become the owner member).
  - Regular users: see only their accessible workspaces (their memberships),
    a few metrics per workspace (pages, todo items, last update) and a direct
    link into each one. No create controls.
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
      user={@user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
      nav={:instance}
    >
      <div class="w-full space-y-6">
        <div class="flex items-start justify-between gap-3">
          <div class="space-y-1.5">
            <h1 class="text-title">{greeting()}</h1>
            <p class="text-caption">
              {format_today()} · {ngettext(
                "%{count} workspace",
                "%{count} workspaces",
                @instance.total_workspaces
              )} · {ngettext("%{count} page", "%{count} pages", @instance.total_pages)}
            </p>
          </div>
          <.button
            :if={@can_create_workspace}
            phx-click="open_context_modal"
            id="new-workspace-btn"
          >
            <.icon name="hero-plus" class="size-4" />
            {gettext("New workspace")}
          </.button>
        </div>

        <div class="space-y-4">
          <h2 class="text-heading">{gettext("Your workspaces")}</h2>

          <div
            :if={@my_workspaces == []}
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
                      "Ask the administrator of a workspace to add you by email. Every workspace is private — there is nothing to browse."
                    )}
              </p>
            </div>
            <.button
              :if={@can_create_workspace}
              phx-click="open_context_modal"
              id="new-workspace-empty-btn"
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("New workspace")}
            </.button>
          </div>

          <div :if={@my_workspaces != []} class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <.workspace_card
              :for={ws <- @my_workspaces}
              ws={ws}
              metrics={Map.get(@workspace_metrics, ws.id, %{pages: 0, last_updated: nil})}
              can_manage={@can_create_workspace or Map.get(ws, :role) in ~w(owner admin)}
            />
          </div>
        </div>

        <%!-- The instance owner reaches every workspace of the instance (see
             require_workspace_access/2), so the ones they are NOT a member of are
             listed apart instead of mixed in with their own: one card per user in
             the same list makes your own workspace hard to find. --%>
        <div :if={@org_workspaces != []} class="space-y-4">
          <div class="space-y-1">
            <h2 class="text-heading">{gettext("Organization")}</h2>
            <p class="text-caption">
              {gettext(
                "Workspaces you are not a member of. You can reach them because you own this instance."
              )}
            </p>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <.workspace_card
              :for={ws <- @org_workspaces}
              ws={ws}
              metrics={Map.get(@workspace_metrics, ws.id, %{pages: 0, last_updated: nil})}
              can_manage={true}
            />
          </div>
        </div>
      </div>

      <%!-- New workspace modal (owner-only) --%>
      <.modal
        :if={@show_workspace_modal}
        id="workspace-modal"
        title={gettext("New workspace")}
        on_close="close_context_modal"
      >
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
      </.modal>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    # `:user` is the DB struct loaded by assign_to_socket (nil when the session
    # has no matching row). The permission is the real gate, not "is the
    # instance owner": a user granted `can_create_workspaces` may create too.
    socket =
      socket
      |> assign(
        can_create_workspace: Dran.Accounts.can_create_workspaces?(socket.assigns[:user]),
        new_workspace_form:
          to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :context),
        show_workspace_modal: false,
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
  def handle_event("validate_context", %{"context" => params}, socket) do
    name = params["name"] || ""

    # The preview shows the slug the workspace will ACTUALLY get, suffix
    # included. It used to show the bare slugified name, so typing "Personal"
    # promised /personal and then produced /personal-3f9a2b — a lie the user only
    # discovered once the URL existed. There is deliberately no slug field in this
    # form: you type a name, the server derives the URL, and you can read it here
    # before creating.
    suggested_slug = suggested_slug_for(name)

    form =
      %Dran.Workspace{}
      |> Dran.Workspace.changeset(Map.put(params, "slug", suggested_slug))
      |> to_form(as: :context)

    {:noreply, assign(socket, new_workspace_form: form, suggested_slug: suggested_slug)}
  end

  @impl true
  def handle_event("create_workspace", %{"context" => params}, socket) do
    # Permission enforced server-side too (the button is hidden without it).
    if socket.assigns[:can_create_workspace] do
      # The form carries no slug field, so whatever `slug` arrived is the
      # preview's, not the user's. Drop it and let the server derive the URL
      # (with its own collision suffix): nothing sent by the client picks it.
      params = Map.drop(params, ["slug"])

      case Dran.Accounts.create_workspace_for(socket.assigns[:user], params) do
        {:ok, _workspace} ->
          {:noreply,
           socket
           |> reload_workspaces()
           |> assign_new_form()
           |> assign(show_workspace_modal: false, suggested_slug: "")
           |> put_flash(:info, gettext("Workspace created"))}

        {:error, :name_taken} ->
          # The name is not unique in the database (two people may both have a
          # "Personal"), but repeating one INSIDE your own list is a mistake:
          # it would silently hand you a suffixed URL you never chose. Say so on
          # the field instead of creating something else than what was asked.
          changeset =
            %Dran.Workspace{}
            |> Dran.Workspace.changeset(
              Map.put(params, "slug", suggested_slug_for(params["name"] || ""))
            )
            |> Ecto.Changeset.add_error(
              :name,
              gettext("You already have a workspace with this name.")
            )
            # `action` is what decides whether the error is VISIBLE:
            # Phoenix.HTML.FormData only exposes a changeset's errors while it has
            # an action, so with the default nil `to_form/2` hands back fields with
            # no errors at all and the message is swallowed without a trace.
            |> Map.put(:action, :validate)

          {:noreply, assign(socket, new_workspace_form: to_form(changeset, as: :context))}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, gettext("Insufficient permissions"))}

        {:error, changeset} ->
          {:noreply, assign(socket, new_workspace_form: to_form(changeset, as: :context))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Insufficient permissions"))}
    end
  end

  # ── Data ─────────────────────────────────────────────────────────────────

  defp reload_workspaces(socket) do
    user = socket.assigns[:user]
    is_instance_owner = Dran.Accounts.is_owner?(user)

    # "Propios": the workspaces the user was added to, their personal one first.
    # Same list the switcher uses.
    my_workspaces = (user && Dran.Accounts.accessible_workspaces(user)) || []

    # "De la organización": only the instance owner has any. They reach every
    # workspace of the instance (require_workspace_access/2), so the ones they
    # are NOT a member of are shown apart instead of mixed in with their own.
    org_workspaces = org_workspaces(user, my_workspaces)

    workspaces = my_workspaces ++ org_workspaces

    ws_metrics = workspace_metrics(workspaces)

    total_pages =
      ws_metrics
      |> Map.values()
      |> Enum.map(& &1.pages)
      |> Enum.sum()

    instance = %{
      total_workspaces: length(workspaces),
      total_pages: total_pages,
      total_users: if(is_instance_owner, do: length(Dran.Accounts.list_users()), else: 0)
    }

    socket
    |> assign(
      workspaces: workspaces,
      my_workspaces: my_workspaces,
      org_workspaces: org_workspaces,
      workspace_metrics: ws_metrics,
      instance: instance
    )
  end

  defp org_workspaces(%{is_owner: true}, my_workspaces) do
    mine = MapSet.new(my_workspaces, & &1.id)

    Dran.Knowledge.list_workspaces()
    |> Enum.reject(&MapSet.member?(mine, &1.id))
    |> Enum.map(&Map.put_new(&1, :role, "owner"))
  end

  defp org_workspaces(_user, _my_workspaces), do: []

  defp assign_new_form(socket) do
    assign(
      socket,
      new_workspace_form: to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :context)
    )
  end

  # The slug the server will ACTUALLY produce: the same base create_workspace/2
  # derives from the name (`base_from_title(name, "workspace")`) uniquified the
  # same way, so the modal's preview can never disagree with the result.
  defp suggested_slug_for(name) do
    name
    |> Slug.base_from_title("workspace")
    |> Dran.Slug.ensure_unique(&Dran.Knowledge.get_workspace_by_slug/1)
  end

  defp workspace_metrics([]), do: %{}

  defp workspace_metrics(workspaces) do
    import Ecto.Query

    ids = Enum.map(workspaces, & &1.id)

    page_counts =
      from(p in Dran.Knowledge.Page,
        where: p.workspace_id in ^ids and p.archived == false,
        group_by: p.workspace_id,
        select: {p.workspace_id, count(p.id)}
      )
      |> Dran.Repo.all()
      |> Map.new()

    last_updated =
      from(p in Dran.Knowledge.Page,
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
         last_updated: Map.get(last_updated, ws.id)
       }}
    end)
  end

  # ── Components ───────────────────────────────────────────────────────────

  attr :ws, :map, required: true
  attr :metrics, :map, default: %{pages: 0, last_updated: nil}
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
          <.link navigate={~p"/#{@ws.slug}"} class="btn btn-primary btn-soft btn-xs gap-1">
            {gettext("Open")}
            <.icon name="hero-arrow-right" class="size-3.5" />
          </.link>
        </div>
      </div>

      <div class="flex items-stretch gap-6 border-t border-base-300 pt-3">
        <div>
          <div class="text-lg font-bold tabular-nums leading-tight">{@metrics.pages}</div>
          <div class="text-caption mt-0.5">{gettext("pages")}</div>
        </div>
        <div class="border-l border-base-300 pl-6">
          <div class="text-sm font-semibold tabular-nums leading-tight">
            {last_updated_label(@metrics.last_updated)}
          </div>
          <div class="text-caption mt-0.5">{gettext("updated")}</div>
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

  defp last_updated_label(nil), do: gettext("Never")

  defp last_updated_label(%mod{} = dt) when mod in [DateTime, NaiveDateTime, Date] do
    Calendar.strftime(dt, "%b %d")
  end

  defp last_updated_label(other), do: to_string(other)
end
