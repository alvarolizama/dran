defmodule Dran.KnowledgeTest do
  use Dran.DataCase, async: false

  alias Dran.Knowledge

  setup do
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

    context =
      Knowledge.get_workspace_by_slug("personal") ||
        elem(Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  describe "disabled page types" do
    test "enabled_page_types/1 returns all types minus disabled", %{context: ctx} do
      assert Knowledge.enabled_page_types(ctx) == Knowledge.page_types()

      {:ok, ctx} =
        Knowledge.update_workspace_settings(ctx, %{disabled_page_types: ["reference", "entity"]})

      enabled = Knowledge.enabled_page_types(ctx)
      refute "reference" in enabled
      refute "entity" in enabled
      assert "note" in enabled
    end

    test "page_type_enabled?/2 reflects disabled types", %{context: ctx} do
      {:ok, ctx} = Knowledge.update_workspace_settings(ctx, %{disabled_page_types: ["reference"]})

      refute Knowledge.page_type_enabled?(ctx, "reference")
      assert Knowledge.page_type_enabled?(ctx, "note")
    end

    test "page_type_enabled?/2 treats nil context as all types enabled" do
      assert Knowledge.page_type_enabled?(nil, "note")
      assert Knowledge.page_type_enabled?(nil, "reference")
    end

    test "update_workspace_settings/2 rejects invalid page types", %{context: ctx} do
      assert {:error, changeset} =
               Knowledge.update_workspace_settings(ctx, %{disabled_page_types: ["bogus_type"]})

      assert %{disabled_page_types: [_]} = errors_on(changeset)
    end

    test "create_page/1 rejects disabled page types", %{context: ctx} do
      {:ok, ctx} = Knowledge.update_workspace_settings(ctx, %{disabled_page_types: ["reference"]})

      assert {:error, :page_type_disabled} =
               Knowledge.create_page(%{
                 "title" => "Disabled type page",
                 "page_type" => "reference",
                 "workspace_id" => ctx.id,
                 "body" => "should not be created"
               })

      # Enabled types still work
      assert {:ok, _page} =
               Knowledge.create_page(%{
                 "title" => "Enabled type page",
                 "page_type" => "note",
                 "workspace_id" => ctx.id,
                 "body" => "works fine"
               })
    end

    test "list_pages/1 excludes disabled page types", %{context: ctx} do
      {:ok, _ref} =
        Knowledge.create_page(%{
          "title" => "Hidden reference",
          "page_type" => "reference",
          "workspace_id" => ctx.id,
          "body" => "a reference"
        })

      {:ok, _note} =
        Knowledge.create_page(%{
          "title" => "Visible note",
          "page_type" => "note",
          "workspace_id" => ctx.id,
          "body" => "a note"
        })

      # Before disabling, reference appears
      pages = Knowledge.list_pages(workspace_id: ctx.id)
      assert Enum.any?(pages, &(&1.page_type == "reference"))

      # After disabling, reference is hidden
      {:ok, ctx} = Knowledge.update_workspace_settings(ctx, %{disabled_page_types: ["reference"]})

      pages = Knowledge.list_pages(workspace_id: ctx.id, workspace: ctx)
      refute Enum.any?(pages, &(&1.page_type == "reference"))
      assert Enum.any?(pages, &(&1.page_type == "note"))
    end
  end

  describe "create_page/1 slug derivation" do
    test "derives slug with accent normalization", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Meditación",
          page_type: "note",
          body: "x"
        })

      assert page.slug == "meditacion"
    end

    test "derives slug from body first line when title is missing", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          page_type: "note",
          body: "¿Qué onda con la Tántrica?\nresto del body"
        })

      assert page.slug == "que-onda-con-la-tantrica"
    end

    test "auto-deduplicates slug on collision with hex suffix", %{context: ctx} do
      {:ok, first} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Reunión semanal",
          page_type: "note",
          body: "x"
        })

      {:ok, second} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Reunión semanal",
          page_type: "note",
          body: "y"
        })

      assert first.slug == "reunion-semanal"
      # Second page should get a hex suffix, not a collision error
      assert second.slug =~ ~r/^reunion-semanal-[a-f0-9]{6}$/
      refute second.slug == first.slug
    end

    test "auto-deduplicates untitled pages", %{context: ctx} do
      {:ok, first} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "你好世界",
          page_type: "note",
          body: "x"
        })

      {:ok, second} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "你好世界",
          page_type: "note",
          body: "y"
        })

      # Non-ASCII titles produce no usable slug chars — the fallback is the
      # page type ("note"), and both pages dedup with a random hex suffix
      # instead of failing with a unique constraint error.
      assert first.slug == "note"
      assert second.slug =~ ~r/^note-[a-f0-9]{6}$/
      refute second.slug == first.slug
    end

    test "respects explicit slug even if duplicate (returns error)", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "A",
          slug: "explicit-dup-test",
          page_type: "note"
        })

      {:error, changeset} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "B",
          slug: "explicit-dup-test",
          page_type: "note"
        })

      # When the user explicitly passes a slug, we don't auto-dedup —
      # we surface the unique constraint error so they can choose a different one.
      errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
      assert errors[:slug] || errors[:workspace_id]
    end
  end

  describe "embeds auto-resolution" do
    test "create_page resolves ![[embed]] into embeds relation", %{context: ctx} do
      {:ok, target_page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "File",
          slug: "file-a",
          page_type: "note"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Note",
          slug: "note-a",
          page_type: "note",
          body: "See ![[file-a]]"
        })

      rels = Knowledge.list_relations_for_page(note.id).outbound

      assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == target_page.id))
    end

    test "update_page removes stale embeds relations", %{context: ctx} do
      {:ok, a} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "A", slug: "a", page_type: "note"})

      {:ok, b} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "B", slug: "b", page_type: "note"})

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "N",
          slug: "n",
          page_type: "note",
          body: "![[a]] ![[b]]"
        })

      {:ok, note} = Knowledge.update_page(note, %{"body" => "only ![[a]] now"})

      targets =
        Knowledge.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))
        |> Enum.map(& &1.target_id)

      assert a.id in targets
      refute b.id in targets
    end
  end

  describe "rename_slug/2" do
    test "updates embed references in other pages", %{context: ctx} do
      {:ok, art} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Art",
          slug: "old-art",
          page_type: "note"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "N",
          slug: "n",
          page_type: "note",
          body: "![[old-art]]"
        })

      {:ok, _} = Knowledge.rename_slug(art, "new-art")

      note = Knowledge.get_page!(note.id)
      assert note.body =~ "![[new-art]]"
      refute note.body =~ "old-art"
    end

    test "embeds relation follows the renamed slug", %{context: ctx} do
      {:ok, art} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Art2",
          slug: "old-art2",
          page_type: "note"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "N2",
          slug: "n2",
          page_type: "note",
          body: "![[old-art2]]"
        })

      {:ok, renamed} = Knowledge.rename_slug(art, "new-art2")
      assert renamed.slug == "new-art2"

      rels = Knowledge.list_relations_for_page(note.id).outbound
      assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == art.id))
    end
  end

  describe "graph_data/1" do
    # These tests assert exact node/edge totals against the context. The
    # shared "personal" context can carry stale rows committed outside the
    # sandbox (e.g. ad-hoc `MIX_ENV=test mix run` debug sessions), which
    # would skew every count — so each test gets a fresh, guaranteed-empty
    # context instead.
    setup do
      uniq = System.unique_integer([:positive])

      {:ok, ctx} =
        Knowledge.create_workspace(%{name: "Graph #{uniq}", slug: "graph-#{uniq}"})

      {:ok, context: ctx}
    end

    test "exposes weight on edges and summary/tags on nodes", %{context: ctx} do
      {:ok, a} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Concept A",
          slug: "concept-a",
          page_type: "concept",
          summary: "A short summary of concept A.",
          tags: ["elixir", "otp"]
        })

      {:ok, b} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Concept B",
          slug: "concept-b",
          page_type: "concept",
          summary: "B's summary.",
          tags: ["phoenix"]
        })

      {:ok, _rel} =
        Knowledge.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "related",
          weight: 0.85
        })

      graph = Knowledge.graph_data(ctx.id)

      # Nodes have summary and tags keys
      node_a = Enum.find(graph.nodes, &(&1.id == a.id))
      assert Map.has_key?(node_a, :summary)
      assert Map.has_key?(node_a, :tags)
      assert node_a.summary == "A short summary of concept A."
      assert node_a.tags == ["elixir", "otp"]

      # Edges expose weight
      edge = Enum.find(graph.edges, &(&1.source == a.id and &1.target == b.id))
      assert Map.has_key?(edge, :weight)
      assert_in_delta edge.weight, 0.85, 0.001
    end

    test "exclude_types filters types in SQL", %{context: ctx} do
      {:ok, note} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "Note", page_type: "note"})

      {:ok, ref} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "Ref", page_type: "reference"})

      {:ok, _} =
        Knowledge.create_relation(%{
          source_id: note.id,
          target_id: ref.id,
          relation_type: "related"
        })

      graph = Knowledge.graph_data(ctx.id, exclude_types: ~w(reference))

      assert Enum.map(graph.nodes, & &1.type) == ["note"]
      assert graph.edges == []
      assert graph.total_nodes == 1
      assert graph.total_edges == 0
    end

    test "hidden_from_graph lists no standard types since only 5 exist", %{context: ctx} do
      {:ok, note} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "Note", page_type: "note"})

      {:ok, ref} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "Ref", page_type: "reference"})

      {:ok, _} =
        Knowledge.create_relation(%{
          source_id: note.id,
          target_id: ref.id,
          relation_type: "related"
        })

      # Every registered page type is a full graph citizen, so the default
      # exclusion list is empty and both nodes appear in the graph.
      assert Dran.PageTypes.hidden_from_graph() == []

      graph = Knowledge.graph_data(ctx.id, exclude_types: Dran.PageTypes.hidden_from_graph())

      assert Enum.sort(Enum.map(graph.nodes, & &1.type)) == ["note", "reference"]
      assert length(graph.edges) == 1
    end

    test "max_nodes caps to the most-connected pages and reports real totals", %{context: ctx} do
      # Hub page with 3 relations — always makes the cut
      {:ok, hub} = Knowledge.create_page(%{workspace_id: ctx.id, title: "Hub", page_type: "note"})

      # A reference that is excluded from this graph run (via exclude_types)
      {:ok, ref} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "Ref", page_type: "reference"})

      {:ok, _} =
        Knowledge.create_relation(%{
          source_id: hub.id,
          target_id: ref.id,
          relation_type: "related"
        })

      # Three leaves, each connected to the hub only (degree 1)
      leaves =
        for i <- 1..3 do
          {:ok, leaf} =
            Knowledge.create_page(%{
              workspace_id: ctx.id,
              title: "Leaf #{i}",
              slug: "leaf-#{i}",
              page_type: "note"
            })

          {:ok, _} =
            Knowledge.create_relation(%{
              source_id: hub.id,
              target_id: leaf.id,
              relation_type: "related"
            })

          leaf
        end

      graph = Knowledge.graph_data(ctx.id, exclude_types: ~w(reference), max_nodes: 2)

      # Top 2 by degree among non-excluded types: hub (3) + one of the
      # leaves (1). The other two leaves tie at degree 1, so only one of
      # them is present. The reference never makes the cut.
      assert length(graph.nodes) == 2
      assert Enum.any?(graph.nodes, &(&1.id == hub.id))
      assert Enum.count(graph.nodes, &(&1.id in Enum.map(leaves, fn l -> l.id end))) == 1

      # Only edges between the returned nodes survive
      assert length(graph.edges) == 1

      # Real totals still exclude the reference
      assert graph.total_nodes == 4
      assert graph.total_edges == 3
    end

    test "max_nodes above the page count returns everything (no cap artifacts)", %{context: ctx} do
      {:ok, _a} = Knowledge.create_page(%{workspace_id: ctx.id, title: "A", page_type: "note"})
      {:ok, _b} = Knowledge.create_page(%{workspace_id: ctx.id, title: "B", page_type: "note"})

      graph = Knowledge.graph_data(ctx.id, max_nodes: 100)

      assert length(graph.nodes) == 2
      assert graph.total_nodes == 2
    end

    test "graph_type_counts groups real totals per type", %{context: ctx} do
      {:ok, _} = Knowledge.create_page(%{workspace_id: ctx.id, title: "N1", page_type: "note"})
      {:ok, _} = Knowledge.create_page(%{workspace_id: ctx.id, title: "N2", page_type: "note"})

      {:ok, _} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "R1", page_type: "reference"})

      {:ok, _} = Knowledge.create_page(%{workspace_id: ctx.id, title: "C1", page_type: "concept"})

      assert Knowledge.graph_type_counts(ctx.id) == %{
               "note" => 2,
               "reference" => 1,
               "concept" => 1,
               "goal" => 0,
               "memory" => 0
             }

      assert Knowledge.graph_type_counts(ctx.id, ~w(reference)) == %{
               "note" => 2,
               "concept" => 1,
               "goal" => 0,
               "memory" => 0
             }
    end
  end

  describe "list_relations_for_pages/1" do
    test "batches relations for multiple pages in two queries", %{context: ctx} do
      {:ok, a} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Batch A",
          slug: "batch-a",
          page_type: "note"
        })

      {:ok, b} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Batch B",
          slug: "batch-b",
          page_type: "note"
        })

      {:ok, c} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Batch C",
          slug: "batch-c",
          page_type: "note"
        })

      {:ok, isolated} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Batch Iso",
          slug: "batch-iso",
          page_type: "note"
        })

      {:ok, _} =
        Knowledge.create_relation(%{source_id: a.id, target_id: b.id, relation_type: "related"})

      {:ok, _} =
        Knowledge.create_relation(%{source_id: b.id, target_id: c.id, relation_type: "related"})

      {:ok, _} =
        Knowledge.create_relation(%{source_id: c.id, target_id: a.id, relation_type: "related"})

      result = Knowledge.list_relations_for_pages([a.id, b.id, c.id, isolated.id])

      # Pages with relations are present
      assert %{outbound: [rel_a], inbound: [rel_a_in]} = result[a.id]
      assert rel_a.target_id == b.id
      assert rel_a_in.source_id == c.id

      assert %{outbound: [rel_b], inbound: [rel_b_in]} = result[b.id]
      assert rel_b.target_id == c.id
      assert rel_b_in.source_id == a.id

      # Isolated page is omitted (callers use Map.get with default)
      refute Map.has_key?(result, isolated.id)

      # Target/source pages are pre-loaded with lightweight fields
      assert %{target: %{id: _, title: _, slug: _, page_type: _}} = result[a.id].outbound |> hd()
    end

    test "returns empty map when no pages have relations", %{context: ctx} do
      {:ok, a} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "Lonely A", page_type: "note"})

      {:ok, b} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "Lonely B", page_type: "note"})

      assert Knowledge.list_relations_for_pages([a.id, b.id]) == %{}
    end
  end

  describe "props filtering" do
    test "list_pages filters by meta.props with AND logic", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Sales VIP",
          slug: "sales-vip",
          page_type: "entity",
          meta: %{"props" => %{"role" => "sales", "tier" => "vip"}}
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Sales Regular",
          slug: "sales-reg",
          page_type: "entity",
          meta: %{"props" => %{"role" => "sales", "tier" => "regular"}}
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Marketing VIP",
          slug: "mkt-vip",
          page_type: "entity",
          meta: %{"props" => %{"role" => "marketing", "tier" => "vip"}}
        })

      # Single prop filter (filter by the slugs we just created to avoid
      # interference from other tests in the same context)
      sales =
        Knowledge.list_pages(workspace_id: ctx.id, props: %{"role" => "sales"})
        |> Enum.filter(&(&1.slug in ["sales-vip", "sales-reg"]))

      assert length(sales) == 2
      assert Enum.all?(sales, &(&1.meta["props"]["role"] == "sales"))

      # Multiple props (AND logic)
      sales_vip =
        Knowledge.list_pages(workspace_id: ctx.id, props: %{"role" => "sales", "tier" => "vip"})
        |> Enum.filter(&(&1.slug in ["sales-vip", "sales-reg", "mkt-vip"]))

      assert length(sales_vip) == 1
      assert hd(sales_vip).slug == "sales-vip"

      # No match
      none = Knowledge.list_pages(workspace_id: ctx.id, props: %{"role" => "engineering"})
      assert none == []
    end

    test "search filters by props post-query", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Elixir Phoenix Guide",
          slug: "elixir-guide",
          page_type: "reference",
          body: "A comprehensive guide to Elixir and Phoenix framework",
          meta: %{"props" => %{"language" => "elixir", "framework" => "phoenix"}}
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Python Django Guide",
          slug: "python-guide",
          page_type: "reference",
          body: "A comprehensive guide to Python and Django framework",
          meta: %{"props" => %{"language" => "python", "framework" => "django"}}
        })

      # Search without props filter (baseline)
      {:ok, all} = Knowledge.search("guide", workspace_id: ctx.id, strategy: :fts)
      assert length(all) == 2

      # Search with props filter
      {:ok, elixir_only} =
        Knowledge.search("guide",
          workspace_id: ctx.id,
          strategy: :fts,
          props: %{"language" => "elixir"}
        )

      assert length(elixir_only) == 1
      assert hd(elixir_only).slug == "elixir-guide"
      assert hd(elixir_only).props["language"] == "elixir"

      # Multiple props
      {:ok, phoenix_only} =
        Knowledge.search("guide",
          workspace_id: ctx.id,
          strategy: :fts,
          props: %{"language" => "elixir", "framework" => "phoenix"}
        )

      assert length(phoenix_only) == 1
      assert hd(phoenix_only).slug == "elixir-guide"
    end
  end

  describe "version_diff/2" do
    test "diffs v1 against current body with added/removed lines", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Diffable",
          slug: "diffable",
          page_type: "note",
          body: "line one\nline two\nline three"
        })

      # v1 snapshot is saved on first body change; update twice.
      {:ok, _} =
        Knowledge.update_page(page, %{"body" => "line one\nline two changed\nline three"})

      page = Knowledge.get_page!(page.id)
      {:ok, _} = Knowledge.update_page(page, %{"body" => "line one\nline two changed\nline four"})
      page = Knowledge.get_page!(page.id)

      {:ok, diff} = Knowledge.version_diff(page, 1)

      assert diff.from == 1
      assert diff.to == page.version
      # old body: "line one", "line two", "line three"
      # new body: "line one", "line two changed", "line four"
      # added:   "line two changed", "line four" => 2
      # removed: "line two", "line three" => 2
      # unchanged: "line one" => 1
      assert diff.changes.added == 2
      assert diff.changes.removed == 2
      assert diff.changes.unchanged == 1
    end

    test "returns error for non-existent version", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "NoVer",
          slug: "no-ver",
          page_type: "note",
          body: "x"
        })

      assert {:error, :version_not_found} = Knowledge.version_diff(page, 99)
    end
  end

  describe "metrics/1" do
    test "returns extended brain-health metrics with all expected keys", %{context: ctx} do
      # Create some pages and relations so the metrics are non-trivial
      {:ok, a} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Metric A",
          slug: "metric-a",
          page_type: "note",
          body: "content a"
        })

      {:ok, b} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Metric B",
          slug: "metric-b",
          page_type: "concept",
          body: "content b"
        })

      {:ok, _} =
        Knowledge.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "related"
        })

      {:ok, _} =
        Knowledge.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "semantic"
        })

      metrics = Knowledge.metrics(ctx.id)

      assert Map.has_key?(metrics, :pages_this_week)
      assert Map.has_key?(metrics, :pages_last_week)
      assert Map.has_key?(metrics, :embedding_coverage)
      assert Map.has_key?(metrics, :relations_by_type)
      assert Map.has_key?(metrics, :contested_count)
      assert Map.has_key?(metrics, :workers)

      # Pages created this week (just created)
      assert metrics.pages_this_week >= 2

      # Embedding coverage is a float between 0.0 and 1.0
      assert is_float(metrics.embedding_coverage)
      assert metrics.embedding_coverage >= 0.0
      assert metrics.embedding_coverage <= 1.0

      # Relations by type includes "related" and "semantic"
      assert metrics.relations_by_type["related"] >= 1
      assert metrics.relations_by_type["semantic"] >= 1

      # Contested count is a non-negative integer
      assert is_integer(metrics.contested_count)
      assert metrics.contested_count >= 0

      # Agents map has expected keys
      assert Map.has_key?(metrics.workers, :sessions_this_week)
      assert Map.has_key?(metrics.workers, :tokens_this_week)
      assert Map.has_key?(metrics.workers, :total_sessions)
    end

    test "embedding_coverage is 0.0 when context has no pages" do
      # Use a fresh context with no pages
      {:ok, empty_ctx} =
        Knowledge.create_workspace(%{name: "Empty Metrics", slug: "empty-metrics"})

      metrics = Knowledge.metrics(empty_ctx.id)
      assert metrics.embedding_coverage == 0.0
      assert metrics.pages_this_week == 0
      assert metrics.relations_by_type == %{}
      assert metrics.contested_count == 0
      assert metrics.workers.sessions_this_week == 0
      assert metrics.workers.tokens_this_week == 0
      assert metrics.workers.total_sessions == 0
    end

    test "agents metrics counts sessions and tokens from worker_sessions", %{context: ctx} do
      # Insert an agent session with tokens_used in meta
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Dran.Repo.insert!(%Dran.Worker.Session{
        workspace_id: ctx.id,
        worker_type: "ask",
        input: "test query",
        status: "done",
        started_at: now,
        meta: %{"tokens_used" => 1500}
      })

      metrics = Knowledge.metrics(ctx.id)

      assert metrics.workers.sessions_this_week >= 1
      assert metrics.workers.tokens_this_week >= 1500
      assert metrics.workers.total_sessions >= 1
    end
  end

  describe "edge cases — derive_title ignores embed lines" do
    test "create_page with body containing only ![[embed]] derives Untitled", %{context: ctx} do
      {:ok, target_page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "File Page",
          slug: "file-page-1",
          page_type: "note"
        })

      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          page_type: "note",
          body: "![[file-page-1]]"
        })

      assert page.title == "Untitled"
      # No title from the body → the fallback slug is the page type.
      assert page.slug == "note"

      # The embed itself is still resolved
      rels = Knowledge.list_relations_for_page(page.id).outbound
      assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == target_page.id))
    end

    test "create_page with embed + text uses the text line as title", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          page_type: "note",
          body: "![[nonexistent]]\nActual Title Here"
        })

      assert page.title == "Actual Title Here"
    end

    test "create_page with body containing only [[wikilink]] derives Untitled", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          page_type: "note",
          body: "[[Some Link]]"
        })

      assert page.title == "Untitled"
    end
  end

  describe "edge cases — reresolve_embeds with empty body" do
    test "clears all embeds when body becomes empty", %{context: ctx} do
      {:ok, _a} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "A", slug: "ea", page_type: "note"})

      {:ok, _b} =
        Knowledge.create_page(%{workspace_id: ctx.id, title: "B", slug: "eb", page_type: "note"})

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "N",
          slug: "en",
          page_type: "note",
          body: "![[ea]] ![[eb]]"
        })

      # Verify embeds exist
      embeds =
        Knowledge.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert length(embeds) == 2

      # Now clear the body
      {:ok, note} = Knowledge.update_page(note, %{"body" => ""})

      embeds =
        Knowledge.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert embeds == []
    end

    test "reresolve_embeds directly with empty body", %{context: ctx} do
      {:ok, a} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "A2",
          slug: "ea2",
          page_type: "note"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "N2",
          slug: "en2",
          page_type: "note",
          body: "![[ea2]]"
        })

      # Verify embed exists
      assert Knowledge.list_relations_for_page(note.id).outbound
             |> Enum.any?(&(&1.relation_type == "embeds" and &1.target_id == a.id))

      # Update body to empty and re-resolve
      {:ok, note} = Knowledge.update_page(note, %{"body" => ""})
      {created, not_found} = Knowledge.reresolve_embeds(note)

      assert created == 0
      assert not_found == []

      embeds =
        Knowledge.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert embeds == []
    end
  end

  describe "edge cases — rename_slug" do
    test "case-only change (My-Page → my-page) works without unique constraint violation", %{
      context: ctx
    } do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Test",
          slug: "My-Page",
          page_type: "note"
        })

      {:ok, renamed} = Knowledge.rename_slug(page, "my-page")
      assert renamed.slug == "my-page"
    end

    test "preserves semantic relations (by IDs) when page is relation target", %{context: ctx} do
      {:ok, target} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Target",
          slug: "target-page",
          page_type: "concept"
        })

      {:ok, source} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Source",
          slug: "source-page",
          page_type: "concept"
        })

      {:ok, _rel} =
        Knowledge.create_relation(%{
          source_id: source.id,
          target_id: target.id,
          relation_type: "related",
          weight: 0.9
        })

      # Rename the target
      {:ok, _renamed} = Knowledge.rename_slug(target, "renamed-target")

      # The relation should still exist (it uses IDs, not slugs)
      rels = Knowledge.list_relations_for_page(source.id).outbound
      assert Enum.any?(rels, &(&1.relation_type == "related" and &1.target_id == target.id))
    end
  end

  describe "edge cases — Knowledge.stats" do
    test "returns valid stats for context with 0 pages" do
      {:ok, empty_ctx} = Knowledge.create_workspace(%{name: "Empty Context", slug: "empty-ctx"})

      stats = Knowledge.stats(empty_ctx.id)

      assert stats.total_pages == 0
      assert stats.by_type == %{}
      assert stats.recent == []
      assert stats.todos_by_status == %{}
      assert stats.orphan_count == 0
      assert stats.total_relations == 0
    end
  end

  describe "edge cases — resolve_embeds with non-existent slug" do
    test "returns slug in not_found without creating broken relation", %{context: ctx} do
      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Note",
          slug: "note-missing",
          page_type: "note",
          body: "![[does-not-exist]]"
        })

      # resolve_embeds is called during create_page, so the relation should
      # already have been attempted. Let's verify directly.
      {created, not_found} = Knowledge.resolve_embeds(note)

      assert created == 0
      assert "does-not-exist" in not_found

      # No embeds relation should exist
      embeds =
        Knowledge.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert embeds == []
    end

    test "mixed existing and non-existent embeds", %{context: ctx} do
      {:ok, target_page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Art",
          slug: "art-exists",
          page_type: "note"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "N",
          slug: "n-mixed",
          page_type: "note",
          body: "![[art-exists]] and ![[nope-not-here]]"
        })

      {created, not_found} = Knowledge.resolve_embeds(note)

      assert created == 1
      assert "nope-not-here" in not_found

      embeds =
        Knowledge.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert length(embeds) == 1
      assert hd(embeds).target_id == target_page.id
    end
  end
end
