defmodule Dran.ReportTest do
  use Dran.DataCase, async: false

  alias Dran.Brain

  setup do
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

    context =
      Brain.get_workspace_by_slug("personal") ||
        elem(Brain.create_workspace(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  describe "create_report/1" do
    test "creates a report with valid attrs", %{context: ctx} do
      attrs = %{
        workspace_id: ctx.id,
        title: "Test Report",
        slug: "test-report"
      }

      assert {:ok, %Brain.Report{} = report} = Brain.create_report(attrs)
      assert report.title == "Test Report"
    end
  end

  describe "list_reports/1" do
    test "lists reports in a workspace", %{context: ctx} do
      {:ok, _} =
        Brain.create_report(%{
          workspace_id: ctx.id,
          title: "Report A",
          slug: "report-a"
        })

      {:ok, _} =
        Brain.create_report(%{
          workspace_id: ctx.id,
          title: "Report B",
          slug: "report-b"
        })

      reports = Brain.list_reports(ctx.id)
      assert length(reports) == 2
    end
  end
end
