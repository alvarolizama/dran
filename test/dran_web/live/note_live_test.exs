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

    # Create source page (will link TO the target)
    {:ok, source} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Source Page",
        body: "This page links to the target",
        page_type: "note"
      })

    # Create target page (will receive the backlink)
    {:ok, target} =
      Brain.create_page(%{
        context_id: context.id,
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
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, source: source, target: target}
  end

  describe "backlinks section" do
    test "shows 'Linked from (1)' with source title on the target page", %{
      conn: conn,
      target: target,
      source: source
    } do
      {:ok, _view, html} = live(conn, ~p"/notes/#{target.slug}")

      # The backlinks section header with count is present (localized)
      assert html =~ t("Linked from")
      assert html =~ "(1)"

      # The source page title appears as a backlink
      assert html =~ source.title

      # The source page is a link to its detail view
      assert html =~ "href=\"/notes/#{source.slug}\""

      # The relation type badge is present
      assert html =~ "related"
    end

    test "shows 'No backlinks yet' empty state on a page with no inbound relations", %{
      conn: conn,
      source: source
    } do
      # The source page has no inbound relations (it only has outbound)
      {:ok, _view, html} = live(conn, ~p"/notes/#{source.slug}")

      # The empty state is shown (localized)
      assert html =~ t("No backlinks yet")
    end

    test "shows 'Links to' section with outbound relations", %{conn: conn, source: source} do
      # The source page has an outbound relation to the target
      {:ok, _view, html} = live(conn, ~p"/notes/#{source.slug}")

      # The outbound section header is present (localized)
      assert html =~ t("Links to")
      assert html =~ "(1)"
    end
  end
end
