defmodule Dran.PropsMaterializerTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.PropsMaterializer

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
    {:ok, ctx} = Brain.create_context(%{name: "Props Test #{slug}", slug: slug})
    ctx
  end

  defp create_person(ctx, slug, props) do
    {:ok, page} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "entity",
        body: "A person",
        meta: %{"kind" => "person", "props" => props}
      })

    page
  end

  describe "materializable_keys/0" do
    test "returns the known prop keys" do
      keys = PropsMaterializer.materializable_keys()
      assert "role" in keys
      assert "tier" in keys
      assert "location" in keys
      assert "language" in keys
      assert "framework" in keys
    end
  end

  describe "materialize/1" do
    test "creates target page and typed relation for a mapped prop" do
      ctx = fresh_context("mat")
      person = create_person(ctx, "juan", %{"role" => "sales"})

      assert {:ok, 1} = PropsMaterializer.materialize(person)

      target = Brain.get_page_by_slug("sales", ctx.id)
      assert target.page_type == "entity"
      assert target.meta["auto"] == true
      assert target.meta["created_from"] == "props_materializer"

      relations = Brain.list_relations_for_page(person.id).outbound
      works_in = Enum.filter(relations, &(&1.relation_type == "works_in"))
      assert length(works_in) == 1
      assert hd(works_in).target_id == target.id
    end

    test "materializes multiple props at once" do
      ctx = fresh_context("mat-multi")
      person = create_person(ctx, "juan", %{"role" => "sales", "tier" => "vip"})

      assert {:ok, 2} = PropsMaterializer.materialize(person)

      sales = Brain.get_page_by_slug("sales", ctx.id)
      vip = Brain.get_page_by_slug("vip", ctx.id)
      assert sales.page_type == "entity"
      assert vip.page_type == "concept"

      relations = Brain.list_relations_for_page(person.id).outbound
      works_in = Enum.filter(relations, &(&1.relation_type == "works_in"))
      has_tier = Enum.filter(relations, &(&1.relation_type == "has_tier"))
      assert length(works_in) == 1
      assert length(has_tier) == 1
    end

    test "ignores unmapped props silently" do
      ctx = fresh_context("mat-unmapped")
      person = create_person(ctx, "juan", %{"role" => "sales", "favorite_color" => "blue"})

      assert {:ok, 1} = PropsMaterializer.materialize(person)

      # Only the mapped prop created an edge
      relations = Brain.list_relations_for_page(person.id).outbound
      assert length(relations) == 1
      assert hd(relations).relation_type == "works_in"

      # No page for the unmapped prop
      assert Brain.get_page_by_slug("blue", ctx.id) == nil
    end

    test "page without props materializes nothing" do
      ctx = fresh_context("mat-no-props")

      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "plain",
          slug: "plain",
          page_type: "note",
          body: "no props",
          meta: %{"kind" => "thought"}
        })

      assert {:ok, 0} = PropsMaterializer.materialize(page)
    end

    test "page with nil meta materializes nothing" do
      ctx = fresh_context("mat-nil-meta")

      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "nilmeta",
          slug: "nilmeta",
          page_type: "note",
          body: "nil meta"
        })

      assert {:ok, 0} = PropsMaterializer.materialize(page)
    end

    test "reuses existing target page of correct type" do
      ctx = fresh_context("mat-reuse")

      {:ok, _existing} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Sales",
          slug: "sales",
          page_type: "entity",
          body: "existing entity"
        })

      person = create_person(ctx, "juan", %{"role" => "sales"})
      assert {:ok, 1} = PropsMaterializer.materialize(person)

      # Only ONE sales page
      entities =
        Brain.list_pages(context_id: ctx.id, type: "entity")
        |> Enum.filter(&(&1.slug == "sales"))

      assert length(entities) == 1
    end

    test "skips target when slug collides with different page_type" do
      ctx = fresh_context("mat-collision")

      {:ok, _note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Sales",
          slug: "sales",
          page_type: "note",
          body: "a note, not an entity"
        })

      person = create_person(ctx, "juan", %{"role" => "sales"})
      assert {:ok, 0} = PropsMaterializer.materialize(person)

      # No works_in edge created
      relations = Brain.list_relations_for_page(person.id).outbound
      assert Enum.filter(relations, &(&1.relation_type == "works_in")) == []

      # Original note untouched
      assert Brain.get_page_by_slug("sales", ctx.id).page_type == "note"
    end

    test "skips self-links" do
      ctx = fresh_context("mat-self")
      person = create_person(ctx, "sales", %{"role" => "sales"})

      assert {:ok, 0} = PropsMaterializer.materialize(person)

      relations = Brain.list_relations_for_page(person.id).outbound
      assert relations == []
    end

    test "is idempotent — re-materializing creates no duplicates" do
      ctx = fresh_context("mat-idem")
      person = create_person(ctx, "juan", %{"role" => "sales"})

      assert {:ok, 1} = PropsMaterializer.materialize(person)
      assert {:ok, 1} = PropsMaterializer.materialize(person)

      relations = Brain.list_relations_for_page(person.id).outbound
      works_in = Enum.filter(relations, &(&1.relation_type == "works_in"))
      assert length(works_in) == 1
    end

    test "non-string prop values are skipped" do
      ctx = fresh_context("mat-nonstr")
      person = create_person(ctx, "juan", %{"role" => 42})

      assert {:ok, 0} = PropsMaterializer.materialize(person)
    end

    test "empty prop values are skipped" do
      ctx = fresh_context("mat-empty")
      person = create_person(ctx, "juan", %{"role" => "  "})

      assert {:ok, 0} = PropsMaterializer.materialize(person)
    end

    test "caps materializations per page" do
      ctx = fresh_context("mat-cap")

      # Build props with many values for the same mapped key — the module
      # processes map entries (not unique keys), and @max_props_per_page is 10.
      # We can't repeat map keys, so we test the cap by using all 5 mapped keys
      # with distinct values and confirming all 5 materialize (under the cap).
      # A true >10 case would need 11+ mapped keys, which doesn't exist yet.
      props = %{
        "role" => "sales",
        "tier" => "vip",
        "location" => "cdmx",
        "language" => "elixir",
        "framework" => "phoenix"
      }

      person = create_person(ctx, "juan", props)
      assert {:ok, 5} = PropsMaterializer.materialize(person)

      relations = Brain.list_relations_for_page(person.id).outbound
      assert length(relations) == 5

      types = Enum.map(relations, & &1.relation_type) |> Enum.sort()
      assert types == ["based_in", "built_with", "has_tier", "works_in", "written_in"]
    end

    test "page without context materializes nothing" do
      page = %Brain.Page{context_id: nil, meta: %{"props" => %{"role" => "sales"}}}
      assert {:ok, 0} = PropsMaterializer.materialize(page)
    end

    test "props with atom keys in meta are handled" do
      ctx = fresh_context("mat-atom")

      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "atom-props",
          slug: "atom-props",
          page_type: "entity",
          body: "atom keys",
          meta: %{kind: "person", props: %{"role" => "sales"}}
        })

      # Ecto JSONB round-trip stringifies keys, so this tests the stored shape
      assert {:ok, 1} = PropsMaterializer.materialize(page)
    end
  end
end
