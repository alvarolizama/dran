defmodule DranWeb.GraphLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

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

    context = Brain.get_context_by_slug("personal")

    # Create a few pages so the graph has nodes and edges
    {:ok, _page1} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Alpha Note",
        body: "First note for graph test",
        page_type: "note"
      })

    {:ok, _page2} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Beta Concept",
        body: "Second page for graph test",
        page_type: "concept"
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn}
  end
end
