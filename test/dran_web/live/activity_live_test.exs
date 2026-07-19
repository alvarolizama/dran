defmodule DranWeb.ActivityLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't try to call external APIs
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

    context = Brain.get_context_by_slug("personal")

    # Create a page — this generates a "page.create" log entry.
    {:ok, page} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Activity Test Page",
        body: "A page for the activity feed test",
        page_type: "note"
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, page: page}
  end

  test "renders the activity feed with the page.create entry", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/activity")

    # Header is present (localized)
    assert html =~ t("Activity")

    # The log entry for the created page appears (slug or title)
    assert html =~ "activity-test-page" or html =~ "Activity Test Page"
    # Action label for create (localized)
    assert html =~ t("Created")
  end

  test "shows relative time for each entry", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/activity")

    # The entry was just created, so it should show "just now"
    assert html =~ t("just now")
  end

  test "links to the created page", %{conn: conn, page: page} do
    {:ok, _view, html} = live(conn, ~p"/activity")

    # The subject slug should be a link to /notes/<slug>
    assert html =~ "href=\"/notes/#{page.slug}\""
  end

  test "renders empty state when no log entries", %{conn: conn} do
    context = Brain.get_context_by_slug("personal")

    import Ecto.Query

    Dran.Repo.delete_all(from(l in Dran.Brain.Log, where: l.context_id == ^context.id))

    {:ok, _view, html} = live(conn, ~p"/activity")

    assert html =~ t("No activity yet")
    assert html =~ t("Create or edit a page to see it here.")
  end

  test "updates live when a new page is created (handle_info)", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/activity")

    # Initially one page exists
    assert html =~ t("Created")

    # Create another page — broadcasts :page_changed to the brain topic
    context = Brain.get_context_by_slug("personal")

    {:ok, _page2} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Second Activity Page",
        body: "Another page",
        page_type: "note"
      })

    # The LiveView is subscribed to the brain:<context_id> topic and should
    # reload on the broadcast. Give it a moment to process.
    Process.sleep(50)

    html = render(view)
    # Both entries should be present now (subject slugs)
    assert html =~ "second-activity-page" or html =~ "Second Activity Page"
  end
end
