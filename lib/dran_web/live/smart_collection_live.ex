defmodule DranWeb.SmartCollectionLive do
  @moduledoc """
  LiveView for Smart Collections.

  A smart collection is a page with `page_type: "query"` whose `meta` field
  contains a `"query"` map with filter criteria. When viewed, the collection
  parses the query, calls `Brain.list_pages/1` with the resulting filters, and
  renders the matching pages as a live-updating list.

  ## Routes

  - `:index` — `/collections` — lists all saved smart collections
  - `:show`  — `/collections/:slug` — renders the live query results

  The `:show` view subscribes to the context's PubSub topic so that
  whenever any page is created, updated, or deleted, the collection
  re-executes its query and refreshes the results in real time.

  ## Saving

  The `:new` action provides a form for saving a set of filters as a
  new smart collection. Filter params can arrive via URL query string
  (e.g. from the "Save as Smart Collection" button on search results
  or filtered list pages).
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.SmartCollection
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
      context_slug={@context_slug}
      contexts={@contexts}
    >
      <div :if={@live_action == :index} class="p-6 overflow-y-auto w-full">
        <div class="flex items-center justify-between mb-4">
          <div>
            <h1 class="text-2xl font-bold">Smart Collections</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Saved queries that auto-update as your brain changes
            </p>
          </div>
          <.link navigate={~p"/collections/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> New Collection
          </.link>
        </div>

        <div :if={@collections == []} class="text-center py-16">
          <.icon name="hero-folder-plus" class="w-16 h-16 mx-auto mb-4 text-base-content/30" />
          <h2 class="text-lg font-semibold text-base-content/70">
            {gettext("No smart collections yet.")}
          </h2>
          <p class="text-sm text-base-content/50 mt-1 max-w-sm mx-auto">
            {gettext("Save a set of filters from search or any page list to create one.")}
          </p>
          <.link navigate={~p"/collections/new"} class="btn btn-primary btn-sm mt-4">
            <.icon name="hero-plus" class="w-4 h-4" />
            {gettext("Create your first collection")}
          </.link>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <.link
            :for={collection <- @collections}
            navigate={~p"/collections/#{collection.slug}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition cursor-pointer"
          >
            <div class="card-body p-5">
              <div class="flex items-center gap-2 mb-1">
                <.icon name="hero-funnel" class="w-5 h-5 text-primary/70" />
                <h2 class="card-title text-lg">{collection.title}</h2>
              </div>
              <p :if={collection.summary} class="text-sm text-base-content/60">
                {collection.summary}
              </p>
              <div class="flex flex-wrap gap-1.5 mt-3">
                <span
                  :for={{key, value} <- format_query_tags(collection)}
                  class="px-2 py-0.5 text-xs rounded-full bg-base-200 text-base-content/70"
                >
                  {key}: {value}
                </span>
                <span :if={format_query_tags(collection) == []} class="text-xs text-base-content/40">
                  All pages
                </span>
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
              <h1 class="text-2xl font-bold">{@collection.title}</h1>
            </div>
            <p :if={@collection.summary} class="text-sm text-base-content/50">
              {@collection.summary}
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/collections"} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> Back
            </.link>
            <button
              phx-click="delete_collection"
              data-confirm="Delete this smart collection? The pages it references will not be affected."
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4" /> Delete
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
            No filters — showing all pages in this context
          </span>
        </div>

        <div class="flex items-center justify-between mb-3">
          <span class="text-sm text-base-content/60">
            {@result_count} {if @result_count == 1, do: "page", else: "pages"}
          </span>
          <span class="text-xs text-base-content/40 flex items-center gap-1">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span> Live
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
            <div class="flex flex-wrap gap-1 mt-2">
              <span
                :for={tag <- Enum.take(page.tags || [], 5)}
                class="px-1.5 py-0.5 text-xs rounded bg-base-300"
              >
                {tag}
              </span>
            </div>
          </div>

          <div :if={@results == []} class="text-center py-12">
            <.icon
              name="hero-document-magnifying-glass"
              class="w-12 h-12 mx-auto mb-3 text-base-content/30"
            />
            <p class="text-sm text-base-content/50">
              {gettext("No pages match this collection's filters.")}
            </p>
          </div>
        </div>
      </div>

      <div :if={@live_action == :new} class="p-6 overflow-y-auto w-full max-w-2xl mx-auto">
        <h1 class="text-2xl font-bold mb-6">New Smart Collection</h1>

        <form phx-submit="create_collection" class="space-y-5">
          <.input
            id="collection-title"
            name="title"
            type="text"
            label="Title"
            value={@form["title"]}
            placeholder="e.g. Urgent Todos This Week"
            required
          />

          <.input
            id="collection-slug"
            name="slug"
            type="text"
            label="Slug"
            value={@form["slug"]}
            placeholder="auto-generated from title if blank"
            class="font-mono text-sm"
          />

          <.input
            id="collection-summary"
            name="summary"
            type="text"
            label="Summary"
            value={@form["summary"]}
            placeholder="One-line description"
          />

          <div class="border-t border-base-300 pt-5">
            <h3 class="text-sm font-semibold text-base-content/70 mb-3">Filters</h3>
            <div class="grid grid-cols-2 gap-4">
              <.input
                id="filter-type"
                name="type"
                type="select"
                label="Page type"
                value={@form["type"]}
                options={@type_options}
              />
              <.input
                id="filter-status"
                name="status"
                type="select"
                label="Status (kanban)"
                value={@form["status"]}
                options={@status_options}
              />
              <.input
                id="filter-tag"
                name="tag"
                type="text"
                label="Tag"
                value={@form["tag"]}
                placeholder="any tag"
              />
              <.input
                id="filter-owner"
                name="owner"
                type="text"
                label="Owner"
                value={@form["owner"]}
                placeholder="any owner"
              />
              <.input
                id="filter-due-after"
                name="due_after"
                type="date"
                label="Due after"
                value={@form["due_after"]}
              />
              <.input
                id="filter-due-before"
                name="due_before"
                type="date"
                label="Due before"
                value={@form["due_before"]}
              />
            </div>
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/collections"} class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </.link>
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
      [{"All types", ""}] ++
        Enum.map(Brain.page_types(), fn t -> {String.capitalize(t), t} end)

    status_options = [
      {"Any status", ""},
      {"Backlog", "backlog"},
      {"This Week", "this_week"},
      {"Today", "today"},
      {"In Progress", "in_progress"},
      {"Done", "done"},
      {"Cancelled", "cancelled"}
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
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    collections =
      if socket.assigns.context do
        SmartCollection.list_all(socket.assigns.context.id)
      else
        []
      end

    assign(socket, collections: collections, page_title: "Smart Collections")
  end

  defp apply_action(socket, :show, %{"slug" => slug}) do
    context = socket.assigns.context

    if context do
      case SmartCollection.get_by_slug(slug, context.id) do
        nil ->
          push_navigate(socket, to: ~p"/collections")

        collection ->
          query = get_in(collection.meta, ["query"]) || %{}
          results = SmartCollection.execute(query, context.id)
          query_tags = format_query_tags(collection)

          assign(socket,
            collection: collection,
            results: results,
            result_count: length(results),
            query_tags: query_tags,
            page_title: collection.title
          )
      end
    else
      push_navigate(socket, to: ~p"/collections")
    end
  end

  defp apply_action(socket, :new, params) do
    # Pre-fill filter fields from URL params (e.g. from "Save as Smart Collection" button)
    form = %{
      "title" => params["title"] || "",
      "slug" => "",
      "summary" => "",
      "type" => params["type"] || "",
      "tag" => params["tag"] || "",
      "status" => params["status"] || "",
      "owner" => params["owner"] || "",
      "due_before" => params["due_before"] || "",
      "due_after" => params["due_after"] || ""
    }

    assign(socket, form: form, page_title: "New Smart Collection")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  def handle_event("show_page", %{"slug" => slug, "type" => type}, socket) do
    path = "/#{DranWeb.PageTypes.path(type)}/#{slug}"
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    # Fallback: navigate to search by slug if type unknown
    {:noreply, push_navigate(socket, to: "/search?q=#{URI.encode_www_form(slug)}")}
  end

  def handle_event("delete_collection", _params, socket) do
    collection = socket.assigns.collection
    context = socket.assigns.context

    if collection && context do
      case Brain.delete_page(collection) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Smart collection deleted.")
           |> push_navigate(to: ~p"/collections")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not delete collection.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_collection", params, socket) do
    context = socket.assigns.context

    cond do
      context == nil ->
        {:noreply, put_flash(socket, :error, "No context available.")}

      String.trim(params["title"] || "") == "" ->
        {:noreply, put_flash(socket, :error, "Title is required.")}

      true ->
        attrs = %{
          "context_id" => context.id,
          "title" => params["title"],
          "slug" => params["slug"],
          "summary" => params["summary"],
          "query" => params
        }

        case SmartCollection.create(attrs) do
          {:ok, page} ->
            {:noreply,
             socket
             |> put_flash(:info, "Smart collection created.")
             |> push_navigate(to: ~p"/collections/#{page.slug}")}

          {:error, _changeset} ->
            {:noreply,
             put_flash(socket, :error, "Could not create collection. Slug may already exist.")}
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # PubSub — auto-refresh on any page change in the context
  # ──────────────────────────────────────────────────────────────────────────

  def handle_info({:page_changed, _action, _page}, socket) do
    # Re-execute the query if we're on a collection show view
    if socket.assigns.live_action == :show && socket.assigns.collection do
      context = socket.assigns.context
      query = get_in(socket.assigns.collection.meta, ["query"]) || %{}
      results = SmartCollection.execute(query, context.id)

      {:noreply, assign(socket, results: results, result_count: length(results))}
    else
      # On index view, refresh the collection list
      if socket.assigns.live_action == :index && socket.assigns.context do
        collections = SmartCollection.list_all(socket.assigns.context.id)
        {:noreply, assign(socket, collections: collections)}
      else
        {:noreply, socket}
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp format_query_tags(collection) do
    query = get_in(collection.meta, ["query"]) || %{}

    query
    |> Enum.reject(fn {_k, v} -> v == nil or v == "" end)
    |> Enum.map(fn {k, v} ->
      {format_label(k), format_value(v)}
    end)
  end

  defp format_label("due_before"), do: "due before"
  defp format_label("due_after"), do: "due after"
  defp format_label("created_by"), do: "created by"
  defp format_label(key), do: String.replace(key, "_", " ")

  defp format_value("<today>"), do: "today"
  defp format_value(value), do: to_string(value)
end
