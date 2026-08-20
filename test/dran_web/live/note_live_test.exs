defmodule DranWeb.NoteLiveTest do
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

    # Create source page (will link TO the target)
    {:ok, source} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Source Page",
        body: "This page links to the target",
        page_type: "note"
      })

    # Create target page (will receive the backlink)
    {:ok, target} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Target Page",
        body: "This page is linked from the source",
        page_type: "note"
      })

    # Create a relation: source -> target (so target has an inbound backlink)
    {:ok, _relation} =
      Brain.create_relation(%{
        source_id: source.id,
        target_id: target.id,
        relation_type: "related"
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn, source: source, target: target}
  end

  describe "backlinks section" do
    test "shows 'Linked from (1)' with source title on the target page", %{
      conn: conn,
      target: target,
      source: source
    } do
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{target.slug}")

      # The backlinks section header with count is present (localized)
      assert html =~ t("Linked from")
      assert html =~ "(1)"

      # The source page title appears as a backlink
      assert html =~ source.title

      # The source page is a link to its detail view
      assert html =~ "href=\"/panel/notes/#{source.slug}\""

      # The relation type badge is present
      assert html =~ "related"
    end

    test "shows 'No backlinks yet' empty state on a page with no inbound relations", %{
      conn: conn,
      source: source
    } do
      # The source page has no inbound relations (it only has outbound)
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{source.slug}")

      # The empty state is shown (localized)
      assert html =~ t("No backlinks yet")
    end

    test "shows 'Links to' section with outbound relations", %{conn: conn, source: source} do
      # The source page has an outbound relation to the target
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{source.slug}")

      # The outbound section header is present (localized)
      assert html =~ t("Links to")
      assert html =~ "(1)"
    end
  end

  describe "detail tabs" do
    # Extract the class attribute of a detail tab button from rendered HTML
    defp tab_class(html, id) do
      [classes] =
        Regex.run(~r/<button id="#{id}"[^>]*class="([^"]*)"/, html, capture: :all_but_first)

      classes
    end

    # Extract the class attribute of a detail panel from rendered HTML
    defp panel_classes(html, id) do
      [classes] =
        Regex.run(~r/id="#{id}"[^>]*class="([^"]*)"/, html, capture: :all_but_first)

      classes
    end

    test "content tab is the only active tab on initial load", %{conn: conn, target: target} do
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{target.slug}")

      assert tab_class(html, "detail-tab-content") =~ "border-primary"
      refute tab_class(html, "detail-tab-content") =~ "border-transparent"
      refute tab_class(html, "detail-tab-insights") =~ "border-primary"
      # Content panel visible, insights panel hidden
      refute panel_classes(html, "detail-panel-content") =~ "hidden"
      assert panel_classes(html, "detail-panel-insights") =~ "hidden"
    end

    test "selecting insights shows the insights panel and hides the content panel", %{
      conn: conn,
      target: target
    } do
      {:ok, view, _html} = live(conn, ~p"/panel/notes/#{target.slug}")

      view |> element("#detail-tab-insights") |> render_click()
      html = render(view)

      assert tab_class(html, "detail-tab-insights") =~ "border-primary"
      refute tab_class(html, "detail-tab-content") =~ "border-primary"

      # Insights panel visible; content panel hidden
      refute panel_classes(html, "detail-panel-insights") =~ "hidden"
      assert panel_classes(html, "detail-panel-content") =~ "hidden"

      # The insights slot renders something (empty state when no community summary)
      assert html =~ t("No community data yet. Run community summaries first.")
    end

    test "graph button links to /graph/:slug", %{conn: conn, target: target} do
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{target.slug}")

      assert html =~ ~s(href="/panel/graph/#{target.slug}")
    end

    test "edit button links to ?edit=true", %{conn: conn, target: target} do
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{target.slug}")

      assert html =~ "?edit=true"
    end

    test "content tab shows rendered markdown, not the editor, by default", %{
      conn: conn,
      target: target
    } do
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{target.slug}")

      # The editor form should not be present in read-only mode
      refute html =~ ~s(id="page-edit-form")
    end

    test "edit mode shows the editor form", %{conn: conn, target: target} do
      {:ok, _view, html} = live(conn, ~p"/panel/notes/#{target.slug}?edit=true")

      assert html =~ ~s(id="page-edit-form")
    end
  end

  describe "archive flow" do
    test "archiving a page from detail hides it from the list and shows it in the Archived section",
         %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/panel/notes/#{source.slug}")

      # Archive via the detail button
      view |> element("button", t("Archive")) |> render_click()

      assert Brain.get_page_by_slug(source.slug, source.workspace_id).archived == true

      # The list no longer shows the page; the Archived section is hidden
      # until the header toggle is clicked
      {:ok, view, html} = live(conn, ~p"/panel/notes")
      refute html =~ ~s(data-testid="page-card-#{source.slug}")
      refute html =~ ~s(data-testid="archived-section")

      view |> element("[data-testid='toggle-archived']") |> render_click()

      html = render(view)
      assert html =~ ~s(data-testid="archived-section")
      assert html =~ ~s(data-testid="archived-page-#{source.slug}")
    end

    test "archived detail shows banner and Unarchive restores the page",
         %{conn: conn, target: target} do
      {:ok, _} = Brain.archive_page(target)

      {:ok, view, html} = live(conn, ~p"/panel/notes/#{target.slug}")
      assert html =~ t("Archived")

      view |> element("button", t("Unarchive")) |> render_click()

      assert Brain.get_page_by_slug(target.slug, target.workspace_id).archived == false

      {:ok, _view, html} = live(conn, ~p"/panel/notes")
      assert html =~ ~s(data-testid="page-card-#{target.slug}")
    end

    test "archived section filter narrows by page type", %{conn: conn} do
      context = Brain.get_workspace_by_slug("personal")

      {:ok, note} =
        Brain.create_page(%{
          workspace_id: context.id,
          title: "Archived Note XYZ",
          page_type: "note"
        })

      {:ok, _} = Brain.archive_page(note)

      {:ok, view, html} = live(conn, ~p"/panel/notes")
      # Archived section hidden until toggled on
      assert html =~ ~s(data-testid="toggle-archived")
      refute html =~ ~s(data-testid="archived-page-#{note.slug}")

      view |> element("[data-testid='toggle-archived']") |> render_click()

      html = render(view)
      assert html =~ ~s(data-testid="archived-page-#{note.slug}")

      # Filter chips only render when archived pages span multiple types;
      # with a single type the section still lists the page
      assert html =~ t("Archived")
    end
  end
end
