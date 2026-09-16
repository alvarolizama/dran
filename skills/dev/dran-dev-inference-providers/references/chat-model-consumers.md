# Chat-model consumers in Dran (what `model_chat` drives)

Use when the user asks "what is this model for / when does it run" about
the model selects at `/admin/models`. `model_chat` (setting key `chat`,
resolved by `Dran.Inference.Config.chat_model/0`) is the general-purpose
LLM behind all background language processing.

## Consumers

| Consumer | Module | What it does |
| --- | --- | --- |
| PageAugmenter | `lib/dran/page_augmenter.ex` | One call extracts title + summary + tags + entities + inline_links per page |
| Cluster summaries | `lib/dran/graph/cluster_summaries.ex` | Summarizes graph clusters (topics) |
| Worker engine | `lib/dran/worker/engine.ex` | ReAct loop brain for all three workers |
| Page summaries backfill | `lib/dran/page_summaries.ex` | Nightly fill of missing page summaries |
| Memory API metadata | `memory_controller.ex` | Reports model name in response metadata |

Embeddings and rerank-free search do NOT use it — that is `model_embedding`.

## Trigger chain for page summaries/tags

`Knowledge.create_page` / `update_page` (and the plugin create path) call
`Dran.PageAugmenter.schedule/1` → Task under
`Dran.Relations.TaskSupervisor` (returns immediately; sync only when
`:inference, schedule_async: false` in tests) → `Summaries.augment_page`
→ single chat call with `response_format: json_object`, temperature 0.3,
body truncated to the same window as embeddings
(`Embeddings.truncate_body/1`).

Guarantees:
- `summary` is machine-owned: an existing summary is NEVER overwritten —
  augmentation only fills missing fields. Editing does not churn summaries.
- Inference off → schedule is a silent `:ignored`.
- Nightly catch-up: `page_summaries_nightly` Quantum job re-fills pages
  whose summary is still empty (max 500/run, concurrency 3) — covers the
  inference-was-down case.

## Worker engine (ReAct)

`Dran.Worker.Engine.run(module, input, workspace_id, opts)` inserts a
`worker_sessions` row (meta.model = chat model) and returns immediately;
the loop runs supervised. Each step: chat call → tool action → observation
→ repeat until `done` or limits. Steps persist and broadcast on PubSub
`workers:<session_id>`; sessions are cancellable via the SessionRegistry.

Safety limits: max steps ~150, per-step timeout 120s, max 5 consecutive
errors, per-workspace `worker_max_pages` cap on created pages.

The three workers (all implement `Engine.Behaviour`):
- **Curator** — duplicate detection (embedding distance < 0.05), flags
  `kb_contested`, writes a report page. Scheduled daily.
- **LinkGardener** — cross-page link maintenance. Scheduled weekly.
- **GraphRag** — Q&A over the KB (local/global/drift search + answer
  synthesis, creates an answer page). On demand only.

Execution triggers: Quantum cron in `config/config.exs` routed through
`Dran.Jobs.run_scheduled/1` (daily curator, weekly link_gardener), and the
The `dran_start_worker` plugin tool for on-demand runs of any of the three.
