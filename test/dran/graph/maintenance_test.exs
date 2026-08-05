defmodule Dran.Graph.MaintenanceTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.Graph.Maintenance

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
    {:ok, ctx} = Brain.create_context(%{name: "Maintenance Test #{slug}", slug: slug})
    ctx
  end

  defp create_page(ctx, slug) do
    {:ok, page} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "note",
        body: ""
      })

    page
  end

  defp semantic_edge(source, target, distance) do
    {:ok, rel} =
      Brain.create_relation(%{
        source_id: source.id,
        target_id: target.id,
        relation_type: "semantic",
        weight: distance,
        meta: %{"auto" => true, "distance" => distance}
      })

    rel
  end

  defp semantic_count(ctx) do
    import Ecto.Query

    Dran.Repo.all(
      from r in Brain.Relation,
        join: s in Brain.Page,
        on: s.id == r.source_id,
        where: s.context_id == ^ctx.id,
        where: r.relation_type == "semantic",
        select: count(r.id)
    )
    |> List.first()
  end

  describe "prune_semantic/2" do
    test "deletes edges above the threshold, keeps the rest" do
      ctx = fresh_context("prune")
      a = create_page(ctx, "a")
      b = create_page(ctx, "b")
      c = create_page(ctx, "c")

      semantic_edge(a, b, 0.10)
      semantic_edge(b, a, 0.10)
      semantic_edge(a, c, 0.50)
      semantic_edge(c, a, 0.50)

      assert semantic_count(ctx) == 4

      deleted = Maintenance.prune_semantic(ctx.id, 0.28)

      assert deleted == 2
      assert semantic_count(ctx) == 2
    end

    test "never touches non-semantic relations regardless of weight" do
      ctx = fresh_context("prune-types")
      a = create_page(ctx, "a")
      b = create_page(ctx, "b")

      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "related",
          weight: 0.99
        })

      deleted = Maintenance.prune_semantic(ctx.id, 0.1)

      assert deleted == 0
      assert length(Brain.list_relations_for_page(a.id).outbound) == 1
    end

    test "uses the long-body setting threshold when none is given" do
      ctx = fresh_context("prune-default")
      a = create_page(ctx, "a")
      b = create_page(ctx, "b")

      # Default long threshold is 0.28 per PageAugmenter docs
      semantic_edge(a, b, 0.50)

      deleted = Maintenance.prune_semantic(ctx.id)
      assert deleted == 1
    end

    test "edges with no distance info are left alone" do
      ctx = fresh_context("prune-nodist")
      a = create_page(ctx, "a")
      b = create_page(ctx, "b")

      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "semantic",
          meta: %{"auto" => true}
        })

      assert Maintenance.prune_semantic(ctx.id, 0.01) == 0
    end
  end

  describe "filter_mutual/1" do
    test "keeps reciprocated edges, drops one-directional ones" do
      ctx = fresh_context("mutual")
      a = create_page(ctx, "a")
      b = create_page(ctx, "b")
      c = create_page(ctx, "c")

      # Mutual pair
      semantic_edge(a, b, 0.10)
      semantic_edge(b, a, 0.10)

      # One-directional
      semantic_edge(a, c, 0.12)

      deleted = Maintenance.filter_mutual(ctx.id)

      assert deleted == 1
      assert semantic_count(ctx) == 2
    end

    test "does not touch non-semantic edges" do
      ctx = fresh_context("mutual-types")
      a = create_page(ctx, "a")
      b = create_page(ctx, "b")

      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "part_of"
        })

      assert Maintenance.filter_mutual(ctx.id) == 0
    end
  end

  describe "sweep/1" do
    test "prunes first, then drops non-mutual survivors" do
      ctx = fresh_context("sweep")
      a = create_page(ctx, "a")
      b = create_page(ctx, "b")
      c = create_page(ctx, "c")
      d = create_page(ctx, "d")

      # Mutual and close — survives everything
      semantic_edge(a, b, 0.10)
      semantic_edge(b, a, 0.10)

      # Mutual but weak — pruned by threshold
      semantic_edge(c, d, 0.90)
      semantic_edge(d, c, 0.90)

      # Close but one-directional — removed by mutual filter
      semantic_edge(a, c, 0.15)

      result = Maintenance.sweep(ctx.id)

      assert result.pruned == 2
      assert result.non_mutual == 1
      assert semantic_count(ctx) == 2
    end
  end
end
