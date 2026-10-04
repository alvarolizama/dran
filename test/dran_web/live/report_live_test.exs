defmodule DranWeb.ReportLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge

  alias Dran.Reports
  # Gettext wrapper. English is the app default locale, so the msgid is
  # what the app renders unless a test pins another locale.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't try to call external APIs
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
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

    context = Knowledge.get_workspace_by_slug("personal")

    {:ok, report} =
      Reports.create_report(%{
        workspace_id: context.id,
        title: "Weekly job report",
        slug: "weekly-job-report",
        body: "All jobs succeeded.",
        report_type: "log"
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, report: report}
  end

  describe "show" do
    test "renders the report detail at /reports/:slug", %{conn: conn, report: report} do
      {:ok, _view, html} = live(conn, ~p"/reports/#{report.slug}")

      # Title, rendered body and the localized type badge
      assert html =~ report.title
      assert html =~ "All jobs succeeded."
      assert html =~ t("Report")
    end

    test "redirects to /activity when the report does not exist", %{conn: conn} do
      result = live(conn, ~p"/reports/no-such-report")
      assert {:error, {:live_redirect, %{to: "/activity"}}} = result
    end
  end

  describe "el destino del reporte (W3)" do
    test "la píldora traduce el destino y se oculta en privado", %{conn: conn, report: report} do
      # El default (`private`) no se anuncia y el valor crudo nunca se imprime.
      {:ok, view, _html} = live(conn, ~p"/reports/#{report.slug}")

      refute has_element?(view, "#report-visibility-badge")
      refute render(view) =~ ">private<"
    end

    test "un reporte público usa la píldora compartida", %{conn: conn} do
      context = Knowledge.get_workspace_by_slug("personal")

      {:ok, public_report} =
        Reports.create_report(%{
          workspace_id: context.id,
          title: "Public job report",
          slug: "public-job-report",
          body: "Shared with the instance.",
          report_type: "log",
          visibility: "public"
        })

      {:ok, view, _html} = live(conn, ~p"/reports/#{public_report.slug}")

      assert has_element?(view, "#report-visibility-badge", t("Public"))
      refute has_element?(view, "#report-visibility-badge[data-inherited='true']")
      refute render(view) =~ ">public<"
    end
  end
end
