# Graph Algorithms for Dran — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add structural graph intelligence to Dran: PageRank-weighted search ranking, GraphRAG expansion for the QA agent, transitive `part_of` inference for the Link Gardener, and community detection (Label Propagation) — all with zero new dependencies.

**Architecture:** A new `Dran.Graph` module computes structural signals (PageRank, communities) in-memory over edges loaded via `Brain`. Results are persisted into `Page.meta` (no schema migration). A nightly Quantum job refreshes them. Search ranking blends PageRank into RRF; the QA agent gets an `expand_neighbors` tool; the Link Gardener receives a `transitive_candidates` tool fed by recursive SQL.

**Tech Stack:** Elixir puro, Ecto/PostgreSQL (`WITH RECURSIVE`), Quantum (ya instalado), pgvector (ya instalado). **Zero new deps.**

**Current context / assumptions:**
- Edges live in `relations` (`lib/dran/brain/relation.ex`): types `related|contradicts|supersedes|part_of|embeds|semantic`, unique `(source_id, target_id, relation_type)`.
- `Page.meta` is a JSONB map validated by `Dran.Brain.PageMeta` (`lib/dran/brain/page_meta.ex`) — new keys must be added there or they fail validation.
- `Brain.update_page/2` (`lib/dran/brain.ex:472`) and pattern `update_page_meta_field/3` (`brain.ex:994`) already write meta.
- Quantum jobs are declared in `config/config.exs:77-85` with `if config_env() != :test` guard; `config/test.exs` disables them.
- RRF fusion lives in `Brain.hybrid_search/2` (`brain.ex:1124`) and `fuse_rank/4` (`brain.ex:1156`).
- QA agent tools are defined in `lib/dran/agent/qa.ex` (`tools/0` at line 50, `execute_tool/3` clauses below).
- Link Gardener tools in `lib/dran/agent/link_gardener.ex` (`tools/0` at line 61, `execute_tool/3` at 228+).
- `Brain.list_relations_for_page/1` (`brain.ex:683`) returns `%{inbound: [...], outbound: [...]}`.
- Settings pattern: `Dran.Settings.get/1` (`lib/dran/settings.ex`) with defaults map — add graph weights there.
- Tests: `PORT=4099 mix test` (dev server occupies 4000; runtime.exs sets server unconditionally).

**Edge weights (single source of truth — `Dran.Graph`):**

| relation_type | weight (authority flow) | counts for community? | expand in GraphRAG? |
|---------------|------------------------|----------------------|---------------------|
| `part_of`     | 1.0                    | ✅                    | ✅                   |
| `embeds`      | 0.8                    | ✅                    | ✅                   |
| `supersedes`  | 0.7                    | ✅                    | ✅                   |
| `related`     | 0.5                    | ✅                    | ✅                   |
| `contradicts` | 0.2 (signal, no boost) | ❌                    | ⚠️ only as flag      |
| `semantic`    | 0.1                    | ❌ (too dense)        | ❌                   |

---

## Phase 1 — PageRank ponderado + boost en search

### Task 1.1: Add graph fields to PageMeta

**Objective:** Allow `meta` to carry `pagerank` and `community_id` without validation errors.

**Files:**
- Modify: `lib/dran/brain/page_meta.ex` (embedded_schema, ~line 20-60)

**Step 1: Write failing test**

Create `test/dran/brain/page_meta_test.exs` (or extend if exists):

```elixir
defmodule Dran.Brain.PageMetaTest do
  use Dran.DataCase, async: true

  alias Dran.Brain.PageMeta

  test "accepts pagerank and community_id in meta" do
    attrs = %{"pagerank" => 0.42, "community_id" => 3}
    changeset = PageMeta.changeset(%PageMeta{}, attrs, "note")
    assert changeset.valid?
  end
end
```

Check `PageMeta.changeset/3` actual arity first (`grep -n "def changeset" lib/dran/brain/page_meta.ex`) and adapt.

**Step 2: Run test to verify failure**

Run: `PORT=4099 mix test test/dran/brain/page_meta_test.exs`
Expected: FAIL — fields not casted/unknown.

**Step 3: Implement**

In `lib/dran/brain/page_meta.ex` embedded_schema, add under "Common":

```elixir
# graph signals (computed by Dran.Graph)
field :pagerank, :float
field :community_id, :integer
```

And add both to the `cast` list used for common fields.

**Step 4: Run test to verify pass**

