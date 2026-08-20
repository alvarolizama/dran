defmodule DranWeb.JourneyLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Knowledge

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't try to call external APIs
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
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

    # Create some pages for the journey
    context = Knowledge.get_workspace_by_slug("personal")

    for i <- 1..3 do
      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Test Page #{i}",
        slug: "test-page-#{i}",
        page_type: "note"
      })
    end

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn}
  end

  test "renders the journey page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/panel/journey")
    assert html =~ "Trayectoria" or html =~ "Journey"
  end
end
