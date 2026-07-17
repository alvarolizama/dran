defmodule DranWeb.ContextLive do
  @moduledoc """
  LiveView for managing contexts: create new contexts and delete existing ones.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.Brain.Context
  alias Dran.Slug
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    {:ok,
     socket
     |> assign(:active_nav, "contexts")
     |> assign(:contexts, Brain.list_contexts())
     |> assign(:form, to_form(Context.changeset(%Context{}, %{}), as: :context))
     |> assign(:confirm_delete_id, nil)
     |> assign(:slug_touched, false)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"context" => params, "_target" => target}, socket) do
    name = params["name"] || ""
    slug_touched = socket.assigns[:slug_touched] || false

    # If user edited the slug field directly, stop auto-generating
    slug_touched =
      if target == ["context", "slug"], do: true, else: slug_touched

    # Auto-generate slug from name unless user has manually edited it
    params =
      if slug_touched do
        params
      else
        Map.put(params, "slug", Slug.slugify(name))
      end

    form = %Context{} |> Context.changeset(params) |> to_form(as: :context)
    {:noreply, assign(socket, form: form, slug_touched: slug_touched)}
  end

  def handle_event("save", %{"context" => params}, socket) do
    case Brain.create_context(params) do
      {:ok, _context} ->
        {:noreply,
         socket
         |> assign(:contexts, Brain.list_contexts())
         |> assign(:form, to_form(Context.changeset(%Context{}, %{}), as: :context))
         |> assign(:slug_touched, false)
         |> put_flash(:info, "Context created")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :context))}
    end
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_delete_id, id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_id, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    context = Enum.find(socket.assigns.contexts, &(&1.id == id))

    if context do
      case Brain.delete_context(context) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:contexts, Brain.list_contexts())
           |> assign(:confirm_delete_id, nil)
           |> put_flash(:info, "Context \"#{context.name}\" deleted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not delete context")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
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
      <div class="p-6 overflow-y-auto w-full">
        <div class="w-full space-y-6">
          <div>
            <h1 class="text-2xl font-bold">Contexts</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Manage the contexts of your second brain.
            </p>
          </div>

          <div class="p-4 rounded-lg border border-base-300 bg-base-200/30">
            <h2 class="text-sm font-semibold text-base-content/60 mb-3">
              New context
            </h2>
            <.form
              for={@form}
              id="context-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-3"
            >
              <div class="grid grid-cols-2 gap-3">
                <div phx-change="update_slug">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label="Name"
                    placeholder="e.g. Personal"
                    class="w-full"
                  />
                </div>
                <.input
                  field={@form[:slug]}
                  type="text"
                  label="Slug"
                  placeholder="e.g. personal"
                  class="w-full font-mono text-sm"
                />
              </div>
              <div class="flex justify-end">
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  phx-disable-with={gettext("Creating…")}
                >
                  <.icon name="hero-plus" class="size-4" /> {gettext("Create")}
                </button>
              </div>
            </.form>
          </div>

          <div class="space-y-2">
            <h2 class="text-sm font-semibold text-base-content/60">
              Existing contexts ({length(@contexts)})
            </h2>

            <div :if={@contexts == []} class="text-center py-12">
              <.icon
                name="hero-square-3-stack-3d"
                class="w-12 h-12 mx-auto mb-3 text-base-content/30"
              />
              <p class="text-sm text-base-content/50">
                {gettext("No contexts yet. Create one above.")}
              </p>
            </div>

            <div
              :for={ctx <- @contexts}
              id={"context-#{ctx.id}"}
              class={[
                "flex items-center justify-between p-3 rounded-lg border",
                @confirm_delete_id == ctx.id && "border-error/50 bg-error/5",
                @confirm_delete_id != ctx.id && "border-base-300"
              ]}
            >
              <div class="min-w-0">
                <div class="font-medium">{ctx.name}</div>
                <div class="text-xs text-base-content/50 font-mono">{ctx.slug}</div>
              </div>
              <div class="flex items-center gap-2">
                <%= if @confirm_delete_id == ctx.id do %>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={ctx.id}
                    class="btn btn-error btn-xs"
                  >
                    <.icon name="hero-check" class="size-3.5" /> Confirm
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_delete"
                    class="btn btn-ghost btn-xs"
                  >
                    Cancel
                  </button>
                <% else %>
                  <.link href={~p"/?context=#{ctx.slug}"} class="btn btn-ghost btn-xs">
                    Switch
                  </.link>
                  <button
                    type="button"
                    phx-click="ask_delete"
                    phx-value-id={ctx.id}
                    class="btn btn-ghost btn-xs text-error hover:bg-error/10"
                    title="Delete context"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
