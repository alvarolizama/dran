defmodule DranWeb.PageEditEmbedsTest do
  @moduledoc """
  The server half of the paste flow: the editor inserts `![[yt:ID]]` and asks
  `resolve_embed` for the title, which the handler answers with a reply (the JS
  hook writes it into the embed's display text) and caches — that cache is the
  only thing the RENDER path reads.
  """
  use ExUnit.Case, async: false

  alias Dran.Embeds
  alias Dran.Embeds.Cache
  alias DranWeb.PageEdit

  @yt "dQw4w9WgXcQ"

  setup do
    original = Application.get_env(:dran, :embeds)
    Application.put_env(:dran, :embeds, req_plug: {Req.Test, Dran.Embeds})
    Cache.clear()

    on_exit(fn ->
      restore(original)
      Cache.clear()
    end)

    :ok
  end

  defp restore(nil), do: Application.delete_env(:dran, :embeds)
  defp restore(value), do: Application.put_env(:dran, :embeds, value)

  defp resolve(ref) do
    assert {:reply, reply, _socket} =
             PageEdit.handle_event("resolve_embed", %{"ref" => ref}, %{assigns: %{}})

    reply
  end

  test "answers with the oEmbed title and warms the cache the renderer reads" do
    Req.Test.stub(Dran.Embeds, fn conn ->
      Req.Test.json(conn, %{
        "title" => "Never Gonna Give You Up",
        "author_name" => "Rick Astley",
        "provider_name" => "YouTube"
      })
    end)

    assert %{ok: true, title: "Never Gonna Give You Up", author: "Rick Astley"} =
             resolve("yt:#{@yt}")

    assert %{title: "Never Gonna Give You Up"} = Embeds.cached("yt:#{@yt}")
  end

  test "a map answers ok: false — Google Maps publishes no oEmbed endpoint" do
    # No stub configured: any request would raise.
    assert %{ok: false, reason: reason} = resolve("map:Eiffel Tower")
    assert reason =~ "no_oembed"
  end

  test "a provider failure is reported, never raised into the socket" do
    Req.Test.stub(Dran.Embeds, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert %{ok: false, reason: reason} = resolve("yt:#{@yt}")
    assert reason =~ "http_status"
  end

  test "a hostile reference never reaches the network" do
    # No stub configured: a request would raise.
    assert %{ok: false, reason: reason} = resolve("evil:payload")
    assert reason =~ "unsupported_provider"
  end

  test "a missing ref is refused deterministically" do
    assert {:reply, %{ok: false, reason: "missing_ref"}, _socket} =
             PageEdit.handle_event("resolve_embed", %{}, %{assigns: %{}})
  end
end
