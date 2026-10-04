defmodule Dran.EmbedsTest do
  @moduledoc """
  External embeds: the provider allowlist, the reference parser and the oEmbed
  resolver.

  The security tests are the point of this file: an author (or an agent)
  writes the body, so every hostile input must come out as `{:error, _}` — a
  reference that never reaches an `src` attribute — not as sanitized markup.
  """
  use ExUnit.Case, async: false

  alias Dran.Embeds
  alias Dran.Embeds.Cache

  @yt "dQw4w9WgXcQ"

  setup do
    original = Application.get_env(:dran, :embeds)
    Application.put_env(:dran, :embeds, req_plug: {Req.Test, Dran.Embeds})
    Cache.clear()

    on_exit(fn ->
      restore(:embeds, original)
      Cache.clear()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dran, key)
  defp restore(key, value), do: Application.put_env(:dran, key, value)

  # ── References ────────────────────────────────────────────────────────────

  describe "parse/1 — references" do
    test "youtube: canonical reference builds a nocookie embed" do
      assert {:ok, embed} = Embeds.parse("yt:#{@yt}")

      assert embed.provider == :youtube
      assert embed.ref == "yt:#{@yt}"
      assert embed.id == @yt
      assert embed.embed_url == "https://www.youtube-nocookie.com/embed/#{@yt}"
      assert embed.label == "YouTube"
      assert embed.allow =~ "encrypted-media"
    end

    test "youtube: the long prefix and surrounding whitespace are accepted" do
      assert {:ok, %{ref: "yt:" <> _}} = Embeds.parse("  youtube:#{@yt}  ")
    end

    test "youtube: any id that is not exactly 11 url-safe chars is rejected" do
      for id <- [
            "",
            "short",
            String.slice(@yt, 0, 10),
            @yt <> "x",
            "dQw4w9Wg cQ",
            "../../etc/passwd",
            "<script>alert(1)</script>",
            "\" onload=\"alert(1)",
            "dQw4w9WgXcQ&autoplay=1"
          ] do
        assert {:error, _} = Embeds.parse("yt:" <> id), "accepted hostile id: #{inspect(id)}"
      end
    end

    test "vimeo: digits only, and the id survives the round trip" do
      assert {:ok, embed} = Embeds.parse("vimeo:76979871")
      assert embed.provider == :vimeo
      assert embed.embed_url == "https://player.vimeo.com/video/76979871"

      for id <- ["", "abc", "12", "76979871x", "<iframe>"] do
        assert {:error, _} = Embeds.parse("vimeo:" <> id), "accepted hostile id: #{inspect(id)}"
      end
    end

    test "maps: a free-text query is encoded, never echoed raw" do
      assert {:ok, embed} = Embeds.parse("map:Eiffel Tower, Paris")
      assert embed.provider == :maps
      assert embed.id == "Eiffel Tower, Paris"
      assert embed.allow == nil

      assert embed.embed_url ==
               "https://www.google.com/maps/embed?origin=mfe&pb=!1m2!2m1!1sEiffel+Tower%2C+Paris"
    end

    test "maps: markup and control characters are stripped from the query" do
      assert {:ok, embed} = Embeds.parse(~s|map:Eiffel <script>"alert"</script>|)

      refute embed.embed_url =~ "<"
      refute embed.embed_url =~ "\""
      assert embed.embed_url =~ "!1m2!2m1!1sEiffel+script+alert+%2Fscript"
    end

    test "maps: an empty query is an error, not an empty map" do
      assert {:error, :invalid_query} = Embeds.parse("map:   ")
      assert {:error, :empty} = Embeds.parse("")
    end

    test "maps: a validated pb blob passes through verbatim" do
      pb = "!1m2!2m1!1sEiffel+Tower"

      assert {:ok, embed} = Embeds.parse("map:" <> pb)
      assert embed.ref == "map:" <> pb
      assert embed.embed_url == "https://www.google.com/maps/embed?pb=" <> pb
    end

    test "maps: a pb blob carrying anything outside the allowlist is rejected" do
      for pb <- [
            "!1m2!2m1!1sEiffel&output=embed",
            "!1m2!2m1!1sEiffel\" onload=\"alert(1)",
            "!1m2!2m1!1sEiffel<script>",
            "!",
            "!" <> String.duplicate("1m2!", 400)
          ] do
        assert {:error, :invalid_pb} = Embeds.parse("map:" <> pb), "accepted pb: #{inspect(pb)}"
      end
    end

    test "an unknown prefix is unsupported, not a page slug" do
      assert {:error, :unsupported_provider} = Embeds.parse("evil:payload")
      assert {:error, :unsupported_provider} = Embeds.parse("javascript:alert(1)")
      assert {:error, :unsupported_provider} = Embeds.parse("data:text/html,<h1>x</h1>")
      assert {:error, :unsupported} = Embeds.parse("plain-slug")
      assert {:error, :unsupported} = Embeds.parse(nil)
    end
  end

  # ── URLs ──────────────────────────────────────────────────────────────────

  describe "parse/1 — URLs" do
    test "the youtube URL shapes resolve to the same embed" do
      urls = [
        "https://www.youtube.com/watch?v=#{@yt}",
        "https://www.youtube.com/watch?v=#{@yt}&t=30s",
        "https://m.youtube.com/watch?v=#{@yt}",
        "https://music.youtube.com/watch?v=#{@yt}",
        "https://youtu.be/#{@yt}",
        "https://youtu.be/#{@yt}?t=30",
        "https://www.youtube.com/embed/#{@yt}",
        "https://www.youtube.com/shorts/#{@yt}",
        "https://www.youtube.com/live/#{@yt}",
        "https://www.youtube-nocookie.com/embed/#{@yt}",
        "http://www.youtube.com/watch?v=#{@yt}"
      ]

      for url <- urls do
        assert {:ok, %{provider: :youtube, ref: "yt:" <> @yt}} = Embeds.parse(url),
               "failed to parse #{url}"
      end
    end

    test "the vimeo URL shapes resolve to the same embed" do
      urls = [
        "https://vimeo.com/76979871",
        "https://player.vimeo.com/video/76979871",
        "https://vimeo.com/channels/staffpicks/76979871",
        "https://vimeo.com/76979871?share=copy"
      ]

      for url <- urls do
        assert {:ok, %{provider: :vimeo, id: "76979871"}} = Embeds.parse(url),
               "failed to parse #{url}"
      end
    end

    test "maps URLs resolve to a query or to a pb blob" do
      assert {:ok, %{id: "Eiffel Tower"}} =
               Embeds.parse("https://maps.google.com/maps?q=Eiffel+Tower&output=embed")

      assert {:ok, %{id: "Eiffel Tower"}} =
               Embeds.parse("https://www.google.com/maps/place/Eiffel+Tower/@48.8584,2.2945,17z")

      assert {:ok, %{embed_url: "https://www.google.com/maps/embed?pb=!1m18!1m12"}} =
               Embeds.parse("https://www.google.com/maps/embed?pb=!1m18!1m12")

      assert {:ok, %{embed_url: "https://www.google.com/maps/embed?pb=!1m2!2m1!1sEiffel+Tower"}} =
               Embeds.parse(
                 "https://www.google.com/maps/embed?origin=mfe&pb=!1m2!2m1!1sEiffel+Tower"
               )
    end

    test "a non-maps path on a google host is not a map" do
      assert {:error, :invalid_url} = Embeds.parse("https://www.google.com/search?q=elixir")
    end

    test "hosts outside the allowlist are rejected even when the path looks right" do
      for url <- [
            "https://evil.example.com/watch?v=#{@yt}",
            "https://www.youtube.com.evil.example/watch?v=#{@yt}",
            "https://youtube.com.evil.example/embed/#{@yt}",
            "https://notyoutube.com/watch?v=#{@yt}",
            "https://evil.example.com/maps/embed?pb=!1m2!2m1!1sX",
            "https://maps.app.goo.gl/abc123"
          ] do
        assert {:error, _} = Embeds.parse(url), "accepted hostile host: #{url}"
      end
    end

    test "malformed URLs never raise" do
      for value <- ["http://", "https:///x", "https://%zz.com", "https://", "http://[::1"] do
        assert {:error, _} = Embeds.parse(value)
      end
    end
  end

  # ── Source normalization ──────────────────────────────────────────────────

  describe "normalize_markdown/1" do
    test "a pasted URL becomes the canonical reference" do
      assert Embeds.normalize_markdown("![[https://youtu.be/#{@yt}]]") == "![[yt:#{@yt}]]"

      assert Embeds.normalize_markdown("![[https://www.youtube.com/watch?v=#{@yt}|Rick]]") ==
               "![[yt:#{@yt}|Rick]]"
    end

    test "external URLs in an embed position are canonicalized too" do
      assert Embeds.normalize_markdown("![[https://maps.google.com/maps?q=Eiffel+Tower]]") ==
               "![[map:Eiffel Tower]]"
    end

    test "unknown URLs and canonical references are left alone" do
      for body <- [
            "![[https://example.com/nope]]",
            "![[yt:#{@yt}]]",
            "![[my-page-slug]]",
            "![[my-page-slug|Display]]",
            "just text with no embeds"
          ] do
        assert Embeds.normalize_markdown(body) == body, "rewrote #{inspect(body)}"
      end
    end
  end

  # ── oEmbed ────────────────────────────────────────────────────────────────

  describe "resolve/2" do
    test "youtube metadata comes from the keyless oEmbed endpoint" do
      Req.Test.stub(Dran.Embeds, fn conn ->
        assert conn.host == "www.youtube.com"
        assert conn.request_path == "/oembed"

        assert URI.decode_query(conn.query_string)["url"] ==
                 "https://www.youtube.com/watch?v=#{@yt}"

        Req.Test.json(conn, %{
          "title" => "Never Gonna Give You Up",
          "author_name" => "Rick Astley",
          "thumbnail_url" => "https://i.ytimg.com/vi/#{@yt}/hqdefault.jpg",
          "provider_name" => "YouTube"
        })
      end)

      assert {:ok, meta} = Embeds.resolve("yt:#{@yt}")
      assert meta.title == "Never Gonna Give You Up"
      assert meta.author == "Rick Astley"
      assert meta.provider == "YouTube"
      assert meta.thumbnail_url == "https://i.ytimg.com/vi/#{@yt}/hqdefault.jpg"
    end

    test "a second resolve is served from the cache" do
      test_pid = self()

      Req.Test.stub(Dran.Embeds, fn conn ->
        send(test_pid, :requested)
        Req.Test.json(conn, %{"title" => "Cached"})
      end)

      assert {:ok, %{title: "Cached"}} = Embeds.resolve("yt:#{@yt}")
      assert_receive :requested

      assert {:ok, %{title: "Cached"}} = Embeds.resolve("yt:#{@yt}")
      refute_receive :requested, 50
    end

    test "the cache can be bypassed" do
      test_pid = self()

      Req.Test.stub(Dran.Embeds, fn conn ->
        send(test_pid, :requested)
        Req.Test.json(conn, %{"title" => "Fresh"})
      end)

      assert {:ok, _} = Embeds.resolve("yt:#{@yt}", cache: false)
      assert_receive :requested
      assert {:ok, _} = Embeds.resolve("yt:#{@yt}", cache: false)
      assert_receive :requested
    end

    test "provider failures are cached briefly, so a dead endpoint is not re-hammered" do
      test_pid = self()

      Req.Test.stub(Dran.Embeds, fn conn ->
        send(test_pid, :requested)
        Plug.Conn.send_resp(conn, 404, "nope")
      end)

      assert {:error, {:http_status, 404}} = Embeds.resolve("yt:#{@yt}")
      assert_receive :requested

      assert {:error, {:http_status, 404}} = Embeds.resolve("yt:#{@yt}")
      refute_receive :requested, 50
    end

    test "an unexpected payload yields nil metadata instead of crashing a page" do
      Req.Test.stub(Dran.Embeds, fn conn ->
        Plug.Conn.send_resp(conn, 200, "not json")
      end)

      assert {:ok, %{title: nil, author: nil, thumbnail_url: nil}} = Embeds.resolve("yt:#{@yt}")
    end

    test "a non-https thumbnail is dropped" do
      Req.Test.stub(Dran.Embeds, fn conn ->
        Req.Test.json(conn, %{"title" => "T", "thumbnail_url" => "http://insecure.example/x.jpg"})
      end)

      assert {:ok, %{thumbnail_url: nil}} = Embeds.resolve("yt:#{@yt}")
    end

    test "maps has no oEmbed endpoint and makes no request at all" do
      # No stub configured: any request would raise.
      assert {:error, :no_oembed} = Embeds.resolve("map:Eiffel Tower")
    end

    test "an unparseable reference is never requested" do
      assert {:error, :invalid_id} = Embeds.resolve("yt:nope")
    end
  end

  describe "cached/1" do
    test "is nil before anything is resolved — and never hits the network" do
      # No stub configured: a request here would raise.
      assert Embeds.cached("yt:#{@yt}") == nil
      assert Embeds.cached("map:Eiffel Tower") == nil
      assert Embeds.cached("yt:nope") == nil
    end

    test "reads back what resolve/2 stored" do
      Req.Test.stub(Dran.Embeds, fn conn ->
        Req.Test.json(conn, %{"title" => "Stored", "author_name" => "Someone"})
      end)

      assert {:ok, _} = Embeds.resolve("yt:#{@yt}")
      assert %{title: "Stored", author: "Someone"} = Embeds.cached("yt:#{@yt}")
      # The URL form resolves to the same cache key.
      assert %{title: "Stored"} = Embeds.cached("https://youtu.be/#{@yt}")
    end
  end

  # ── Cache ─────────────────────────────────────────────────────────────────

  describe "Dran.Embeds.Cache" do
    test "an entry past its ttl reads as a miss" do
      Cache.put({:oembed, "yt:test"}, {:ok, %{}}, 1_000)
      assert {:ok, _} = Cache.get({:oembed, "yt:test"})

      # 1_001 ms later the entry is dead: the caller re-fetches, never renders
      # a value that was meant to expire.
      assert :miss = Cache.get({:oembed, "yt:test"}, System.monotonic_time(:millisecond) + 1_001)
      assert :miss = Cache.get({:oembed, "yt:test"})
    end

    test "clear/0 empties the table" do
      Cache.put({:oembed, "yt:test"}, {:ok, %{}})
      assert {:ok, _} = Cache.get({:oembed, "yt:test"})

      Cache.clear()
      assert :miss = Cache.get({:oembed, "yt:test"})
    end
  end
end
