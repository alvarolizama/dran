defmodule DranWeb.DashboardLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference so create_page doesn't call external APIs
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

    context = Brain.get_workspace_by_slug("personal")

    # Create some pages so the brain health cards have non-zero values
    {:ok, _page_a} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Dashboard Test Page A",
        slug: "dashboard-test-a",
        page_type: "note",
        body: "content a"
      })

    {:ok, _page_b} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Dashboard Test Page B",
        slug: "dashboard-test-b",
        page_type: "concept",
        body: "content b"
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe
    # through the browser pipeline that Auth expects.
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn}
  end

  describe "brain health section" do
    test "renders the Brain health heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/panel")

      assert html =~ t("Brain health")
    end

    test "renders the four brain health cards with labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/panel")

      # Card labels (localized)
      assert html =~ t("This week")
      assert html =~ t("Embedding coverage")
      assert html =~ t("Relations")
      assert html =~ t("Agent sessions")
    end
  end
end
