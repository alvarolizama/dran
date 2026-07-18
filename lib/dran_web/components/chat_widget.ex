defmodule DranWeb.ChatWidget do
  @moduledoc """
  Floating Brain Copilot chat widget (LiveComponent).

  Rendered in the app layout alongside the CommandPalette. A floating action
  button (FAB) toggles a chat panel for conversing with the Brain.

  ## Optional assigns

    * `page_slug` — slug of the page being viewed (enables page-scoped context)
    * `page_type` — type of the current page (goal, note, ...) for suggestions
    * `view_type` — type of the current view (dashboard, ...) for suggestions

  When a `context_slug` and `current_user` are present and the
  `Dran.Chat.Supervisor` / `Dran.Chat.Server` modules are loaded, the widget
  starts (or reuses) a chat process and loads its history.
  """

  use DranWeb, :live_component

  alias DranWeb.PageTypes

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:messages, [])
     |> assign(:input, "")
     |> assign(:loading, false)
     |> assign(:chat_pid, nil)
     |> assign(:page_slug, nil)
     |> assign(:page_type, nil)
     |> assign(:view_type, nil)
     |> assign(:context_slug, nil)
     |> assign(:current_user, nil)}
  end

  @impl true
  def update(%{chat_reply: reply, sources: sources}, socket) do
    assistant_msg = %{"role" => "assistant", "content" => reply, "sources" => sources || []}
    {:ok, assign(socket, messages: socket.assigns.messages ++ [assistant_msg], loading: false)}
  end

  def update(%{chat_error: _reason}, socket) do
    # TODO: surface the error to the user as an inline message or flash
    {:ok, assign(socket, loading: false)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:context_slug, assigns[:context_slug])
      |> assign(:current_user, assigns[:current_user])
      |> assign(:page_slug, assigns[:page_slug])
      |> assign(:page_type, assigns[:page_type])
      |> assign(:view_type, assigns[:view_type])
      |> assign(:id, assigns[:id] || "chat-widget")

    socket = maybe_start_chat(socket, assigns)
    {:ok, socket}
  end

  defp maybe_start_chat(socket, assigns) do
    if Phoenix.LiveView.connected?(socket) and
         is_nil(socket.assigns[:chat_pid]) and
         not is_nil(assigns[:context_slug]) and
         Code.ensure_loaded?(Dran.Chat.Supervisor) do
      user = assigns[:current_user] || "anon"
      context_slug = assigns[:context_slug]

      try do
        pid = Dran.Chat.Supervisor.find_or_start(context_slug, user)
        history = Dran.Chat.Server.history(pid)
        assign(socket, chat_pid: pid, messages: history)
      rescue
        _ -> socket
      end
    else
      socket
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-target={@myself}>
      <button
        id={"#{@id}-fab"}
        type="button"
        class="fixed bottom-4 right-4 z-50 btn btn-primary btn-circle shadow-lg hover:scale-105 active:scale-95 transition-transform"
        phx-click="toggle"
        phx-target={@myself}
        aria-label={gettext("Open Brain Copilot")}
      >
        <.icon :if={!@open} name="hero-chat-bubble-left-right" class="size-5" />
        <.icon :if={@open} name="hero-x-mark" class="size-5" />
      </button>

      <div
        :if={@open}
        class="fixed bottom-20 right-4 z-50 w-96 max-w-[calc(100vw-2rem)] transition"
      >
        <div class="flex flex-col h-[32rem] rounded-xl border border-base-300 bg-base-100 shadow-2xl">
          <%!-- Header --%>
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
            <div class="flex items-center gap-2 min-w-0">
              <.icon name="hero-sparkles" class="size-4 text-primary shrink-0" />
              <span class="font-semibold text-sm truncate">{gettext("Brain Copilot")}</span>
              <span :if={@context_slug} class="badge badge-sm badge-ghost truncate">
                {@context_slug}
              </span>
            </div>
            <div class="flex items-center gap-1 shrink-0">
              <button
                id={"#{@id}-clear"}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="clear"
                phx-target={@myself}
                title={gettext("Clear conversation")}
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="close"
                phx-target={@myself}
                title={gettext("Close")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>

          <div
            :if={@page_slug}
            class="px-4 py-1.5 text-xs text-base-content/60 bg-base-200/50 border-b border-base-300 truncate"
          >
            {gettext("Chatting about")}: <span class="font-medium">{@page_slug}</span>
          </div>

          <%!-- Messages area --%>
          <div
            id={"#{@id}-messages"}
            class="flex-1 overflow-y-auto p-4 space-y-3"
            phx-hook="ScrollBottom"
          >
            <div :if={Enum.empty?(@messages)} class="space-y-4">
              <p class="text-sm text-base-content/50 text-center py-4">
                {gettext("Ask me anything about your second brain.")}
              </p>
              <div class="flex flex-wrap gap-2 justify-center">
                <button
                  :for={suggestion <- suggestions_for(@page_type, @view_type)}
                  type="button"
                  class="btn btn-sm btn-outline btn-primary"
                  phx-click="suggestion"
                  phx-value-text={suggestion}
                  phx-target={@myself}
                >
                  {suggestion}
                </button>
              </div>
            </div>

            <div :for={msg <- @messages} class="flex flex-col">
              <div class={["max-w-[85%] rounded-lg px-3 py-2 text-sm", message_classes(msg)]}>
                <p class="whitespace-pre-wrap break-words">{msg["content"]}</p>
                <div
                  :if={msg["role"] == "assistant" and length(msg["sources"] || []) > 0}
                  class="mt-2 flex flex-wrap gap-1"
                >
                  <span class="text-[10px] text-base-content/40 uppercase tracking-wide w-full">
                    {gettext("Sources")}
                  </span>
                  <.link
                    :for={source <- msg["sources"] || []}
                    navigate={source_path(source)}
                    class="badge badge-sm badge-ghost hover:badge-primary"
                  >
                    {source_title(source)}
                  </.link>
                </div>
              </div>
            </div>

            <div :if={@loading} class="flex justify-start">
              <div class="bg-base-200 rounded-lg px-4 py-3 text-sm">
                <span class="loading loading-dots loading-sm"></span>
              </div>
            </div>
          </div>

          <%!-- Input --%>
          <form
            id={"#{@id}-form"}
            phx-submit="send"
            phx-target={@myself}
            class="flex items-center gap-2 p-3 border-t border-base-300"
          >
            <input
              type="text"
              name="text"
              value={@input}
              phx-change="input_change"
              phx-debounce="200"
              phx-target={@myself}
              placeholder={gettext("Type a message...")}
              class="input input-sm input-bordered flex-1 focus:ring-1 focus:ring-primary"
              autocomplete="off"
            />
            <button type="submit" class="btn btn-sm btn-primary" disabled={@loading}>
              <.icon name="hero-paper-airplane" class="size-4" />
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle", _params, socket) do
    {:noreply, assign(socket, :open, !socket.assigns.open)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("clear", _params, socket) do
    pid = socket.assigns[:chat_pid]

    if not is_nil(pid) and Code.ensure_loaded?(Dran.Chat.Server) do
      try do
        Dran.Chat.Server.clear(pid)
      rescue
        _ -> :ok
      end
    end

    {:noreply, assign(socket, messages: [])}
  end

  def handle_event("input_change", %{"text" => text}, socket) do
    {:noreply, assign(socket, :input, text)}
  end

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      user_msg = %{"role" => "user", "content" => text, "sources" => []}
      messages = socket.assigns.messages ++ [user_msg]
      pid = socket.assigns[:chat_pid]
      page_slug = socket.assigns[:page_slug]
      myself = socket.assigns.myself

      has_pid = not is_nil(pid)

      if has_pid and Code.ensure_loaded?(Dran.Chat.Server) do
        Task.start(fn ->
          case call_server(pid, text, page_slug) do
            {:ok, reply, sources} ->
              send_update(myself, %{chat_reply: reply, sources: sources || []})

            {:error, reason} ->
              send_update(myself, %{chat_error: to_string(reason)})

            _ ->
              send_update(myself, %{chat_error: "unexpected"})
          end
        end)
      end

      {:noreply,
       socket
       |> assign(:messages, messages)
       |> assign(:input, "")
       |> assign(:loading, has_pid)}
    end
  end

  def handle_event("suggestion", %{"text" => text}, socket) do
    handle_event("send", %{"text" => text}, socket)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp call_server(pid, text, page_slug) do
    # When the Brain supports page-scoped context, pass page_slug as opts.
    # We check at runtime whether send_message/3 is available so the widget
    # works whether or not the Server has been extended with the 3-arg form.
    # Using apply/3 avoids the compile-time warning about the undefined
    # send_message/3 clause while preserving the dynamic dispatch.
    cond do
      page_slug && function_exported?(Dran.Chat.Server, :send_message, 3) ->
        apply(Dran.Chat.Server, :send_message, [pid, text, [page_slug: page_slug]])

      true ->
        Dran.Chat.Server.send_message(pid, text)
    end
  end

  defp message_classes(%{"role" => "user"}) do
    "self-end bg-primary text-primary-content"
  end

  defp message_classes(%{"role" => "assistant"}) do
    "self-start bg-base-200 text-base-content"
  end

  defp message_classes(_), do: "self-start bg-base-200 text-base-content"

  defp suggestions_for(page_type, view_type) do
    case {page_type, view_type} do
      {"goal", _} ->
        [gettext("List all todos"), gettext("What's the status?")]

      {"note", _} ->
        [gettext("Summarize this note"), gettext("Relate to other pages")]

      {_, "dashboard"} ->
        [gettext("What did I do this week?"), gettext("Which goals are red?")]

      _ ->
        [gettext("What can you help me with?"), gettext("Summarize recent activity")]
    end
  end

  defp source_path(%{"slug" => slug, "page_type" => type}) when is_binary(slug) do
    "/#{PageTypes.path(type)}/#{slug}"
  end

  defp source_path(%{"slug" => slug}) when is_binary(slug), do: "/notes/#{slug}"
  defp source_path(%{"path" => path}) when is_binary(path), do: path
  defp source_path(_), do: "#"

  defp source_title(%{"title" => title}), do: title
  defp source_title(%{"slug" => slug}), do: slug
  defp source_title(other) when is_binary(other), do: other
  defp source_title(_), do: gettext("Source")
end
