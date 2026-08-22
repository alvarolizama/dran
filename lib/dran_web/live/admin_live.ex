defmodule DranWeb.AdminLive do
  @moduledoc """
  Admin landing page — instance-level policy cards linking to the dedicated
  /admin/* LiveViews. Only accessible to instance owners via the :admin
  pipeline in the router.
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Admin"), workspace_slug: nil)

    {:ok, socket}
  end

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
          <div>
            <h1 class="text-title">{gettext("Admin")}</h1>
            <p class="text-caption mt-1">
              {gettext("Instance-level administration — users, workspaces, models, system, and jobs.")}
            </p>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            <.admin_card
              href={~p"/admin/users"}
              icon="hero-users"
              title={gettext("Users")}
              description={gettext("Manage users, assign workspaces, copy tokens.")}
            />

            <.admin_card
              href={~p"/admin/workspaces"}
              icon="hero-building-office-2"
              title={gettext("Workspaces")}
              description={gettext("Create, delete, set default, toggle visibility.")}
            />

            <.admin_card
              href={~p"/admin/models"}
              icon="hero-cpu-chip"
              title={gettext("Models")}
              description={gettext("Select models for chat, embeddings, and reranking.")}
            />

            <.admin_card
              href={~p"/admin/system"}
              icon="hero-server-stack"
              title={gettext("System")}
              description={gettext("Read-only environment: inference, agents, uploads.")}
            />

            <.admin_card
              href={~p"/admin/jobs"}
              icon="hero-clock"
              title={gettext("Jobs")}
              description={gettext("Toggle scheduled crons, run now, view last run.")}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Components ─────────────────────────────────────────────────────────────

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil

  defp admin_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="card bg-base-100 border border-base-300 hover:border-primary/40 hover:shadow-md transition-all duration-150 cursor-pointer group"
    >
      <div class="card-body py-5 gap-2">
        <div class="flex items-center gap-3">
          <div class="shrink-0 size-10 rounded-lg flex items-center justify-center bg-primary/10 group-hover:bg-primary/20 transition-colors">
            <.icon name={@icon} class="size-5 text-primary" />
          </div>
          <div>
            <h3 class="font-semibold text-base-content group-hover:text-primary transition-colors">
              {@title}
            </h3>
            <p :if={@description} class="text-caption text-sm mt-0.5">
              {@description}
            </p>
          </div>
        </div>
      </div>
    </.link>
    """
  end
end
