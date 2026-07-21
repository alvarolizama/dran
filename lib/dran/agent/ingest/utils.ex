defmodule Dran.Agent.Ingest.Utils do
  @moduledoc """
  Pure utilities shared by the ingest agent and the API ingest controller.

  Handles SSRF-safe URL validation, HEAD inspection, file download, and
  creating pages from URLs or binaries.
  """

  alias Dran.{Brain, Slug, Uploads}
  alias Dran.Ingest.Converter
  alias Dran.Inference.{ASR, Config, MarkItDown, Vision}

  require Logger

  @max_download_size 100 * 1024 * 1024
  @blocked_schemes ~w(http https)

  @doc """
  Public ingest function for a URL.

  - For HTML pages: saves the URL as a reference.
  - For files: downloads and stores the file, creating a reference page.

  Returns `{:ok, page}` or `{:error, reason_string}`.
  """
  def do_ingest(context, url, params \\ %{}) do
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

  @doc """
  Validate a URL against SSRF risks.
  """
  @spec validate_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_url(url) when is_binary(url) do
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
            {:ok, url}
        end

      _ ->
        {:error, "invalid URL: must be http or https"}
    end
  end

  def validate_url(_), do: {:error, "invalid URL"}

  defp blocked_ip?({a, b, _c, _d}) do
    a == 127 or
      a == 10 or
      (a == 172 and b >= 16 and b <= 31) or
      (a == 192 and b == 168) or
      (a == 169 and b == 254) or
      a == 0 or
      (a == 100 and b >= 64 and b <= 127)
  end

  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip?({0xFE80, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp blocked_ip?(_), do: false

  @doc """
  Fetch headers for a URL, returning content type and a suggested filename.
  """
  @spec fetch_url_head(String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_url_head(url) do
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

  @doc """
  Download a URL body with size limits.
  """
  @spec download_file(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def download_file(url) do
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

  @doc """
  Create a reference page from a web URL.
  """
  @spec ingest_url(Brain.Context.t(), String.t(), String.t(), map()) ::
          {:ok, Brain.Page.t()} | {:error, String.t()}
  def ingest_url(context, url, title, params) do
    slug = params["slug"] || Slug.generate(title || title_from_url(url), context.id, "reference")

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

  @doc """
  Store a downloaded binary and create a reference page from it.

  When inference is configured, the file body is enriched with the
  extracted content (markdown for documents, description for images,
  transcription for audio). When inference is disabled or extraction
  fails, the page falls back to a simple download link — preserving
  the previous behaviour.
  """
  @spec ingest_file(Brain.Context.t(), String.t(), binary(), String.t(), String.t(), map()) ::
          {:ok, Brain.Page.t()} | {:error, String.t()}
  def ingest_file(context, url, binary, filename, content_type, params) do
    stored = Uploads.store(context.id, binary, filename, content_type)
    slug = params["slug"] || Slug.generate(filename, context.id, "reference")
    body = build_file_body(url, stored, filename, content_type, binary)

    page_attrs = %{
      context_id: context.id,
      title: filename,
      slug: slug,
      body: body,
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

  @doc """
  Decide which extraction strategy applies to a content type.

  Returns one of `:markitdown`, `:vision`, `:asr`, or `:none`. This is a
  pure function over the content type and the supported MIME types of
  `MarkItDown`; it does not check whether inference is configured. Callers
  must handle the case where the chosen strategy fails at runtime.
  """
  @spec extraction_strategy(String.t()) :: :markitdown | :vision | :asr | :none
  def extraction_strategy(content_type) when is_binary(content_type) do
    cond do
      content_type in MarkItDown.supported_mime_types() -> :markitdown
      String.starts_with?(content_type, "image/") -> :vision
      String.starts_with?(content_type, "audio/") -> :asr
      true -> :none
    end
  end

  # Builds the page body for an ingested file. When inference is enabled
  # and extraction succeeds, the body is enriched with the extracted
  # content (prefixed by the source URL). On any failure — inference
  # disabled, network error, or unexpected response — the body falls
  # back to a plain download link, preserving the original behaviour.
  defp build_file_body(url, stored, filename, content_type, binary) do
    fallback_body = "Source: #{url}\n\n[Download](#{stored.storage_path})"

    if not Config.enabled?() do
      fallback_body
    else
      case extract_content(extraction_strategy(content_type), filename, content_type, binary) do
        {:ok, extracted} ->
          format_extracted_body(url, extraction_strategy(content_type), extracted, stored)

        {:error, reason} ->
          Logger.info(
            "ingest extraction failed for #{filename} (#{content_type}): #{inspect(reason)}; falling back to download link"
          )

          fallback_body
      end
    end
  end

  defp extract_content(:markitdown, filename, content_type, binary) do
    MarkItDown.to_markdown(filename, content_type, binary)
  end

  defp extract_content(:vision, _filename, _content_type, binary) do
    Vision.describe(
      binary,
      "Describe this image in detail, in Spanish. Include visible text, objects, and context."
    )
  end

  defp extract_content(:asr, filename, _content_type, binary) do
    ASR.transcribe(binary, filename)
  end

  defp extract_content(:none, _filename, _content_type, _binary) do
    {:error, :no_extraction_strategy}
  end

  defp format_extracted_body(url, :vision, description, stored) do
    "Source: #{url}\n\n**Description:** #{description}\n\n[View image](#{stored.storage_path})"
  end

  defp format_extracted_body(url, :asr, transcript, stored) do
    "Source: #{url}\n\n**Transcription:** #{transcript}\n\n[Listen](#{stored.storage_path})"
  end

  defp format_extracted_body(url, _strategy, markdown, _stored) do
    "Source: #{url}\n\n#{markdown}"
  end

  @doc """
  Upload, convert, and create a note from a Plug.Upload.
  """
  @spec upload_file(Brain.Context.t(), Plug.Upload.t(), list(String.t())) ::
          {:ok, Brain.Page.t()} | {:error, String.t()}
  def upload_file(
        context,
        %Plug.Upload{filename: filename, content_type: content_type, path: path},
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

          case Converter.convert(filename, content_type, binary) do
            {:ok, %{body: markdown}} ->
              page_attrs = %{
                context_id: context.id,
                title: title,
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

  defp create_page(page_attrs) do
    case Brain.create_page(page_attrs) do
      {:ok, page} ->
        {:ok, page}

      {:error, changeset} ->
        {:error, format_errors_string(changeset)}
    end
  end

  defp file_type?(content_type), do: not String.contains?(content_type, "text/html")

  defp get_content_type(headers) when is_map(headers) do
    case headers["content-type"] || headers["Content-Type"] do
      [ct | _] -> normalize_content_type(ct)
      ct when is_binary(ct) -> normalize_content_type(ct)
      _ -> "application/octet-stream"
    end
  end

  defp get_content_type(_), do: "application/octet-stream"

  defp normalize_content_type(ct) do
    ct
    |> String.split(";")
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  def title_from_url(url) do
    uri = URI.parse(url)
    path = uri.path || ""
    name = path |> String.split("/") |> List.last() |> String.replace(~r/\.\w+$/, "")
    name = String.replace(name, ~r/[-_]+/, " ") |> String.trim()
    if name == "", do: uri.host || "untitled", else: name
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

  defp to_error_string(reason) when is_binary(reason), do: reason
  defp to_error_string(reason), do: inspect(reason)
end
