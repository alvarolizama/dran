# Updating the Dran README

When asked to update `README.md` to reflect the real state of the project,
verify every claim against source before writing it. Do not trust the existing
README or SKILL.md blindly — both drift.

## Verification map

| Claim to verify | Where to check in source |
| --- | --- |
| MCP tool count + names | `grep -nE '"name" => "[a-z_]+"' lib/dran/mcp.ex` |
| Agent types | `grep -n "@agent_type\|def agent_type" lib/dran/agent/*.ex` |
| Agent tools (per agent) | `grep -n "def execute_tool" lib/dran/agent/*.ex` |
| Quantum jobs + schedules | `config/config.exs` (search `Quantum` / `jobs:`) |
| Runtime settings + defaults | `lib/dran/settings.ex` (`@defaults` map) |
| Env vars in `.env.example` | `grep -E '^[A-Z_]+=' .env.example` |
| PageAugmenter dynamic thresholds | `lib/dran/brain/page_augmenter.ex` (`semantic_threshold/1`) |
| LiveView features (daily notes, activity, copilot, settings) | `ls lib/dran_web/live/`, `ls lib/dran_web/components/` |
| Exporter | `lib/dran/exporter.ex`, `lib/dran_web/controllers/api/export_controller.ex` |
| Version history | `lib/dran/brain.ex` (`list_page_versions`, `save_page_version`) |

## Workflow

1. Read the current README end-to-end (use `read_file` with offset/limit for
   large files — README is ~550 lines).
2. Read SKILL.md section 4 (Configuration) to cross-check env vars.
3. Run the grep/ls commands above to verify each feature claim.
4. Patch in this order: Features → Stack → Env vars → MCP tools table →
   Autonomous agents table → Screenshots placeholder.
5. For the MCP tools table, count the actual `"name" =>` entries in
   `lib/dran/mcp.ex` — do not guess. As of 2026-07-17 there are 18 tools
   (all prefixed `dran_`; `semantic_search` was removed in v4.0.0).
6. Screenshots: add a `## Screenshots` section with `![Alt](docs/screenshots/<name>.png)`
   placeholders. Another agent generates the actual images later.

## Pitfalls

- **Don't trust the old tool count.** The README and skill have said different
  numbers over time. Always recount `"name" =>` entries in `lib/dran/mcp.ex`.
- **Don't trust the old agent list.** The README said "research or ingest" but
  there are 6 agent types. Check `@agent_type` in every file under
  `lib/dran/agent/`.
- **SKILL.md env-var table is not authoritative for README.** SKILL.md section
  4 omits `DRAN_USERNAME`, `DRAN_CONTEXT_SLUG`, `DRAN_CONTEXT_NAME` from its
  main table (they appear elsewhere). Cross-check against `.env.example` and
  `config/runtime.exs`.
- **Quantum is in `config/config.exs`, not `config/runtime.exs`.** The job
  definitions live under `if config_env() != :test do config :dran, Dran.Scheduler, jobs: [...]`.
