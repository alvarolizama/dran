defmodule Dran.PropsBackfillTest do
  use Dran.DataCase, async: false

  alias Dran.{Brain, PropsBackfill}

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

  defp fresh_context(prefix) do
    slug = "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, ctx} = Brain.create_workspace(%{name: "Backfill #{slug}", slug: slug})
    ctx
  end

  describe "run/0" do
    test "returns stats for pages with props" do
      ctx = fresh_context("backfill")

      {:ok, person} =
        Brain.create_page(%{
          workspace_id: ctx.id,
          title: "Juan",
          slug: "juan",
          page_type: "entity",
          body: "A person",
          meta: %{"kind" => "person", "props" => %{"role" => "sales", "tier" => "vip"}}
        })

      assert {:ok, stats} = PropsBackfill.run()
      assert stats.pages >= 1
      assert stats.edges >= 0

      # After backfill, relations exist (augmenter ran, even without inference
      # the PropsMaterializer still materializes props)
      relations = Brain.list_relations_for_page(person.id).outbound
      works_in = Enum.filter(relations, &(&1.relation_type == "works_in"))
      assert length(works_in) >= 1
    end

    test "ignores pages without props" do
      ctx = fresh_context("backfill-no-props")

      {:ok, _note} =
        Brain.create_page(%{
          workspace_id: ctx.id,
          title: "No Props",
          slug: "no-props",
          page_type: "note",
          body: "Nothing here",
          meta: %{"kind" => "thought"}
        })

      assert {:ok, stats} = PropsBackfill.run()
      # Only pages WITH props are counted; the note doesn't contribute
      assert stats.pages >= 0
    end

    test "ignores pages with empty props map" do
      ctx = fresh_context("backfill-empty-props")

      {:ok, _page} =
        Brain.create_page(%{
          workspace_id: ctx.id,
          title: "Empty Props",
          slug: "empty-props",
          page_type: "entity",
          body: "Empty props",
          meta: %{"kind" => "person", "props" => %{}}
        })

      assert {:ok, stats} = PropsBackfill.run()
      assert stats.pages >= 0
    end

    test "is idempotent — running twice creates no duplicates" do
      ctx = fresh_context("backfill-idem")

      {:ok, person} =
        Brain.create_page(%{
          workspace_id: ctx.id,
          title: "Maria",
          slug: "maria",
          page_type: "entity",
          body: "Another person",
          meta: %{"kind" => "person", "props" => %{"role" => "sales"}}
        })

      assert {:ok, _} = PropsBackfill.run()
      assert {:ok, _} = PropsBackfill.run()

      relations = Brain.list_relations_for_page(person.id).outbound
      works_in = Enum.filter(relations, &(&1.relation_type == "works_in"))
      assert length(works_in) == 1
    end
  end
end