Run: `PORT=4099 mix test test/dran/brain/page_meta_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/dran/brain/page_meta.ex test/dran/brain/page_meta_test.exs
git commit -m "feat: add pagerank and community_id fields to PageMeta"
```

---

### Task 1.2: Create Dran.Graph with edge loading and weights

**Objective:** Central module that loads edges for a context and exposes typed weights.

**Files:**
- Create: `lib/dran/graph.ex`
- Test: `test/dran/graph_test.exs`

**Step 1: Write failing test**

```elixir
defmodule Dran.GraphTest do
  use Dran.DataCase, async: true

  alias Dran.Graph

  test "edge_weight/1 returns typed weights" do
    assert Graph.edge_weight("part_of") == 1.0
    assert Graph.edge_weight("related") == 0.5
    assert Graph.edge_weight("semantic") == 0.1
    assert Graph.edge_weight("unknown") == 0.5
  end

  test "community_edge?/1 excludes semantic and contradicts" do
    assert Graph.community_edge?("part_of")
    refute Graph.community_edge?("semantic")
    refute Graph.community_edge?("contradicts")
  end
end
```

**Step 2: Run** — `PORT=4099 mix test test/dran/graph_test.exs` → FAIL (module doesn't exist).

**Step 3: Implement `lib/dran/graph.ex`**

```elixir
defmodule Dran.Graph do
  @moduledoc """
  Structural graph algorithms over the relations table.

  Pure-Elixir implementations (PageRank, Label Propagation) that run
  in-memory over edges loaded via Ecto. No external dependencies.
  """

  import Ecto.Query
  alias Dran.Repo
  alias Dran.Brain.Relation

  @edge_weights %{
    "part_of" => 1.0,
    "embeds" => 0.8,
    "supersedes" => 0.7,
    "related" => 0.5,
    "contradicts" => 0.2,
    "semantic" => 0.1
  }

  @community_types ~w(part_of embeds supersedes related)

  @doc "Authority-flow weight for a relation type."
  def edge_weight(type), do: Map.get(@edge_weights, type, 0.5)

  @doc "Whether an edge type participates in community detection."
  def community_edge?(type), do: type in @community_types

  @doc """
  Load all edges for a context as a list of
  `%{source: id, target: id, type: type, weight: typed_weight}`.
  """
  def load_edges(context_id) do
    from(r in Relation,
      join: s in assoc(r, :source),
      where: s.context_id == ^context_id,
      select: %{source: r.source_id, target: r.target_id, type: r.relation_type}
    )
    |> Repo.all()
    |> Enum.map(fn e -> Map.put(e, :weight, edge_weight(e.type)) end)
  end
end
```

**Step 4: Run** — `PORT=4099 mix test test/dran/graph_test.exs` → PASS.

**Step 5: Commit**

```bash
git add lib/dran/graph.ex test/dran/graph_test.exs
git commit -m "feat: add Dran.Graph module with typed edge weights"
```

---

### Task 1.3: PageRank computation

**Objective:** `Graph.pagerank(context_id)` returns `%{page_id => score}`.

**Files:**
- Modify: `lib/dran/graph.ex`
- Test: `test/dran/graph_test.exs`

**Step 1: Failing test** (use DataCase with factory/insert helpers already in repo — check `test/support/` for page fixtures, e.g. `Dran.BrainFixtures`):

```elixir
test "pagerank/1 ranks hub pages higher" do
  ctx = context_fixture()
  a = page_fixture(ctx, "a")
  b = page_fixture(ctx, "b")
  c = page_fixture(ctx, "c")
  relation_fixture(a, b, "part_of")
  relation_fixture(c, b, "part_of")
  # b receives 2 inlinks; a and c receive none

  ranks = Graph.pagerank(ctx.id)
  assert ranks[b.id] > ranks[a.id]
  assert ranks[b.id] > ranks[c.id]
end
```

If no fixtures exist for relations, insert directly via `Brain.create_relation/1` after creating pages with `Brain.create_page/1`.

**Step 2: Run** → FAIL (`pagerank/1` undefined).

**Step 3: Implement in `lib/dran/graph.ex`**

```elixir
@damping 0.85
@iterations 20

@doc """
Weighted PageRank over the context graph.

Returns a normalized map `%{page_id => score}` where scores sum to 1.
Outbound weight is split proportionally by typed edge weight, so
`part_of` transfers more authority than `semantic`.
"""
def pagerank(context_id) do
  edges = load_edges(context_id)
  nodes = edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

  case nodes do
    [] ->
      %{}

    _ ->
      n = length(nodes)
      base = (1.0 - @damping) / n

      out_links =
        Enum.group_by(edges, & &1.source)
        |> Map.new(fn {src, outs} ->
          total = Enum.sum(Enum.map(outs, & &1.weight))
          {src, Enum.map(outs, fn o -> {o.target, o.weight / total} end)}
        end)

      initial = Map.new(nodes, &{&1, 1.0 / n})

      ranks =
        Enum.reduce(1..@iterations, initial, fn _, acc ->
          incoming =
            Enum.reduce(edges, %{}, fn e, m ->
              src_score = Map.get(acc, e.source, 0.0)
              total = out_links |> Map.get(e.source, []) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
              share = if total > 0, do: src_score * e.weight / (total * n_of(out_links, e.source)), else: 0.0
              Map.update(m, e.target, share, &(&1 + share))
            end)

          Map.new(nodes, fn node ->
            {node, base + @damping * Map.get(incoming, node, 0.0)}
          end)
        end)

      total = Enum.sum(Map.values(ranks))
      if total > 0, do: Map.new(ranks, fn {k, v} -> {k, v / total} end), else: ranks
  end
end

defp n_of(out_links, src), do: length(Map.get(out_links, src, []))
```

NOTE for implementer: the share computation above is the "weighted-split" variant. Simpler correct alternative: `share = src_score * (e.weight / total_weight_of_source)` where `total_weight_of_source` is precomputed in `out_links` — prefer that (cleaner); adjust test to only assert ordering (`>`), not exact values.

**Step 4: Run** → PASS.

**Step 5: Commit** — `feat: add weighted PageRank to Dran.Graph`

---

### Task 1.4: Persist PageRank into Page.meta + refresh function

**Objective:** `Graph.refresh_pagerank(context_id)` writes scores into each page's meta.

**Files:**
- Modify: `lib/dran/graph.ex`
- Modify: `lib/dran/brain.ex` — expose a lightweight `update_page_meta/2` that does NOT trigger augmenter/broadcasts if `update_page/2` has side effects (check `brain.ex:472` body first; if it schedules PageAugmenter, write a direct `Repo.update_all` meta-merge instead via `fragment("meta || ?", ^new_meta)`).

**Step 1: Failing test**

```elixir
test "refresh_pagerank/1 writes pagerank into page meta" do
  ctx = context_fixture()
  a = page_fixture(ctx, "a")
  b = page_fixture(ctx, "b")
  relation_fixture(a, b, "part_of")

  :ok = Graph.refresh_pagerank(ctx.id)

  b_reloaded = Dran.Brain.get_page!(b.id)
  assert is_float(b_reloaded.meta["pagerank"])
  assert b_reloaded.meta["pagerank"] > 0
end
```

**Step 2: Run** → FAIL.

**Step 3: Implement**

```elixir
@doc "Recompute PageRank and persist scores into pages' meta."
def refresh_pagerank(context_id) do
  ranks = pagerank(context_id)

  Enum.each(ranks, fn {page_id, score} ->
    from(p in Dran.Brain.Page, where: p.id == ^page_id)
    |> Repo.update_all(
      set: [meta: fragment("COALESCE(meta, '{}'::jsonb) || ?", ^%{"pagerank" => Float.round(score, 6)})]
    )
  end)

  :ok
end
```

Using `Repo.update_all` + jsonb merge avoids triggering augmenter side effects per page. Round to 6 decimals to keep meta clean.

**Step 4: Run** → PASS. Verify no embedding/augmenter jobs fire (check logs in test or assert `Repo` calls only).

**Step 5: Commit** — `feat: persist PageRank scores into page meta`

---

### Task 1.5: Nightly Quantum job

**Objective:** Schedule PageRank refresh for the default context nightly.

**Files:**
- Modify: `config/config.exs` (jobs block, ~line 77)
- Modify: `lib/dran/graph.ex` — add `refresh_all/0` that resolves default context via `Dran.Auth.default_context_slug/0` + `Brain.get_context_by_slug/1` (same pattern as `Curator.run_scheduled/0`, `lib/dran/agent/curator.ex:58`).

**Step 1: Implement**

```elixir
@doc "Refresh PageRank for the default context (Quantum entrypoint)."
def refresh_all_scheduled do
  slug = Dran.Auth.default_context_slug()

  case Dran.Brain.get_context_by_slug(slug) do
    nil -> {:error, :context_not_found}
    ctx -> refresh_pagerank(ctx.id)
  end
end
```

In `config/config.exs` jobs list add:

```elixir
pagerank_nightly: [
  schedule: "0 3 * * *",
  task: {Dran.Graph, :refresh_all_scheduled, []}
],
```

**Step 2: Verify** — `mix compile --warnings-as-errors` passes; test config keeps `jobs: []`.

**Step 3: Manual smoke** — in `iex -S mix` run `Dran.Graph.refresh_all_scheduled()` then `psql -U brain -d dran_dev -c "SELECT slug, meta->>'pagerank' FROM pages WHERE meta ? 'pagerank' LIMIT 5;"`.

**Step 4: Commit** — `feat: schedule nightly PageRank refresh via Quantum`

---

### Task 1.6: Blend PageRank into search ranking

**Objective:** Pages with higher PageRank get a boost in `hybrid_search` results.

**Files:**
- Modify: `lib/dran/brain.ex` — `fuse_rank/4` (line 1156) and `hybrid_search/2` (1124).
- Modify: `lib/dran/settings.ex` — add defaults: `"pagerank_boost" => 0.15`.

**Step 1: Failing test** (in `test/dran/brain_test.exs` or search-focused test file):

```elixir
test "hybrid_search boosts pages with higher pagerank meta" do
  ctx = context_fixture()
  # two pages with identical body so FTS/semantic tie
  low = page_fixture(ctx, "low-rank", body: "elixir deployment guide")
  high = page_fixture(ctx, "high-rank", body: "elixir deployment guide")
  set_meta(high, "pagerank", 0.9)
  set_meta(low, "pagerank", 0.001)

  {:ok, results} = Brain.hybrid_search("elixir deployment", context_id: ctx.id)
  assert hd(results).slug == "high-rank"
end
```

**Step 2: Run** → FAIL (order not influenced).

**Step 3: Implement**

In `fuse_rank/4`, when building the merged map, read pagerank from the page struct (need `meta` in select — check `semantic_search` select at `brain.ex:1091` and FTS query; add `meta: p.meta` to both selects, or a second lightweight fetch). Then after fusion, in `hybrid_search/2`:

```elixir
boost = Dran.Settings.get("pagerank_boost")

results =
  scored
  |> Enum.map(fn {id, r} ->
    pr = get_in(r, [:meta, "pagerank"]) || 0.0
    {id, Map.put(r, :score, r.score * (1.0 + boost * pr))}
  end)
  |> Enum.sort_by(fn {_id, %{score: s}} -> s end, :desc)
  ...
```

Keep boost multiplicative so zero-PR pages are unaffected. Since meta is only needed for scoring, prefer adding `meta: p.meta` to the two source queries' selects (small payload).

**Step 4: Run** → PASS. Also run full search tests: `PORT=4099 mix test test/dran/brain_test.exs`.

**Step 5: Acceptance criteria**

- [ ] Search order changes only when pagerank differs.
- [ ] Pages without `pagerank` in meta behave exactly as before (boost=0).
- [ ] `mix precommit` passes with no warnings.

**Step 6: Commit** — `feat: blend PageRank authority into hybrid search ranking`

---

## Phase 2 — GraphRAG expansion for QA agent

### Task 2.1: Brain.expand_neighbors/2

**Objective:** Given a page id, return typed neighbors (excluding `semantic`) with relation type and direction.

**Files:**
- Modify: `lib/dran/brain.ex` (near `list_relations_for_page/1`, line 683)
- Test: `test/dran/brain_test.exs`

**Step 1: Failing test**

```elixir
test "expand_neighbors/1 returns typed neighbors excluding semantic" do
  ctx = context_fixture()
  a = page_fixture(ctx, "a")
  b = page_fixture(ctx, "b")
  s = page_fixture(ctx, "s")
  Brain.create_relation(%{source_id: a.id, target_id: b.id, relation_type: "part_of"})
  Brain.create_relation(%{source_id: a.id, target_id: s.id, relation_type: "semantic"})

  neighbors = Brain.expand_neighbors(a.id)
  slugs = Enum.map(neighbors, & &1.slug)
  assert "b" in slugs
  refute "s" in slugs
  assert Enum.find(neighbors, &(&1.slug == "b")).relation_type == "part_of"
end
```

**Step 2: Run** → FAIL.

**Step 3: Implement in `lib/dran/brain.ex`**

```elixir
@doc """
Return graph neighbors of a page for RAG expansion.

Excludes `semantic` edges (too dense) by default. Each result:
`%{id, slug, title, page_type, summary, relation_type, direction}`.
Options: `:types` — list of relation types to include.
"""
def expand_neighbors(page_id, opts \\ []) do
  types = Keyword.get(opts, :types, ~w(part_of embeds supersedes related))

  %{inbound: inbound, outbound: outbound} = list_relations_for_page(page_id)

  inbound_items =
    inbound
    |> Enum.filter(&(&1.relation_type in types))
    |> Enum.map(fn r ->
      r.source
      |> Map.take([:id, :slug, :title, :page_type])
      |> Map.merge(%{relation_type: r.relation_type, direction: "inbound"})
    end)

  outbound_items =
    outbound
    |> Enum.filter(&(&1.relation_type in types))
    |> Enum.map(fn r ->
      r.target
      |> Map.take([:id, :slug, :title, :page_type])
      |> Map.merge(%{relation_type: r.relation_type, direction: "outbound"})
    end)

  (inbound_items ++ outbound_items)
  |> Enum.uniq_by(& &1.id)
end
```

NOTE: verify the exact shape returned by `list_relations_for_page/1` (`brain.ex:683-720`) — adapt `r.source`/`r.target` access to the actual key names in that function's select.

**Step 4: Run** → PASS.

**Step 5: Commit** — `feat: add Brain.expand_neighbors/2 for graph-aware retrieval`

---

### Task 2.2: `expand_neighbors` tool in QA agent

**Objective:** The `ask` agent can walk the graph from seed pages.

**Files:**
- Modify: `lib/dran/agent/qa.ex` (tools list at line 50+, `execute_tool/3` clauses)
- Test: `test/dran/agent/qa_test.exs` (check existing file name first)

**Step 1: Failing test**

```elixir
test "expand_neighbors tool returns neighbors for a slug" do
  # setup: pages + part_of relation; start QA state via Engine or
  # call execute_tool directly with a built %QA.State{}
  assert {:ok, result} = call_tool("expand_neighbors", %{"slug" => "a"})
  assert [%{"slug" => "b"} | _] = result
end
```

Follow existing test patterns for other tools in that file.

**Step 2: Run** → FAIL (unknown_tool).

**Step 3: Implement**

Add to `tools/0`:

```elixir
%{
  "type" => "function",
  "function" => %{
    "name" => "expand_neighbors",
    "description" =>
      "Devuelve las páginas conectadas a una página por relaciones tipadas " <>
        "(part_of, embeds, supersedes, related). Úsalo tras un search para " <>
        "ampliar contexto alrededor de las páginas semilla.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "slug" => %{"type" => "string", "description" => "Slug de la página semilla"}
      },
      "required" => ["slug"]
    }
  }
}
```

Add `execute_tool/3` clause:

```elixir
def execute_tool("expand_neighbors", args, %State{} = state) do
  slug = String.trim(args["slug"] || "")

  case Brain.get_page_by_slug(slug, state.session.context_id) do
    nil ->
      {{:error, "page '#{slug}' not found"}, state}

    page ->
      neighbors =
        page.id
        |> Brain.expand_neighbors()
        |> Enum.take(10)
        |> Enum.map(fn n ->
          %{slug: n.slug, title: n.title, relation_type: n.relation_type,
            direction: n.direction, summary: Map.get(n, :summary)}
        end)

      {{:ok, neighbors}, state}
  end
end
```

Update the QA `system_prompt` to document the workflow: search → expand_neighbors on best seeds → get_page for the most relevant → answer. Update `summarize_result/1` if it pattern-matches tool results (check existing clauses).

**Step 4: Run** — `PORT=4099 mix test test/dran/agent/qa_test.exs` → PASS.

**Step 5: Acceptance criteria**

- [ ] Tool rejects unknown slugs with error tuple.
- [ ] Results capped at 10.
- [ ] System prompt documents search→expand→read workflow.
- [ ] Existing QA tests still pass.

**Step 6: Commit** — `feat: add expand_neighbors tool to QA agent (GraphRAG)`

---

## Phase 3 — Transitive part_of inference for Link Gardener

### Task 3.1: Brain.transitive_part_of_candidates/1

**Objective:** Recursive SQL returns `(A, C)` pairs where `A part_of B`, `B part_of C`, and `A part_of C` does NOT yet exist.

**Files:**
- Modify: `lib/dran/brain.ex`
- Test: `test/dran/brain_test.exs`

**Step 1: Failing test**

```elixir
test "transitive_part_of_candidates/1 finds missing transitive edges" do
  ctx = context_fixture()
  a = page_fixture(ctx, "a"); b = page_fixture(ctx, "b"); c = page_fixture(ctx, "c")
  Brain.create_relation(%{source_id: a.id, target_id: b.id, relation_type: "part_of"})
  Brain.create_relation(%{source_id: b.id, target_id: c.id, relation_type: "part_of"})

  candidates = Brain.transitive_part_of_candidates(ctx.id)
  assert %{source_slug: "a", target_slug: "c", via_slug: "b"} in candidates
end
```

**Step 2: Run** → FAIL.

**Step 3: Implement in `lib/dran/brain.ex`**

```elixir
@doc """
Find candidate transitive `part_of` relations via recursive CTE.

Returns up to 50 maps `%{source_slug, target_slug, via_slug}` where
source part_of via, via part_of target, and the direct edge is missing.
Cycles are guarded with a depth limit.
"""
def transitive_part_of_candidates(context_id) do
  sql = """
  WITH RECURSIVE chain AS (
    SELECT r.source_id, r.target_id, r.target_id AS via_id, 1 AS depth,
           ARRAY[r.source_id] AS visited
    FROM relations r
    JOIN pages p ON p.id = r.source_id
    WHERE r.relation_type = 'part_of' AND p.context_id = $1

    UNION

    SELECT c.source_id, r.target_id, r.target_id, c.depth + 1, c.visited || r.source_id
    FROM chain c
    JOIN relations r ON r.source_id = c.target_id AND r.relation_type = 'part_of'
    WHERE c.depth < 3 AND NOT (r.source_id = ANY(c.visited))
  )
  SELECT DISTINCT ps.slug AS source_slug, pt.slug AS target_slug, pv.slug AS via_slug
  FROM chain c
  JOIN pages ps ON ps.id = c.source_id
  JOIN pages pt ON pt.id = c.target_id
  JOIN pages pv ON pv.id = c.via_id
  WHERE c.depth = 2
    AND c.source_id != c.target_id
    AND NOT EXISTS (
      SELECT 1 FROM relations r2
      WHERE r2.source_id = c.source_id AND r2.target_id = c.target_id
        AND r2.relation_type = 'part_of'
    )
  LIMIT 50
  """

  case Ecto.Adapters.SQL.query(Repo, sql, [context_id]) do
    {:ok, %{rows: rows}} ->
      Enum.map(rows, fn [s, t, v] ->
        %{source_slug: s, target_slug: t, via_slug: v}
      end)

    {:error, _} ->
      []
  end
end
```

Depth 2 (A→B→C) only; visited-array guards cycles.

**Step 4: Run** → PASS. Test cycle guard: create A→B, B→A and assert no crash/no infinite.

**Step 5: Commit** — `feat: add transitive part_of candidate detection via recursive SQL`

---

### Task 3.2: `transitive_candidates` tool in Link Gardener

**Objective:** Link Gardener can fetch structurally-evidenced candidates and propose them with justification.

**Files:**
- Modify: `lib/dran/agent/link_gardener.ex`
- Test: `test/dran/agent/link_gardener_test.exs`

**Step 1: Failing test** — call tool, assert list contains expected pair.

**Step 2: Run** → FAIL.

**Step 3: Implement**

Tool spec:

```elixir
%{
  "type" => "function",
  "function" => %{
    "name" => "transitive_candidates",
    "description" =>
      "List candidate part_of relations inferred transitively (A part_of B, " <>
        "B part_of C, but A part_of C missing). Each candidate includes the " <>
        "intermediate page as evidence. Verify with get_page before proposing.",
    "parameters" => %{"type" => "object", "properties" => %{}, "required" => []}
  }
}
```

Execute clause:

```elixir
def execute_tool("transitive_candidates", _args, %State{} = state) do
  candidates = Brain.transitive_part_of_candidates(state.session.context_id)
  {{:ok, candidates}, state}
end
```

Update `system_prompt/1` workflow: step 0 = call `transitive_candidates`, verify each with `get_page`, and propose with justification referencing the intermediate page ("A ya es parte de B, y B es parte de C").

**Step 4: Run** → PASS (full link_gardener suite).

**Step 5: Acceptance criteria**

- [ ] Tool returns pairs with `via_slug` evidence.
- [ ] Gardener proposals still respect `@max_proposals`.
- [ ] Prompt instructs verify-before-propose.

**Step 6: Commit** — `feat: feed transitive part_of candidates to Link Gardener`

---

## Phase 4 — Community detection (Label Propagation)

### Task 4.1: Graph.communities/1

**Objective:** Label Propagation over typed edges (excluding `semantic`/`contradicts`) returns `%{page_id => community_id}`.

**Files:**
- Modify: `lib/dran/graph.ex`
- Test: `test/dran/graph_test.exs`

**Step 1: Failing test**

```elixir
test "communities/1 clusters densely connected pages" do
  ctx = context_fixture()
  # cluster 1: a-b-c fully linked; cluster 2: x-y linked; no cross links
  for {s, t} <- [{"a","b"},{"b","c"},{"a","c"}] do
    relation_fixture_by_slug(ctx, s, t, "related")
  end
  relation_fixture_by_slug(ctx, "x", "y", "related")

  comms = Graph.communities(ctx.id)
  by = fn slug -> comms[page_id(ctx, slug)] end
  assert by.("a") == by.("b") and by.("b") == by.("c")
  assert by.("x") == by.("y")
  assert by.("a") != by.("x")
end
```

Label Propagation is stochastic — make the test deterministic by passing a fixed `:seed` option (`:rand.seed(:exsss, {1,2,3})` inside when seed given) or by asserting on the pair-equality properties above which hold for any valid clustering of this fixture.

**Step 2: Run** → FAIL.

**Step 3: Implement in `lib/dran/graph.ex`**

```elixir
@lp_iterations 30

@doc """
Detect communities via Label Propagation over typed edges.

Treats edges as undirected for community purposes. Returns
`%{page_id => community_label}` where labels are integers.
Isolated pages each form their own community (label = unique).
"""
def communities(context_id, opts \\ []) do
  edges =
    context_id
    |> load_edges()
    |> Enum.filter(&community_edge?(&1.type))

  nodes = edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

  # undirected weighted adjacency: node => %{neighbor => weight}
  adj =
    Enum.reduce(edges, %{}, fn e, acc ->
      acc
      |> update_in([e.source, e.target], &((&1 || 0.0) + e.weight))
      |> update_in([e.target, e.source], &((&1 || 0.0) + e.weight))
    end)

  labels = Map.new(nodes, &{&1, &1})

  final =
    Enum.reduce(1..@lp_iterations, labels, fn iter, acc ->
      Enum.reduce(Enum.shuffle(nodes), acc, fn node, labels_acc ->
        neighbors = Map.get(adj, node, %{})

        if map_size(neighbors) == 0 do
          labels_acc
        else
          best =
            neighbors
            |> Enum.group_by(fn {n, _w} -> Map.get(labels_acc, n, Map.get(acc, n)) end)
            |> Enum.map(fn {label, group} ->
              {label, group |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
            end)
            |> Enum.max_by(fn {_l, w} -> w end)
            |> elem(0)

          Map.put(labels_acc, node, best)
        end
      end)
      |> then(fn new -> if new == acc and iter > 3, do: acc, else: new end)
    end)

  # compress labels to 1..k integers
  unique = final |> Map.values() |> Enum.uniq() |> Enum.with_index(1) |> Map.new()
  Map.new(final, fn {node, label} -> {node, unique[label]} end)
end
```

**Step 4: Run** → PASS (also with a larger random-ish fixture; assert convergence < 30 iterations on small graphs).

**Step 5: Commit** — `feat: add Label Propagation community detection to Dran.Graph`

---

### Task 4.2: Persist community_id + extend nightly job

**Objective:** `Graph.refresh_communities/1` writes `community_id` into meta; nightly job refreshes both signals.

**Files:**
- Modify: `lib/dran/graph.ex` (`refresh_communities/1`, and make `refresh_all_scheduled/0` call both refreshes)
- Test: `test/dran/graph_test.exs`

**Step 1: Failing test** — after `refresh_communities`, pages share integer `community_id` in meta per cluster.

**Step 2: Run** → FAIL.

**Step 3: Implement** — same `Repo.update_all` jsonb-merge pattern as Task 1.4:

```elixir
def refresh_communities(context_id) do
  context_id
  |> communities()
  |> Enum.each(fn {page_id, cid} ->
    from(p in Dran.Brain.Page, where: p.id == ^page_id)
    |> Repo.update_all(
      set: [meta: fragment("COALESCE(meta, '{}'::jsonb) || ?", ^%{"community_id" => cid})]
    )
  end)

  :ok
end
```

Update `refresh_all_scheduled/0` to run `refresh_pagerank/1` then `refresh_communities/1`.

**Step 4: Run** → PASS.

**Step 5: Commit** — `feat: persist community ids and refresh nightly alongside PageRank`

---

### Task 4.3: Surface communities — Brain.community_pages/2 + Curator/Weekly Review wiring

**Objective:** Consumers can query pages by community; Curator uses same-community as extra duplicate evidence.

**Files:**
- Modify: `lib/dran/brain.ex` — `community_pages(context_id, community_id)` query on `meta->>'community_id'`.
- Modify: `lib/dran/agent/curator.ex` — in the `find_duplicates` flow, include `same_community` boolean per pair (read meta of both pages) so the LLM weighs community evidence; NO new tool, just enrich the pair payload.
- Test: `test/dran/brain_test.exs`, `test/dran/agent/curator_test.exs`

**Step 1: Failing tests** — query returns only same-community pages; curator payload includes `same_community: true`.

**Step 2: Run** → FAIL.

**Step 3: Implement**

```elixir
@doc "List pages belonging to a detected community."
def community_pages(context_id, community_id) do
  from(p in Page,
    where: p.context_id == ^context_id,
    where: fragment("(meta->>'community_id')::int = ?", ^community_id),
    select: %{id: p.id, slug: p.slug, title: p.title, page_type: p.page_type}
  )
  |> Repo.all()
end
```

Curator change: where pairs are built (`curator.ex` ~line 220-250), fetch `meta["community_id"]` for both pages and add `"same_community" => cid1 == cid1` to the pair map; document it in the curator's system prompt as additional duplicate evidence.

**Step 4: Run** → PASS.

**Step 5: Acceptance criteria**

- [ ] `community_pages/2` returns correct subset.
- [ ] Curator duplicate pairs carry `same_community` flag.
- [ ] `mix precommit` green: `PORT=4099 mix precommit`.

**Step 6: Commit** — `feat: expose community queries and feed community evidence to Curator`

---

## Files touched (summary)

| File | Phases |
|------|--------|
| `lib/dran/graph.ex` (new) | 1, 3, 4 |
| `lib/dran/brain/page_meta.ex` | 1 |
| `lib/dran/brain.ex` | 1, 2, 3, 4 |
| `lib/dran/settings.ex` | 1 |
| `config/config.exs` | 1 |
| `lib/dran/agent/qa.ex` | 2 |
| `lib/dran/agent/link_gardener.ex` | 3 |
| `lib/dran/agent/curator.ex` | 4 |
| `test/dran/graph_test.exs` (new) + brain/agent tests | all |

## Global verification

After each phase: `PORT=4099 mix test` (full suite) + `mix compile --warnings-as-errors`.
At the end: `PORT=4099 mix precommit` must be green.

Manual smoke (dev): create 3 pages with part_of chain via MCP `dran_create_page`/`dran_create_relation`, run `Dran.Graph.refresh_all_scheduled()` in `iex -S mix`, verify:
- `meta->>'pagerank'` present and ordered hub > leaf.
- `meta->>'community_id'` equal for all 3.
- QA agent with `start_agent` ask → session log shows `expand_neighbors` calls.
- Link Gardener run → proposes A→C part_of with via-B justification.

## Risks / tradeoffs / open questions

1. **PageRank on tiny graphs is flat.** With <20 pages, scores are near-uniform — boost does little. Acceptable: value grows as the brain grows. The `pagerank_boost` setting (0.15) can be tuned or set to 0 to disable without code changes.
2. **Label Propagation is non-deterministic** across runs (shuffle order). Community IDs are unstable between refreshes (id 3 tonight ≠ id 3 tomorrow). Consumers must treat `community_id` as opaque grouping key, never as stable identity. If stable communities are needed later, upgrade to Louvain (still dep-free but ~3x the code) — out of scope now.
3. **Transitive depth capped at 2** (A→B→C). Deeper chains multiply false positives; revisit with real usage data.
4. **`update_page_meta` side effects:** implementer MUST verify whether `Brain.update_page/2` triggers PageAugmenter/broadcasts. If it does, use the `Repo.update_all` jsonb-merge pattern (specified) — never the full update path — for graph-signal writes.
5. **Semantic edges excluded everywhere structural.** If the brain later accumulates enough manual typed edges, re-evaluate whether `semantic` should participate in communities (probably still no — density).
6. **Open question:** should GraphRAG expansion be automatic server-side in the Engine (no tool-call cost) instead of an agent tool? Plan chooses the tool (LLM decides when) — cheaper context, more control. Flip later if QA underuses it.
