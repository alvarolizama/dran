defmodule Dran.JourneyTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.Journey

  setup do
    # Disable inference so create_page doesn't call external embedding/rerank APIs
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

    {:ok, context} = Brain.create_workspace(%{name: "Test", slug: "test"})
    {:ok, context: context}
  end

  describe "timeline/1" do
    test "returns empty payload when no log entries", %{context: context} do
      result = Journey.timeline(context.id)

      assert result.buckets == []
      assert result.total == 0
      assert result.stats.total_pages == 0
      assert result.stats.by_type == %{}
      assert result.stats.by_creator == %{}
      assert result.trajectory == []
      assert result.range.granularity == nil
    end

    test "groups pages by day", %{context: context} do
      for i <- 1..5 do
        Brain.create_page(%{
          workspace_id: context.id,
          title: "Page #{i}",
          slug: "page-#{i}",
          page_type: "note"
        })
      end

      result = Journey.timeline(context.id)
      assert length(result.buckets) >= 1
      assert result.total == 5

      bucket = hd(result.buckets)
      assert bucket.total == 5
      assert length(bucket.pages) == 5
      assert match?({_year, _month, _day}, bucket.period_key)
    end

    test "includes type distribution", %{context: context} do
      Brain.create_page(%{workspace_id: context.id, title: "Note", slug: "n1", page_type: "note"})

      Brain.create_page(%{
        workspace_id: context.id,
        title: "Concept",
        slug: "c1",
        page_type: "concept"
      })

      result = Journey.timeline(context.id)
      assert Map.get(result.stats.by_type, "note") == 1
      assert Map.get(result.stats.by_type, "concept") == 1
      assert result.stats.busiest_count == 2
    end

    test "includes creator distribution", %{context: context} do
      Brain.create_page(%{
        workspace_id: context.id,
        title: "By Alvaro",
        slug: "a1",
        page_type: "note",
        created_by: "alvaro"
      })

      Brain.create_page(%{
        workspace_id: context.id,
        title: "By Agent",
        slug: "a2",
        page_type: "note",
        created_by: "agent"
      })

      result = Journey.timeline(context.id)
      assert Map.get(result.stats.by_creator, "alvaro") == 1
      assert Map.get(result.stats.by_creator, "agent") == 1
    end

    test "computes cumulative trajectory points for sparkline", %{context: context} do
      for i <- 1..3 do
        Brain.create_page(%{
          workspace_id: context.id,
          title: "P#{i}",
          slug: "p#{i}",
          page_type: "note"
        })
      end

      result = Journey.timeline(context.id)
      assert length(result.trajectory) == length(result.buckets)
      # Trajectory is cumulative — last point equals total
      assert List.last(result.trajectory) == result.total
      # Every point >= previous (monotonic non-decreasing)
      assert result.trajectory == Enum.sort(result.trajectory)
    end

    test "exposes axis labels for the timeline", %{context: context} do
      Brain.create_page(%{workspace_id: context.id, title: "Note", slug: "n1", page_type: "note"})

      result = Journey.timeline(context.id)
      assert is_binary(result.axis.start)
      assert is_binary(result.axis.end)
      assert is_integer(result.range.min_ts)
      assert is_integer(result.range.max_ts)
      assert result.range.granularity in ["day", "month", "year"]
    end

    test "excludes second-citizen report pages from the whole timeline", %{context: context} do
      Brain.create_page(%{workspace_id: context.id, title: "Note", slug: "n1", page_type: "note"})

      Brain.create_page(%{
        workspace_id: context.id,
        title: "Job report",
        slug: "r1",
        page_type: "report"
      })

      result = Journey.timeline(context.id)

      # Only the note counts — in total, buckets, by_type and trajectory
      assert result.total == 1
      assert Map.get(result.stats.by_type, "note") == 1
      refute Map.has_key?(result.stats.by_type, "report")
      assert List.last(result.trajectory) == 1

      bucket_pages = Enum.flat_map(result.buckets, & &1.pages)
      assert Enum.map(bucket_pages, & &1.slug) == ["n1"]
    end

    test "a context with only report pages yields the empty payload", %{context: context} do
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Job report",
        slug: "r1",
        page_type: "report"
      })

      assert Journey.timeline(context.id) == Journey.empty_payload()
    end
  end

  describe "suggest_granularity/2" do
    test "returns day when span <= 32 days" do
      assert Journey.suggest_granularity(0, 10 * 86_400) == "day"
      assert Journey.suggest_granularity(0, 32 * 86_400) == "day"
    end

    test "returns month when span <= 18 months" do
      assert Journey.suggest_granularity(0, 60 * 86_400) == "month"
      assert Journey.suggest_granularity(0, 540 * 86_400) == "month"
    end

    test "returns year for longer spans" do
      assert Journey.suggest_granularity(0, 600 * 86_400) == "year"
      assert Journey.suggest_granularity(0, 3_650 * 86_400) == "year"
    end
  end

  describe "type_colors/0" do
    test "returns a deterministic hex color per page type" do
      colors = Journey.type_colors()

      # The 4 remaining page types: note, concept, entity, reference
      assert map_size(colors) == 4
      assert colors == Journey.type_colors()
      assert colors["note"] == "#D36969"
      assert Enum.all?(colors, fn {_type, hex} -> Regex.match?(~r/^#[0-9A-F]{6}$/, hex) end)
    end

    test "golden-angle spacing yields distinct colors for all types" do
      colors = Journey.type_colors()
      assert colors |> Map.values() |> Enum.uniq() |> length() == map_size(colors)
    end
  end
end
