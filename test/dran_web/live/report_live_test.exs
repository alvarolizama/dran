defmodule DranWeb.ReportLiveTest do
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

    {:ok, report} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Weekly job report",
        body: "All jobs succeeded.",
        page_type: "report",
        meta: %{"kind" => "log"}
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn, report: report}
  end

  describe "show" do
    test "renders the report detail at /reports/:slug", %{conn: conn, report: report} do
      {:ok, _view, html} = live(conn, ~p"/panel/reports/#{report.slug}")

      # Title, rendered body and the localized type badge
      assert html =~ report.title
      assert html =~ "All jobs succeeded."
      assert html =~ t("Report")
    end

    test "edit mode shows the editor form", %{conn: conn, report: report} do
      {:ok, _view, html} = live(conn, ~p"/panel/reports/#{report.slug}?edit=true")

      assert html =~ ~s(id="page-edit-form")
    end

    test "redirects to /activity when the report does not exist", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/panel/activity"}}} =
               live(conn, ~p"/panel/reports/no-such-report")
    end
  end
end
