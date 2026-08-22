defmodule Dran.Graph.ClusterSummariesTest do
  use Dran.DataCase, async: false

  # Tests for Dran.Graph.ClusterSummaries (Plan F1: Cluster Summaries).
  #
  # Same setup pattern as graph_test.exs: inference is disabled so the pages
  # helpers never call external embedding/rerank APIs, and `generate_all/1`
  # falls back to its deterministic summary. Each test creates its OWN isolated
  # context (rather than sharing "personal"). `async: false` keeps the sandbox
  # in shared mode so the `Task.async_stream` workers can check out a
  # connection.

  alias Dran.Knowledge
  alias Dran.Graph.ClusterSummaries
  alias Dran.Repo

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

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp fresh_context(prefix) do
    slug = "comm-#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, ctx} = Knowledge.create_workspace(%{name: "Comm Test #{slug}", slug: slug})
    ctx
  end

  defp create_page(ctx, slug, cluster_id, pagerank) do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "note",
        body: "",
        summary: "Summary for #{slug}",
        meta: %{"cluster_id" => cluster_id, "pagerank" => pagerank}
      })

    page
  end

  # Two clusters: cluster 1 has 2 pages, cluster 2 has 1 page, and one
  # page has no cluster_id (must be ignored).
  defp ctx_with_clusters do
    ctx = fresh_context("two")
    create_page(ctx, "comm-a1", 1, 0.9)
    create_page(ctx, "comm-a2", 1, 0.5)
    create_page(ctx, "comm-b1", 2, 0.1)
    create_page(ctx, "comm-orphan", nil, 0.0)
    ctx
  end

  defp persisted(workspace_id) do
    Repo.all(
      from cs in Dran.Graph.ClusterSummary,
        where: cs.workspace_id == ^workspace_id,
        order_by: cs.cluster_id
    )
  end

  # ── generate_all/1 ────────────────────────────────────────────────────────

  describe "generate_all/1" do
    test "persists one summary per cluster with page_count and fallback summary" do
      ctx = ctx_with_clusters()

      assert :ok = ClusterSummaries.generate_all(ctx.id)

      rows = persisted(ctx.id)
      assert length(rows) == 2

      [c1, c2] = rows
      # Summary row for cluster 1 (2 pages) sorts before cluster 2 (1 page)
      # when ordered by cluster_id.
      assert c1.cluster_id == 1
      assert c1.page_count == 2
      assert c1.summary =~ "Cluster of 2 pages including:"
      assert c1.summary =~ "comm-a1"
      assert c1.summary =~ "comm-a2"
      assert Enum.map(c1.top_pages, & &1["slug"]) == ["comm-a1", "comm-a2"]

      assert c2.cluster_id == 2
      assert c2.page_count == 1
      assert c2.summary =~ "Cluster of 1 pages including: comm-b1"
    end

    test "pages without a cluster_id are ignored" do
      ctx = ctx_with_clusters()

      :ok = ClusterSummaries.generate_all(ctx.id)

      rows = persisted(ctx.id)
      assert length(rows) == 2
      refute Enum.any?(rows, &(&1.cluster_id == nil))
    end

    test "returns :ok for a context with no clusters" do
      ctx = fresh_context("empty")
      assert :ok = ClusterSummaries.generate_all(ctx.id)
      assert persisted(ctx.id) == []
    end

    test "regenerating upserts rather than duplicating rows" do
      ctx = ctx_with_clusters()

      :ok = ClusterSummaries.generate_all(ctx.id)
      :ok = ClusterSummaries.generate_all(ctx.id)

      rows = persisted(ctx.id)
      assert length(rows) == 2
    end

    test "stores the top pages sorted by pagerank desc" do
      ctx = fresh_context("top")
      create_page(ctx, "comm-lo", 1, 0.2)
      create_page(ctx, "comm-mid", 1, 0.5)
      create_page(ctx, "comm-hi", 1, 0.9)

      assert :ok = ClusterSummaries.generate_all(ctx.id)

      {:ok, summary} = ClusterSummaries.get_summary(ctx.id, 1)
      # Highest pagerank first.
      assert Enum.map(summary.top_pages, & &1["slug"]) == ["comm-hi", "comm-mid", "comm-lo"]

      # Each entry carries slug, title, and pagerank (jsonb decodes to string keys).
      [top | _] = summary.top_pages
      assert top["title"] == "comm-hi"
      assert is_float(top["pagerank"])
    end

    test "only keeps the top 10 pages" do
      ctx = fresh_context("topcap")

      for i <- 1..15 do
        create_page(ctx, "comm-p#{i}", 1, i / 10)
      end

      :ok = ClusterSummaries.generate_all(ctx.id)

      {:ok, summary} = ClusterSummaries.get_summary(ctx.id, 1)
      assert length(summary.top_pages) == 10
      # Pages 15..6 have the highest pagerank (i/10 for i in 1..15), in desc order.
      assert Enum.map(summary.top_pages, & &1["slug"]) ==
               Enum.map(15..6//-1, &"comm-p#{&1}")
    end
  end

  # ── Fallback (inference not configured) ────────────────────────────────────

  describe "fallback when inference is not configured" do
    test "skips the LLM and writes a deterministic fallback summary" do
      ctx = ctx_with_clusters()

      # Inference is disabled in this suite; assert the fallback string is used
      # and no `content` came from an external call.
      assert :ok = ClusterSummaries.generate_all(ctx.id)

      rows = persisted(ctx.id)
      assert length(rows) == 2

      assert Enum.all?(rows, fn row -> String.starts_with?(row.summary, "Cluster of ") end)
      assert Enum.all?(rows, fn row -> String.contains?(row.summary, "pages including:") end)
    end
  end

  # ── get_summary/2 ─────────────────────────────────────────────────────────

  describe "get_summary/2" do
    test "returns the summary for a specific cluster" do
      ctx = ctx_with_clusters()
      :ok = ClusterSummaries.generate_all(ctx.id)

      assert {:ok, summary} = ClusterSummaries.get_summary(ctx.id, 1)
      assert summary.cluster_id == 1
      assert summary.page_count == 2
      assert summary.summary =~ "comm-a1"

      assert {:ok, summary2} = ClusterSummaries.get_summary(ctx.id, 2)
      assert summary2.cluster_id == 2
    end

    test "returns :not_found for an unknown cluster" do
      ctx = fresh_context("gnf")
      assert {:error, :not_found} = ClusterSummaries.get_summary(ctx.id, 99)
    end
  end

  # ── get_summary_for_page/1 ────────────────────────────────────────────────

  describe "get_summary_for_page/1" do
    test "finds the summary for the cluster a page belongs to" do
      ctx = ctx_with_clusters()
      page = create_page(ctx, "comm-extra", 1, 0.3)
      :ok = ClusterSummaries.generate_all(ctx.id)

      assert {:ok, summary} = ClusterSummaries.get_summary_for_page(page.id)
      assert summary.cluster_id == 1
      assert summary.page_count == 3
    end

    test "returns :not_found when the page has no cluster" do
      ctx = ctx_with_clusters()
      page = create_page(ctx, "comm-orphan2", nil, 0.0)
      :ok = ClusterSummaries.generate_all(ctx.id)

      assert {:error, :not_found} = ClusterSummaries.get_summary_for_page(page.id)
    end

    test "returns :not_found for an unknown page" do
      assert {:error, :not_found} =
               ClusterSummaries.get_summary_for_page("00000000-0000-4000-8000-000000000000")
    end
  end

  # ── list_summaries/1 ─────────────────────────────────────────────────────

  describe "list_summaries/1" do
    test "returns summaries ordered by page_count desc" do
      ctx = ctx_with_clusters()
      :ok = ClusterSummaries.generate_all(ctx.id)

      [first | _rest] = ClusterSummaries.list_summaries(ctx.id)
      assert first.page_count == 2

      page_count_desc =
        ctx.id
        |> ClusterSummaries.list_summaries()
        |> Enum.map(& &1.page_count)

      assert page_count_desc == Enum.sort(page_count_desc, :desc)
    end

    test "returns an empty list for a context with no summaries" do
      ctx = fresh_context("ls-empty")
      assert ClusterSummaries.list_summaries(ctx.id) == []
    end
  end

  # ── delete_all/1 ─────────────────────────────────────────────────────────

  describe "delete_all/1" do
    test "removes all summaries for a context" do
      ctx = ctx_with_clusters()
      :ok = ClusterSummaries.generate_all(ctx.id)

      assert length(persisted(ctx.id)) == 2
      assert :ok = ClusterSummaries.delete_all(ctx.id)
      assert persisted(ctx.id) == []
    end

    test "returns :ok when there is nothing to delete" do
      ctx = fresh_context("da-empty")
      assert :ok = ClusterSummaries.delete_all(ctx.id)
    end
  end

  # ── summarize_with_llm nil content guard ─────────────────────────────────

  describe "LLM nil content degrades gracefully" do
    test "uses fallback summary when inference is not configured (nil content path)" do
      ctx = fresh_context("nilc")
      create_page(ctx, "nilc-page1", 1, 0.8)

      assert :ok = ClusterSummaries.generate_all(ctx.id)

      {:ok, summary} = ClusterSummaries.get_summary(ctx.id, 1)
      assert summary.summary =~ "Cluster of 1 pages including: nilc-page1"
    end
  end
end
