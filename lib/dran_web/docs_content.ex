defmodule DranWeb.DocsContent do
  @moduledoc """
  Static code samples used by the in-app documentation (DocsLive).

  Kept in a plain module (module attributes) because HEEx `~H\"""` templates
  cannot contain nested triple-quoted heredocs.

  ## Data model (v7)

  Dran uses a split model:

    - **Pages** — the knowledge graph (4 types: note, concept, entity,
    reference).
  - **Goals** — first-class OKR entities (own table, not pages).
  - **Tasks** — first-class kanban action items (own table): status,
    priority, due_date, recurrence, checklist. Linked to goals/pages
    via optional part_of relations.
  - **Projects** — first-class grouping entities (own table, not pages).
  - **Collections** — saved filter queries (own table, replaces the old
    Smart Collection pattern).
  - **Reports** — system-created logs, lint outputs, agent output (own table).

  ## Polymorphic relations

  Pages, goals, and projects are linked via the relations table using
  `source_type` and `target_type` columns (`"page"`, `"goal"`, `"project"`).
  See `planning_hierarchy_diagram/0` for the canonical description.

  ## Graph intelligence

  PageRank (weighted by relation type), Label Propagation clusters, and
  transitive `part_of` candidates are documented in `graph_intelligence_doc/0`.
  These algorithms are implemented in `Dran.Graph` and refreshed nightly by the
  `pagerank_nightly` Quantum job.
  """

  @agent_connect_example """
  # Connect to Dran MCP
  POST http://localhost:4000/api/mcp
  Authorization: Bearer ***
  Content-Type: application/json

  {"jsonrpc": "2.0", "id": 1, "method": "initialize",
   "params": {"protocolVersion": "2025-03-26", "capabilities": {},
              "clientInfo": {"name": "my-agent", "version": "1.0"}}}

  # Verify schema
  ./scripts/mcp_smoke.sh
  """

  @auth_api_curl """
  curl -H "Authorization: Bearer ***" \
       http://localhost:4000/api/pages?context=personal
  """

  # ── Planning model (v7 — polymorphic relations) ──
  #
  # Pages, goals, and projects are linked via polymorphic `part_of` relations
  # in the relations table. source_type and target_type columns identify what
  # each side of the relation is ("page", "goal", or "project").
  #
  # There is no precedence between link types. A page may link to a goal,
  # a project, or both — each materializes its own `part_of` relation.

  @planning_hierarchy_diagram """
  Polymorphic relations — v7 model
  ==================================

  Pages, goals, and projects are linked via the relations table using
  polymorphic source/target pairs. There is no rigid hierarchy — each link
  is independent and optional.

    source       source_type  →  target_type  target
    ─────────────────────────────────────────────────────
    page         "page"          "goal"        goal
    page         "page"          "project"     project
    goal         "goal"          "project"     project
    page         "page"          "page"        page   (embeds, part_of, related, etc.)

  The source_type and target_type columns on the relations table tell the
  application which entity each side of the relation refers to. GraphQL
  traversal respects these types.

  Example — a note linked to a goal and a project simultaneously:

    NOTE  →  part_of goal    "mrr-100k"    (source_type="page",  target_type="goal")
          →  part_of project "acme"        (source_type="page",  target_type="project")

  Goal → Project linking:

    GOAL  →  part_of project "acme"        (source_type="goal",  target_type="project")

  Tasks (first-class entity, own table):
    status          backlog | todo | in_progress | done | cancelled
    priority        low | medium | high | urgent
    due_date        date (nullable)
    recurrence      none | daily | weekly | monthly (auto-clones on completion)
    checklist       meta.checklist = [%{text, done}] — lightweight subtasks
    assignee_id     FK to users (nullable)
    Linked to goals/pages via optional part_of relations
    (source_type="task").

  Collections (first-class entity):
    Saved filter queries live in their own table with `filters` JSONB.
    They replace the old Smart Collection pattern.

  Sidebar:
    Top: Dashboard, Tasks, Projects, Goals, Graph, Journey,
    Activity. Knowledge: Notes, Concepts, Entities, References,
    Collections. System: Reports. Config: Settings
    (admin only), Documentation.
  """

  @graph_intelligence_doc """
  Graph intelligence
  ===================

  Dran runs three pure-Elixir structural algorithms over the relations
  table, implemented in `Dran.Graph`. They run in-memory over edges
  loaded via Ecto (no external graph database) and persist their results
  into each page's `meta` JSONB column. A Quantum job recomputes them
  nightly on the default context.

  ─────────────────────────────────────────────────────────────────────
  1. PageRank (weighted, type-aware)
  ─────────────────────────────────────────────────────────────────────

  Classic PageRank with damping 0.85 and 20 iterations, but edges are
  weighted by relation type so authority flows more strongly along
  "structural" links than along noisy or auto-generated ones:

    part_of     1.0   (strongest — hierarchy)
    embeds      0.8
    supersedes  0.7
    related     0.5
    contradicts 0.2
    semantic    0.1   (weakest — auto-created, high-volume)

  Unknown relation types default to 0.5. Each node distributes its
  score across its outbound edges proportional to their typed weight;
  dangling nodes (no outbound edges) redistribute their score
  uniformly to avoid leaking rank out of the graph. Final scores are
  normalized to sum to 1.

  Persistence:
    `Dran.Graph.refresh_pagerank/1` writes each page's score into
    `meta.pagerank`, rounded to 6 decimals, using a jsonb merge
    (`COALESCE(meta, '{}'::jsonb) || ?::jsonb`) so it does NOT trigger
    the augmenter, embeddings, broadcasts, or other update side effects.

  Search boost (the consumer):
    After hybrid search fuses FTS + semantic candidates with Reciprocal
    Rank Fusion (RRF), each result's score is multiplied by:

      (1.0 + pagerank_boost * meta.pagerank)

    Pages with no `pagerank` in meta get exactly 1.0 (no change). The
    boost is MULTIPLICATIVE on top of the fused relevance score, so
    high-authority pages are nudged up without overriding the relevance
    signal. The `pagerank_boost` runtime setting (default 0.15,
    editable at `/settings`) controls the strength; set it to 0.0 to
    disable the boost entirely.

  ─────────────────────────────────────────────────────────────────────
  2. Clusters (Label Propagation)
  ─────────────────────────────────────────────────────────────────────

  Cluster detection via Label Propagation over typed edges, up to 30
  iterations with early-stop after iteration 3 if labels converge.
  Edges are treated as undirected for cluster purposes (each edge
  contributes its weight in both directions).

  IMPORTANT — which edges participate:
    Only `part_of`, `embeds`, `supersedes`, and `related` edges are
    used. `semantic` and `contradicts` edges are EXCLUDED:
      - `semantic` is high-volume auto-generated noise that would smear
        clusters together.
      - `contradicts` links pages that disagree, which is the opposite
        of "belongs to the same cluster".
    So two pages that only share a `semantic` or `contradicts` edge
    will NOT end up in the same cluster.

  Persistence:
    `Dran.Graph.refresh_clusters/1` writes the detected cluster id
    into `meta.cluster_id` (an integer 1..k) using the same jsonb
    merge as PageRank.

  cluster_id is OPAQUE and NOT STABLE between refreshes:
    Label Propagation is non-deterministic — the node update order is
    shuffled each iteration, so a page's `cluster_id` integer can
    change between nightly runs even if the graph itself didn't.
    Consumers MUST treat `cluster_id` as an opaque grouping key
    (use it to check "are A and B in the same cluster?"), NEVER as
    a stable identity. Do not display it to users or link to it.

  Reading a cluster's pages:
    `Knowledge.cluster_pages(workspace_id, cluster_id)` returns the
    lightweight list `%{id, slug, title, page_type}` of pages in a
    given cluster — no body, no embeddings. The Curator agent uses
    this to gather evidence when evaluating duplicate candidates.

  ─────────────────────────────────────────────────────────────────────
  3. Transitive part_of (Link Gardener — transitive_candidates)
  ─────────────────────────────────────────────────────────────────────

  The `link_gardener` agent has a tool `transitive_candidates` that
  finds inferred `part_of` relations via an intermediate page:

    If  A part_of B  and  B part_of C  exist,
    but the direct edge  A part_of C  does NOT exist,
    then  (A, C)  is a candidate, with `via_slug = B` as evidence.

  Implementation:
    `Knowledge.transitive_part_of_candidates/1` runs a recursive CTE
    (depth capped at 2, cycle-guarded with a `visited` array) against
    the relations table, limited to 50 candidates per context.

  Workflow:
    1. The agent calls `transitive_candidates` to get the list.
    2. For each candidate, it MUST call `get_page` on A and C to
       verify the inference makes sense before proposing the relation.
    3. It proposes the direct `A part_of C` relation citing the
       intermediate page B in the justification (e.g. "A ya es parte
       de B, y B es parte de C").

  The gardener never auto-creates these — it only proposes them with
  evidence. A human (or the agent's own verification step) decides.

  ─────────────────────────────────────────────────────────────────────
  Nightly refresh (Quantum)
  ─────────────────────────────────────────────────────────────────────

  `Dran.Graph.refresh_all_scheduled/0` runs via the `pagerank_nightly`
  job at `0 3 * * *` (03:00 daily). It resolves the default context,
  then runs:
    1. refresh_pagerank/1    (writes meta.pagerank)
    2. refresh_clusters/1 (writes meta.cluster_id)

  All scheduled jobs route through `Dran.Jobs.run_scheduled/1`, which
  honors the per-job toggles in Settings → Brain and writes a
  `Dran.Report` record per run:
    curator_daily                06:00  daily
    pagerank_nightly             03:00  daily  (this pipeline)
    cluster_summaries_nightly  03:30  daily  (LLM summary per cluster)
    graph_maintenance_nightly    03:45  daily  (prunes stale derived relations)
    link_gardener_weekly         07:00  Sundays

  Disabled in `config/test.exs`.
  """

  def agent_connect_example, do: @agent_connect_example
  def auth_api_curl, do: @auth_api_curl
  def planning_hierarchy_diagram, do: @planning_hierarchy_diagram
  def graph_intelligence_doc, do: @graph_intelligence_doc
end
