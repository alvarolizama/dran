defmodule DranWeb.API.IngestController do
  use DranWeb, :controller

  alias Dran.Brain
  alias Dran.Ingest.Converter
  alias Dran.Uploads

  @doc "POST /api/ingest — save a URL or download a file as a reference page"
  def ingest(conn, %{"url" => url, "context" => context_slug} = params) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case do_ingest(context, url, params) do
        {:ok, page} ->
          conn
          |> put_status(:created)
          |> json(%{data: %{slug: page.slug, title: page.title, page_type: page.page_type}})

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{errors: %{detail: reason}})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "url and context are required"}})
  end

  @doc "POST /api/ingest/file — upload and convert a file to a markdown note"
  def file(conn, %{"context" => context_slug, "file" => %Plug.Upload{} = upload} = params) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      tag_list = parse_tags(params["tags"])

      case upload_file(context, upload, tag_list) do
        {:ok, page} ->
          conn
          |> put_status(:created)
          |> json(%{data: %{slug: page.slug, title: page.title, page_type: page.page_type}})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{detail: reason}})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def file(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "file and context are required"}})
  end

  @doc """
  Public ingest function callable from MCP or LiveView.
  - For HTML pages: saves the URL as a reference (no content extraction).
  - For PDFs and other files: downloads and stores the file, creates a reference with download link.
  Returns `{:ok, page}` or `{:error, reason_string}`.
  """
  def do_ingest(context, url, params) when is_map(params) do
    with {:ok, validated_url} <- validate_url(url),
         {:ok, %{content_type: content_type, filename: filename}} <- fetch_url_head(validated_url) do
      if file_type?(content_type) do
        case download_file(validated_url) do
          {:ok, binary} ->
            ingest_file(context, validated_url, binary, filename, content_type, params)

          {:error, reason} ->
            {:error, "failed to download file: #{reason}"}
        end
      else
        ingest_url(context, validated_url, filename, params)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── URL validation (SSRF protection) ──

  @max_download_size 100 * 1024 * 1024
  @blocked_schemes ~w(http https)

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in @blocked_schemes and is_binary(host) and host != "" ->
        case :inet.getaddr(to_charlist(host), :inet) do
          {:ok, ip} ->
            if blocked_ip?(ip) do
              {:error, "URL points to a blocked address (private/loopback/link-local)"}
            else
              {:ok, url}
            end

          {:error, _} ->
            # DNS resolution failed — could be a domain that doesn't exist.
            # Allow it; Req will fail gracefully.
            {:ok, url}
        end

      _ ->
        {:error, "invalid URL: must be http or https"}
    end
  end

  defp validate_url(_), do: {:error, "invalid URL"}

  defp blocked_ip?({a, b, _c, _d}) do
    # Loopback 127.0.0.0/8
    # Private 10.0.0.0/8
    # Private 172.16.0.0/12
    # Private 192.168.0.0/16
    # Link-local 169.254.0.0/16 (includes cloud metadata)
    # 0.0.0.0/8
    # CGNAT 100.64.0.0/10
    a == 127 or
      a == 10 or
      (a == 172 and b >= 16 and b <= 31) or
      (a == 192 and b == 168) or
      (a == 169 and b == 254) or
      a == 0 or
      (a == 100 and b >= 64 and b <= 127)
  end

  # IPv6 — block loopback ::1 and link-local fe80::/10
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip?({0xFE80, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp blocked_ip?(_), do: false

  # ── URL-only ingest (no download) ──

  defp ingest_url(context, url, title, params) do
    slug = params["slug"] || slugify(title || title_from_url(url))

    page_attrs = %{
      context_id: context.id,
      title: title || title_from_url(url),
      slug: slug,
      body: "Source: #{url}",
      page_type: "reference",
      tags: params["tags"] || [],
      meta:
        Map.merge(params["meta"] || %{}, %{
          "kind" => "article",
          "source_url" => url,
          "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }),
      kb_source_url: url,
      owner: params["owner"] || "system",
      created_by: params["created_by"] || "system"
    }

    create_page(page_attrs)
  end

  # ── File ingest (download + store) ──

  defp ingest_file(context, url, binary, filename, content_type, params) do
    stored = Uploads.store(context.id, binary, filename, content_type)
    slug = params["slug"] || slugify(filename)

    page_attrs = %{
      context_id: context.id,
      title: filename,
      slug: slug,
      body: "Source: #{url}\n\n[Download](#{stored.storage_path})",
      page_type: "reference",
      tags: params["tags"] || [],
      meta:
        Map.merge(params["meta"] || %{}, %{
          "kind" => "file",
          "source_url" => url,
          "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "filename" => stored.filename,
          "mime_type" => stored.mime_type,
          "size" => stored.size,
          "storage_path" => stored.storage_path,
          "sha256" => stored.sha256
        }),
      kb_source_url: url,
      owner: params["owner"] || "system",
      created_by: params["created_by"] || "system"
    }

    create_page(page_attrs)
  end

  defp create_page(page_attrs) do
    case Brain.create_page(page_attrs) do
      {:ok, page} ->
        {:ok, page}

      {:error, changeset} ->
        {:error, format_errors_string(changeset)}
    end
  end

  # ── Multipart file ingest (upload + MarkItDown) ──

  defp upload_file(
         context,
         %Plug.Upload{
           filename: filename,
           content_type: content_type,
           path: path
         },
         tags
       ) do
    case File.read(path) do
      {:ok, binary} ->
        max_size = Uploads.max_size()

        if byte_size(binary) > max_size do
          {:error, "file too large (max #{max_size} bytes)"}
        else
          stored = Uploads.store(context.id, binary, filename, content_type)
          title = Converter.title(filename)
          slug = slugify(title)

          case Converter.convert(filename, content_type, binary) do
            {:ok, %{body: markdown}} ->
              page_attrs = %{
                context_id: context.id,
                title: title,
                slug: slug,
                body: markdown,
                page_type: "note",
                tags: tags,
                summary: summarize_text(markdown),
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

              create_page(page_attrs)

            {:error, reason} ->
              {:error, to_error_string(reason)}
          end
        end

      {:error, reason} ->
        {:error, "failed to read upload: #{inspect(reason)}"}
    end
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(tags) when is_list(tags), do: tags
  defp parse_tags(_), do: []

  defp to_error_string(reason) when is_binary(reason), do: reason
  defp to_error_string(reason), do: inspect(reason)

  # ── URL helpers ──

  # Fetch only headers to determine content type (HEAD request)
  defp fetch_url_head(url) do
    case Req.head(url,
           headers: %{"User-Agent" => "Dran/0.1 (second-brain)"},
           receive_timeout: 15_000,
           redirect: true,
           max_redirects: 5
         ) do
      {:ok, %{status: 200, headers: headers}} ->
        content_type = get_content_type(headers)
        filename = title_from_url(url)
        {:ok, %{content_type: content_type, filename: filename}}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # Download the full file with size limit
  defp download_file(url) do
    case Req.get(url,
           headers: %{"User-Agent" => "Dran/0.1 (second-brain)"},
           receive_timeout: 60_000,
           redirect: true,
           max_redirects: 3,
           compressed: false,
           raw: true
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        if byte_size(body) > @max_download_size do
          {:error, "file too large (max #{@max_download_size} bytes)"}
        else
          {:ok, body}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # Determine if the content type is a downloadable file (not HTML)
  defp file_type?(content_type) do
    not String.contains?(content_type, "text/html")
  end

  defp get_content_type(headers) when is_map(headers) do
    case headers["content-type"] || headers["Content-Type"] do
      [ct | _] -> String.split(ct, ";") |> hd() |> String.trim() |> String.downcase()
      ct when is_binary(ct) -> String.split(ct, ";") |> hd() |> String.trim() |> String.downcase()
      _ -> "application/octet-stream"
    end
  end

  defp get_content_type(_), do: "application/octet-stream"

  defp title_from_url(url) do
    uri = URI.parse(url)
    path = uri.path || ""
    name = path |> String.split("/") |> List.last() |> String.replace(~r/\.\w+$/, "")
    name = String.replace(name, ~r/[-_]+/, " ") |> String.trim()
    if name == "", do: uri.host || "untitled", else: name
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

  defp summarize_text(markdown) do
    markdown
    |> String.split("\n", trim: true)
    |> Enum.take(3)
    |> Enum.join(" ")
    |> String.trim()
    |> String.slice(0, 240)
  end

  defp format_errors_string(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
