defmodule DranWeb.PageNewLive do
  @moduledoc """
  Generic LiveView for creating a new page of any type.

  The page type is derived from the request path (e.g. `/notes/new`
  → "note"). Renders the shared markdown editor and delegates save
  to `DranWeb.PageEdit`.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

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
      <div class="w-full mx-auto p-6">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold">
            {new_label(@page_type)}
          </h1>
          <.link navigate={@back_path} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
          </.link>
        </div>

        <.form for={@form} id="page-new-form" phx-change="validate_page" phx-submit="save_page">
          <div class="flex gap-6 items-start">
            <%!-- Left: title + editor --%>
            <div class="flex-1 min-w-0 space-y-5">
              <.input
                field={@form[:title]}
                type="text"
                label={gettext("Title")}
                placeholder={gettext("Enter a title…")}
                class="text-lg font-medium"
              />

              <div>
                <span class="label mb-1 block text-sm font-medium text-base-content/70">
                  {gettext("Content")}
                </span>
                <.markdown_editor
                  id="page-new-editor"
                  body={@body}
                  context_id={@context_id}
                  save_status={@save_status}
                />
              </div>
            </div>

            <%!-- Right: attributes sidebar --%>
            <aside class="w-80 shrink-0 space-y-4 surface-2 rounded-2xl p-5 sticky top-6">
              <h2 class="text-sm font-semibold text-base-content/70 uppercase tracking-wider">
                {gettext("Atributos")}
              </h2>

              <.input
                field={@form[:tags]}
                type="text"
                label={gettext("Tags")}
                placeholder={gettext("comma, separated, tags")}
                class="text-sm"
              />

              <.input
                field={@form[:summary]}
                type="text"
                label={gettext("Summary")}
                placeholder={gettext("One-line description")}
                class="text-sm"
              />

              <.meta_fields page_type={@page_type} meta={@meta} context_id={@context_id} />
            </aside>
          </div>

          <div class="flex justify-end gap-2 pt-4 mt-4 border-t border-base-300">
            <.link navigate={@back_path} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="size-4" /> {gettext("Create")}
            </button>
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
       meta: %{},
       context_id: if(context, do: context.id),
       save_status: "idle",
       active_nav: "notes"
     )}
  end

  def handle_params(_params, url, socket) do
    # Derive the page type from the URL path (e.g. "/notes/new" → "note")
    path = URI.parse(url).path || ""
    page_type = type_from_path(path)
    back_path = "/#{PageTypes.path(page_type)}"

    context = socket.assigns[:context]
    context_id = if context, do: context.id

    meta = default_meta_for(page_type)

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
       meta: meta,
       page_title: gettext("New %{type}", type: PageTypes.label(page_type)),
       active_nav: PageTypes.path(page_type)
     )}
  end

  def handle_event("validate_page", %{"page" => page_params} = _event, socket) do
    context_id = if socket.assigns[:context], do: socket.assigns.context.id

    # Carry smart-default meta through live validation so the meta_fields
    # component keeps showing the prefilled values until the user changes
    # them. Once the form submits a meta map, that takes precedence.
    base_meta = socket.assigns[:meta] || %{}
    meta = Map.merge(base_meta, meta_from_params(page_params))

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
     |> assign(form: to_form(changeset, as: :page), body: body, meta: meta)}
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
        type_path = PageTypes.path(page.page_type)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Page created."))
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

  # Gender-aware "Nuevo/Nueva <tipo>" heading — several type labels are
  # feminine in Spanish (Nota, Tarea, Referencia, Entidad, Comparación, Consulta).
  defp new_label(page_type) do
    label = PageTypes.label(page_type)

    feminine =
      Enum.map(
        ["Note", "Todo", "Reference", "Entity", "Comparison", "Query"],
        &Gettext.gettext(DranWeb.Gettext, &1)
      )

    if label in feminine do
      gettext("Nueva %{type}", type: label)
    else
      gettext("Nuevo %{type}", type: label)
    end
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
  defp type_to_page("projects"), do: "project"
  defp type_to_page("plans"), do: "plan"
  defp type_to_page("todos"), do: "todo"
  defp type_to_page("artifacts"), do: "artifact"
  defp type_to_page("comparisons"), do: "comparison"
  defp type_to_page("queries"), do: "query"
  defp type_to_page(_), do: "note"

  # Smart defaults per page type for the :new form. These prefill the meta
  # map so the user does not have to pick the common starting state. The
  # slug is NOT set here — Brain.ensure_title_and_slug/1 derives it from
  # the title on save.
  defp default_meta_for("note") do
    %{"kind" => "thought", "date" => Date.utc_today() |> Date.to_string()}
  end

  defp default_meta_for("todo") do
    %{"kanban_status" => "backlog", "priority" => "medium"}
  end

  defp default_meta_for(type) when type in ["project", "plan"] do
    %{"status" => "draft"}
  end

  defp default_meta_for("goal") do
    %{"health_source" => "derived"}
  end

  defp default_meta_for(_), do: %{}

  # Merge any meta values submitted in the form params on top of the
  # smart defaults, so user edits win over defaults.
  defp meta_from_params(%{"meta" => form_meta}) when is_map(form_meta) do
    form_meta
    |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
    |> Map.new()
  end

  defp meta_from_params(_), do: %{}

  defp ensure_slug(%{"slug" => slug} = params, _context_id)
       when is_binary(slug) and slug != "",
       do: params

  defp ensure_slug(params, context_id) do
    title = Map.get(params, "title", "")
    slug = Dran.Slug.generate(title, context_id, Map.get(params, "page_type", "page"))
    Map.put(params, "slug", slug)
  end

  defp handle_progress(:file, _entry, socket) do
    {:noreply, socket}
  end
end
