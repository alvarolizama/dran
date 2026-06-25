defmodule DranWeb.EnrichHandler do
  @moduledoc """
  Shared LiveView handler for the "Enrich" button.

  Usage in a LiveView:

      import DranWeb.EnrichHandler

      def handle_event("enrich_page", %{"slug" => slug}, socket) do
        handle_enrich(slug, socket)
      end
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Dran.{Brain, TagEnricher}

  def handle_enrich(slug, socket) do
    context_id = socket.assigns.context.id

    case Brain.get_page_by_slug(slug, context_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Page not found")}

      page ->
        socket = put_flash(socket, :info, "Enriching page with web search...")

        Task.Supervisor.start_child(Dran.Relations.TaskSupervisor, fn ->
          case TagEnricher.enrich_page(page) do
            {:ok, _} ->
              send(socket.root_pid, {:enriched, slug})

            {:error, reason} ->
              send(socket.root_pid, {:enrich_failed, slug, reason})
          end
        end)

        {:noreply, socket}
    end
  end
end
