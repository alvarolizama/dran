defmodule DranWeb.ChatWidget do
  @moduledoc """
  Floating Brain Copilot chat widget (LiveComponent).

  Rendered in the app layout alongside the CommandPalette. A floating action
  button (FAB) toggles a chat panel for conversing with the Brain.

  ## Image / audio uploads

  Users can attach images and audio files via a paperclip button. A colocated
  JS hook (`.ChatUpload`) reads the file client-side with `FileReader`, sends
  the base64 data to the server via `pushEventTo`, and the server processes
  images with `Dran.Inference.Vision` and audio with `Dran.Inference.ASR`.
  The resulting description/transcript is injected into the message text.

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
     |> assign(:current_user, nil)
     |> assign(:attachments, [])
     |> assign(:processing_upload, false)
     |> assign(:current_step, nil)}
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

        # Subscribe to agent session broadcasts for real-time tool step feedback
        Phoenix.PubSub.subscribe(Dran.PubSub, "agents:all")

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
              <span
                :if={@loading}
                class="inline-flex items-center gap-1 text-xs text-primary animate-pulse"
                role="status"
              >
                <.icon name="hero-sparkles" class="size-3.5" />
                {gettext("Thinking...")}
              </span>
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

            <div
              :if={@loading}
              class="flex justify-start"
              role="status"
              aria-live="polite"
            >
              <div class="bg-base-200 rounded-lg px-4 py-3 text-sm">
                <div class="flex items-center gap-2">
                  <div class="flex items-center gap-1">
                    <span class="w-2 h-2 rounded-full bg-base-content/50 animate-bounce [animation-delay:0ms]"></span>
                    <span class="w-2 h-2 rounded-full bg-base-content/50 animate-bounce [animation-delay:150ms]"></span>
                    <span class="w-2 h-2 rounded-full bg-base-content/50 animate-bounce [animation-delay:300ms]"></span>
                  </div>
                  <span class="text-xs text-base-content/60">
                    {if @current_step, do: @current_step, else: gettext("Thinking...")}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <%!-- Attachment preview area --%>
          <div
            :if={@attachments != [] or @processing_upload}
            class="flex flex-wrap gap-2 px-3 pt-2 border-t border-base-300"
          >
            <div
              :if={@processing_upload}
              class="flex items-center gap-1.5 badge badge-outline badge-sm animate-pulse"
            >
              <.icon name="hero-arrow-path" class="size-3" />
              <span class="text-xs">{gettext("Processing...")}</span>
            </div>
            <div
              :for={{ref, attachment} <- @attachments}
              class="flex items-center gap-1.5 badge badge-outline badge-sm"
              id={"#{@id}-attachment-#{ref}"}
            >
              <.icon
                name={if attachment.kind == :image, do: "hero-photo", else: "hero-musical-note"}
                class="size-3"
              />
              <span class="text-xs truncate max-w-32">{attachment.filename}</span>
              <button
                type="button"
                class="btn btn-ghost btn-xs px-0.5"
                phx-click="remove-attachment"
                phx-value-ref={ref}
                phx-target={@myself}
                title={gettext("Remove")}
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </div>
          </div>

          <%!-- Input --%>
          <form
            id={"#{@id}-form"}
            phx-submit="send"
            phx-target={@myself}
            class="flex items-center gap-2 p-3 border-t border-base-300"
          >
            <div
              id={"#{@id}-upload"}
              phx-hook=".ChatUpload"
              class="contents"
            >
              <input
                type="file"
                id={"#{@id}-file-input"}
                class="hidden"
                accept="image/*,audio/*"
                data-chat-upload-target={@myself}
                phx-update="ignore"
              />
              <button
                type="button"
                class="btn btn-sm btn-ghost btn-circle"
                onclick={"document.getElementById('#{@id}-file-input').click(); return false;"}
                disabled={@loading or @processing_upload}
                title={gettext("Attach image or audio")}
              >
                <.icon name="hero-paper-clip" class="size-4" />
              </button>
            </div>
            <input
              type="text"
              name="text"
              value={@input}
              phx-change="input_change"
              phx-debounce="200"
              phx-target={@myself}
              placeholder={
                if @loading,
                  do: gettext("Waiting for response..."),
                  else: gettext("Type a message...")
              }
              class={[
                "input input-sm input-bordered flex-1 focus:ring-1 focus:ring-primary",
                @loading && "opacity-60"
              ]}
              autocomplete="off"
              disabled={@loading}
            />
            <button type="submit" class="btn btn-sm btn-primary" disabled={@loading}>
              <.icon name="hero-paper-airplane" class="size-4" />
            </button>
          </form>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatUpload">
        export default {
          mounted() {
            const input = this.el.querySelector('input[type="file"]');
            if (!input) return;

            input.addEventListener("change", (e) => {
              const file = e.target.files[0];
              if (!file) return;

              const reader = new FileReader();
              reader.onload = (ev) => {
                // ev.target.result is "data:<mime>;base64,<data>"
                const result = ev.target.result;
                const base64 = result.split(",")[1] || "";
                const target = input.getAttribute("data-chat-upload-target");

                this.pushEventTo(target, "upload_attachment", {
                  filename: file.name,
                  mime_type: file.type,
                  data: base64
                });
              };
              reader.onerror = () => {
                // Silently reset on read error
              };
              reader.readAsDataURL(file);

              // Reset so the same file can be selected again
              e.target.value = "";
            });
          }
        }
      </script>
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

  def handle_event(
        "upload_attachment",
        %{"filename" => filename, "mime_type" => mime, "data" => data},
        socket
      ) do
    socket = assign(socket, :processing_upload, true)

    # Process synchronously — in tests the fallback is instant, and in prod
    # the Vision/ASR calls are external HTTP requests that benefit from the
    # user seeing immediate feedback (processing indicator) before the result.
    result = process_attachment(filename, mime, data)

    socket =
      case result do
        {:ok, ref, attachment} ->
          socket
          |> assign(:attachments, socket.assigns.attachments ++ [{ref, attachment}])
          |> assign(:processing_upload, false)

        {:error, _reason} ->
          assign(socket, :processing_upload, false)
      end

    {:noreply, socket}
  end

  def handle_event("remove-attachment", %{"ref" => ref}, socket) do
    attachments = Enum.reject(socket.assigns.attachments, fn {r, _} -> r == ref end)
    {:noreply, assign(socket, :attachments, attachments)}
  end

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)
    attachments = socket.assigns.attachments

    if text == "" and attachments == [] do
      {:noreply, socket}
    else
      # Inject attachment descriptions into the message text
      attachment_texts =
        attachments
        |> Enum.map(fn {_ref, att} -> att.text end)
        |> Enum.filter(&(&1 != ""))

      full_text =
        [text | attachment_texts]
        |> Enum.filter(&(&1 != ""))
        |> Enum.join("\n\n")

      user_msg = %{"role" => "user", "content" => full_text, "sources" => []}
      messages = socket.assigns.messages ++ [user_msg]
      pid = socket.assigns[:chat_pid]
      page_slug = socket.assigns[:page_slug]
      myself = socket.assigns.myself

      has_pid = not is_nil(pid)

      if has_pid and Code.ensure_loaded?(Dran.Chat.Server) do
        Task.start(fn ->
          case call_server(pid, full_text, page_slug) do
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
       |> assign(:attachments, [])
       |> assign(:loading, has_pid)}
    end
  end

  def handle_event("suggestion", %{"text" => text}, socket) do
    handle_event("send", %{"text" => text}, socket)
  end

  # ---------------------------------------------------------------------------
  # PubSub (agent session broadcasts)
  # ---------------------------------------------------------------------------

  def handle_info({:agent, _session_id, {:step_started, step}}, socket) do
    tool = Map.get(step, :tool_name, "unknown")
    msg = gettext("Using tool: %{tool}", tool: tool)
    {:noreply, assign(socket, :current_step, msg)}
  end

  def handle_info({:agent, _session_id, {:step_completed, _step, _result}}, socket) do
    {:noreply, assign(socket, :current_step, nil)}
  end

  def handle_info({:agent, _session_id, {:session_done, _summary, _count}}, socket) do
    {:noreply, assign(socket, :current_step, nil)}
  end

  def handle_info(_other, socket) do
    {:noreply, socket}
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

  # Process an uploaded attachment (base64 data) and return a result tuple
  # suitable for send_update/2 via the `attachment_processed` update clause.
  #
  # Images are described via `Dran.Inference.Vision.describe/2`.
  # Audio files are transcribed via `Dran.Inference.ASR.transcribe/2`.
  # When inference is not configured, a fallback placeholder is used so the
  # attachment still appears in the message.
  defp process_attachment(filename, mime, base64_data) do
    ref = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    case Base.decode64(base64_data) do
      {:ok, bytes} ->
        {kind, text} = process_bytes(filename, mime, bytes)
        {:ok, ref, %{filename: filename, kind: kind, text: text}}

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp process_bytes(filename, mime, bytes) do
    cond do
      String.starts_with?(mime, "image/") ->
        description = describe_image(bytes)
        {:image, "[Imagen: #{description}]"}

      String.starts_with?(mime, "audio/") ->
        transcript = transcribe_audio(bytes, filename)
        {:audio, "[Audio: #{transcript}]"}

      true ->
        {:other, "[Archivo: #{filename}]"}
    end
  end

  defp describe_image(bytes) do
    if Code.ensure_loaded?(Dran.Inference.Vision) and Dran.Inference.enabled?() do
      case Dran.Inference.Vision.describe(bytes) do
        {:ok, description} -> description
        {:error, _reason} -> "no se pudo procesar"
      end
    else
      "descripción no disponible"
    end
  rescue
    _ -> "no se pudo procesar"
  catch
    _, _ -> "no se pudo procesar"
  end

  defp transcribe_audio(bytes, filename) do
    if Code.ensure_loaded?(Dran.Inference.ASR) and Dran.Inference.enabled?() do
      case Dran.Inference.ASR.transcribe(bytes, filename) do
        {:ok, transcript} -> transcript
        {:error, _reason} -> "no se pudo transcribir"
      end
    else
      "transcripción no disponible"
    end
  rescue
    _ -> "no se pudo transcribir"
  catch
    _, _ -> "no se pudo transcribir"
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
