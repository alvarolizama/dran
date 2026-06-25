defmodule DranWeb.IngestLive do
  @moduledoc """
  Web UI for ingesting URLs and files into the second brain.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.Ingest.Converter
  alias Dran.Uploads
  alias DranWeb.Plugs.Auth

  @supported_accept ~w(application/pdf
                       application/vnd.openxmlformats-officedocument.wordprocessingml.document
                       application/vnd.openxmlformats-officedocument.presentationml.presentation
                       application/vnd.ms-powerpoint
                       application/msword
                       text/plain)

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
            <h1 class="text-2xl font-bold">Ingest</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Save a URL or upload a PDF / Office document / text file as a searchable note.
            </p>
          </div>

          <.form
            for={@form}
            id="ingest-form"
            phx-submit="ingest"
            phx-change="validate_ingest"
            class="space-y-6"
          >
            <div class="tabs tabs-boxed bg-base-200 p-1">
              <button
                type="button"
                phx-click="switch_mode"
                phx-value-mode="url"
                class={[
                  "tab flex-1",
                  @mode == "url" && "tab-active"
                ]}
              >
                URL
              </button>
              <button
                type="button"
                phx-click="switch_mode"
                phx-value-mode="file"
                class={[
                  "tab flex-1",
                  @mode == "file" && "tab-active"
                ]}
              >
                File
              </button>
            </div>

            <div :if={@mode == "url"} class="space-y-4">
              <.input
                field={@form[:url]}
                type="url"
                label="URL"
                placeholder="https://example.com/article or https://example.com/doc.pdf"
                class="w-full"
                autofocus
              />
            </div>

            <div :if={@mode == "file"} class="space-y-4">
              <label class="block">
                <span class="block text-sm font-medium text-base-content/70 mb-1.5">
                  File (PDF, DOCX, PPTX, TXT)
                </span>
                <.live_file_input upload={@uploads.file} class="file-input w-full" />
              </label>
              <p :if={@upload_error} class="text-sm text-error">{@upload_error}</p>
              <div :for={entry <- @uploads.file.entries} class="space-y-2">
                <div class="flex items-center gap-2 text-sm">
                  <.icon name="hero-document" class="size-4" />
                  <span>{entry.client_name}</span>
                  <span class="text-base-content/50">
                    ({format_bytes(entry.client_size)})
                  </span>
                </div>
                <progress
                  :if={entry.progress < 100}
                  value={entry.progress}
                  max="100"
                  class="progress progress-primary w-full"
                >
                  {entry.progress}%
                </progress>
                <div :for={err <- upload_errors(@uploads.file, entry)} class="text-sm text-error">
                  {error_to_string(err)}
                </div>
              </div>
            </div>

            <.input
              field={@form[:tags]}
              type="text"
              label="Tags (optional)"
              placeholder="comma, separated"
              class="w-full text-sm"
            />

            <div class="flex justify-end gap-2 pt-2">
              <button type="submit" class="btn btn-primary btn-sm" disabled={@ingesting}>
                <%= if @ingesting do %>
                  <span class="loading loading-spinner loading-xs"></span> Ingesting…
                <% else %>
                  <.icon name="hero-arrow-down-tray" class="size-4" /> Ingest
                <% end %>
              </button>
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
                • <strong>Files (PDF, DOCX, PPTX, TXT)</strong>: stores the file and creates a searchable markdown note.
              </li>
              <li>• The source URL / file path is preserved in the page metadata.</li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      if context do
        allow_upload(socket, :file,
          accept: @supported_accept,
          max_file_size: Uploads.max_size(),
          auto_upload: false,
          progress: &handle_progress/3
        )
      else
        socket
      end

    {:ok,
     assign(socket,
       context: context,
       mode: "url",
       form: to_form(%{"url" => "", "tags" => ""}, as: :ingest),
       ingesting: false,
       upload_error: nil,
       result: nil,
       result_path: nil,
       error: nil,
       page_title: "Ingest"
     )}
  end

  def handle_event("switch_mode", %{"mode" => mode}, socket) when mode in ["url", "file"] do
    {:noreply, assign(socket, mode: mode, result: nil, error: nil)}
  end

  def handle_event("validate_ingest", _params, socket) do
    {:noreply, assign(socket, upload_error: nil, result: nil, error: nil)}
  end

  def handle_event("ingest", params, socket) do
    context = socket.assigns.context

    if context do
      socket = assign(socket, ingesting: true, result: nil, error: nil, upload_error: nil)
      params = normalize_tags(params)

      case ingest_for_mode(socket, socket.assigns.mode, params) do
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
           assign(socket, ingesting: false, error: to_error_string(reason))
           |> put_flash(:error, "Ingest failed")}
      end
    else
      {:noreply, put_flash(socket, :error, "No context selected")}
    end
  end

  defp ingest_for_mode(socket, "url", params) do
    Dran.Agent.Ingest.Utils.do_ingest(socket.assigns.context, params["url"], params)
  end

  defp ingest_for_mode(socket, "file", params) do
    context = socket.assigns.context

    case Phoenix.LiveView.Upload.consume_uploaded_entries(socket, :file, fn meta, entry ->
           consume_file_upload(socket, context, meta, entry)
         end) do
      [] ->
        {:error, "no file selected"}

      [result | _] ->
        case result do
          {:ok, page} ->
            maybe_update_tags(Map.get(params, "tags", []), page)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp consume_file_upload(socket, context, _meta, entry) do
    binary =
      Phoenix.LiveView.Upload.consume_uploaded_entry(socket, entry, fn %{path: path} ->
        File.read!(path)
      end)

    max_size = Uploads.max_size()

    if byte_size(binary) > max_size do
      {:error, "file too large (max #{max_size} bytes)"}
    else
      stored = Uploads.store(context.id, binary, entry.client_name, entry.client_type)
      title = Converter.title(entry.client_name)
      slug = slugify(title)

      case Converter.convert(entry.client_name, entry.client_type, binary) do
        {:ok, %{body: markdown}} ->
          page_attrs = %{
            context_id: context.id,
            title: title,
            slug: slug,
            body: markdown,
            page_type: "note",
            tags: [],
            meta: %{
              "kind" => "file",
              "source_url" => stored.storage_path,
              "filename" => stored.filename,
              "mime_type" => stored.mime_type,
              "size" => stored.size,
              "storage_path" => stored.storage_path,
              "sha256" => stored.sha256
            },
            kb_source_url: stored.storage_path,
            owner: "system",
            created_by: "system"
          }

          case Brain.create_page(page_attrs) do
            {:ok, page} ->
              {:ok, page}

            {:error, changeset} ->
              {:error, format_changeset_errors(changeset)}
          end

        {:error, reason} ->
          {:error, to_error_string(reason)}
      end
    end
  end

  defp normalize_tags(%{"ingest" => params} = _params) do
    params
    |> Map.update("tags", [], fn
      nil ->
        []

      "" ->
        []

      tags when is_binary(tags) ->
        tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      tags ->
        tags
    end)
  end

  defp normalize_tags(params), do: params

  defp maybe_update_tags([], page), do: {:ok, page}

  defp maybe_update_tags(tags, page) when is_list(tags) do
    case Brain.update_page(page, %{tags: tags}) do
      {:ok, page} -> {:ok, page}
      {:error, _} -> {:ok, page}
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
    |> case do
      "" -> "untitled"
      other -> other
    end
  end

  defp format_bytes(nil), do: "0 B"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp error_to_string(:too_large), do: "File too large"
  defp error_to_string(:too_many_files), do: "Too many files"
  defp error_to_string(:not_accepted), do: "File type not accepted"
  defp error_to_string(err), do: to_string(err)

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end

  defp to_error_string(reason) when is_binary(reason), do: reason
  defp to_error_string(reason), do: inspect(reason)

  defp handle_progress(:file, _entry, socket), do: {:noreply, socket}
end
