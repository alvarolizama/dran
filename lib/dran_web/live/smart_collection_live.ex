defmodule DranWeb.SmartCollectionLive do
  @moduledoc """
  LiveView for Smart Collections.

  A collection is a saved filter query that auto-updates as pages change.
  Lives in its own table with `filters` JSONB.
  """

  use DranWeb, :live_view

  alias Dran.Knowledge

  alias Dran.Collections
  alias DranWeb.Plugs.Auth

  # ──────────────────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
    >
      <div :if={@live_action == :index} class="p-6 overflow-y-auto w-full">
        <div class="flex items-center justify-between mb-4">
          <div>
            <h1 class="text-title">{gettext("Smart Collections")}</h1>
            <p class="text-caption mt-1">
              {gettext("Saved queries that auto-update as your brain changes")}
            </p>
          </div>
          <.link navigate={~p"/#{@workspace_slug}/collections/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Collection")}
          </.link>
        </div>

        <.empty_state
          :if={@collections == []}
          icon="hero-folder-plus"
          title={gettext("No smart collections yet.")}
          caption={gettext("Save a set of filters from search or any page list to create one.")}
        >
          <.link
            navigate={~p"/#{@workspace_slug}/collections/new"}
            class="btn btn-primary btn-sm mt-4"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {gettext("Create your first collection")}
          </.link>
        </.empty_state>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <.link
            :for={collection <- @collections}
            navigate={~p"/#{@workspace_slug}/collections/#{collection.slug}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer"
          >
            <div class="card-body p-5">
              <div class="flex items-center gap-2 mb-1">
                <.icon name="hero-funnel" class="w-5 h-5 text-primary/70" />
                <h2 class="card-title text-lg">{collection.name}</h2>
              </div>
              <p :if={collection.description} class="text-sm text-base-content/60">
                {collection.description}
              </p>
              <div class="flex flex-wrap gap-1.5 mt-3">
                <span
                  :for={{key, value} <- format_filters(collection)}
                  class="px-2 py-0.5 text-xs rounded-full bg-base-200 text-base-content/70"
                >
                  {key}: {value}
                </span>
                <span :if={format_filters(collection) == []} class="text-xs text-base-content/40">{gettext(
                  "All pages"
                )}</span>
              </div>
            </div>
          </.link>
        </div>
      </div>

      <div :if={@live_action == :show} class="p-6 overflow-y-auto w-full">
        <div class="flex items-center justify-between mb-6">
          <div>
            <div class="flex items-center gap-2 mb-1">
              <.icon name="hero-funnel" class="w-6 h-6 text-primary/70" />
              <h1 class="text-title">{@collection.name}</h1>
            </div>
            <p :if={@collection.description} class="text-caption">{@collection.description}</p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/#{@workspace_slug}/collections"} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back")}
            </.link>
            <button
              phx-click="delete_collection"
              data-confirm={
                gettext("Delete this smart collection? The pages it references will not be affected.")
              }
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
            </button>
          </div>
        </div>

        <div class="flex flex-wrap gap-2 mb-6">
          <span
            :for={{key, value} <- @query_tags}
            class="px-3 py-1 text-sm rounded-lg bg-base-200 border border-base-300"
          >
            <span class="text-base-content/50">{key}:</span>
            <span class="font-medium">{value}</span>
          </span>
          <span :if={@query_tags == []} class="text-sm text-base-content/40">
            {gettext("No filters — showing all pages in this context")}
          </span>
        </div>

        <div class="flex items-center justify-between mb-3">
          <span class="text-sm text-base-content/60">
            {@result_count} {ngettext("page", "pages", @result_count)}
          </span>
          <span class="text-xs text-base-content/40 flex items-center gap-1">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span> {gettext(
              "Live"
            )}
          </span>
        </div>

        <div class="space-y-2">
          <div
            :for={page <- @results}
            class="p-3 rounded-lg border border-base-300 hover:bg-base-200 cursor-pointer transition"
            phx-click="show_page"
            phx-value-slug={page.slug}
            phx-value-type={page.page_type}
          >
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2 min-w-0">
                <.icon
                  name={DranWeb.PageTypes.icon(page.page_type)}
                  class="w-4 h-4 text-base-content/40 shrink-0"
                />
                <span class="font-medium truncate">{page.title}</span>
              </div>
              <span class="text-xs text-base-content/50 shrink-0 ml-2">
                {DranWeb.PageTypes.label(page.page_type)}
              </span>
            </div>
            <p :if={page.summary} class="text-sm text-base-content/60 mt-1 truncate">
              {page.summary}
            </p>
          </div>

          <.empty_state
            :if={@results == []}
            icon="hero-document-magnifying-glass"
            title={gettext("No pages match this collection's filters.")}
          />
        </div>
      </div>

      <div :if={@live_action == :new} class="p-6 overflow-y-auto w-full max-w-2xl mx-auto">
        <div class="mb-6">
          <h1 class="text-title">{gettext("New Smart Collection")}</h1>
          <p class="text-caption mt-1">
            {gettext("Save a set of filters as a live-updating collection.")}
          </p>
        </div>

        <form phx-submit="create_collection" class="space-y-5">
          <.input
            id="collection-title"
            name="name"
            type="text"
            label={gettext("Name")}
            value={@form["name"]}
            placeholder={gettext("e.g. Urgent Todos This Week")}
            required
          />

          <.input
            id="collection-slug"
            name="slug"
            type="text"
            label={gettext("Slug")}
            value={@form["slug"]}
            placeholder={gettext("auto-generated from name if blank")}
            class="font-mono text-sm"
          />

          <.input
            id="collection-description"
            name="description"
            type="text"
            label={gettext("Description")}
            value={@form["description"]}
            placeholder={gettext("One-line description")}
          />

          <div class="border-t border-base-300 pt-5">
            <h3 class="text-sm font-semibold text-base-content/70 mb-3">{gettext("Filters")}</h3>
            <div class="grid grid-cols-2 gap-4">
              <.input
                id="filter-type"
                name="type"
                type="select"
                label={gettext("Page type")}
                value={@form["type"]}
                options={@type_options}
              />
              <.input
                id="filter-status"
                name="status"
                type="select"
                label={gettext("Status (kanban)")}
                value={@form["status"]}
                options={@status_options}
              />
              <.input
                id="filter-tag"
                name="tag"
                type="text"
                label={gettext("Tag")}
                value={@form["tag"]}
                placeholder={gettext("any tag")}
              />
              <.input
                id="filter-owner"
                name="owner"
                type="text"
                label={gettext("Owner")}
                value={@form["owner"]}
                placeholder={gettext("any owner")}
              />
            </div>
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/#{@workspace_slug}/collections"} class="btn btn-ghost btn-sm">{gettext(
              "Cancel"
            )}</.link>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Creating…")}
            >
              <.icon name="hero-check" class="w-4 h-4" /> {gettext("Save Collection")}
            </button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    if context do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    type_options =
      [{gettext("All types"), ""}] ++
        Enum.map(DranWeb.PageTypes.all(), fn {type, _} -> {String.capitalize(type), type} end)

    status_options = [
      {gettext("Any status"), ""},
      {gettext("Backlog"), "backlog"},
      {gettext("This Week"), "this_week"},
      {gettext("Today"), "today"},
      {gettext("In Progress"), "in_progress"},
      {gettext("Done"), "done"},
      {gettext("Cancelled"), "cancelled"}
    ]

    {:ok,
     assign(socket,
       context: context,
       active_nav: "collections",
       collection: nil,
       results: [],
       result_count: 0,
       query_tags: [],
       collections: [],
       type_options: type_options,
       status_options: status_options,
       form: %{}
     )}
  end

  def handle_params(params, _url, socket) do
    {socket, _context} = Auth.resolve_workspace(socket, params)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    collections =
      if socket.assigns.context do
        Collections.list_collections(socket.assigns.context.id)
      else
        []
      end

    assign(socket, collections: collections, page_title: gettext("Smart Collections"))
  end

  defp apply_action(socket, :show, %{"slug" => slug}) do
    context = socket.assigns.context

    if context do
      case Collections.get_collection_by_slug(slug, context.id) do
        nil ->
          push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/collections")

        collection ->
          filters = collection.filters || %{}
          results = execute_filters(filters, context.id)
          query_tags = format_filters(collection)

          assign(socket,
            collection: collection,
            results: results,
            result_count: length(results),
            query_tags: query_tags,
            page_title: collection.name
          )
      end
    else
      push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/collections")
    end
  end

  defp apply_action(socket, :new, params) do
    form = %{
      "name" => params["name"] || "",
      "slug" => "",
      "description" => params["description"] || "",
      "type" => params["type"] || "",
      "tag" => params["tag"] || "",
      "status" => params["status"] || "",
      "owner" => params["owner"] || ""
    }

    assign(socket, form: form, page_title: gettext("New Smart Collection"))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  def handle_event("show_page", %{"slug" => slug, "type" => type}, socket) do
    path = "/#{DranWeb.PageTypes.path(type)}/#{slug}"
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: "/search?q=#{URI.encode_www_form(slug)}")}
  end

  def handle_event("delete_collection", _params, socket) do
    collection = socket.assigns.collection
    context = socket.assigns.context

    if collection && context do
      case Collections.delete_collection(collection) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Smart collection deleted."))
           |> push_navigate(to: ~p"/#{socket.assigns[:workspace_slug]}/collections")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete collection."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_collection", params, socket) do
    context = socket.assigns.context

    cond do
      context == nil ->
        {:noreply, put_flash(socket, :error, gettext("No context available."))}

      String.trim(params["name"] || "") == "" ->
        {:noreply, put_flash(socket, :error, gettext("Name is required."))}

      true ->
        filters =
          %{
            "type" => params["type"],
            "status" => params["status"],
            "tag" => params["tag"],
            "owner" => params["owner"]
          }
          |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
          |> Map.new()

        slug = params["slug"]
        slug = if slug in ["", nil], do: Dran.Slug.slugify(params["name"]), else: slug

        attrs = %{
          "workspace_id" => context.id,
          "name" => params["name"],
          "slug" => slug,
          "description" => params["description"],
          "filters" => filters
        }

        case Collections.create_collection(attrs) do
          {:ok, collection} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Smart collection created."))
             |> push_navigate(
               to: ~p"/#{socket.assigns[:workspace_slug]}/collections/#{collection.slug}"
             )}

          {:error, _changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not create collection. Slug may already exist.")
             )}
        end
    end
  end

  # ── PubSub ──

  def handle_info({:page_changed, _action, _page}, socket) do
    if socket.assigns.live_action == :show && socket.assigns.collection do
      context = socket.assigns.context
      filters = socket.assigns.collection.filters || %{}
      results = execute_filters(filters, context.id)
      {:noreply, assign(socket, results: results, result_count: length(results))}
    else
      if socket.assigns.live_action == :index && socket.assigns.context do
        collections = Collections.list_collections(socket.assigns.context.id)
        {:noreply, assign(socket, collections: collections)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ──

  defp execute_filters(filters, workspace_id) do
    opts = [workspace_id: workspace_id]

    opts =
      opts
      |> maybe_add_filter(:type, filters["type"])
      |> maybe_add_filter(:status, filters["status"])
      |> maybe_add_filter(:tag, filters["tag"])
      |> maybe_add_filter(:owner, filters["owner"])

    Knowledge.list_pages(opts)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_filters(collection) do
    (collection.filters || %{})
    |> Enum.reject(fn {_k, v} -> v == nil or v == "" end)
    |> Enum.map(fn {k, v} ->
      {format_label(k), v}
    end)
  end

  defp format_label("due_before"), do: gettext("due before")
  defp format_label("due_after"), do: gettext("due after")
  defp format_label("created_by"), do: gettext("created by")
  defp format_label(key), do: String.replace(key, "_", " ")
end
