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
end
