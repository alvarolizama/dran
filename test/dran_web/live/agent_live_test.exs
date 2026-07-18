defmodule DranWeb.AgentLiveTest do
  use DranWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn}
  end

  describe "research agent form" do
    test "shows max_pages input with default from settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/research")

      assert has_element?(view, "#agent-form")
      assert has_element?(view, "#agent-form input[name='agent[max_pages]']")

      # Default value comes from Dran.Settings ("agent_max_pages", default 10)
      expected = to_string(Dran.Settings.get("agent_max_pages") || 10)
      assert has_element?(view, "#agent-form input[name='agent[max_pages]'][value='#{expected}']")
    end

    test "shows language selector", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/research")

      assert has_element?(view, "#agent-form select[name='agent[lang]']")
    end
  end

  describe "ingest agent form" do
    test "does NOT show max_pages input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/ingest")

      assert has_element?(view, "#agent-form")
      refute has_element?(view, "#agent-form input[name='agent[max_pages]']")
    end
  end
end
