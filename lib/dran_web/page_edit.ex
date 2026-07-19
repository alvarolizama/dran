defmodule DranWeb.PageEdit do
  @moduledoc """
  Shared LiveView handlers for inline page editing and creation.

  Each page-type LiveView (NoteLive, ConceptLive, etc.) imports this module
  and delegates the common edit/create events here. The LiveView is still
  responsible for `handle_params`, `mount`, and any type-specific events.

  ## Required assigns

  LiveViews using these handlers must have in `socket.assigns`:

  - `:page` — the `%Dran.Brain.Page{}` being edited (for edit mode)
  - `:context` — the `%Dran.Brain.Context{}` (or nil)
  - `:page_type` — the page type string (e.g. `"note"`)

  ## Events handled

  - `"toggle_edit"` — toggle edit mode on the current page (push_patch with ?edit)
  - `"validate_page"` — validate form changes without saving
  - `"save_page"` — persist the page (create or update)
  - `"body_change"` — autosave body (debounced on the client)
  - `"request_upload"` — open the file picker for an embed upload
  - `"cancel_edit"` — exit edit mode
  """

  use Phoenix.LiveView

  use Gettext, backend: DranWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: DranWeb.Router,
    statics: DranWeb.static_paths()

  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2, push_patch: 2, push_event: 3]
  import Phoenix.Component, only: [to_form: 2, assign: 2]
  alias Phoenix.LiveView.Upload, as: Upload

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Summaries
  alias Dran.Uploads

  @doc """
  Handles inline editing events: toggle_edit, cancel_edit, validate_page,
  save_page, body_change (autosave), request_upload, and upload_complete.
  """
  def handle_event("toggle_edit", _params, %{assigns: %{page: page, page_type: type}} = socket) do
    editing = Map.get(socket.assigns, :editing, false)
    path = page_path(type, page.slug)

    socket = ensure_tag_suggestions(socket)

    if editing do
      {:noreply, push_patch(socket, to: path)}
    else
      {:noreply, push_patch(socket, to: path <> "?edit=true")}
    end
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot edit: no page loaded."))}
  end

  def handle_event("cancel_edit", _params, %{assigns: %{page: page, page_type: type}} = socket) do
    {:noreply, push_patch(socket, to: page_path(type, page.slug))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, push_navigate(socket, to: "/notes")}
  end

  def handle_event("suggest_summary", _params, %{assigns: %{page: %Page{}}} = socket) do
    apply_suggestion(socket, "summary", &Summaries.summarize_page/1)
  end

  def handle_event("suggest_summary", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot suggest summary: no page loaded."))}
  end

  def handle_event("suggest_tags", _params, %{assigns: %{page: %Page{}}} = socket) do
    apply_suggestion(socket, "tags", &Summaries.suggest_tags/1)
  end

  def handle_event("suggest_tags", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot suggest tags: no page loaded."))}
  end

  def handle_event("validate_page", %{"page" => page_params}, socket) do
    page = socket.assigns[:page] || %Page{}

    changeset =
      Brain.change_page(page, Map.put_new(page_params, "context_id", context_id(socket)))

    socket = assign(socket, form: to_form(changeset, as: :page))

    # Autosave metadata fields (title, summary, tags) for existing pages.
    # The slug is NOT autosaved — it only saves on Save button click.
    socket =
      case page do
        %Page{slug: slug} when is_binary(slug) ->
          save_params =
            page_params
            |> Map.drop(["slug"])
            |> Enum.reject(fn {k, v} -> String.starts_with?(k, "_") or v == nil end)
            |> Map.new()

          if map_size(save_params) > 0 do
            maybe_autosave_fields(socket, page, save_params)
          else
            socket
          end

        %Page{} ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("validate_page", params, socket) do
    handle_event("validate_page", %{"page" => params}, socket)
  end

  def handle_event(
        "field_change",
        %{"page" => %{"slug" => new_slug}},
        %{assigns: %{page: %Page{} = page}} = socket
      ) do
    context_id = context_id(socket)

    if is_nil(context_id) do
      {:noreply, put_flash(socket, :error, gettext("No context available for slug rename."))}
    else
      new_slug = String.trim(new_slug)
      old_slug = page.slug

      # Update the form's slug field
      changeset = Brain.change_page(page, %{"slug" => new_slug})
      socket = assign(socket, form: to_form(changeset, as: :page))

      if new_slug != "" and new_slug != old_slug do
        # Ensure uniqueness
        final_slug = ensure_unique_slug(new_slug, context_id, page.slug, 0)

        case Brain.update_page(page, %{slug: final_slug}) do
          {:ok, updated_page} ->
            {:noreply,
             socket
             |> assign(page: updated_page, save_status: "saved")
             |> push_patch(to: page_path(updated_page.page_type, final_slug) <> "?edit=true")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset, as: :page))}
        end
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("field_change", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_page", %{"page" => page_params}, socket) do
    page = socket.assigns[:page]
    page_type = socket.assigns.page_type
    context_id = context_id(socket)

    page_params =
      page_params
      |> Map.put_new("context_id", context_id)
      |> Map.put_new("page_type", page_type)
      |> ensure_slug(context_id, page)

    if page do
      update_page_with_relink(socket, page, page_params, context_id)
    else
      create_page(socket, page_params)
    end
  end

  def handle_event("save_page", params, socket) do
    handle_event("save_page", %{"page" => params}, socket)
  end

  def handle_event("body_change", %{"body" => body}, %{assigns: %{page: %Page{} = page}} = socket) do
    if body == page.body do
      {:noreply, assign(socket, save_status: "saved")}
    else
      case Brain.update_page(page, %{body: body}) do
        {:ok, updated_page} ->
          rendered_body =
            DranWeb.PageComponents.render_markdown(updated_page.body,
              context_id: updated_page.context_id,
              inline_links: Map.get(updated_page.meta || %{}, "inline_links", [])
            )

          {:noreply,
           socket
           |> assign(page: updated_page, save_status: "saved", rendered_body: rendered_body)}

        {:error, _changeset} ->
          {:noreply, assign(socket, save_status: "idle")}
      end
    end
  end

  def handle_event("body_change", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("delete_page", _params, %{assigns: %{page: %Page{} = page}} = socket) do
    case Brain.delete_page(page) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Page deleted."))
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete page."))}
    end
  end

  def handle_event("delete_page", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot delete: no page loaded."))}
  end

  def handle_event("archive_page", _params, %{assigns: %{page: %Page{} = page}} = socket) do
    case Brain.archive_page(page) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(page: updated)
         |> put_flash(:info, gettext("Page archived."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not archive page."))}
    end
  end

  def handle_event("archive_page", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot archive: no page loaded."))}
  end

  def handle_event("unarchive_page", _params, %{assigns: %{page: %Page{} = page}} = socket) do
    case Brain.unarchive_page(page) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(page: updated)
         |> put_flash(:info, gettext("Page restored from archive."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not unarchive page."))}
    end
  end

  def handle_event("unarchive_page", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot unarchive: no page loaded."))}
  end

  def handle_event("request_upload", _params, socket) do
    upload = socket.assigns[:upload]

    if upload do
      # The client will open the file input; we just acknowledge.
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("Uploads are not configured."))}
    end
  end

  def handle_event("upload_complete", _params, %{assigns: %{upload: _upload}} = socket) do
    context_id = context_id(socket)

    consumed =
      Upload.consume_uploaded_entries(socket, :file, fn _meta, entry ->
        filename = entry.client_name
        client_type = entry.client_type

        binary =
          Upload.consume_uploaded_entry(socket, entry, fn %{path: path} ->
            File.read!(path)
          end)

        store_file_and_create_artifact(socket, context_id, binary, filename, client_type)
      end)
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    if consumed != [] do
      embeds_md = Enum.map(consumed, &"![[#{&1.slug}|#{&1.title}]]") |> Enum.join("\n")
      {:noreply, push_event(socket, "insert_embeds", %{markdown: embeds_md})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("upload_complete", _params, socket) do
    {:noreply, socket}
  end

  # ── Helpers ──

  defp create_page(socket, page_params) do
    case Brain.create_page(page_params) do
      {:ok, page} ->
        type = page.page_type

        {:noreply,
         socket
         |> put_flash(:info, gettext("Page created."))
         |> push_navigate(to: page_path(type, page.slug) <> "?edit=true")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :page))}
    end
  end

  defp update_page_with_relink(socket, %Page{} = page, page_params, _context_id) do
    case Brain.update_page(page, page_params) do
      {:ok, updated_page} ->
        socket =
          socket
          |> assign(page: updated_page, save_status: "saved")
          |> put_flash(:info, gettext("Saved."))

        {:noreply,
         push_patch(socket,
           to: page_path(updated_page.page_type, updated_page.slug) <> "?edit=true"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :page))}
    end
  end

  defp maybe_autosave_fields(socket, %Page{} = page, save_params) do
    # Only keep fields that are real Page fields and changed
    known_fields =
      ~w(title slug summary tags meta kb_confidence kb_source_url kb_contested owner created_by updated_by on_behalf_of)

    save_params =
      save_params
      |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "_") end)
      |> Enum.filter(fn {k, _v} -> k in known_fields end)
      |> Map.new()

    if map_size(save_params) == 0 do
      socket
    else
      changed =
        Enum.any?(save_params, fn {k, v} ->
          field = String.to_existing_atom(k)
          Map.get(page, field) != v
        end)

      if changed do
        case Brain.update_page(page, save_params) do
          {:ok, updated_page} ->
            socket
            |> assign(page: updated_page, save_status: "saved")

          {:error, _changeset} ->
            socket
        end
      else
        socket
      end
    end
  end

  defp context_id(socket) do
    case socket.assigns[:context] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp ensure_slug(params, context_id, nil) do
    if Map.get(params, "slug") in [nil, ""] do
      title = Map.get(params, "title", "")
      slug = unique_slug(title, context_id, Map.get(params, "page_type", "page"))
      Map.put(params, "slug", slug)
    else
      params
    end
  end

  defp ensure_slug(params, _context_id, %Page{} = _page), do: params

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

  defp ensure_unique_slug(base, context_id, original_slug, attempt) do
    slug =
      if attempt == 0 do
        base
      else
        suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        "#{base}-#{suffix}"
      end

    # The original slug belongs to the page being renamed, so it's valid
    if slug == original_slug or is_nil(Brain.get_page_by_slug(slug, context_id)) do
      slug
    else
      ensure_unique_slug(base, context_id, original_slug, attempt + 1)
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
  end

  defp page_path(type, slug) do
    "/#{DranWeb.PageTypes.path(type)}/#{slug}"
  end

  defp store_file_and_create_artifact(socket, context_id, binary, filename, client_type) do
    max_size = Uploads.max_size()

    if byte_size(binary) > max_size do
      put_flash(socket, :error, gettext("File too large (max %{max} bytes).", max: max_size))
      nil
    else
      stored = Uploads.store(context_id, binary, filename, client_type)

      slug = unique_slug(filename, context_id, "artifact")

      attrs = %{
        context_id: context_id,
        title: filename,
        slug: slug,
        page_type: "artifact",
        body: "",
        tags: [],
        meta: %{
          "kind" => "file",
          "filename" => stored.filename,
          "mime_type" => stored.mime_type,
          "size" => stored.size,
          "storage_path" => stored.storage_path,
          "sha256" => stored.sha256
        }
      }

      case Brain.create_page(attrs) do
        {:ok, page} -> page
        {:error, _} -> nil
      end
    end
  end

  # ── Suggestion helpers ──

  defp apply_suggestion(socket, field, suggest_fn) do
    page = socket.assigns.page

    case suggest_fn.(page) do
      {:ok, value} ->
        value = normalize_suggested_value(field, value)
        params = Map.merge(socket.assigns.form.params || %{}, %{field => value})
        handle_event("validate_page", %{"page" => params}, socket)

      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, gettext("Inference is not configured."))}

      {:error, reason} ->
        message =
          gettext("Could not suggest %{field}: %{reason}",
            field: field,
            reason: format_error(reason)
          )

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp normalize_suggested_value("tags", tags) when is_list(tags) do
    tags
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp normalize_suggested_value("tags", tags) when is_binary(tags), do: tags
  defp normalize_suggested_value(_field, value), do: value

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp ensure_tag_suggestions(socket) do
    case socket.assigns[:tag_suggestions] do
      nil ->
        case context_id(socket) do
          nil -> assign(socket, tag_suggestions: [])
          id -> assign(socket, tag_suggestions: Brain.list_tags(id))
        end

      _ ->
        socket
    end
  end
end
