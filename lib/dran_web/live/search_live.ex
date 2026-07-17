defmodule DranWeb.SearchLive do
  @moduledoc """
  LiveView for full-text search across the second brain.

  The sidebar search form submits a GET to `/search?q=...`, which loads
  this page with the query. The in-page form uses `phx-submit` for live
  updates without a full page reload.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.HTMLSanitizer
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @search_modes [
    {"auto", gettext("Auto")},
    {"fts", gettext("FTS")},
    {"semantic", gettext("Semantic")},
    {"hybrid", gettext("Hybrid")}
  ]

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       context: context,
       active_nav: "search",
       query: "",
       results: [],
       search_mode: "auto",
       search_modes: @search_modes
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params["q"] do
      q when is_binary(q) and q != "" ->
        {:ok, results} =
          Brain.search(q,
            context_id: socket.assigns.context.id,
            limit: 20,
            strategy: String.to_atom(socket.assigns.search_mode)
          )

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
          {:ok, r} =
            Brain.search(q,
              context_id: socket.assigns.context.id,
              limit: 20,
              strategy: String.to_atom(socket.assigns.search_mode)
            )

          r

        _ ->
          []
      end

    {:noreply, assign(socket, query: q, results: results)}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, search_mode: mode)}
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
        <h1 class="text-title mb-4">{gettext("Search")}</h1>

        <form phx-submit="search" class="mb-4">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="size-5 text-base-content/40 absolute left-4 top-1/2 -translate-y-1/2 pointer-events-none"
            />
            <.input
              id="search-q"
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search pages...")}
              class="focus-ring w-full py-3 pl-12 pr-4 text-base"
            />
          </div>
        </form>

        <div class="mb-6">
          <div
            role="group"
            aria-label={gettext("Search strategy")}
            class="inline-flex rounded-lg bg-base-200 p-1"
          >
            <button
              :for={{mode, label} <- @search_modes}
              type="button"
              phx-click="set_mode"
              phx-value-mode={mode}
              class={[
                "px-3 py-1.5 text-sm transition-colors rounded-md",
                if @search_mode == mode do
                  "bg-base-100 shadow-sm font-medium"
                else
                  "text-base-content/60 hover:text-base-content"
                end
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <div data-testid="search-results" class="space-y-2">
          <div :if={@query == ""} class="text-center py-16">
            <.icon name="hero-command-line" class="size-10 mx-auto text-base-content/30" />
            <p class="text-caption mt-3">
              {gettext("Try: 'elixir', 'meeting', tag:programming")}
            </p>
          </div>

          <div :if={@query != "" && @results == []} class="text-center py-16">
            <.icon name="hero-face-frown" class="size-10 mx-auto text-base-content/30" />
            <p class="text-caption mt-3">
              {gettext("No results for '%{query}'", query: @query)}
            </p>
            <p class="text-caption mt-1 text-base-content/40">
              {gettext("Check the spelling or try a different strategy above.")}
            </p>
          </div>

          <div
            :for={result <- @results}
            class="surface-2 lift p-3"
          >
            <div class="flex items-start gap-3">
              <div class="shrink-0 size-8 rounded-md bg-primary/10 flex items-center justify-center">
                <.icon name={PageTypes.icon(result.page_type)} class="size-4 text-primary" />
              </div>
              <div class="flex-1 min-w-0">
                <div class="font-medium text-sm break-words">{result.title}</div>
                <div
                  :if={result.excerpt && result.excerpt != ""}
                  class="mt-1 text-sm text-base-content/60 line-clamp-2"
                >
                  {raw(HTMLSanitizer.sanitize_to_string(result.excerpt))}
                </div>
                <div class="flex items-center gap-2 mt-1.5">
                  <span class="text-caption">
                    {PageTypes.label(result.page_type)}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
