defmodule Dran.PageSummariesTest do
  use Dran.DataCase, async: false

  alias Dran.Knowledge
  alias Dran.PageSummaries

  setup do
    original = Application.get_env(:dran, :inference)

    # The chat capability goes through Dran.Inference.Queue — start it for tests.
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Dran.Inference.Queue.start_link(capability: :chat) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  defp configure_inference! do
    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      chat_model: "Qwen3.5-9B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false
    )
  end

  defp stub_chat!(summary_text) do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      case conn.request_path do
        "/v1/chat/completions" ->
          Req.Test.json(conn, %{
            "id" => "chat-test",
            "object" => "chat.completion",
            "model" => "Qwen3.5-9B",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => summary_text},
                "finish_reason" => "stop"
              }
            ]
          })

        path ->
          Req.Test.json(conn, %{"error" => "unexpected path #{path}"})
      end
    end)
  end

  test "backfill/1 fills the summary of pages that lack one" do
    configure_inference!()

    context = Knowledge.get_workspace_by_slug("personal")

    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Summaryless note",
        slug: "summaryless-note",
        body: "A note with content but no summary yet.",
        page_type: "note"
      })

    stub_chat!(~s({"summary": "A note about backfills", "tags": [], "entities": [], "links": []}))

    assert {:ok, %{filled: 1}} = PageSummaries.backfill(context.id)

    refreshed = Knowledge.get_page_by_slug("summaryless-note", context.id)
    assert refreshed.summary == "A note about backfills"
    assert page.summary in [nil, ""]
  end

  test "backfill/1 never overwrites an existing summary" do
    configure_inference!()

    context = Knowledge.get_workspace_by_slug("personal")

    Knowledge.create_page(%{
      workspace_id: context.id,
      title: "Already summarized",
      slug: "already-summarized",
      body: "A note that already has a summary.",
      summary: "Human set this via MCP",
      page_type: "note"
    })

    stub_chat!(~s({"summary": "LLM wants to overwrite", "tags": [], "entities": [], "links": []}))

    assert {:ok, %{filled: 0}} = PageSummaries.backfill(context.id)

    refreshed = Knowledge.get_page_by_slug("already-summarized", context.id)
    assert refreshed.summary == "Human set this via MCP"
  end

  test "backfill/1 skips pages with empty bodies" do
    configure_inference!()

    context = Knowledge.get_workspace_by_slug("personal")

    Knowledge.create_page(%{
      workspace_id: context.id,
      title: "Empty body",
      slug: "empty-body-note",
      body: "",
      page_type: "note"
    })

    stub_chat!(~s({"summary": "should not be called", "tags": [], "entities": [], "links": []}))

    assert {:ok, %{filled: 0, skipped: 0}} = PageSummaries.backfill(context.id)

    # No chat call was made for it — the stub would have been consumed otherwise.
    refreshed = Knowledge.get_page_by_slug("empty-body-note", context.id)
    assert refreshed.summary in [nil, ""]
  end

  test "backfill/1 returns error when inference is not configured" do
    Application.put_env(:dran, :inference, nil)

    context = Knowledge.get_workspace_by_slug("personal")

    assert {:error, :not_configured} = PageSummaries.backfill(context.id)
  end

  test "backfill/1 counts LLM errors without failing the run" do
    configure_inference!()

    context = Knowledge.get_workspace_by_slug("personal")

    Knowledge.create_page(%{
      workspace_id: context.id,
      title: "Doomed note",
      slug: "doomed-note",
      body: "The LLM will fail on this one.",
      page_type: "note"
    })

    Req.Test.stub(Dran.Inference.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"error" => %{"message" => "boom"}})
    end)

    assert {:ok, %{filled: 0, errors: 1}} = PageSummaries.backfill(context.id)
  end

  test "run_scheduled/0 renders a markdown report" do
    configure_inference!()

    context = Knowledge.get_workspace_by_slug("personal")

    Knowledge.create_page(%{
      workspace_id: context.id,
      title: "Report note",
      slug: "report-note",
      body: "Body for the report test.",
      page_type: "note"
    })

    stub_chat!(~s({"summary": "Reported", "tags": [], "entities": [], "links": []}))

    assert {:ok, report} = PageSummaries.backfill_all()
    body = PageSummaries.report_body(report)

    assert body =~ "# Page summaries backfill"
    assert body =~ "Filled #{report.filled}"
    assert body =~ "Errors #{report.errors}"
  end

  test "backfill/1 ignores archived pages" do
    configure_inference!()

    context = Knowledge.get_workspace_by_slug("personal")

    Knowledge.create_page(%{
      workspace_id: context.id,
      title: "Archived note",
      slug: "archived-note",
      body: "This one is archived.",
      archived: true,
      page_type: "note"
    })

    stub_chat!(~s({"summary": "nope", "tags": [], "entities": [], "links": []}))

    assert {:ok, %{filled: 0}} = PageSummaries.backfill(context.id)
  end
end
