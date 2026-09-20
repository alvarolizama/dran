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
  attr :user, :map, default: nil, doc: "the authenticated user struct (ownership/visibility)"
  attr :is_owner, :boolean, default: false, doc: "whether the current user is the instance owner"
  attr :workspace_slug, :string, default: nil, doc: "the active workspace slug"
  attr :workspaces, :list, default: [], doc: "available workspaces for the selector"
  attr :page_counts, :map, default: %{}, doc: "map of workspace_id => page count"

  attr :active_nav, :string,
    default: nil,
    doc: "the active sidebar nav key, used for highlighting"

  attr :impersonator, :string,
    default: nil,
    doc: "the email of the admin who is impersonating the current user"

  attr :sidebar, :boolean,
    default: true,
    doc: "when false, hides the sidebar entirely (login/setup only)"

  attr :nav, :atom,
    values: [:workspace, :instance],
    default: :workspace,
    doc:
      "which nav the sidebar renders: :workspace (per-workspace links, default) | :instance (Workspaces/Account/Admin). The instance pages (/, /settings/*, /admin/*) use :instance — one shell for the whole app, no topbar flow."

  attr :topbar, :boolean,
    default: false,
    doc: "DEPRECATED, no-op: instance pages use nav={:instance} now"

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
    # Instance nav pages never render the selector, so the aggregate is
    # skipped there.
    sidebar? = assigns[:sidebar] != false
    instance_nav? = assigns[:nav] == :instance

    page_counts =
      case assigns[:page_counts] do
        counts_by_context when is_map(counts_by_context) and map_size(counts_by_context) > 0 ->
          counts_by_context

        _ when not sidebar? or instance_nav? ->
          %{}

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
        is_owner: is_owner,
        instance_nav?: instance_nav?
      )

    ~H"""
    <div class="h-screen bg-base-100 text-base-content">
      <%!-- Shell colapsable (desktop): el checkbox ES el estado y el CSS de
           app.css lo aplica sobre .shell-sidebar / .shell-reveal. Vive acá
           —fuera del drawer— para que las reglas funcionen por hermandad. --%>
      <input id="sidebar-collapse" type="checkbox" class="hidden" />

      <%!-- El `lg:grid-rows-1` NO es cosmético. El drawer de daisyUI es un grid y
           declara solo `grid-auto-columns`: la fila queda IMPLÍCITA y su tamaño
           (`grid-auto-rows: auto`) se infla con el contenido de la página. Con
           contenido largo la fila medía 3024px para una ventana de 900, así que
           `main` dejaba de scrollear por dentro (2968/2968) y scrolleaba el
           DOCUMENTO entero: el sidebar y el topbar se iban con la rueda
           (medido: sidebar top -400 con la ventana scrolleada 400px).
           `repeat(1, minmax(0, 1fr))` acota la fila al viewport y el scroll
           vuelve a vivir dentro de `main` (844/2968), con el sidebar fijo.
           Funciona porque este daisyUI ya pone `grid-row-start: 1` en
           `.drawer-content` y `.drawer-side`; el `minmax(0, …)` es lo que
           permite bajar por debajo del contenido.
           Scope `lg` a propósito: en < lg el `.drawer-side` es un overlay
           `position: fixed` y no hay columna que acotar. --%>
      <div class="drawer lg:drawer-open lg:grid-rows-1 h-full">
        <%!-- Móvil: el drawer-toggle abre/cierra la gaveta con overlay --%>
        <input id="app-drawer" type="checkbox" class="drawer-toggle" />

        <div class="drawer-content flex flex-col min-w-0 h-full">
          <%!-- Barra del contenido: SIEMPRE visible y con el ÚNICO toggle de la
               navegación, en el mismo sitio en todos los anchos. En móvil abre
               la gaveta; en desktop colapsa la sidebar a rail. (Antes había dos
               controles: hamburguesa en móvil + chevron dentro del sidebar.) --%>
          <header class="flex items-center gap-2 h-14 px-3 shrink-0 border-b border-base-300 bg-base-100/80 backdrop-blur">
            <label
              for="app-drawer"
              class="lg:hidden btn btn-ghost btn-sm btn-square"
              title={gettext("Menu")}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </label>
            <label
              for="sidebar-collapse"
              class="hidden lg:inline-flex btn btn-ghost btn-sm btn-square"
              title={gettext("Collapse or expand the sidebar")}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </label>
            <a
              href={~p"/"}
              class="lg:hidden flex items-center gap-2 shrink-0 transition-colors duration-150 hover:opacity-80 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none rounded"
            >
              <img src={~p"/logo.png"} class="size-6 shrink-0" alt="" />
              <span class="text-lg font-bold tracking-tight">Dran</span>
            </a>
          </header>

          <main class={[
            "flex-1 min-h-0 overflow-y-auto flex flex-col w-full",
            !@sidebar && "items-center"
          ]}>
            <div class={[
              "w-full",
              if(@instance_nav? or not @sidebar, do: "p-4 pb-16 sm:p-6", else: "contents")
            ]}>
              {render_slot(@inner_block)}
            </div>
          </main>
        </div>

        <div :if={@sidebar} class="drawer-side z-40">
          <label for="app-drawer" class="drawer-overlay"></label>
          <aside class="shell-sidebar w-60 shrink-0 border-r border-base-300 bg-base-200/50 flex flex-col h-full">
            <div class="p-3 border-b border-base-300">
              <div class="shell-sidebar-header flex items-center gap-2">
                <a
                  href={~p"/"}
                  class="flex items-center gap-2 shrink-0 transition-colors duration-150 hover:opacity-80 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none rounded"
                >
                  <img src={~p"/logo.png"} class="size-6 shrink-0" alt="" />
                  <span class="shell-hide text-lg font-bold tracking-tight">Dran</span>
                </a>
              </div>
            </div>

            <div :if={@workspace_slug} class="p-3 border-b border-base-300">
              <%!-- The id is not decorative: without it LiveView cannot restore the
               field after a crash/reconnect and warns on every page load. --%>
              <form
                id="sidebar-search-form"
                action={~p"/search"}
                method="get"
                class="relative"
              >
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

            <nav class="flex-1 overflow-y-auto p-2 flex flex-col gap-4">
              <%= if @instance_nav? do %>
                <.instance_nav active={@active_nav} is_owner={@is_owner} />
              <% else %>
                <.sidebar_nav
                  active={@active_nav}
                  counts={@counts}
                  is_owner={@is_owner}
                  workspace_slug={@workspace_slug}
                  workspace_role={assigns[:workspace_role]}
                />
              <% end %>
            </nav>

            <div class="p-3 border-t border-base-300">
              <.user_footer
                current_user={@current_user}
                user={@user}
                workspace_slug={@workspace_slug}
                workspace_role={assigns[:workspace_role]}
                is_owner={@is_owner}
                active={@active_nav}
              />
            </div>
          </aside>
        </div>
      </div>

      <.live_component
        module={DranWeb.CommandPalette}
        id="command-palette"
        workspace_slug={@workspace_slug}
        user={@user}
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
        # Iterates the workspace's EFFECTIVE types (4 built-in ∪ custom), and
        # the key is the type's own path — custom types declare theirs.
        type_counts =
          Map.new(Dran.Knowledge.effective_page_types(context), fn type ->
            count = if type in disabled, do: 0, else: by_type[type] || 0
            {String.to_atom(Dran.Workspace.page_type_path(context, type)), count}
          end)

        # Smart collections are first-class Brain collections now.
        collection_count = Dran.Collections.count_collections(context.id)

        contexts_count =
          try do
            Dran.Knowledge.count_workspaces()
          rescue
            _ -> 0
          end

        clusters_count =
          try do
            Dran.Repo.aggregate(
              from(cs in Dran.Graph.ClusterSummary,
                where: cs.workspace_id == ^context.id
              ),
              :count
            )
          rescue
            _ -> 0
          end

        %{
          dashboard: stats[:total_pages] || 0,
          # Per-type badges derive from stats.by_type — a new registry type
          # shows its count without touching this map.
          clusters: clusters_count,
          collections: collection_count,
          contexts: contexts_count,
          graph: stats[:total_relations] || 0,
          activity: Dran.Knowledge.count_log(context.id),
          memory:
            try do
              Dran.Memory.count_memories(context.id)
            rescue
              _ -> 0
            end
        }
        |> Map.merge(type_counts)
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
    # the always-visible entries (Inicio/Grafo/Journey) in one block, Memory in
    # its own block (the nav separates blocks with a gap), and the page types
    # under a labelled "Knowledge base" group; without a workspace
    # (dashboard/admin/account) the nav is empty and only the footer icons show.
    slug = assigns[:workspace_slug]

    groups =
      if is_binary(slug) and slug != "" do
        # resolve_workspace may return nil if the DB lookup fails — but we
        # still have the slug from the URL, which is all we need to build
        # nav paths. workspace_groups handles ws=nil gracefully.
        ws = resolve_workspace(slug)

        workspace_groups(ws, slug, assigns[:counts])
      else
        []
      end

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div :for={group <- @groups} data-nav-block={group[:key]} class="flex flex-col">
      <div :if={!group.label && group.items != []} class="flex flex-col gap-1">
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
        <summary class="shell-hide flex items-center gap-1 px-3 pt-1 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/70 cursor-pointer select-none transition-colors duration-150 hover:text-base-content/80 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none rounded">
          <.icon
            name="hero-chevron-right"
            class="size-3.5 shrink-0 transition-transform duration-150 group-open:rotate-90"
          />
          {group.label}
        </summary>
        <div class="flex flex-col gap-1 mt-1">
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

  # Resolves the %Workspace{} behind a slug; nil-safe (not found → nil).
  defp resolve_workspace(slug) when is_binary(slug) do
    try do
      Dran.Knowledge.get_workspace_by_slug(slug)
    rescue
      _ -> nil
    end
  end

  # "" is truthy in Elixir — the flat router's empty base must still land on
  # "/" for the Home link.
  defp home_path(""), do: "/"
  defp home_path(base), do: base

  # Builds the workspace nav: the always-visible entries (Inicio, Grafo,
  # Journey, Memory) plus the labelled Knowledge base group, gated by feature
  # flags.
  defp workspace_groups(ws, _slug, counts) do
    enabled? = fn feature ->
      case ws do
        nil -> true
        ws -> Dran.Workspace.feature_enabled?(ws, feature)
      end
    end

    # Single-workspace model (W1): flat URLs — no /:workspace_slug prefix.
    base = ""

    disabled = (ws && ws.disabled_page_types) || []

    # Types come from the workspace (built-in ∪ custom) so a custom type is
    # navigable as soon as it is declared.
    page_type_items =
      (for type <- Dran.Knowledge.effective_page_types(ws),
           type not in disabled,
           ui = Dran.Workspace.page_type_ui(ws, type) do
         %{
           key: ui.path,
           label: ui.plural,
           icon: ui.icon,
           path: "#{base}/#{ui.path}",
           badge: counts[type_atom(ws, type)] || 0
         }
       end ++
         [
           enabled?.("clusters") &&
             %{
               key: "clusters",
               label: gettext("Clusters"),
               icon: "hero-squares-2x2",
               path: base <> "/clusters",
               badge: counts[:clusters] || 0
             }
         ])
      |> Enum.reject(&(!&1))

    # Sin etiqueta (siempre visibles): Inicio, Grafo y Journey comparten bloque;
    # **Memory va en su propio bloque** para que el nav deje el hueco de 1rem
    # entre ambos (los bloques del nav se separan con el `gap-4` del contenedor).
    # Memory no es una vista de páginas — son hechos de los workers — así que no
    # debe leerse como continuación del timeline. Activity y Workspace settings
    # viven en el menú de usuario (#user-menu), no en el nav.
    view_items =
      [
        %{key: "home", label: gettext("Home"), icon: "hero-home", path: home_path(base)},
        enabled?.("graph") &&
          %{key: "graph", label: gettext("Graph"), icon: "hero-share", path: base <> "/graph"},
        enabled?.("journey") &&
          %{
            key: "journey",
            label: gettext("Journey"),
            icon: "hero-clock",
            path: base <> "/journey"
          }
      ]
      |> Enum.reject(&(!&1))

    # Memory no es un feature gestionable (no está en @features de
    # WorkspaceSettingsLive), así que no lleva gate — siempre visible.
    memory_items = [
      %{
        key: "memory",
        label: gettext("Memory"),
        icon: "hero-cpu-chip",
        path: base <> "/memory",
        badge: counts[:memory] || 0
      }
    ]

    [
      %{key: "views", label: nil, items: view_items},
      %{key: "memory", label: nil, items: memory_items},
      %{key: "knowledge-base", label: gettext("Knowledge base"), items: page_type_items}
    ]
  end

  # Badge keys are keyed by the type's workspace path (e.g. "notes" → :notes)
  # — compute_counts builds them the same way, so a new type needs no clause.
  defp type_atom(ws, type) do
    ws |> Dran.Workspace.page_type_path(type) |> String.to_atom()
  end

  # ── Instance nav (/, /settings/*, /admin/*) ───────────────────────────────
  #
  # The sidebar nav for instance-level pages: Workspaces at the top, then
  # Account (with its two tabs), then Admin for owners (with its sub-pages).
  # Same link style as sidebar_nav's nav_link, so both navs read as one shell.

  attr :active, :string, default: nil
  attr :is_owner, :boolean, default: false

  def instance_nav(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1">
        <.nav_link
          label={gettext("Workspaces")}
          icon="hero-squares-2x2"
          path={~p"/"}
          active={@active == "dashboard"}
        />
      </div>

      <.nav_group label={gettext("Account")}>
        <.nav_link
          label={gettext("Profile")}
          icon="hero-user"
          path={~p"/settings/account"}
          active={@active == "settings"}
        />
        <.nav_link
          label={gettext("API keys")}
          icon="hero-key"
          path={~p"/settings/api-keys"}
          active={@active == "api_keys"}
        />
      </.nav_group>

      <.nav_group :if={@is_owner} label={gettext("Admin")}>
        <.nav_link
          label={gettext("Users")}
          icon="hero-users"
          path={~p"/admin/users"}
          active={@active == "admin_users"}
        />
        <.nav_link
          label={gettext("Groups")}
          icon="hero-user-group"
          path={~p"/admin/groups"}
          active={@active == "admin_groups"}
        />
        <.nav_link
          label={gettext("All workspaces")}
          icon="hero-building-office-2"
          path={~p"/admin/workspaces"}
          active={@active == "admin_workspaces"}
        />
        <.nav_link
          label={gettext("Models")}
          icon="hero-cpu-chip"
          path={~p"/admin/models"}
          active={@active == "admin_models"}
        />
        <.nav_link
          label={gettext("System")}
          icon="hero-server-stack"
          path={~p"/admin/system"}
          active={@active == "admin_system"}
        />
        <.nav_link
          label={gettext("Jobs")}
          icon="hero-clock"
          path={~p"/admin/jobs"}
          active={@active == "admin_jobs"}
        />
      </.nav_group>
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
  Shows the current user row at the bottom of the sidebar: avatar with the
  initial, name + email truncated, and a menu.

  The menu is the global fallback from any URL: Workspaces (back to the list)
  plus the account entries (Profile · API keys). When the shell is showing a
  workspace it also carries the workspace-scoped entries (Activity · Workspace
  settings) after a divider — the nav itself stays for the workspace content.

  `user` is the DB struct when available (provides the display name); the
  email always comes from `current_user`.
  """
  attr :current_user, :string, default: nil
  attr :user, :map, default: nil
  attr :workspace_slug, :string, default: nil
  attr :workspace_role, :string, default: nil
  attr :is_owner, :boolean, default: false
  attr :active, :string, default: nil

  def user_footer(assigns) do
    name = display_name(assigns[:user], assigns[:current_user])

    can_config = assigns[:is_owner] || assigns[:workspace_role] in ~w(owner admin)

    assigns =
      assigns
      |> assign(:display_name, name)
      |> assign(:can_config, can_config)

    ~H"""
    <div
      :if={@current_user}
      class="shell-user-footer rounded-lg p-2 hover:bg-base-200 transition-colors duration-150 flex items-center gap-2.5"
    >
      <a
        href={~p"/settings/account"}
        class="flex items-center gap-2.5 min-w-0 flex-1"
        title={gettext("Account settings")}
      >
        <span class="size-8 rounded-full bg-primary text-primary-content flex items-center justify-center text-xs font-semibold uppercase shrink-0">
          {String.first(@display_name || @current_user)}
        </span>
        <span class="shell-hide flex-1 min-w-0 leading-tight">
          <span class="block text-sm font-medium truncate">{@display_name}</span>
          <span class="block text-xs text-base-content/50 truncate mt-0.5" title={@current_user}>
            {@current_user}
          </span>
        </span>
      </a>

      <details class="relative" id="user-menu">
        <summary
          class="btn btn-ghost btn-xs btn-circle list-none"
          aria-label={gettext("Account menu")}
        >
          <.icon name="hero-chevron-up" class="size-3" />
        </summary>
        <div class="absolute bottom-full right-0 mb-1 w-48 bg-base-100 border border-base-300 rounded-lg shadow-lg py-1 z-50">
          <.menu_item
            href={~p"/"}
            icon="hero-squares-2x2"
            label={gettext("Workspaces")}
            active={@active == "dashboard"}
          />
          <.menu_item
            href={~p"/settings/account"}
            icon="hero-user"
            label={gettext("Profile")}
          />
          <.menu_item
            href={~p"/settings/api-keys"}
            icon="hero-key"
            label={gettext("API keys")}
          />

          <div :if={@workspace_slug} class="border-t border-base-300 my-1"></div>
          <.menu_item
            :if={@workspace_slug}
            href={~p"/activity"}
            icon="hero-signal"
            label={gettext("Activity")}
            active={@active == "activity"}
          />
          <.menu_item
            :if={@workspace_slug && @can_config}
            href={~p"/settings/instance"}
            icon="hero-cog-6-tooth"
            label={gettext("Instance settings")}
            active={@active == "workspace_settings"}
          />

          <div class="border-t border-base-300 my-1"></div>
          <form id="logout-form" action={~p"/session"} method="post">
            <input type="hidden" name="_method" value="delete" />
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button
              type="submit"
              class="flex items-center gap-2 px-3 py-1.5 text-sm w-full text-left text-error hover:bg-base-200 transition-colors"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="size-4" />
              {gettext("Log out")}
            </button>
          </form>
        </div>
      </details>
    </div>
    """
  end

  # Display name for the sidebar footer: the user's name when present,
  # otherwise the email local part (never an empty row).
  defp display_name(%{name: name}, _email) when is_binary(name) and name != "", do: name

  defp display_name(_user, email) when is_binary(email) do
    email |> String.split("@") |> List.first()
  end

  defp display_name(_user, _email), do: nil
end
