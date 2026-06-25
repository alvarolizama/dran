defmodule DranWeb.PageNewLive do
  @moduledoc """
  Generic LiveView for creating a new page of any type.

  The page type is derived from the request path (e.g. `/notes/new`
  → "note"). Renders the shared markdown editor and delegates save
  to `DranWeb.PageEdit`.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.Plugs.Auth

  @type_to_path %{
    "note" => "notes",
    "concept" => "concepts",
    "entity" => "entities",
    "reference" => "references",
    "goal" => "goals",
    "plan" => "plans",
    "todo" => "todos",
    "artifact" => "artifacts",
    "comparison" => "comparisons"
  }

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
    >
      <div class="w-full mx-auto p-6">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold">
            New {DranWeb.PageComponents.type_label(@page_type)}
          </h1>
          <.link navigate={@back_path} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Back
          </.link>
        </div>

        <.form for={@form} id="page-new-form" phx-change="validate_page" phx-submit="save_page">
          <div class="space-y-5">
            <.input
              field={@form[:title]}
              type="text"
              label="Title"
              placeholder="Enter a title…"
              class="text-lg font-medium"
            />

            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:slug]}
                type="text"
                label="Slug"
                placeholder="auto from title"
                class="font-mono text-sm"
              />
              <.input
                field={@form[:summary]}
                type="text"
                label="Summary"
                placeholder="One-line description"
                class="text-sm"
              />
            </div>

            <.input
              field={@form[:tags]}
              type="text"
              label="Tags"
              placeholder="comma, separated, tags"
              class="text-sm"
            />

            <.meta_fields page_type={@page_type} meta={%{}} />

            <div>
              <span class="label mb-1 block text-sm font-medium text-base-content/70">Content</span>
              <.markdown_editor
                id="page-new-editor"
                body={@body}
                context_id={@context_id}
                save_status={@save_status}
              />
            </div>

            <div class="flex justify-end gap-2 pt-2 border-t border-base-300">
              <.link navigate={@back_path} class="btn btn-ghost btn-sm">Cancel</.link>
              <button type="submit" class="btn btn-primary btn-sm">
                <.icon name="hero-plus" class="size-4" /> Create
              </button>
            </div>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      if context do
        allow_upload(
          socket,
          :file,
          accept:
            ~w(image/* video/* audio/* application/pdf text/plain text/markdown text/csv text/html application/json application/zip),
          max_file_size: Dran.Uploads.max_size(),
          auto_upload: true,
          progress: &handle_progress/3
        )
      else
        socket
      end

    {:ok,
     assign(socket,
       context: context,
       page_type: "note",
       back_path: "/notes",
       form: nil,
       body: "",
       context_id: if(context, do: context.id),
       save_status: "idle"
     )}
  end

  def handle_params(_params, url, socket) do
    # Derive the page type from the URL path (e.g. "/notes/new" → "note")
    path = URI.parse(url).path || ""
    page_type = type_from_path(path)
    back_path = "/#{@type_to_path[page_type] || "notes"}"

    context = socket.assigns[:context]
    context_id = if context, do: context.id

    changeset =
      Brain.change_page(%Brain.Page{}, %{
        context_id: context_id,
        page_type: page_type,
        body: "",
        tags: []
      })

    {:noreply,
     assign(socket,
       page_type: page_type,
       back_path: back_path,
       form: to_form(changeset, as: :page),
       page_title: "New #{DranWeb.PageComponents.type_label(page_type)}"
     )}
  end

  def handle_event("validate_page", %{"page" => page_params}, socket) do
    context_id = if socket.assigns[:context], do: socket.assigns.context.id

    changeset =
      Brain.change_page(
        %Brain.Page{},
        page_params
        |> Map.put("context_id", context_id)
        |> Map.put("page_type", socket.assigns.page_type)
      )

    body = Map.get(page_params, "body", socket.assigns.body)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, as: :page), body: body)}
  end

  def handle_event("validate_page", params, socket) do
    handle_event("validate_page", %{"page" => params}, socket)
  end

  def handle_event("body_change", %{"body" => body}, socket) do
    {:noreply, assign(socket, body: body)}
  end

  def handle_event("save_page", %{"page" => page_params}, socket) do
    context_id = if socket.assigns[:context], do: socket.assigns.context.id
    page_type = socket.assigns.page_type

    page_params =
      page_params
      |> Map.put("context_id", context_id)
      |> Map.put("page_type", page_type)
      |> Map.put_new("body", socket.assigns.body)
      |> ensure_slug(context_id)

    case Brain.create_page(page_params) do
      {:ok, page} ->
        type_path = @type_to_path[page.page_type] || "notes"

        {:noreply,
         socket
         |> put_flash(:info, "Page created.")
         |> push_navigate(to: "/#{type_path}/#{page.slug}?edit=true")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :page))}
    end
  end

  def handle_event("save_page", params, socket) do
    handle_event("save_page", %{"page" => params}, socket)
  end

  def handle_event("request_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_complete", _params, socket) do
    {:noreply, socket}
  end

  # ── Helpers ──

  defp type_from_path(path) when is_binary(path) do
    # path is like "/notes/new" or "/concepts/new"
    case path |> String.trim("/") |> String.split("/") do
      [type_plural, "new" | _] ->
        type_to_page(type_plural)

      _ ->
        "note"
    end
  end

  defp type_to_page("notes"), do: "note"
  defp type_to_page("concepts"), do: "concept"
  defp type_to_page("entities"), do: "entity"
  defp type_to_page("references"), do: "reference"
  defp type_to_page("goals"), do: "goal"
  defp type_to_page("plans"), do: "plan"
  defp type_to_page("todos"), do: "todo"
  defp type_to_page("artifacts"), do: "artifact"
  defp type_to_page("comparisons"), do: "comparison"
  defp type_to_page(_), do: "note"

  defp ensure_slug(%{"slug" => slug} = params, _context_id) when is_binary(slug) and slug != "",
    do: params

  defp ensure_slug(params, context_id) do
    title = Map.get(params, "title", "")
    slug = unique_slug(title, context_id, Map.get(params, "page_type", "page"))
    Map.put(params, "slug", slug)
  end

  defp unique_slug(title, context_id, fallback_type) do
    base = slugify(title)
    base = if base == "", do: fallback_type, else: base
    ensure_unique_slug(base, context_id, 0)
  end

  defp ensure_unique_slug(base, context_id, attempt) do
    slug =
      if attempt == 0 do
        base
      else
        suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        "#{base}-#{suffix}"
      end

    if Brain.get_page_by_slug(slug, context_id) do
      ensure_unique_slug(base, context_id, attempt + 1)
    else
      slug
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
  end

  defp handle_progress(:file, _entry, socket) do
    {:noreply, socket}
  end
end
