defmodule Dran.Embeds do
  @moduledoc """
  External embeds inside page bodies: `![[yt:ID]]`, `![[vimeo:ID]]`,
  `![[map:query]]`.

  Internal page embeds (`![[slug]]`) are `Dran.Knowledge`'s business — it
  resolves them into `embeds` relations — and `DranWeb.PageComponents` renders
  them as local media. This module owns the other half: media hosted by a third
  party, rendered as an `<iframe>`.

  ## The security stance (read before touching the renderer)

  Markdown runs with `render: [unsafe: false]` (MDEx/comrak), so raw HTML in a
  body is discarded — verified: an `<iframe>` in a body renders as nothing. The
  external embeds keep that stance instead of relaxing it:

    * the author writes a **reference** (`![[yt:dQw4w9WgXcQ]]`), never markup;
    * `parse/1` validates it against the provider allowlist below and extracts
      a strict id (11 chars for YouTube, digits for Vimeo, a cleaned query or a
      validated `pb` blob for Maps);
    * the `<iframe>` — src, `allow`, `title`, referrer policy — is built by
      `DranWeb.PageComponents` from the parsed parts.

  Nothing an author types reaches a `src` attribute unless it matched a pattern
  here. Hostile input degrades to a plain "broken embed" marker, never to
  markup.

  ## Providers

  | reference         | embed src                                    | oEmbed          |
  |-------------------|----------------------------------------------|-----------------|
  | `yt:VIDEO_ID`     | `https://www.youtube-nocookie.com/embed/ID`   | keyless         |
  | `vimeo:ID`        | `https://player.vimeo.com/video/ID`           | keyless         |
  | `map:QUERY`       | `https://www.google.com/maps/embed?…`         | none            |
  | `map:!1m2!…`      | `https://www.google.com/maps/embed?pb=…`      | none            |

  Google Maps publishes **no** oEmbed endpoint (checked: `google.com/oembed`
  answers 404 for a Maps URL), so `resolve/2` returns `{:error, :no_oembed}`
  for it and the renderer's caption falls back to the display text or the
  provider label. Both Maps forms are keyless: the `pb` form is what Google's
  own `output=embed` redirect produces, and the query form is built from it.

  YouTube and Vimeo answer keyless oEmbed, so their titles are resolvable —
  cached by `Dran.Embeds.Cache`, and only ever read (never fetched) while
  rendering.

  ## Where it is wired

    * `DranWeb.PageComponents.render_markdown/2` — normalizes raw URLs in the
      source and renders the iframe.
    * `Dran.Embeds.Cache` — metadata, warmed at insert time.
    * `assets/js/hooks/markdown_editor.js` — paste handler that turns a pasted
      provider URL into the canonical reference.
  """

  alias Dran.Embeds.Cache

  # The embed idiom, shared with the renderer so the two can never drift:
  #   ![[ref]]        ![[ref|display]]
  # `ref` is a page slug (internal, resolved by Dran.Knowledge) or a provider
  # reference (external, resolved here).
  @embed_pattern ~r/!\[\[([^|\]]+)(?:\|([^\]]+))?\]\]/

  @youtube_id ~r/^[A-Za-z0-9_-]{11}$/
  @vimeo_id ~r/^[0-9]{4,12}$/
  # A Google Maps `pb` blob: opaque, `!`-segmented, and deliberately restricted
  # to characters that cannot break out of an HTML attribute, a query string or
  # a URL path. Anything else is rejected rather than escaped.
  @maps_pb ~r/^![A-Za-z0-9_\-!~*.,:%+=]{2,900}$/
  @maps_query_max 200

  @timeout_ms 5_000
  @ok_ttl 24 * 60 * 60 * 1000
  @error_ttl 5 * 60 * 1000

  @youtube_allow "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
  @vimeo_allow "autoplay; fullscreen; picture-in-picture"

  @type provider :: :youtube | :vimeo | :maps

  @type embed :: %{
          provider: provider(),
          ref: String.t(),
          id: String.t(),
          embed_url: String.t(),
          label: String.t(),
          aspect: String.t(),
          allow: String.t() | nil,
          fullscreen: boolean()
        }

  @type metadata :: %{
          title: String.t() | nil,
          author: String.t() | nil,
          thumbnail_url: String.t() | nil,
          provider: String.t() | nil
        }

  @doc "The embed idiom, so callers scan bodies with the same pattern."
  def embed_pattern, do: @embed_pattern

  @doc """
  Parse a provider reference (`"yt:dQw4w9WgXcQ"`) or a provider URL into an
  embed map.

  Accepts the canonical reference and the URLs a person actually copies:

      "yt:dQw4w9WgXcQ"                                 -> YouTube
      "https://youtu.be/dQw4w9WgXcQ?t=30"              -> YouTube
      "https://www.youtube.com/shorts/dQw4w9WgXcQ"     -> YouTube
      "vimeo:76979871" / "https://vimeo.com/76979871"  -> Vimeo
      "map:Eiffel Tower"                               -> Google Maps
      "https://maps.google.com/maps?q=Eiffel+Tower"    -> Google Maps

  Anything else answers `{:error, :unsupported_host}`,
  `{:error, :unsupported_provider}` or `{:error, :invalid_id}`.
  """
  @spec parse(term()) :: {:ok, embed()} | {:error, atom()}
  def parse(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :empty}
      url?(value) -> from_url(value)
      String.contains?(value, ":") -> from_ref(value)
      true -> {:error, :unsupported}
    end
  end

  def parse(_), do: {:error, :unsupported}

  @doc """
  Rewrite `![[<provider URL>]]` in a markdown **source** into its canonical
  reference.

  This has to happen before MDEx: with `autolink: true` the URL inside the
  brackets becomes `<a href=…>` and the embed renders as broken-link text
  (verified). URLs whose provider is unknown are left untouched, so the
  markdown keeps whatever meaning it had.
  """
  @spec normalize_markdown(binary()) :: binary()
  def normalize_markdown(body) when is_binary(body) do
    Regex.replace(@embed_pattern, body, fn whole, ref, display ->
      ref = String.trim(ref)

      with true <- url?(ref),
           {:ok, embed} <- parse(ref) do
        case String.trim(display || "") do
          "" -> "![[" <> embed.ref <> "]]"
          text -> "![[" <> embed.ref <> "|" <> text <> "]]"
        end
      else
        _ -> whole
      end
    end)
  end

  def normalize_markdown(body), do: body

  @doc """
  oEmbed metadata for a reference or URL, from the cache when possible.

  Options:

    * `:cache` — `false` skips both the read and the write (tests, one-shot
      refresh).

  Returns `{:ok, metadata}` or `{:error, reason}`. Maps answers
  `{:error, :no_oembed}`: there is nothing to ask.
  """
  @spec resolve(term(), keyword()) :: {:ok, metadata()} | {:error, term()}
  def resolve(value, opts \\ [])

  def resolve(value, opts) do
    case parse(value) do
      {:ok, embed} -> cached_or_fetch(embed, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Metadata already cached for a reference, WITHOUT touching the network.

  The render path calls this and nothing else: a page with fifty embeds must
  render with zero outbound requests, and a provider outage must never delay a
  reader.
  """
  @spec cached(term()) :: metadata() | nil
  def cached(value) do
    with {:ok, embed} <- parse(value),
         {:ok, {:ok, meta}} <- Cache.get({:oembed, embed.ref}) do
      meta
    else
      _ -> nil
    end
  end

  # ── References ────────────────────────────────────────────────────────────

  defp from_ref(value) do
    case String.split(value, ":", parts: 2) do
      [prefix, rest] -> parse_prefixed(String.downcase(prefix), String.trim(rest))
      _ -> {:error, :unsupported}
    end
  end

  defp parse_prefixed(prefix, rest) when prefix in ["yt", "youtube"], do: youtube(rest)
  defp parse_prefixed(prefix, rest) when prefix in ["vimeo"], do: vimeo(rest)
  defp parse_prefixed(prefix, rest) when prefix in ["map", "maps"], do: maps_value(rest)
  defp parse_prefixed(_prefix, _rest), do: {:error, :unsupported_provider}

  # ── YouTube ───────────────────────────────────────────────────────────────

  defp youtube(id) do
    if Regex.match?(@youtube_id, id) do
      {:ok,
       %{
         provider: :youtube,
         ref: "yt:" <> id,
         id: id,
         embed_url: "https://www.youtube-nocookie.com/embed/" <> id,
         label: "YouTube",
         aspect: "16 / 9",
         allow: @youtube_allow,
         fullscreen: true
       }}
    else
      {:error, :invalid_id}
    end
  end

  # ── Vimeo ─────────────────────────────────────────────────────────────────

  defp vimeo(id) do
    if Regex.match?(@vimeo_id, id) do
      {:ok,
       %{
         provider: :vimeo,
         ref: "vimeo:" <> id,
         id: id,
         embed_url: "https://player.vimeo.com/video/" <> id,
         label: "Vimeo",
         aspect: "16 / 9",
         allow: @vimeo_allow,
         fullscreen: true
       }}
    else
      {:error, :invalid_id}
    end
  end

  # ── Google Maps ───────────────────────────────────────────────────────────

  defp maps_value(rest) do
    cond do
      url?(rest) -> from_url(rest)
      Regex.match?(@maps_pb, rest) -> maps_pb(rest)
      String.starts_with?(rest, "!") -> {:error, :invalid_pb}
      true -> maps_query(rest)
    end
  end

  defp maps_query(query) do
    case sanitize_query(query) do
      "" -> {:error, :invalid_query}
      clean -> {:ok, maps_query_embed(clean)}
    end
  end

  defp maps_query_embed(query) do
    # Same shape Google's own `?q=…&output=embed` redirect lands on.
    %{
      provider: :maps,
      ref: "map:" <> query,
      id: query,
      embed_url:
        "https://www.google.com/maps/embed?origin=mfe&pb=!1m2!2m1!1s" <>
          URI.encode_www_form(query),
      label: "Google Maps",
      aspect: "4 / 3",
      allow: nil,
      fullscreen: false
    }
  end

  defp maps_pb(pb) do
    # The blob is already validated character-by-character: pass it through
    # verbatim (percent-encoding it would break the parser on Google's side).
    {:ok,
     %{
       provider: :maps,
       ref: "map:" <> pb,
       id: pb,
       embed_url: "https://www.google.com/maps/embed?pb=" <> pb,
       label: "Google Maps",
       aspect: "4 / 3",
       allow: nil,
       fullscreen: false
     }}
  end

  defp sanitize_query(query) do
    query
    |> String.replace(~r/[\x00-\x1f<>"'\\]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @maps_query_max)
  end

  # ── URLs ──────────────────────────────────────────────────────────────────

  defp url?(value), do: String.starts_with?(value, ["http://", "https://"])

  defp from_url(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        host = String.downcase(host)

        cond do
          youtube_host?(host) -> youtube_from_uri(uri)
          vimeo_host?(host) -> vimeo_from_uri(uri)
          maps_host?(host) -> maps_from_uri(uri)
          true -> {:error, :unsupported_host}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  defp youtube_host?(host) do
    host in [
      "youtube.com",
      "www.youtube.com",
      "m.youtube.com",
      "music.youtube.com",
      "youtube-nocookie.com",
      "www.youtube-nocookie.com",
      "youtu.be"
    ]
  end

  defp vimeo_host?(host), do: host in ["vimeo.com", "www.vimeo.com", "player.vimeo.com"]

  defp maps_host?(host), do: host in ["maps.google.com", "www.google.com", "google.com"]

  defp youtube_from_uri(%URI{path: path, query: query}) do
    params = query_params(query)

    case params["v"] do
      v when is_binary(v) -> youtube(v)
      _ -> youtube_from_path(path)
    end
  end

  defp youtube_from_path(path) do
    case path |> String.split("/", trim: true) do
      ["embed", id | _] -> youtube(id)
      ["shorts", id | _] -> youtube(id)
      ["live", id | _] -> youtube(id)
      ["v", id | _] -> youtube(id)
      [id] -> youtube(id)
      _ -> {:error, :invalid_url}
    end
  end

  defp vimeo_from_uri(%URI{path: path}) do
    # /76979871, /video/76979871, /channels/staffpicks/76979871 — the numeric
    # segment is the id in every public form.
    path
    |> String.split("/", trim: true)
    |> Enum.find(&Regex.match?(@vimeo_id, &1))
    |> case do
      nil -> {:error, :invalid_url}
      id -> vimeo(id)
    end
  end

  defp maps_from_uri(%URI{path: path, query: query}) do
    params = query_params(query)
    path = path || ""

    cond do
      pb = raw_param(query, "pb") ->
        maps_value(pb)

      # `/maps` is the only path shape that means "a map": a google.com URL
      # with a `q` elsewhere is a search, not a place.
      not String.starts_with?(path, "/maps") ->
        {:error, :invalid_url}

      is_binary(params["q"]) ->
        maps_query(params["q"])

      is_binary(params["query"]) ->
        maps_query(params["query"])

      is_binary(params["daddr"]) ->
        maps_query(params["daddr"])

      place = place_from_path(path) ->
        maps_query(place)

      true ->
        {:error, :invalid_url}
    end
  end

  defp place_from_path(path) do
    case Regex.run(~r{/maps/place/([^/@?]+)}, path) do
      [_, name] -> decode(name)
      _ -> nil
    end
  end

  defp query_params(nil), do: %{}

  defp query_params(query) do
    URI.decode_query(query)
  rescue
    _ -> %{}
  end

  # Raw query value for a key, WITHOUT www-form decoding.
  #
  # A Maps `pb` blob encodes spaces inside its `!`-segments as `+`
  # (`pb=!1m2!2m1!1sEiffel+Tower` is exactly what Google's own
  # `?q=…&output=embed` redirect emits) and Google parses it back verbatim, so
  # the `+` must survive — `URI.decode_query/1` would turn it into a space and
  # the blob would fail its allowlist. Percent-escapes (`%21`) are decoded,
  # because those really are encoding.
  defp raw_param(nil, _key), do: nil

  defp raw_param(query, key) do
    query
    |> String.split("&")
    |> Enum.find_value(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [^key, value] when value != "" -> URI.decode(value)
        _ -> nil
      end
    end)
  end

  defp decode(value) do
    URI.decode_www_form(value)
  rescue
    _ -> value
  end

  # ── oEmbed ────────────────────────────────────────────────────────────────

  defp cached_or_fetch(embed, opts) do
    key = {:oembed, embed.ref}

    if Keyword.get(opts, :cache, true) do
      case Cache.get(key) do
        {:ok, result} ->
          result

        :miss ->
          result = fetch_metadata(embed)
          Cache.put(key, result, ttl_for(result))
          result
      end
    else
      fetch_metadata(embed)
    end
  end

  defp ttl_for({:ok, _}), do: @ok_ttl
  defp ttl_for(_), do: @error_ttl

  defp fetch_metadata(%{provider: :maps}), do: {:error, :no_oembed}

  defp fetch_metadata(embed) do
    embed
    |> oembed_url()
    |> request()
  end

  defp oembed_url(%{provider: :youtube, id: id}) do
    "https://www.youtube.com/oembed?format=json&url=" <>
      URI.encode_www_form("https://www.youtube.com/watch?v=" <> id)
  end

  defp oembed_url(%{provider: :vimeo, id: id}) do
    "https://vimeo.com/api/oembed.json?url=" <>
      URI.encode_www_form("https://vimeo.com/" <> id)
  end

  defp request(url) do
    opts = [
      method: :get,
      url: url,
      retry: false,
      receive_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms],
      headers: [{"user-agent", "dran-embeds/1.0"}]
    ]

    opts =
      case Application.get_env(:dran, :embeds, [])[:req_plug] do
        nil -> opts
        plug -> Keyword.put(opts, :plug, plug)
      end

    case Req.request(opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, metadata(body)}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp metadata(body) when is_map(body) do
    %{
      title: text(body["title"]),
      author: text(body["author_name"]),
      thumbnail_url: thumbnail(body["thumbnail_url"]),
      provider: text(body["provider_name"])
    }
  end

  defp metadata(_), do: %{title: nil, author: nil, thumbnail_url: nil, provider: nil}

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil

  # A thumbnail is rendered as an image: anything that is not an https URL is
  # not a thumbnail.
  defp thumbnail(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> url
      _ -> nil
    end
  end

  defp thumbnail(_), do: nil
end
