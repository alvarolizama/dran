defmodule DranWeb.JourneyLiveTest do
  use DranWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the journey page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journey")
    assert html =~ "Trayectoria" or html =~ "Journey"
  end
end
