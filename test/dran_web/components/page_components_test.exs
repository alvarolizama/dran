defmodule DranWeb.PageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.HTML, only: [safe_to_string: 1]

  alias DranWeb.PageComponents

  defp render(body, opts \\ []) do
    body
    |> PageComponents.render_markdown(opts)
    |> safe_to_string()
  end

  describe "render_markdown/2" do
    test "preserves language-* class on fenced code blocks (mermaid hook depends on it)" do
      html = render("```mermaid\nflowchart LR\n  A --> B\n```")

      assert html =~ ~s(<code class="language-mermaid">)
    end

    test "preserves language class for other languages" do
      html = render("```elixir\nIO.puts(\"hola\")\n```")

      assert html =~ ~s(<code class="language-elixir">)
    end

    test "still renders tables and tasklists" do
      html = render("| a | b |\n|---|---|\n| 1 | 2 |\n\n- [ ] todo\n")

      assert html =~ "<table>"
      assert html =~ "<input"
    end
  end

  describe "render_markdown/2 — external embeds" do
    setup do
      Dran.Embeds.Cache.clear()
      on_exit(fn -> Dran.Embeds.Cache.clear() end)
      :ok
    end

    test "a youtube reference renders a nocookie iframe with the provider allowlist" do
      html = render("![[yt:dQw4w9WgXcQ]]")

      assert html =~ ~s(<iframe src="https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
      assert html =~ ~s(loading="lazy")
      assert html =~ ~s(referrerpolicy="strict-origin-when-cross-origin")
      assert html =~ "allowfullscreen"
      assert html =~ ~s(allow="accelerometer;)
      assert html =~ "<figcaption>YouTube</figcaption>"
      assert html =~ "embed-youtube"
    end

    test "the author's display text wins over the provider label" do
      html = render("![[yt:dQw4w9WgXcQ|Never Gonna Give You Up]]")

      assert html =~ "<figcaption>Never Gonna Give You Up</figcaption>"
      assert html =~ ~s(title="Never Gonna Give You Up")
    end

    test "a cached oEmbed title is used when the author wrote no display text" do
      Dran.Embeds.Cache.put(
        {:oembed, "yt:dQw4w9WgXcQ"},
        {:ok,
         %{
           title: "Rick Astley - Never Gonna Give You Up",
           author: nil,
           thumbnail_url: nil,
           provider: "YouTube"
         }}
      )

      html = render("![[yt:dQw4w9WgXcQ]]")

      assert html =~ "<figcaption>Rick Astley - Never Gonna Give You Up</figcaption>"
    end

    test "a URL pasted into the body renders the same iframe" do
      html = render("![[https://youtu.be/dQw4w9WgXcQ]]")

      assert html =~ ~s(src="https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
      refute html =~ "embed-broken"
    end

    test "vimeo and maps render on their own hosts" do
      vimeo = render("![[vimeo:76979871]]")
      assert vimeo =~ ~s(src="https://player.vimeo.com/video/76979871")
      assert vimeo =~ ~s(allow="autoplay; fullscreen; picture-in-picture")

      maps = render("![[map:Eiffel Tower]]")
      # The `&` of the provider query is escaped: it is an HTML attribute.
      assert maps =~
               ~s(src="https://www.google.com/maps/embed?origin=mfe&amp;pb=!1m2!2m1!1sEiffel+Tower")

      assert maps =~ "embed-maps"
      refute maps =~ "allowfullscreen"
    end

    test "hostile references degrade to a broken marker, never to an iframe" do
      bodies = [
        "![[yt:<script>alert(1)</script>]]",
        ~s|![[yt:" onload="alert(1)]]|,
        "![[yt:short]]",
        "![[evil:payload]]",
        "![[javascript:alert(1)]]",
        "![[https://evil.example.com/embed/dQw4w9WgXcQ]]",
        "![[map:!1m2!2m1!1sX&output=embed]]",
        "![[vimeo:../../etc/passwd]]"
      ]

      for body <- bodies do
        html = render(body)

        refute html =~ "<iframe", "rendered an iframe for #{body}"
        # The reference may still appear as TEXT (that is the broken marker);
        # what must never appear is a foreign host inside a fetched attribute.
        refute html =~ ~s(src="https://evil), "fetched a foreign host for #{body}"
        refute html =~ ~s(src="javascript:), "rendered a javascript src for #{body}"
        assert html =~ "embed-broken", "did not degrade for #{body}"
      end
    end

    test "raw HTML in a body is still discarded — `unsafe` stays off" do
      html = render(~s|<iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>|)

      refute html =~ "<iframe"
      refute html =~ "youtube.com/embed"

      refute render("<script>alert(1)</script>") =~ "<script"
    end
  end
end
