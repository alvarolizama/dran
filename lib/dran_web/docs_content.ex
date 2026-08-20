defmodule DranWeb.DocsContent do
  @moduledoc """
  Static code samples used by the in-app documentation (DocsLive).

  Kept in a plain module (module attributes) because HEEx `~H\"""` templates
  cannot contain nested triple-quoted heredocs.

  ## Planning model (v6)

  The planning model was rewritten: pages are orphans by default and the three
  link slugs (`project_slug`, `goal_slug`, `plan_slug`) live independently in
  `meta` — there is no precedence between them. Each one materializes its own
  `part_of` relation. See `planning_hierarchy_diagram/0` and
  `planning_model_overview/0` for the canonical description.

  ## Graph intelligence

  PageRank (weighted by relation type), Label Propagation communities, and
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

  # ── Planning model (v6) ──
  #
  # All pages are orphans by default. The three link slugs in `meta`
  # (project_slug, goal_slug, plan_slug) are INDEPENDENT and optional — there
  # is no precedence. Each one materializes its own `part_of` relation when
  # set. This holds for every page type (notes, concepts, entities, goals,
  # plans, todos, projects, ...).
  #
  # The old rule (plan > goal > project precedence, goal derived from plan) is
  # REMOVED. A todo may carry 0, 1, 2 or all 3 slugs simultaneously and each
  # is honored.

  @planning_hierarchy_diagram """
  Independent links — no precedence (v6 model)
  =============================================

  Every page is an orphan by default. The three slugs below are independent
  and optional; each materializes its own `part_of` relation when set.

    meta.project_slug  →  part_of project   (optional, any page type)
    meta.goal_slug     →  part_of goal      (optional, any page type)
    meta.plan_slug     →  part_of plan      (optional, any page type)

  No precedence. A todo (or any page) may carry 0, 1, 2 or all 3 slugs.

  Example — one todo linked to three things at once:
    TODO  meta: { project_slug: "acme", goal_slug: "mrr-100k", plan_slug: "2026-q3" }
      ├── part_of project "acme"
      ├── part_of goal    "mrr-100k"
      └── part_of plan    "2026-q3"

  Orphan convention (GTD inbox):
    list_pages(project_slug: "none")  → pages with no project link
    list_pages(goal_slug: "none")     → pages with no goal link
    list_pages(plan_slug: "none")     → pages with no plan link

  Page types:
    project — executive dashboard (status/priority/health), health derived from goals
    goal    — knowledge page with kind + metrics (metric/target_value/current_value/progress)
    plan    — strategic doc with kind/horizon/period/status/due_date
    todo    — actionable item with kind, kanban_status and assignee (lives in /kanban)

  Sidebar:
    Top: Dashboard, Kanban, Projects, Objetivos, Grafo, Trayectoria,
    Actividad. Planning: Planes, Tareas. Knowledge: Notes, Concepts,
    Entities, References, Queries, Collections. Configs: Settings
    (admin only), Documentation.
  """

  @planning_model_overview """
  Planning model overview (v6)
  =============================

  Three principles:

  1. Orphans by default, independent links.
     Every page is created orphan. `meta.project_slug`, `meta.goal_slug`
     and `meta.plan_slug` are independent and optional — there is no
     precedence. Setting any of them materializes a `part_of` relation for
     that slug only. The old rule (plan > goal > project precedence, goal
     derived from plan) is REMOVED.

  2. Projects, Goals and Plans are knowledge pages, not containers.
     - Project: executive dashboard with status/priority/health. Health is
       derived from the average of its linked goals' health, unless
       overridden manually via `health_source: "manual"`.
     - Goal: knowledge page with metrics (metric, target_value,
       current_value, unit, progress). Progress auto-calculates from linked
       todos (done / total non-cancelled) unless `progress_manual: true`.
     - Plan: strategic doc with horizon, period, status (draft|active|
       done|archived — on_hold and completed no longer exist) and due_date.

  3. One global Kanban.
     `/kanban` replaces the embedded kanbans in Goal/Project. It has 6
     columns and 3 combinable filters (Project / Goal / Plan), each
     offering All / None (orphans) / <slug>. Cards show link badges; click a
     badge to filter. Drag-drop updates `kanban_status`.

  Slug conventions:
    project_slug / goal_slug / plan_slug — independent, kebab-case.
    "none" — sentinel value meaning "no link of this kind" (orphan filter).

  Sidebar:
    Top (no group): Dashboard, Kanban, Projects, Objetivos (goals),
      Grafo, Trayectoria (journey), Actividad
    Planning: Planes, Tareas (todo list; the global board is /kanban)
    Knowledge: Notes, Concepts, Entities, References, Queries,
      Collections
    Configs: Settings (admin only), Documentation
  """

  @project_page_type """
  Page type: project
  ==================

  A `project` page is an executive dashboard for an initiative. It is NOT a
  hierarchical container — linked pages are discovered via their independent
  `meta.project_slug` link, not via tree descent.

  Meta fields:
    status         draft | active | on_hold | done | archived
    priority       low | medium | high | urgent
    health         green | yellow | red
    health_source  manual | derived   (default: derived)
    start_date     date
    target_date    date

  Derived health (health_source: "derived", default):
    floor( average( goal.health for goals linked to this project ) )
    using green=3, yellow=2, red=1. Returns nil if no goals are linked.
    Override: set health_source: "manual" and pick a health value — the
    derived value is ignored.

  ProjectLive tabs (/projects/:slug):
    1. Overview   — status, priority, health, dates, description
    2. Todos      — todos linked via project_slug (no embedded kanban)
    3. Goals      — goals linked via project_slug (with their health)
    4. Plans      — plans linked via project_slug
    5. Graph      — subgraph centered on the project
    6. Related    — other related pages

  There is no kanban tab. Each ProjectLive page has an "Open in Kanban"
  link that jumps to `/kanban?project=<slug>` with the filter pre-applied.
  """

  @global_kanban_doc """
  Global Kanban — /kanban
  =======================

  A single full-viewport kanban board at `/kanban` replaces the embedded
  kanbans that used to live inside Goal and Project pages. Every todo in
  the context is visible here, regardless of which (if any) project, goal
  or plan it links to.

  Columns (kanban_status):
    backlog → this_week → today → in_progress → done → cancelled

  Filters (3, combinable):
    Project ▾   All | None (orphans) | <project slugs>
    Goal    ▾   All | None (orphans) | <goal slugs>
    Plan    ▾   All | None (orphans) | <plan slugs>

  Examples:
    /kanban                                 → all todos
    /kanban?project=acme                    → todos linked to project "acme"
    /kanban?project=acme&goal=mrr-100k      → intersection (project + goal)
    /kanban?goal=none                       → orphan todos (GTD inbox)
    /kanban?plan=2026-q3                    → todos in plan "2026-q3"

  Cards:
    - Show up to 2 link badges (color-coded by type: project/goal/plan).
    - Hover a badge for the slug tooltip.
    - Click a badge to filter the board by that link.
    - Drag-drop between columns updates `meta.kanban_status` in place.

  Real-time:
    Board updates live via PubSub when an autonomous agent creates or moves
    a todo, or when another client changes a kanban_status.
  """

  @manual_flags_doc """
  Manual flags — free meta fields (unvalidated)
  =============================================

  These two flags live in `meta` and are NOT enforced by the schema. They
  are conventions the application layer honors when present, but you must
  set them explicitly — they default to the auto behavior.

  progress_manual  (boolean, on goal pages)
    - absent / false: goal.progress is auto-calculated as
      (done todos) / (total non-cancelled todos linked to the goal).
    - true: the auto-calculation is skipped and the value stored in
      `meta.progress` is shown as-is. Use this when a goal's progress
      cannot be derived from todo completion (e.g. a qualitative goal).

  health_source  (string, on project pages — "manual" | "derived")
    - "derived" (default): project.health is computed from the floor of
      the average health of its linked goals (green=3, yellow=2, red=1).
    - "manual": the derived value is ignored; the value stored in
      `meta.health` is shown as-is. Use this to override a project's
      health when the aggregate is misleading.

  Both fields are free-form meta — the application reads them at runtime.
  There is no schema-level validation, so typos (e.g. health_source: "Manual")
  will fall through to the default (derived) behavior silently.
  """

  @reminder_note_kind_doc """
  Note kind: reminder
  ===================

  `note` pages support a `reminder` kind (in addition to thought, journal,
  idea, meeting, question, quote):

    meta.kind = "reminder"

  When kind == "reminder", the `due_date` meta field is expected (soft
  validation — not required at the schema level, but the form shows it
  conditionally and the UI treats it as a reminder's due date).

  Example:
    POST /api/pages
    {
      "page_type": "note",
      "title": "Renew domain",
      "slug": "renew-domain",
      "meta": { "kind": "reminder", "due_date": "2026-08-01" }
    }

  `due_date` is a shared meta field (also used by `todo` and `plan`); the
  reminder kind just reuses it to mean "when this reminder is due".
  """

  @plan_statuses_doc """
  Plan statuses (v6)
  =================

  `plan` pages use these statuses in `meta.status`:

    draft | active | done | archived

  The old values `on_hold` and `completed` NO LONGER EXIST. Plans are not
  pausable; if a plan is no longer active, set it to `done` (finished) or
  `archived` (abandoned/superseded).

  Other plan meta fields:
    horizon   weekly | monthly | quarterly | yearly
    period    free string, e.g. "2026-Q3", "July 2026"
    due_date  date (optional deadline for the plan itself)
    goal_slug     optional independent link (no precedence)
    project_slug  optional independent link (no precedence)
  """

  @goal_metrics_doc """
  Goal metrics (v6)
  =================

  `goal` pages carry optional quantitative metrics in `meta`:

    metric          free string, e.g. "MRR", "users", "uptime"
    target_value    float — objective
    current_value   float — latest measured value
    unit            free string, e.g. "%", "USD", "users"
    progress        float 0.0 – 1.0 — auto or manual

  Auto-progress:
    When `meta.progress_manual` is absent or false, progress is
    recalculated as (done todos) / (total non-cancelled todos linked via
    `goal_slug`). The recalculation triggers when any linked todo's
    `kanban_status` changes. Returns nil if the goal has no todos.

  Manual override:
    Set `meta.progress_manual: true` and store a literal value in
    `meta.progress` (0.0–1.0). The auto-calculation is then skipped.

  Other goal meta:
    health       green | yellow | red
    start_date   date
    target_date  date
    team         array of strings
    project_slug optional independent link (no precedence)
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
  2. Communities (Label Propagation)
  ─────────────────────────────────────────────────────────────────────

  Community detection via Label Propagation over typed edges, up to 30
  iterations with early-stop after iteration 3 if labels converge.
  Edges are treated as undirected for community purposes (each edge
  contributes its weight in both directions).

  IMPORTANT — which edges participate:
    Only `part_of`, `embeds`, `supersedes`, and `related` edges are
    used. `semantic` and `contradicts` edges are EXCLUDED:
      - `semantic` is high-volume auto-generated noise that would smear
        communities together.
      - `contradicts` links pages that disagree, which is the opposite
        of "belongs to the same cluster".
    So two pages that only share a `semantic` or `contradicts` edge
    will NOT end up in the same community.

  Persistence:
    `Dran.Graph.refresh_communities/1` writes the detected community id
    into `meta.community_id` (an integer 1..k) using the same jsonb
    merge as PageRank.

  community_id is OPAQUE and NOT STABLE between refreshes:
    Label Propagation is non-deterministic — the node update order is
    shuffled each iteration, so a page's `community_id` integer can
    change between nightly runs even if the graph itself didn't.
    Consumers MUST treat `community_id` as an opaque grouping key
    (use it to check "are A and B in the same community?"), NEVER as
    a stable identity. Do not display it to users or link to it.

  Reading a community's pages:
    `Brain.community_pages(workspace_id, community_id)` returns the
    lightweight list `%{id, slug, title, page_type}` of pages in a
    given community — no body, no embeddings. The Curator agent uses
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
    `Brain.transitive_part_of_candidates/1` runs a recursive CTE
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
    2. refresh_communities/1 (writes meta.community_id)

  All 5 scheduled jobs route through `Dran.Jobs.run_scheduled/1`, which
  honors the per-job toggles in Settings → Brain and writes a `report`
  page per run:
    curator_daily                06:00  daily
    pagerank_nightly             03:00  daily  (this pipeline)
    community_summaries_nightly  03:30  daily  (LLM summary per community)
    graph_maintenance_nightly    03:45  daily  (prunes stale derived relations)
    link_gardener_weekly         07:00  Sundays

  Disabled in `config/test.exs`.
  """

  def agent_connect_example, do: @agent_connect_example
  def auth_api_curl, do: @auth_api_curl
  def planning_hierarchy_diagram, do: @planning_hierarchy_diagram

  # New (v6) planning model documentation.
  def planning_model_overview, do: @planning_model_overview
  def project_page_type, do: @project_page_type
  def global_kanban_doc, do: @global_kanban_doc
  def manual_flags_doc, do: @manual_flags_doc
  def reminder_note_kind_doc, do: @reminder_note_kind_doc
  def plan_statuses_doc, do: @plan_statuses_doc
  def goal_metrics_doc, do: @goal_metrics_doc
  def graph_intelligence_doc, do: @graph_intelligence_doc
end
