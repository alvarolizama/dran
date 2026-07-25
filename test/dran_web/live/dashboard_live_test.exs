defmodule DranWeb.DashboardLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  # Phoenix HTML escapes apostrophes as &#39; in rendered output.
  defp html_escape(text), do: String.replace(text, "'", "&#39;")

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

    context = Brain.get_context_by_slug("personal")

    # Create some pages so the brain health cards have non-zero values
    {:ok, _page_a} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Dashboard Test Page A",
        slug: "dashboard-test-a",
        page_type: "note",
        body: "content a"
      })

    {:ok, _page_b} =
      Brain.create_page(%{
        context_id: context.id,
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
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn}
  end

  describe "brain health section" do
    test "renders the Brain health heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ t("Brain health")
    end

    test "renders the four brain health cards with labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Card labels (localized)
      assert html =~ t("This week")
      assert html =~ t("Embedding coverage")
      assert html =~ t("Relations")
      assert html =~ t("Agents")
    end

    test "shows daily note CTA when today's note does not exist", %{conn: conn} do
      # Ensure no daily note exists for today
      slug = "daily-" <> Date.to_iso8601(Date.utc_today())
      context = Brain.get_context_by_slug("personal")

      if page = Brain.get_page_by_slug(slug, context.id) do
        Brain.delete_page(page)
      end

      {:ok, _view, html} = live(conn, ~p"/")

      # The CTA button is present (phx-click attribute)
      assert html =~ "open_daily_note"
      # The CTA text (localized, HTML-escaped)
      assert html =~ html_escape(t("Open today's note"))
      assert html =~ t("No daily note for today yet.")
    end

    test "shows ready state when today's note exists with content", %{conn: conn} do
      context = Brain.get_context_by_slug("personal")
      slug = "daily-" <> Date.to_iso8601(Date.utc_today())

      # Clean up any existing daily note first
      if page = Brain.get_page_by_slug(slug, context.id) do
        Brain.delete_page(page)
      end

      # Create a daily note with content
      {:ok, _note} =
        Brain.create_page(%{
          context_id: context.id,
          title: "Daily — #{Date.to_iso8601(Date.utc_today())}",
          slug: slug,
          page_type: "note",
          body: "Some content for today",
          meta: %{"kind" => "journal", "date" => Date.to_iso8601(Date.utc_today())}
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ html_escape(t("Today's daily note is ready."))
    end
  end
end
