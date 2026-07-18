defmodule DranWeb.ChatWidgetTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  # The app default locale is "es" — assertions must match translated strings.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference so create_page doesn't call external APIs
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      markitdown_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    context =
      Brain.get_context_by_slug("personal") ||
        elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, context: context}
  end

  # Helper: poll render/1 until the predicate returns true or attempts run out.
  # The upload handler uses Task.start + send_update, so the attachment
  # appears asynchronously. This mirrors the `eventually/2` pattern used
  # elsewhere in the test suite (agent tests).
  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: :timeout

  describe "rendering" do
    test "renders the floating FAB button when closed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(id="chat-widget")
      # The FAB is always present
      assert html =~ ~s(id="chat-widget-fab")
      # Panel is not rendered when closed (input form only exists when open)
      refute html =~ ~s(id="chat-widget-form")
    end

    test "toggle event opens the chat panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      html = render(view)
      assert html =~ t("Brain Copilot")
      assert html =~ t("Type a message...")
    end

    test "shows contextual suggestions when messages are empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      html = render(view)
      # Default suggestions (no page_type / view_type)
      assert html =~ t("What can you help me with?")
      assert html =~ t("Summarize recent activity")
    end
  end

  describe "sending messages" do
    test "shows the optimistic user message immediately", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Open the panel
      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Send a message — the optimistic message should appear immediately.
      view
      |> element("#chat-widget-form")
      |> render_submit(%{"text" => "Hello Brain"})

      html = render(view)
      assert html =~ "Hello Brain"
    end

    test "clear event empties the messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      view
      |> element("#chat-widget-form")
      |> render_submit(%{"text" => "A message"})

      html = render(view)
      assert html =~ "A message"

      view
      |> element("#chat-widget-clear")
      |> render_click()

      html = render(view)
      refute html =~ "A message"
    end
  end

  describe "upload UI" do
    test "shows the upload button when the panel is open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="chat-widget-upload")
      assert html =~ ~s(id="chat-widget-file-input")
      assert html =~ "hero-paper-clip"
    end

    test "file input accepts images and audio", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      html = render(view)
      assert html =~ ~s(accept="image/*,audio/*")
    end

    test "upload button is not disabled initially", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      html = render(view)
      # The upload button exists and is not disabled when idle
      assert html =~ ~s(id="chat-widget-upload")
      # The paper-clip button should be present without disabled
      assert html =~ "hero-paper-clip"
    end
  end

  describe "upload_attachment event" do
    test "processes an image upload and shows the attachment", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Simulate the JS hook pushing base64 image data
      png_bytes = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1>>
      base64 = Base.encode64(png_bytes)

      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "photo.png",
        "mime_type" => "image/png",
        "data" => base64
      })

      # The attachment appears asynchronously via Task + send_update
      assert :ok ==
               eventually(fn ->
                 html = render(view)
                 html =~ "photo.png" and html =~ "hero-photo"
               end)
    end

    test "processes an audio upload and shows the attachment", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Simulate the JS hook pushing base64 audio data
      audio_bytes = <<0x49, 0x44, 0x33, 0x03, 0, 0, 0, 0, 0, 0>>
      base64 = Base.encode64(audio_bytes)

      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "voice.mp3",
        "mime_type" => "audio/mpeg",
        "data" => base64
      })

      assert :ok ==
               eventually(fn ->
                 html = render(view)
                 html =~ "voice.mp3" and html =~ "hero-musical-note"
               end)
    end

    test "processes upload synchronously and shows attachment immediately", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      png_bytes = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1>>
      base64 = Base.encode64(png_bytes)

      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "photo.png",
        "mime_type" => "image/png",
        "data" => base64
      })

      html = render(view)
      # Processing is synchronous — attachment appears immediately
      assert html =~ "photo.png"
      assert html =~ "hero-photo"
      # No lingering processing indicator
      refute html =~ t("Processing...")
    end

    test "handles invalid base64 gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Push invalid base64 data
      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "bad.png",
        "mime_type" => "image/png",
        "data" => "!!!not-valid-base64!!!"
      })

      # The processing indicator should disappear after the error
      assert :ok ==
               eventually(fn ->
                 html = render(view)
                 not (html =~ t("Processing..."))
               end)
    end
  end

  describe "removing attachments" do
    test "remove-attachment event removes the attachment from the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Add an attachment first
      png_bytes = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1>>
      base64 = Base.encode64(png_bytes)

      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "to-remove.png",
        "mime_type" => "image/png",
        "data" => base64
      })

      # Wait for attachment to appear
      assert :ok ==
               eventually(fn ->
                 render(view) =~ "to-remove.png"
               end)

      # Find the attachment ref from the rendered HTML
      html = render(view)

      # The attachment badge has an id like "chat-widget-attachment-<ref>"
      # Extract the ref and remove it
      assert Regex.match?(~r/chat-widget-attachment-[A-Za-z0-9_-]+/, html)

      # Get the ref from the remove button's phx-value-ref
      ref =
        case Regex.run(~r/phx-value-ref="([A-Za-z0-9_-]+)"/, html) do
          [_, r] -> r
          nil -> flunk("No attachment ref found in HTML")
        end

      # Remove the attachment
      view
      |> with_target("#chat-widget")
      |> render_hook("remove-attachment", %{"ref" => ref})

      html = render(view)
      refute html =~ "to-remove.png"
    end
  end

  describe "sending with attachments" do
    test "injects attachment text into the message when sent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Add an image attachment
      png_bytes = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1>>
      base64 = Base.encode64(png_bytes)

      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "diagram.png",
        "mime_type" => "image/png",
        "data" => base64
      })

      # Wait for attachment to be processed
      assert :ok ==
               eventually(fn ->
                 render(view) =~ "diagram.png"
               end)

      # Send a message with the attachment
      view
      |> element("#chat-widget-form")
      |> render_submit(%{"text" => "What is in this image?"})

      html = render(view)
      # The user message should contain both the text and the image description
      assert html =~ "What is in this image?"
      assert html =~ "[Imagen:"
    end

    test "allows sending with only an attachment (no text)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Add an audio attachment
      audio_bytes = <<0x49, 0x44, 0x33, 0x03, 0, 0, 0, 0, 0, 0>>
      base64 = Base.encode64(audio_bytes)

      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "note.mp3",
        "mime_type" => "audio/mpeg",
        "data" => base64
      })

      # Wait for attachment to be processed
      assert :ok ==
               eventually(fn ->
                 render(view) =~ "note.mp3"
               end)

      # Send with empty text — should still send because there's an attachment
      view
      |> element("#chat-widget-form")
      |> render_submit(%{"text" => ""})

      html = render(view)
      assert html =~ "[Audio:"
    end

    test "clears attachments after sending", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#chat-widget-fab")
      |> render_click()

      # Add an attachment
      png_bytes = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1>>
      base64 = Base.encode64(png_bytes)

      view
      |> with_target("#chat-widget")
      |> render_hook("upload_attachment", %{
        "filename" => "temp.png",
        "mime_type" => "image/png",
        "data" => base64
      })

      assert :ok ==
               eventually(fn ->
                 render(view) =~ "temp.png"
               end)

      # Send the message
      view
      |> element("#chat-widget-form")
      |> render_submit(%{"text" => "describe this"})

      html = render(view)
      # The attachment badge should no longer be in the attachment preview area
      # (it's now part of the message)
      refute html =~ ~s(id="chat-widget-attachment-)
    end
  end
end
