defmodule DranWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DranWeb, :html

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
  attr :context_slug, :string, default: nil, doc: "the active context slug"
  attr :contexts, :list, default: [], doc: "available contexts for the selector"

  attr :active_nav, :string,
    default: nil,
    doc: "the active sidebar nav key, used for highlighting"

  attr :fluid, :boolean,
    default: false,
    doc: "when true, the main content area skips internal padding/constraints"

  slot :inner_block, required: true

  def app(assigns) do
    counts = compute_counts(assigns[:context_slug])
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <div class="flex h-screen bg-base-100 text-base-content">
      <aside class="w-64 shrink-0 border-r border-base-300 bg-base-200/50 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <div class="flex items-center gap-2">
            <a href={~p"/"} class="flex items-center gap-2 shrink-0">
              <.icon name="hero-cube-transparent" class="size-5 text-primary" />
              <span class="text-lg font-bold tracking-tight">Dran</span>
            </a>
            <.context_selector context_slug={@context_slug} contexts={@contexts} />
          </div>
        </div>

        <div class="p-3 border-b border-base-300">
          <form action={~p"/search"} method="get" class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-2.5 top-2.5 size-4 text-base-content/50"
            />
            <input
              type="text"
              name="q"
              placeholder={gettext("Search...")}
              class="w-full pl-8 pr-12 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
            />
            <kbd class="absolute right-2.5 top-2 text-[10px] font-mono text-base-content/40 border border-base-300 rounded px-1">
              ⌘K
            </kbd>
          </form>
        </div>

        <nav class="flex-1 overflow-y-auto p-2 space-y-4">
          <.sidebar_nav active={@active_nav} counts={@counts} />
        </nav>

        <div class="p-3 border-t border-base-300 space-y-2">
          <.user_footer current_user={@current_user} />
          <.theme_toggle />
        </div>
      </aside>

      <div class="flex-1 overflow-hidden flex flex-col w-full">
        {render_slot(@inner_block)}
      </div>

      <.live_component
        module={DranWeb.CommandPalette}
        id="command-palette"
        context_slug={@context_slug}
      />

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp compute_counts(nil), do: %{}

  defp compute_counts(context_slug) when is_binary(context_slug) do
    try do
      context = Dran.Brain.get_context_by_slug(context_slug)

      if context do
        stats = Dran.Brain.stats(context.id)
        by_type = stats[:by_type] || %{}

        %{
          dashboard: stats[:total_pages] || 0,
          todos: by_type["todo"] || 0
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
  Links are grouped by category (Knowledge, Planning, Outputs, Agents,
  Configs, Docs). Each labelled group is a collapsible `<details>` section.
  Pass `active` with the nav key of the current page to highlight it.
  Pass `counts` with optional badge data: `%{dashboard: n, todos: n}`.
  """
  attr :active, :string, default: nil
  attr :counts, :map, default: %{}

  def sidebar_nav(assigns) do
    counts = assigns[:counts] || %{}

    groups = [
      %{
        label: nil,
        items: [
          %{
            key: "dashboard",
            label: gettext("Dashboard"),
            icon: "hero-home",
            path: ~p"/",
            badge: counts[:dashboard]
          },
          %{key: "graph", label: gettext("Graph"), icon: "hero-share", path: ~p"/graph"},
          %{
            key: "activity",
            label: gettext("Activity"),
            icon: "hero-clock",
            path: ~p"/activity"
          }
        ]
      },
      %{
        label: gettext("Knowledge"),
        items: [
          %{key: "notes", label: gettext("Notes"), icon: "hero-document-text", path: ~p"/notes"},
          %{
            key: "concepts",
            label: gettext("Concepts"),
            icon: "hero-light-bulb",
            path: ~p"/concepts"
          },
          %{
            key: "entities",
            label: gettext("Entities"),
            icon: "hero-user-group",
            path: ~p"/entities"
          },
          %{
            key: "references",
            label: gettext("References"),
            icon: "hero-bookmark",
            path: ~p"/references"
          },
          %{
            key: "queries",
            label: gettext("Queries"),
            icon: "hero-question-mark-circle",
            path: ~p"/queries"
          }
        ]
      },
      %{
        label: gettext("Planning"),
        items: [
          %{key: "goals", label: gettext("Goals"), icon: "hero-flag", path: ~p"/goals"},
          %{
            key: "plans",
            label: gettext("Plans"),
            icon: "hero-clipboard-document-list",
            path: ~p"/plans"
          },
          %{
            key: "todos",
            label: gettext("Todos"),
            icon: "hero-check-circle",
            path: ~p"/todos",
            badge: counts[:todos]
          }
        ]
      },
      %{
        label: gettext("Outputs"),
        items: [
          %{
            key: "artifacts",
            label: gettext("Artifacts"),
            icon: "hero-cube",
            path: ~p"/artifacts"
          },
          %{
            key: "comparisons",
            label: gettext("Comparisons"),
            icon: "hero-scale",
            path: ~p"/comparisons"
          }
        ]
      },
      %{
        label: gettext("Agents"),
        items: [
          %{
            key: "research",
            label: gettext("Research"),
            icon: "hero-beaker",
            path: ~p"/agents/research"
          },
          %{
            key: "ingest",
            label: gettext("Files Ingest"),
            icon: "hero-arrow-down-tray",
            path: ~p"/agents/ingest"
          }
        ]
      },
      %{
        label: gettext("Configs"),
        items: [
          %{
            key: "contexts",
            label: gettext("Contexts"),
            icon: "hero-rectangle-stack",
            path: ~p"/contexts"
          },
          %{
            key: "settings",
            label: gettext("Settings"),
            icon: "hero-cog-6-tooth",
            path: ~p"/settings"
          }
        ]
      },
      %{
        label: gettext("Docs"),
        items: [
          %{key: "docs", label: gettext("Documentation"), icon: "hero-book-open", path: ~p"/docs"}
        ]
      }
    ]

    assigns = assign(assigns, :groups, groups)

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
        <summary class="flex items-center gap-1 px-2 pt-2 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50 cursor-pointer select-none hover:text-base-content/70">
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
        "flex items-center gap-2 py-1.5 rounded-lg text-sm transition-colors duration-150",
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
  """
  attr :context_slug, :string, default: nil
  attr :contexts, :list, default: []

  def context_selector(assigns) do
    ~H"""
    <div :if={length(@contexts) > 0} class="flex-1">
      <form action={~p"/context"} method="post">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <select
          name="context_slug"
          onchange="this.form.submit()"
          class="w-full px-2 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
        >
          <option :for={ctx <- @contexts} value={ctx.slug} selected={ctx.slug == @context_slug}>
            {ctx.name}
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
      <span class="flex items-center gap-2 text-sm text-base-content/60">
        <.icon name="hero-user" class="size-4" />
        {@current_user}
      </span>
      <form
        action={~p"/session"}
        method="post"
        onsubmit="this.method='delete'; this.submit(); return false;"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <button type="submit" class="btn btn-ghost btn-xs" title={gettext("Logout")}>
          <.icon name="hero-arrow-right-on-rectangle" class="size-4" />
        </button>
      </form>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
