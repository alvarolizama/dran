defmodule DranWeb.IngestLive do
  @moduledoc """
  Web UI for ingesting URLs (articles, PDFs) into the second brain.
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full max-w-2xl mx-auto p-6 space-y-6">
          <div>
            <h1 class="text-2xl font-bold">Ingest URL</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Save a URL or download a file as a reference page.
            </p>
          </div>

          <.form for={@form} id="ingest-form" phx-submit="ingest">
            <div class="space-y-4">
              <.input
                field={@form[:url]}
                type="text"
                label="URL"
                placeholder="https://example.com/article or https://example.com/doc.pdf"
                class="w-full"
                autofocus
              />

              <div class="grid grid-cols-2 gap-4">
                <.input
                  field={@form[:slug]}
                  type="text"
                  label="Slug (optional)"
                  placeholder="auto from title"
                  class="w-full font-mono text-sm"
                />
                <.input
                  field={@form[:tags]}
                  type="text"
                  label="Tags (optional)"
                  placeholder="comma, separated"
                  class="w-full text-sm"
                />
              </div>

              <div class="flex justify-end gap-2 pt-2">
                <button type="submit" class="btn btn-primary btn-sm" disabled={@ingesting}>
                  <%= if @ingesting do %>
                    <span class="loading loading-spinner loading-xs"></span> Fetching…
                  <% else %>
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Ingest
                  <% end %>
                </button>
              </div>
            </div>
          </.form>

          <%= if @result do %>
            <div class="alert alert-success">
              <.icon name="hero-check-circle" class="size-5" />
              <div>
                <p class="font-medium">Ingested successfully</p>
                <p class="text-sm">
                  <.link navigate={@result_path} class="text-primary hover:underline">
                    {@result.title} ({@result.slug})
                  </.link>
                </p>
              </div>
            </div>
          <% end %>

          <%= if @error do %>
            <div class="alert alert-error">
              <.icon name="hero-exclamation-circle" class="size-5" />
              <div>
                <p class="font-medium">Ingest failed</p>
                <p class="text-sm">{@error}</p>
              </div>
            </div>
          <% end %>

          <div class="border-t border-base-300 pt-4">
            <h2 class="text-sm font-semibold text-base-content/60 mb-2">How it works</h2>
            <ul class="text-sm text-base-content/50 space-y-1">
              <li>
                • <strong>Web pages</strong>: saves the URL as a reference. The agent reads the content later.
              </li>
              <li>
                • <strong>Files (PDF, docs, images)</strong>: downloads and stores the file, creates a reference with a download link.
              </li>
              <li>• The source URL is preserved in the page metadata</li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       context: context,
       form: to_form(%{"url" => "", "slug" => "", "tags" => ""}, as: :ingest),
       ingesting: false,
       result: nil,
       result_path: nil,
       error: nil,
       page_title: "Ingest URL"
     )}
  end

  def handle_event("ingest", %{"ingest" => params}, socket) do
    context = socket.assigns.context

    if context do
      socket = assign(socket, ingesting: true, result: nil, error: nil)

      # Convert tags from comma-separated string to list
      params =
        Map.update(params, "tags", [], fn
          nil ->
            []

          "" ->
            []

          tags when is_binary(tags) ->
            tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

          tags ->
            tags
        end)

      case DranWeb.API.IngestController.do_ingest(context, params["url"], params) do
        {:ok, page} ->
          type_path = DranWeb.PageComponents.type_path(page.page_type)

          {:noreply,
           assign(socket,
             ingesting: false,
             result: page,
             result_path: "/#{type_path}/#{page.slug}"
           )
           |> put_flash(:info, "Ingested '#{page.title}'")}

        {:error, reason} ->
          {:noreply,
           assign(socket, ingesting: false, error: reason)
           |> put_flash(:error, "Ingest failed")}
      end
    else
      {:noreply, put_flash(socket, :error, "No context selected")}
    end
  end
end
