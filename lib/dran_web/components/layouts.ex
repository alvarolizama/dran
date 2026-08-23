defmodule DranWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DranWeb, :html

  import Ecto.Query

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout — a full-height shell with a left sidebar
  for navigating the second brain and a main content area.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_user, :string, default: nil, doc: "the authenticated user"
  attr :is_owner, :boolean, default: false, doc: "whether the current user is the instance owner"
  attr :workspace_slug, :string, default: nil, doc: "the active workspace slug"
  attr :workspaces, :list, default: [], doc: "available workspaces for the selector"
  attr :page_counts, :map, default: %{}, doc: "map of workspace_id => page count"

  attr :active_nav, :string,
    default: nil,
    doc: "the active sidebar nav key, used for highlighting"

  attr :fluid, :boolean,
    default: false,
    doc: "when true, the main content area skips internal padding/constraints"

  attr :impersonator, :string,
    default: nil,
    doc: "the email of the admin who is impersonating the current user"

  slot :inner_block, required: true

  def app(assigns) do
    counts = compute_counts(assigns[:workspace_slug])

    # Resolve admin status for the sidebar's admin-only links. A session user
    # with a row in users is admin iff users.is_owner; a session user without
    # a DB row (pre-multi-user sessions) is treated as a full admin.
    is_owner =
      if is_binary(assigns[:current_user]) do
        case Dran.Accounts.get_user_by_email(assigns[:current_user]) do
          nil -> true
          user -> user.is_owner == true
        end
      else
        assigns[:is_owner] || false
      end

    # If the caller didn't forward page_counts, compute them here so the
    # sidebar context selector never silently shows "Context (0)".
    page_counts =
      case assigns[:page_counts] do
        counts_by_context when is_map(counts_by_context) and map_size(counts_by_context) > 0 ->
          counts_by_context

        _ ->
          try do
            Dran.Knowledge.page_counts_by_workspace()
          rescue
            _ -> %{}
          catch
            _, _ -> %{}
          end
      end

    assigns =
      assign(assigns,
        counts: counts,
        page_counts: page_counts,
        is_owner: is_owner
      )

    ~H"""
    <div class="flex h-screen bg-base-100 text-base-content">
      <aside class="w-64 shrink-0 border-r border-base-300 bg-base-200/50 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <div class="flex items-center gap-2">
            <a
              href={~p"/"}
              class="flex items-center gap-2 shrink-0 transition-colors duration-150 hover:opacity-80 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none rounded"
            >
              <.icon name="hero-cube-transparent" class="size-5 text-primary" />
              <span class="text-lg font-bold tracking-tight">Dran</span>
            </a>
            <.workspace_selector
              :if={@workspace_slug}
              workspace_slug={@workspace_slug}
              workspaces={@workspaces}
              page_counts={@page_counts}
            />
          </div>
        </div>

        <div :if={@workspace_slug} class="p-3 border-b border-base-300">
          <form action={~p"/#{@workspace_slug}/search"} method="get" class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-2.5 top-2.5 size-4 text-base-content/50"
            />
            <input
              type="text"
              name="q"
              placeholder={gettext("Search...")}
              class="w-full pl-8 pr-12 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary focus-visible:ring-2 focus-visible:ring-primary"
            />
            <kbd class="absolute right-2.5 top-2 text-[10px] font-mono text-base-content/40 border border-base-300 rounded px-1">
              ⌘K
            </kbd>
          </form>
        </div>

        <nav class="flex-1 overflow-y-auto p-2 space-y-4 flex flex-col">
          <.sidebar_nav
            active={@active_nav}
            counts={@counts}
            is_owner={@is_owner}
            workspace_slug={@workspace_slug}
            workspace_role={assigns[:workspace_role]}
          />
          <.sidebar_footer_icons
            is_owner={@is_owner}
            workspace_slug={@workspace_slug}
            workspace_role={assigns[:workspace_role]}
            active={@active_nav}
          />
        </nav>

        <div class="p-3 border-t border-base-300 space-y-2">
          <.user_footer current_user={@current_user} />
        </div>
      </aside>

      <div class="flex-1 overflow-y-auto flex flex-col w-full">
        {render_slot(@inner_block)}
      </div>

      <.live_component
        module={DranWeb.CommandPalette}
        id="command-palette"
        workspace_slug={@workspace_slug}
      />

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp compute_counts(nil), do: %{}

  defp compute_counts(workspace_slug) when is_binary(workspace_slug) do
    try do
      context = Dran.Knowledge.get_workspace_by_slug(workspace_slug)

      if context do
        stats = Dran.Knowledge.stats(context.id)
        by_type = stats[:by_type] || %{}
        disabled = context.disabled_page_types || []

        # Zero out counts for disabled page types so sidebar links vanish.
        safe_count = fn type ->
          if type in disabled, do: 0, else: by_type[type] || 0
        end

        # Smart collections are first-class Brain collections now.
        collection_count = length(Dran.Collections.list_collections(context.id))

        contexts_count =
          try do
            length(Dran.Knowledge.list_workspaces())
          rescue
            _ -> 0
          end

        clusters_count =
          try do
            Dran.Repo.aggregate(
              from(cs in Dran.Graph.ClusterSummary,
                where: cs.workspace_id == ^context.id,
                select: cs.id
              ),
              :count
            )
          rescue
            _ -> 0
          end

        %{
          dashboard: stats[:total_pages] || 0,
          notes: safe_count.("note"),
          concepts: safe_count.("concept"),
          entities: safe_count.("entity"),
          references: safe_count.("reference"),
          clusters: clusters_count,
          collections: collection_count,
          projects:
            length(
              Dran.Knowledge.list_pages(workspace_id: context.id, kind: "project", limit: 500)
            ),
          goals: length(Dran.Goals.list_goals(workspace_id: context.id, limit: 500)),
          contexts: contexts_count,
          graph: stats[:total_relations] || 0,
          activity: Dran.Knowledge.count_log(context.id)
        }
      else
        %{}
      end
    rescue
      _ -> %{}
    end
  end

  @doc """
  Renders the grouped sidebar navigation for the second brain.
  Links are grouped by category (Dashboard, Planning, Knowledge, Configs).
  Each labelled group is a collapsible `<details>` section.
  Pass `active` with the nav key of the current page to highlight it.
  Pass `counts` with optional badge data: `%{dashboard: n, todos: n}`.
  """
  attr :active, :string, default: nil
  attr :counts, :map, default: %{}
  attr :workspace_slug, :string, default: nil

  attr :workspace_role, :string,
    default: nil,
    doc: "the current user's role in the active workspace (owner/admin/editor/viewer)"

  attr :is_owner, :boolean,
    default: false,
    doc: "whether to show admin-only links (e.g. Settings)"

  def sidebar_nav(assigns) do
    # Unified workspace sidebar: when a workspace_slug is present the nav shows
    # the workspace sections grouped (Inicio, Conocimiento, Planificación,
    # Graph); without a workspace (dashboard/admin/account) the nav is empty
    # and only the footer icons show.
    ws = resolve_workspace(assigns[:workspace_slug])

    groups =
      if ws do
        workspace_groups(ws, assigns[:workspace_slug], assigns[:counts])
      else
        []
      end

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div :for={group <- @groups} class="flex-1 flex flex-col">
      <div :if={!group.label} class="space-y-1">
        <.nav_link
          :for={item <- group.items}
          label={item.label}
          icon={item.icon}
          path={item.path}
          active={@active == item.key}
          badge={item[:badge]}
        />
      </div>
      <details :if={group.label && group.items != []} open class="group">
        <summary class="flex items-center gap-1 px-2 pt-2 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50 cursor-pointer select-none transition-colors duration-150 hover:text-base-content/70 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none rounded">
          <.icon
            name="hero-chevron-right"
            class="size-3.5 shrink-0 transition-transform duration-150 group-open:rotate-90"
          />
          {group.label}
        </summary>
        <div class="space-y-1 mt-1">
          <.nav_link
            :for={item <- group.items}
            label={item.label}
            icon={item.icon}
            path={item.path}
            active={@active == item.key}
            badge={item[:badge]}
          />
        </div>
      </details>
    </div>
    """
  end

  # Resolves the %Workspace{} behind a slug; nil-safe (no workspace → nil).
  defp resolve_workspace(nil), do: nil

  defp resolve_workspace(slug) when is_binary(slug) do
    try do
      Dran.Knowledge.get_workspace_by_slug(slug)
    rescue
      _ -> nil
    end
  end

  defp resolve_workspace(_), do: nil

  # Builds the workspace nav as a flat list of items, gated by feature
  # flags. No group headers — just direct links.
  defp workspace_groups(ws, slug, counts) do
    enabled? = fn feature -> Dran.Workspace.feature_enabled?(ws, feature) end
    base = "/#{slug}"

    disabled = ws.disabled_page_types || []

    page_type_items =
      for type <- Dran.PageRegistry.types(), type not in disabled do
        %{
          key: Dran.PageRegistry.path(type),
          label: Dran.PageRegistry.plural(type),
          icon: Dran.PageRegistry.icon(type),
          path: "#{base}/#{Dran.PageRegistry.path(type)}",
          badge: counts[type_atom(type)] || 0
        }
      end

    items =
      [
        %{key: "home", label: gettext("Inicio"), icon: "hero-home", path: base},
        enabled?.("goals") && %{key: "goals", label: gettext("Objetivos"), icon: "hero-flag", path: base <> "/goals"},
        enabled?.("kanban") && %{key: "kanban", label: gettext("Kanban"), icon: "hero-view-columns", path: base <> "/kanban"}
      ]
      |> Enum.reject(&(!&1))

    knowledge_items =
      (page_type_items ++
         [
           enabled?.("clusters") && %{key: "clusters", label: gettext("Clusters"), icon: "hero-squares-2x2", path: base <> "/clusters"},
           enabled?.("graph") && %{key: "graph", label: gettext("Grafo"), icon: "hero-share", path: base <> "/graph"},
           enabled?.("journey") && %{key: "journey", label: gettext("Journey"), icon: "hero-clock", path: base <> "/journey"}
         ])
      |> Enum.reject(&(!&1))

    [
      %{label: nil, items: items},
      %{label: gettext("Conocimiento"), items: knowledge_items}
    ]
  end

  defp type_atom("note"), do: :notes
  defp type_atom("entity"), do: :entities
  defp type_atom("concept"), do: :concepts
  defp type_atom("reference"), do: :references

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :path, :any, required: true
  attr :active, :boolean, default: false
  attr :badge, :any, default: nil

  def nav_link(assigns) do
    ~H"""
    <a
      href={@path}
      class={[
        "flex items-center gap-2 py-1.5 rounded-lg text-sm transition-all duration-150 hover:translate-x-0.5 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none",
        @active && "bg-primary/10 text-primary font-medium border-l-2 border-primary pl-2.5 pr-2",
        !@active && "text-base-content/80 hover:bg-base-200 hover:text-base-content pl-3 pr-2"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" />
      <span>{@label}</span>
      <span
        :if={@badge && @badge > 0}
        class="ml-auto text-xs font-medium px-1.5 py-0.5 rounded-md bg-base-300 text-base-content/60"
      >
        {@badge}
      </span>
    </a>
    """
  end

  # ── Sidebar footer (Workspace link + Dashboard, Admin, Account, Docs) ───

  attr :is_owner, :boolean, default: false
  attr :workspace_slug, :string, default: nil
  attr :workspace_role, :string, default: nil
  attr :active, :string, default: nil

  def sidebar_footer_icons(assigns) do
    can_config = assigns[:is_owner] || assigns[:workspace_role] in ~w(owner admin)
    assigns = assign(assigns, :can_config, can_config)

    ~H"""
    <div class="mt-auto flex items-center justify-center gap-1 pt-2 border-t border-base-300">
      <a
        href={~p"/"}
        class="flex items-center justify-center size-8 rounded-lg text-base-content/60 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        title={gettext("Dashboard")}
      >
        <.icon name="hero-squares-2x2" class="size-4" />
      </a>
      <a
        :if={@workspace_slug && @can_config}
        href={~p"/#{@workspace_slug}/settings"}
        class={[
          "flex items-center justify-center size-8 rounded-lg transition-all duration-150 hover:translate-x-0.5",
          @active == "workspace_settings" && "bg-primary/10 text-primary",
          @active != "workspace_settings" &&
            "text-base-content/60 hover:bg-base-200 hover:text-base-content"
        ]}
        title={gettext("Workspace")}
      >
        <.icon name="hero-cog-6-tooth" class="size-4" />
      </a>
      <a
        :if={@workspace_slug}
        href={~p"/#{@workspace_slug}/activity"}
        class={[
          "flex items-center justify-center size-8 rounded-lg transition-all duration-150 hover:translate-x-0.5",
          @active == "activity" && "bg-primary/10 text-primary",
          @active != "activity" &&
            "text-base-content/60 hover:bg-base-200 hover:text-base-content"
        ]}
        title={gettext("Activity")}
      >
        <.icon name="hero-signal" class="size-4" />
      </a>
      <a
        :if={@is_owner}
        href={~p"/admin"}
        class="flex items-center justify-center size-8 rounded-lg text-base-content/60 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        title={gettext("Admin")}
      >
        <.icon name="hero-command-line" class="size-4" />
      </a>
      <a
        href={~p"/settings/account"}
        class="flex items-center justify-center size-8 rounded-lg text-base-content/60 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        title={gettext("Account")}
      >
        <.icon name="hero-user" class="size-4" />
      </a>
      <a
        href={~p"/docs"}
        class="flex items-center justify-center size-8 rounded-lg text-base-content/60 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        title={gettext("Documentation")}
      >
        <.icon name="hero-book-open" class="size-4" />
      </a>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Context selector dropdown. Shown when multiple contexts are available.

  Displays the page count next to each context name, e.g. "Personal (142)".
  The `<select>` has `id="context-selector"` so the ⌘⇧C keyboard shortcut
  in app.js can focus and open it.
  """
  attr :workspace_slug, :string, default: nil
  attr :workspaces, :list, default: []
  attr :page_counts, :map, default: %{}

  def workspace_selector(assigns) do
    ~H"""
    <div :if={length(@workspaces) > 0} class="flex-1">
      <form action={~p"/workspace"} method="post">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <select
          id="context-selector"
          name="context_slug"
          onchange="this.form.submit()"
          class="w-full px-2 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary focus-visible:ring-2 focus-visible:ring-primary"
        >
          <option :for={ctx <- @workspaces} value={ctx.slug} selected={ctx.slug == @workspace_slug}>
            {ctx.name} ({Map.get(@page_counts, ctx.id, 0)})
          </option>
        </select>
      </form>
    </div>
    """
  end

  @doc """
  Shows the current user (link to account settings) and a logout button.
  """
  attr :current_user, :string, default: nil

  def user_footer(assigns) do
    ~H"""
    <div :if={@current_user} class="flex items-center justify-between">
      <a
        href={~p"/settings/account"}
        class="flex items-center gap-2 text-sm text-base-content/70 hover:text-base-content min-w-0 transition-colors duration-150"
        title={gettext("Account settings")}
      >
        <span class="size-7 rounded-full bg-primary/15 text-primary flex items-center justify-center text-xs font-bold uppercase shrink-0">
          {String.first(@current_user)}
        </span>
        <span class="truncate">{@current_user}</span>
      </a>
      <form id="logout-form" action={~p"/session"} method="post">
        <input type="hidden" name="_method" value="delete" />
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <button
          type="submit"
          class="btn btn-ghost btn-xs transition-colors duration-150 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none rounded"
          title={gettext("Logout")}
        >
          <.icon name="hero-arrow-right-on-rectangle" class="size-4" />
        </button>
      </form>
    </div>
    """
  end
end
