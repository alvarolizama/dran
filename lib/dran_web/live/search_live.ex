defmodule DranWeb.SearchLive do
  @moduledoc """
  LiveView for full-text search across the second brain.

  The sidebar search form submits a GET to `/search?q=...`, which loads
  this page with the query. The in-page form uses `phx-submit` for live
  updates without a full page reload.
  """
  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       context: context,
       active_nav: "search",
       query: "",
       results: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params["q"] do
      q when is_binary(q) and q != "" ->
        {:ok, results} =
          Brain.search(q, context_id: socket.assigns.context.id, limit: 20)

        {:noreply, assign(socket, query: q, results: results)}

      _ ->
        {:noreply, assign(socket, query: "", results: [])}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    results =
      case q do
        q when is_binary(q) and q != "" ->
          {:ok, r} = Brain.search(q, context_id: socket.assigns.context.id, limit: 20)
          r

        _ ->
          []
      end

    {:noreply, assign(socket, query: q, results: results)}
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
      <div class="p-6 overflow-y-auto max-w-3xl">
        <h1 class="text-2xl font-bold mb-4">Search</h1>

        <form phx-submit="search" class="mb-6">
          <.input
            id="search-q"
            type="text"
            name="q"
            value={@query}
            placeholder="Search pages..."
          />
        </form>

        <div class="space-y-2">
          <div
            :for={{page, excerpt} <- @results}
            class="p-3 rounded-lg border border-base-300"
          >
            <div class="flex items-center justify-between">
              <span class="font-medium">{page.title}</span>
              <span class="text-xs text-base-content/50">{page.page_type}</span>
            </div>
            <div class="mt-1 text-sm text-base-content/70">{raw(excerpt)}</div>
          </div>

          <p :if={@query != "" && @results == []} class="text-base-content/60">
            No results found for "{@query}".
          </p>

          <p :if={@query == ""} class="text-base-content/60">
            Enter a query above to search across all pages.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
