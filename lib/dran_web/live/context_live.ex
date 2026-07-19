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
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-8 max-w-5xl mx-auto">
          <%!-- Page header --%>
          <div>
            <h1 class="text-title">{gettext("Contexts")}</h1>
            <p class="text-caption mt-1">
              {gettext("Manage the contexts of your second brain.")}
            </p>
          </div>

          <%!-- Create form card --%>
          <section class="surface-2 rounded-2xl overflow-hidden">
            <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
              <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
                <.icon name="hero-plus" class="size-4 text-primary" />
              </div>
              <div class="min-w-0">
                <h2 class="text-heading">{gettext("New context")}</h2>
                <p class="text-caption mt-0.5">
                  {gettext("Create an isolated silo for your knowledge.")}
                </p>
              </div>
            </header>

            <.form
              for={@form}
              id="context-form"
              phx-change="validate"
              phx-submit="save"
              class="px-5 py-5 space-y-4"
            >
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div phx-change="update_slug">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label={gettext("Name")}
                    placeholder={gettext("e.g. Personal")}
                    class="w-full"
                  />
                </div>
                <.input
                  field={@form[:slug]}
                  type="text"
                  label={gettext("Slug")}
                  placeholder={gettext("e.g. personal")}
                  class="w-full font-mono text-sm"
                />
              </div>
              <p class="text-caption">
                {gettext("The slug auto-derives from the name unless you edit it directly.")}
              </p>

              <div class="flex justify-end pt-1">
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
          </section>

          <%!-- Existing contexts --%>
          <section class="space-y-3">
            <div class="flex items-baseline justify-between">
              <h2 class="text-heading">
                {gettext("Existing contexts")}
              </h2>
              <span class="text-caption">
                {gettext("%{count} total", count: length(@contexts))}
              </span>
            </div>

            <%!-- Empty state with CTA --%>
            <.empty_state
              :if={@contexts == []}
              icon="hero-square-3-stack-3d"
              title={gettext("No contexts yet")}
              caption={gettext("Create your first context above to start organizing your second brain.")}
              class="surface-2 rounded-2xl"
            />

            <%!-- Context cards --%>
            <.context_card
              :for={{ctx, count} <- contexts_with_counts(@contexts)}
              ctx={ctx}
              page_count={count}
              confirm_delete_id={@confirm_delete_id}
              context_slug={@context_slug}
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- View components --------------------------------------------------------

  attr :ctx, :any, required: true
  attr :page_count, :integer, default: 0
  attr :confirm_delete_id, :any, default: nil
  attr :context_slug, :string, default: nil

  defp context_card(assigns) do
    ~H"""
    <div
      id={"context-#{@ctx.id}"}
      class={[
        "surface-2 lift rounded-2xl p-4 transition-all",
        @confirm_delete_id == @ctx.id && "ring-2 ring-error/60 bg-error/5"
      ]}
    >
      <div class="flex items-start justify-between gap-4">
        <%!-- Identity / metadata --%>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2 flex-wrap">
            <span class="text-sm font-semibold text-base-content truncate">
              {@ctx.name}
            </span>
            <span :if={@context_slug == @ctx.slug} class="text-caption text-primary">
              · {gettext("current")}
            </span>
          </div>
          <div class="flex items-center gap-2 mt-1.5 flex-wrap">
            <code class="inline-flex items-center px-2 py-0.5 text-xs font-mono rounded-md bg-base-200 text-base-content/70">
              {@ctx.slug}
            </code>
            <span class="inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full bg-primary/10 text-primary">
              <.icon name="hero-document" class="size-3" />
              {gettext("%{count} pages", count: @page_count)}
            </span>
            <span class="inline-flex items-center gap-1 text-caption">
              <.icon name="hero-calendar" class="size-3" />
              {format_date(@ctx.inserted_at)}
            </span>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex items-center gap-2 shrink-0">
          <%= if @confirm_delete_id == @ctx.id do %>
            <span class="text-caption text-error mr-1 hidden sm:inline">
              {gettext("Delete?")}
            </span>
            <button
              type="button"
              phx-click="delete"
              phx-value-id={@ctx.id}
              class="btn btn-error btn-xs transition-colors active:scale-95"
            >
              <.icon name="hero-check" class="size-3.5" />
              {gettext("Confirm")}
            </button>
            <button
              type="button"
              phx-click="cancel_delete"
              class="btn btn-ghost btn-xs transition-colors active:scale-95"
            >
              {gettext("Cancel")}
            </button>
          <% else %>
            <.link
              href={~p"/?context=#{@ctx.slug}"}
              class="btn btn-ghost btn-xs transition-colors active:scale-95"
            >
              {gettext("Switch")}
            </.link>
            <button
              type="button"
              phx-click="ask_delete"
              phx-value-id={@ctx.id}
              class="btn btn-ghost btn-xs text-error hover:bg-error/10 transition-colors active:scale-95"
              title={gettext("Delete context")}
              aria-label={gettext("Delete context")}
            >
              <.icon name="hero-trash" class="size-3.5" />
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # One grouped query per render — Brain.page_counts_by_context/0 returns
  # a map of context_id => page_count. Kept out of assigns per the
  # "handlers/assigns identical" contract; called here as a pure render-time
  # lookup and zipped with the contexts list already present in assigns.
  defp contexts_with_counts(contexts) do
    counts = Brain.page_counts_by_context()

    Enum.map(contexts, fn ctx ->
      {ctx, Map.get(counts, ctx.id, 0)}
    end)
  end
end
