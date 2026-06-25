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
    ~H"""
    <div class="flex h-screen bg-base-100 text-base-content">
      <aside class="w-64 shrink-0 border-r border-base-300 bg-base-200/50 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <a href={~p"/"} class="flex items-center gap-2">
            <span class="text-lg font-bold tracking-tight">Dran</span>
          </a>
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
              placeholder="Search..."
              class="w-full pl-8 pr-3 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 focus:outline-none focus:ring-1 focus:ring-primary"
            />
          </form>
        </div>

        <.context_selector context_slug={@context_slug} contexts={@contexts} />

        <nav class="flex-1 overflow-y-auto p-2 space-y-4">
          <.sidebar_nav active={@active_nav} />
        </nav>

        <div class="p-3 border-t border-base-300 space-y-2">
          <.user_footer current_user={@current_user} />
          <.theme_toggle />
        </div>
      </aside>

      <div class="flex-1 overflow-hidden flex flex-col w-full">
        {render_slot(@inner_block)}
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders the grouped sidebar navigation for the second brain.

  Links are grouped by category (Knowledge, Planning, Outputs, Agents).
  Pass `active` with the nav key of the current page to highlight it.
  """
  attr :active, :string, default: nil

  def sidebar_nav(assigns) do
    groups = [
      %{
        label: nil,
        items: [
          %{key: "dashboard", label: "Dashboard", icon: "hero-home", path: ~p"/"},
          %{key: "graph", label: "Graph", icon: "hero-share", path: ~p"/graph"}
        ]
      },
      %{
        label: "Knowledge",
        items: [
          %{key: "notes", label: "Notes", icon: "hero-document-text", path: ~p"/notes"},
          %{key: "concepts", label: "Concepts", icon: "hero-light-bulb", path: ~p"/concepts"},
          %{key: "entities", label: "Entities", icon: "hero-user-group", path: ~p"/entities"},
          %{key: "references", label: "References", icon: "hero-bookmark", path: ~p"/references"}
        ]
      },
      %{
        label: "Planning",
        items: [
          %{key: "goals", label: "Goals", icon: "hero-flag", path: ~p"/goals"},
          %{
            key: "plans",
            label: "Plans",
            icon: "hero-clipboard-document-list",
            path: ~p"/plans"
          },
          %{key: "todos", label: "Todos", icon: "hero-check-circle", path: ~p"/todos"}
        ]
      },
      %{
        label: "Outputs",
        items: [
          %{key: "artifacts", label: "Artifacts", icon: "hero-cube", path: ~p"/artifacts"},
          %{key: "comparisons", label: "Comparisons", icon: "hero-scale", path: ~p"/comparisons"}
        ]
      },
      %{
        label: "Agents",
        items: [
          %{
            key: "ingest",
            label: "Ingest",
            icon: "hero-arrow-down-tray",
            path: ~p"/agents/ingest"
          },
          %{
            key: "search",
            label: "Search",
            icon: "hero-magnifying-glass",
            path: ~p"/agents/search"
          },
          %{
            key: "research",
            label: "Research",
            icon: "hero-beaker",
            path: ~p"/agents/research"
          }
        ]
      },
      %{
        label: "Docs",
        items: [
          %{key: "docs", label: "Documentation", icon: "hero-book-open", path: ~p"/docs"}
        ]
      }
    ]

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div :for={group <- @groups} class="space-y-1">
      <div
        :if={group.label}
        class="px-2 pt-2 pb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50"
      >
        {group.label}
      </div>
      <.nav_link
        :for={item <- group.items}
        label={item.label}
        icon={item.icon}
        path={item.path}
        active={@active == item.key}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :path, :any, required: true
  attr :active, :boolean, default: false

  def nav_link(assigns) do
    ~H"""
    <a
      href={@path}
      class={[
        "flex items-center gap-2 px-2 py-1.5 rounded-lg text-sm transition",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/80 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" />
      <span>{@label}</span>
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
    <div :if={length(@contexts) > 0} class="p-3 border-b border-base-300">
      <form action={~p"/context"} method="post">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <label class="text-xs text-base-content/50 uppercase tracking-wider mb-1 block">
          Context
        </label>
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
        <button type="submit" class="btn btn-ghost btn-xs" title="Logout">
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
