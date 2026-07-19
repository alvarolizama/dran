defmodule DranWeb.TagLive do
  @moduledoc """
  LiveView for tag pages: shows all pages with a given tag.
  Route: `/tags/:tag`
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       context: context
     )}
  end

  @impl true
  def handle_params(%{"tag" => tag}, _url, socket) do
    pages =
      if socket.assigns.context do
        Brain.list_pages(context_id: socket.assigns.context.id, tag: tag, limit: 200)
      else
        []
      end

    {:noreply,
     assign(socket,
       tag: tag,
       pages: pages,
       page_title: "##{tag}"
     )}
  end

  @impl true
  def handle_event("show_page", %{"slug" => slug}, socket) do
    page =
      Enum.find(socket.assigns.pages, fn p -> p.slug == slug end)

    if page do
      {:noreply, push_navigate(socket, to: DranWeb.PageTypes.page_show_path(page))}
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
    >
      <div class="p-6">
        <div class="flex items-center gap-2 mb-1">
          <.icon name="hero-hashtag" class="w-5 h-5 text-base-content/60" />
          <span class="text-sm text-base-content/60 uppercase tracking-wider">
            {gettext("Tag")}
          </span>
        </div>
        <h1 class="text-title mb-1">{@tag}</h1>
        <p class="text-caption mb-6">
          {length(@pages)} {ngettext("page", "pages", length(@pages))} {gettext("with this tag")}
        </p>

        <.empty_state
          :if={@pages == []}
          icon="hero-tag"
          title={gettext("No pages found with this tag.")}
        />

        <div class="space-y-2">
          <div
            :for={page <- @pages}
            class="p-3 rounded-lg border border-base-300 hover:bg-base-200 cursor-pointer"
            phx-click="show_page"
            phx-value-slug={page.slug}
          >
            <div class="flex items-center gap-2">
              <.icon
                name={DranWeb.PageTypes.icon(page.page_type)}
                class="w-4 h-4 text-base-content/40"
              />
              <span class="font-medium">{page.title}</span>
            </div>
            <p :if={page.summary} class="text-sm text-base-content/60 mt-1">{page.summary}</p>
            <div class="flex gap-1 mt-2">
              <.link
                :for={t <- Enum.take(page.tags || [], 5)}
                navigate={"/tags/#{URI.encode_www_form(t)}"}
                class="px-1.5 py-0.5 text-xs rounded bg-base-300 hover:bg-base-200 transition"
                onclick="event.stopPropagation()"
              >
                {t}
              </.link>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
