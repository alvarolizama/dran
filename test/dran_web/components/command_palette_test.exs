defmodule DranWeb.CommandPaletteTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  import Phoenix.LiveViewTest

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

    # Ensure the default "personal" context exists
    context =
      Brain.get_context_by_slug("personal") ||
        elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, context: context}
  end

  describe "rendering" do
    test "renders root container but no overlay when closed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(id="command-palette")
      assert html =~ ~s(phx-hook="CommandPalette")
      refute html =~ ~s(role="dialog")
    end

    test "toggle event opens the modal dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#command-palette")
      |> render_hook("toggle", %{})

      html = render(view)
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
    end
  end

  describe "quick actions" do
    test "quick actions are visible when query is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#command-palette")
      |> render_hook("toggle", %{})

      html = render(view)
      assert html =~ "New Note"
      assert html =~ "New Todo"
      assert html =~ "Go to Graph"
      assert html =~ "Go to Todos"
      assert html =~ "Go to Dashboard"
    end
  end

  describe "search" do
    test "typing a query matching an existing page shows the result", %{
      conn: conn,
      context: context
    } do
      # Create a page whose title contains a searchable term
      {:ok, _page} =
        Brain.create_page(%{
          context_id: context.id,
          title: "Elixir Concurrency Guide",
          slug: "elixir-concurrency-guide",
          body: "Elixir processes and message passing",
          page_type: "note"
        })

      {:ok, view, _html} = live(conn, ~p"/")

      # Open the palette
      view
      |> element("#command-palette")
      |> render_hook("toggle", %{})

      # Search for the page
      html =
        view
        |> element("#command-palette")
        |> render_hook("search", %{"query" => "Elixir"})

      # The search result should appear
      assert html =~ "Elixir Concurrency Guide"
    end
  end
end
