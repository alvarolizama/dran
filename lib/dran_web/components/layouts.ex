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

        <nav class="flex-1 overflow-y-auto p-2 space-y-4">
          <.sidebar_nav
            active={@active_nav}
            counts={@counts}
            is_owner={@is_owner}
            workspace_slug={@workspace_slug}
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

        communities_count =
          try do
            Dran.Repo.aggregate(
              from(cs in Dran.Graph.CommunitySummary,
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
          communities: communities_count,
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

  attr :is_owner, :boolean,
    default: false,
    doc: "whether to show admin-only links (e.g. Settings)"

  # Maps sidebar nav keys to page types. Items whose page type is disabled in
  # the current context are hidden. Keys not in this map are always shown.
  @nav_key_page_types %{
    "notes" => "note",
    "concepts" => "concept",
    "entities" => "entity",
    "references" => "reference"
  }

  def sidebar_nav(assigns) do
    counts = assigns[:counts] || %{}
    is_owner = assigns[:is_owner] || false
    workspace_slug = assigns[:workspace_slug]

    disabled_types =
      case assigns[:workspace_slug] &&
             Dran.Knowledge.get_workspace_by_slug(assigns[:workspace_slug]) do
        %{disabled_page_types: disabled} when is_list(disabled) -> disabled
        _ -> []
      end

    # When no workspace context (e.g. instance-level dashboard at /),
    # workspace-scoped paths would crash with nil interpolation.
    # The nil branch is dead code per type inference (workspace_slug
    # is dynamic(not nil) from assigns), but at runtime it can be nil
    # when the Dashboard renders without a workspace. Guard with
    # assigns[:workspace_slug] to avoid the type narrowing.
    assigns =
      if is_nil(assigns[:workspace_slug]) do
        global_items =
          [
            %{key: "dashboard", label: gettext("Dashboard"), icon: "hero-home", path: ~p"/"}
          ] ++
            if(is_owner,
              do: [
                %{
                  key: "settings",
                  label: gettext("Settings"),
                  icon: "hero-cog-6-tooth",
                  path: ~p"/settings"
                }
              ],
              else: []
            ) ++
            [
              %{
                key: "docs",
                label: gettext("Documentation"),
                icon: "hero-book-open",
                path: ~p"/docs"
              }
            ]

        assign(assigns, groups: [%{label: nil, items: global_items}])
      else
        # Workspace context active — build full nav with workspace-scoped paths
        config_items =
          if is_owner do
            [
              %{
                key: "settings",
                label: gettext("Settings"),
                icon: "hero-cog-6-tooth",
                path: ~p"/settings"
              }
            ]
          else
            []
          end ++
            [
              %{
                key: "docs",
                label: gettext("Documentation"),
                icon: "hero-book-open",
                path: ~p"/docs"
              }
            ]

        groups = [
          %{
            label: nil,
            items: [
              %{
                key: "dashboard",
                label: gettext("Dashboard"),
                icon: "hero-home",
                path: ~p"/"
              },
              %{
                key: "kanban",
                label: gettext("Kanban"),
                icon: "hero-view-columns",
                path: ~p"/#{workspace_slug}/kanban",
                badge: counts[:todos]
              },
              %{
                key: "graph",
                label: gettext("Grafo"),
                icon: "hero-share",
                path: ~p"/#{workspace_slug}/graph"
              },
              %{
                key: "journey",
                label: gettext("Trayectoria"),
                icon: "hero-map",
                path: ~p"/#{workspace_slug}/journey"
              },
              %{
                key: "activity",
                label: gettext("Actividad"),
                icon: "hero-clock",
                path: ~p"/#{workspace_slug}/activity"
              },
              %{
                key: "wiki",
                label: gettext("Wiki"),
                icon: "hero-globe-alt",
                path: ~p"/"
              }
            ]
          },
          %{
            label: gettext("Planning"),
            items: [
              %{
                key: "goals",
                label: gettext("Objetivos"),
                icon: "hero-flag",
                path: ~p"/#{workspace_slug}/goals",
                badge: counts[:goals]
              },
              %{
                key: "projects",
                label: gettext("Projects"),
                icon: "hero-rocket-launch",
                path: ~p"/#{workspace_slug}/notes",
                badge: counts[:projects]
              }
            ]
          },
          %{
            label: gettext("Knowledge"),
            items: [
              %{
                key: "notes",
                label: gettext("Notes"),
                icon: "hero-document-text",
                path: ~p"/#{workspace_slug}/notes",
                badge: counts[:notes]
              },
              %{
                key: "concepts",
                label: gettext("Concepts"),
                icon: "hero-light-bulb",
                path: ~p"/#{workspace_slug}/concepts",
                badge: counts[:concepts]
              },
              %{
                key: "entities",
                label: gettext("Entities"),
                icon: "hero-user-group",
                path: ~p"/#{workspace_slug}/entities",
                badge: counts[:entities]
              },
              %{
                key: "references",
                label: gettext("References"),
                icon: "hero-bookmark",
                path: ~p"/#{workspace_slug}/references",
                badge: counts[:references]
              },
              %{
                key: "communities",
                label: gettext("Comunidades"),
                icon: "hero-squares-2x2",
                path: ~p"/#{workspace_slug}/communities",
                badge: counts[:communities]
              },
              %{
                key: "collections",
                label: gettext("Collections"),
                icon: "hero-funnel",
                path: ~p"/#{workspace_slug}/collections",
                badge: counts[:collections]
              }
            ]
          },
          %{
            label: gettext("Configs"),
            items: config_items
          }
        ]

        groups =
          groups
          |> Enum.map(fn group ->
            filtered_items =
              group.items
              |> Enum.reject(fn item ->
                case Map.get(@nav_key_page_types, item.key) do
                  nil -> false
                  page_type -> page_type in disabled_types
                end
              end)

            %{group | items: filtered_items}
          end)
          |> Enum.reject(fn group -> group.label && group.items == [] end)

        _assigns = assign(assigns, :groups, groups)
      end

    ~H"""
    <div :for={group <- @groups}>
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
      <details :if={group.label} open class="group">
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
  Shows the current user and a logout button.
  """
  attr :current_user, :string, default: nil

  def user_footer(assigns) do
    ~H"""
    <div :if={@current_user} class="flex items-center justify-between">
      <span class="flex items-center gap-2 text-sm text-base-content/70 min-w-0">
        <span class="size-7 rounded-full bg-primary/15 text-primary flex items-center justify-center text-xs font-bold uppercase shrink-0">
          {String.first(@current_user)}
        </span>
        {@current_user}
      </span>
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

  # ── Wiki layout ──────────────────────────────────────────────────────────
  # Sidebar + main shell, mirroring `app/1` but for the read-only wiki.
  # The sidebar has: logo, context selector, search, and wiki navigation
  # (categories + sections). Admins/editors get a "Panel" link back to the app.

  attr :flash, :map, required: true
  attr :current_user, :string, default: nil
  attr :is_owner, :boolean, default: false
  attr :workspace_slug, :string, default: nil
  attr :workspaces, :list, default: []
  attr :page_title, :string, default: nil
  attr :live_action, :atom, default: nil
  attr :search_query, :string, default: ""
  attr :search_results, :list, default: nil
  attr :wiki_context, :map, default: nil
  attr :type_index, :list, default: []
  attr :collections, :list, default: []
  attr :pinned_pages, :list, default: []
  attr :counts, :map, default: %{}
  attr :collection_slug, :string, default: nil

  slot :inner_block, required: true

  def home(assigns) do
    counts = compute_counts(assigns[:workspace_slug])

    # Resolve admin/editor from the DB — same as app/1. The wiki layout must
    # not depend on the caller passing correct flags; it should resolve them
    # independently so the Panel button always shows for admins, even if the
    # LiveView's socket assigns are stale or incomplete.
    is_owner =
      if is_binary(assigns[:current_user]) do
        case Dran.Accounts.get_user_by_email(assigns[:current_user]) do
          nil -> true
          user -> user.is_owner == true
        end
      else
        assigns[:is_owner] || false
      end

    assigns =
      assign(assigns,
        counts: counts,
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
            <.home_workspace_selector
              workspace_slug={@workspace_slug}
              workspaces={@workspaces}
            />
          </div>
        </div>

        <div class="p-3 border-b border-base-300">
          <form
            id="wiki-search-form"
            phx-change="wiki_search"
            phx-submit="wiki_search"
            class="relative"
          >
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-2.5 top-2.5 size-4 text-base-content/50"
            />
            <input
              type="text"
              name="q"
              value={@search_query}
              placeholder={gettext("Search wiki...")}
              class="w-full pl-8 pr-3 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary focus-visible:ring-2 focus-visible:ring-primary"
            />
          </form>
        </div>

        <nav class="flex-1 overflow-y-auto p-2 space-y-4 flex flex-col">
          <.wiki_sidebar_nav
            workspace_slug={@workspace_slug}
            live_action={@live_action}
            type_index={@type_index}
            collections={@collections}
            pinned_pages={@pinned_pages}
            workspaces={@workspaces}
            counts={@counts}
            collection_slug={@collection_slug}
          />
          <a
            :if={@is_owner or @is_owner}
            href={~p"/"}
            class="mt-auto flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
            title={gettext("Panel")}
          >
            <.icon name="hero-squares-2x2" class="size-4 shrink-0" />
            <span>{gettext("Panel")}</span>
          </a>
        </nav>

        <div class="p-3 border-t border-base-300">
          <.user_footer current_user={@current_user} />
        </div>
      </aside>

      <div class="flex-1 overflow-y-auto flex flex-col w-full">
        {render_slot(@inner_block)}
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  # ── Wiki context selector ────────────────────────────────────────────────

  attr :workspace_slug, :string, default: nil
  attr :workspaces, :list, default: []

  defp home_workspace_selector(assigns) do
    ~H"""
    <div :if={length(@workspaces) > 0} class="flex-1">
      <select
        id="wiki-context-selector"
        class="w-full px-2 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary focus-visible:ring-2 focus-visible:ring-primary"
        onchange="window.location.href = this.value"
      >
        <option value={~p"/"} selected={!@workspace_slug}>
          {gettext("All contexts")}
        </option>
        <option
          :for={ctx <- @workspaces}
          value={~p"/#{ctx.slug}"}
          selected={ctx.slug == @workspace_slug}
        >
          {ctx.name}
        </option>
      </select>
    </div>
    """
  end

  # ── Wiki sidebar navigation ──────────────────────────────────────────────

  attr :workspace_slug, :string, default: nil
  attr :live_action, :atom, default: nil
  attr :type_index, :list, default: []
  attr :collections, :list, default: []
  attr :pinned_pages, :list, default: []
  attr :workspaces, :list, default: []
  attr :counts, :map, default: %{}
  attr :collection_slug, :string, default: nil

  defp wiki_sidebar_nav(assigns) do
    ~H"""
    <div :if={!@workspace_slug}>
      <div class="space-y-1">
        <a
          href={~p"/"}
          class="flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm transition-all duration-150 hover:translate-x-0.5 text-base-content/80 hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-home" class="size-4 shrink-0" />
          <span>{gettext("Home")}</span>
        </a>
      </div>
    </div>

    <div :if={@workspace_slug}>
      <div class="space-y-1">
        <a
          href={~p"/#{@workspace_slug}"}
          class={[
            "flex items-center gap-2 py-1.5 rounded-lg text-sm transition-all duration-150 hover:translate-x-0.5 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none",
            @live_action == :context_home &&
              "bg-primary/10 text-primary font-medium border-l-2 border-primary pl-2.5 pr-2",
            @live_action != :context_home &&
              "text-base-content/80 hover:bg-base-200 hover:text-base-content pl-3 pr-2"
          ]}
        >
          <.icon name="hero-home" class="size-4 shrink-0" />
          <span>{gettext("Home")}</span>
        </a>
        <a
          :if={@counts[:todos] > 0}
          href={~p"/#{@workspace_slug}/kanban"}
          class={[
            "flex items-center gap-2 py-1.5 rounded-lg text-sm transition-all duration-150 hover:translate-x-0.5 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none",
            @live_action == :kanban &&
              "bg-primary/10 text-primary font-medium border-l-2 border-primary pl-2.5 pr-2",
            @live_action != :kanban &&
              "text-base-content/80 hover:bg-base-200 hover:text-base-content pl-3 pr-2"
          ]}
        >
          <.icon name="hero-view-columns" class="size-4 shrink-0" />
          <span>{gettext("Kanban")}</span>
        </a>
        <a
          :if={@counts[:projects] > 0}
          href={~p"/#{@workspace_slug}/type/project"}
          class="flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        >
          <.icon name="hero-rocket-launch" class="size-4 shrink-0" />
          <span>{gettext("Proyectos")}</span>
          <span class="ml-auto text-xs font-medium px-1.5 py-0.5 rounded-md bg-base-300 text-base-content/60">
            {@counts[:projects]}
          </span>
        </a>
        <a
          :if={@counts[:goals] > 0}
          href={~p"/#{@workspace_slug}/type/goal"}
          class="flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        >
          <.icon name="hero-flag" class="size-4 shrink-0" />
          <span>{gettext("Objetivos")}</span>
          <span class="ml-auto text-xs font-medium px-1.5 py-0.5 rounded-md bg-base-300 text-base-content/60">
            {@counts[:goals]}
          </span>
        </a>
        <a
          href={~p"/#{@workspace_slug}/graph"}
          class={[
            "flex items-center gap-2 py-1.5 rounded-lg text-sm transition-all duration-150 hover:translate-x-0.5 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none",
            @live_action == :graph &&
              "bg-primary/10 text-primary font-medium border-l-2 border-primary pl-2.5 pr-2",
            @live_action != :graph &&
              "text-base-content/80 hover:bg-base-200 hover:text-base-content pl-3 pr-2"
          ]}
        >
          <.icon name="hero-share" class="size-4 shrink-0" />
          <span>{gettext("Grafo")}</span>
        </a>
      </div>
    </div>

    <div :if={@workspace_slug && @pinned_pages != []}>
      <h3 class="px-2 pt-3 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
        {gettext("Pinned")}
      </h3>
      <div class="space-y-1">
        <a
          :for={page <- @pinned_pages}
          href={~p"/#{@workspace_slug}/#{page.page_type}/#{page.slug}"}
          class="flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        >
          <.icon name="hero-bookmark" class="size-4 shrink-0 text-amber-500" />
          <span class="truncate">{page.title}</span>
        </a>
      </div>
    </div>

    <div :if={@workspace_slug && (@counts[:plans] > 0 || @counts[:todos] > 0)}>
      <h3 class="px-2 pt-3 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
        {gettext("Planificacion")}
      </h3>
      <div class="space-y-1">
        <a
          :if={@counts[:plans] > 0}
          href={~p"/#{@workspace_slug}/type/plan"}
          class="flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        >
          <.icon name="hero-clipboard-document-list" class="size-4 shrink-0" />
          <span>{gettext("Planes")}</span>
          <span class="ml-auto text-xs font-medium px-1.5 py-0.5 rounded-md bg-base-300 text-base-content/60">
            {@counts[:plans]}
          </span>
        </a>
        <a
          :if={@counts[:todos] > 0}
          href={~p"/#{@workspace_slug}/type/todo"}
          class="flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        >
          <.icon name="hero-check-circle" class="size-4 shrink-0" />
          <span>{gettext("Tareas")}</span>
          <span class="ml-auto text-xs font-medium px-1.5 py-0.5 rounded-md bg-base-300 text-base-content/60">
            {@counts[:todos]}
          </span>
        </a>
      </div>
    </div>

    <div :if={@workspace_slug && @collections != []}>
      <h3 class="px-2 pt-3 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
        {gettext("Categorias")}
      </h3>
      <div class="space-y-1">
        <a
          :for={coll <- @collections}
          href={~p"/#{@workspace_slug}/collection/#{coll.slug}"}
          class={[
            "flex items-center gap-2 py-1.5 rounded-lg text-sm transition-all duration-150 hover:translate-x-0.5 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none",
            @live_action == :collection && @collection_slug == coll.slug &&
              "bg-primary/10 text-primary font-medium border-l-2 border-primary pl-2.5 pr-2",
            (@live_action != :collection || @collection_slug != coll.slug) &&
              "text-base-content/80 hover:bg-base-200 hover:text-base-content pl-3 pr-2"
          ]}
        >
          <.icon name="hero-funnel" class="size-4 shrink-0" />
          <span class="truncate">{coll.title}</span>
        </a>
      </div>
    </div>

    <div :if={@workspace_slug && @type_index != []}>
      <h3 class="px-2 pt-3 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
        {gettext("Contenido")}
      </h3>
      <div class="space-y-1">
        <a
          :for={item <- @type_index}
          href={~p"/#{@workspace_slug}/#{item.type}"}
          class="flex items-center gap-2 py-1.5 pl-3 pr-2 rounded-lg text-sm text-base-content/80 hover:bg-base-200 hover:text-base-content transition-all duration-150 hover:translate-x-0.5"
        >
          <.icon name={item.icon} class="size-4 shrink-0" />
          <span>{item.label}</span>
          <span class="ml-auto text-xs font-medium px-1.5 py-0.5 rounded-md bg-base-300 text-base-content/60">
            {item.count}
          </span>
        </a>
      </div>
    </div>
    """
  end
end
