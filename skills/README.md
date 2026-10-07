# Los skills de Dran (Hermes)

Dran ships **one suite of skills**, versioned with this repo:

| Suite | Path | Who loads it | What it is for |
|---|---|---|---|
| **Agent flows** (9) | `skills/` | an agent operating a Dran instance | router + one flow per operation: knowledge, relations, workers, memory, goals, plans, services, skills |

The agent flows are thin clients over the plugin tools (`dran_*`,
`dran_memory_*`) — they teach the call sequences, not the internals. Nothing
about changing Dran's code ships here.

## Dran serves this suite itself (the built-ins)

These files are ALSO the catalog Dran serves to every API credential by default:
`GET /api/skills` returns all 9 with `"system": true` — for an account token, a
group token and the admin token alike, with no install and no share. The content
is read from these files **at compile time** and reconciled into the `skills`
table on every boot (`Dran.Skills.Builtin`), so:

- editing one of these files and redeploying is the ONLY way to change a
  built-in; the API never writes them (their slugs are reserved, `403` on
  `PUT`/`DELETE`, `422` on a colliding create);
- what the plugin hands the agent by tool and what the API serves are the same
  bytes, by construction;
- the directory must be in the build context before `mix compile` (the Dockerfile
  copies it) — the content is baked into the beam, never read from disk at
  runtime.

Contract and examples: `Dran.Skills` (`lib/dran/skills.ex`) and the
`/api/skills` routes in `lib/dran_web/router.ex`.

## What the suite covers (the app's real surface)

The suite is audited against the code that ships with it — nothing else:

| Skill | Real surface | Source of truth |
|---|---|---|
| `dran` | connection, auth, attribution, the readback rule + the tool-to-flow map | `hermes_plugin/dran/__init__.py`, `lib/dran_web/router.ex` |
| `dran-knowledge-flow` | pages: CRUD, types, rename, reaugment, lint, stats, cluster summaries | `lib/dran/knowledge.ex`, `lib/dran/page_augmenter.ex` |
| `dran-relations-flow` | typed relations — 13 types, 5 of them settable by hand | `lib/dran/relation.ex` |
| `dran-workers-flow` | the 3 workers + what the 7 scheduled jobs are | `lib/dran/worker/`, `lib/dran/jobs.ex` |
| `dran-memory-flow` | memory REST (`/api/memory*`) + the provider tools | `lib/dran_web/controllers/api/memory_controller.ex`, `lib/dran/memory.ex` |
| `dran-goal-flow` | goals · tasks · capture · board · destination (`scope`/grupo) | `lib/dran/goals.ex`, `lib/dran/tasks.ex` |
| `dran-plan-flow` | plans (entidad propia) · su checklist y el `progress` derivado | `lib/dran/plans.ex` |
| `dran-services-flow` | the user's own apps: connect (`/api/services/:toolkit/connect`), state, discovery (`…/tools`, `…/search`), execute | `lib/dran/services.ex`, `lib/dran/composio.ex`, `lib/dran_web/controllers/api/service_controller.ex` |
| `dran-skills-flow` | the skills Dran SERVES to agents: the live catalog (`dran_skills`, `q` to search), one body by tool (`dran_skill`, `unchanged` by hash), create/update and delete after the ASK | `lib/dran/skills.ex`, `lib/dran_web/controllers/api/skill_controller.ex` |

**Invariant:** every registered tool has a home in a flow, and no flow
describes a tool the plugin does not register. Measure both sides before
adding or keeping a line:

```bash
# the toolset the plugin really registers (50: 46 dran_* + 4 dran_memory_*)
grep -oE '"name": "dran_[a-z_]+"' hermes_plugin/dran/__init__.py | sort -u | wc -l
# every registered tool also has an OFF GROUP (`_TOOL_GROUPS`), which is what
# the panel toggles and what names the Hermes toolsets `dran_<group>`
grep -c '("pages"\|("goals"\|("tasks"\|("plans"\|("services"\|("skills"\|("brain"' hermes_plugin/dran/__init__.py
# the names each skill of the suite claims (exact tool names, backticked), to
# diff against the line above — prose suffixes (dran_memory_*) and repo paths
# (lib/dran_web/…) are not tool claims
grep -rhoE '`dran_[a-z_]+`' skills/*/SKILL.md | tr -d '`' | sort -u
# the REST surface under every tool
grep -nE '^\s+(live|get|post|put|patch|delete) "' lib/dran_web/router.ex
```

The three commands are the audit: the second list must contain every name of the
first (no hole) and nothing the first lacks (no phantom).

## How Hermes discovers a skill

| | `skills.external_dirs` (**retired**) | `ctx.register_skill()` (**the pointer only**) | the plugin prompt block + tools (**the suite**) |
|---|---|---|---|
| Shows up in `skills_list` | yes — one row per skill | **yes** — one row: `dran:dran-skills-index` | no — the local list never carries the suite |
| Shows up in the agent's catalog | yes — it loads the skill on its own | no — explicit `skill_view()` only | **yes** — one line per skill in the prompt section, loaded by tool |
| Install | symlink + one config line | automatic at plugin load | none (the built-ins ship with Dran) |
| Body on disk | yes (a second copy) | yes — and it is a POINTER, not a body of the suite | **no** — it arrives by tool and dies with the session |
| Retracted on unload | no | yes | yes — the section is rebuilt per session |

The suite **used** to be installed locally as well. It is not any more: the plugin
already puts the catalog in front of the agent — one line per skill in the prompt
block, the live list and `q=` search through `dran_skills`, and the body through
`dran_skill` — so a local copy of the flows was a second source of the same bytes,
able to drift, and their bodies never needed to live on disk. The activation line
in `soul.md` keeps working because the agent *sees* the skills in the block.

## The one local row (the pointer)

`hermes skills list | grep dran` used to be empty, and that was the design. It now
shows exactly ONE row — `dran:dran-skills-index` — and it is there because **"list
the skills" runs the LOCAL listing** (`skills_list`): that is where the answer has
to exist, and the suite is not in it. The plugin registers that row with
`ctx.register_skill` (`hermes_plugin/dran/skills/dran-skills-index/SKILL.md`).

- Its body is **not** a flow of the suite: it is the route to the live catalog
  (`tool_search` with an English query → `dran_skills` → `dran_skill`).
- No body of the suite is on disk and none is served from that file; the row is
  retracted when the plugin unloads and is never copied to `~/.hermes/skills/`.
- Its description is the trigger and stays ≤60 chars (Hermes truncates there):
  `Use when asked to list skills: Dran serves them remotely.`
- Note the trap the row exists to close: the four skill tools are **deferred** by
  Hermes (every plugin tool is), and the bridge's catalog cuts descriptions to
  ~60 chars — so a query has to be English (`"dran skills"`) and an empty search
  result is a miss, not a missing capability.


## Retiring the local install

If a profile still carries the old setup, remove both halves and confirm:

```bash
rm -f ~/Workspace/Skills/dran ~/Workspace/Skills/dran-*
hermes skills list | grep dran   # exactly one row afterwards: dran:dran-skills-index
```

Also drop the `skills.external_dirs` entry that pointed at
`~/Workspace/Skills`, and the `.hermes/skills` symlink inside a checkout if it
exists (it made the checkout's `skills/` folder a project skill dir).

## Descriptions must stay ≤ 60 characters

Hermes truncates every skill description to **60 chars** in the
`<available_skills>` index (`agent/skill_utils.py: SKILL_PROMPT_DESC_LIMIT`).
The description is the routing signal — a truncated one loses exactly the
part that tells the agent *when* to load the skill. Keep the frontmatter
`description:` at 60 characters or fewer, and put the detail in the body.

Check the whole suite:

```bash
for f in skills/*/SKILL.md; do
  d=$(grep -m1 '^description:' "$f" | sed 's/^description: *//; s/^"//; s/"$//')
  printf '%-34s %2d %s\n' "$f" "${#d}" "$([ ${#d} -le 60 ] && echo ok || echo TOO-LONG)"
done
```

## Naming convention

| Prefix | Meaning |
|---|---|
| `dran` | the router |
| `dran-<flow>` | an agent operation flow (knowledge, relations, workers, memory, goals, plans, services, skills) |

There is no `dran-dev-*` prefix any more: the suite is for operating a Dran
instance, so no skill about its code ships with it.

## What does NOT ship as a skill

- **Developer skills**: no `dran-dev-*`. The coding skills that used to live in
  `skills/dev/` were removed — the suite teaches how to USE Dran, never how it
  is built, and a flow that talks about internals is a flow the agent loads for
  the wrong job. They exist only in git history.
- **MCP**: there is no MCP server any more. If you find a skill mentioning
  MCP tool names or `mcp_servers`, it is stale — the plugin tools and the REST
  API replaced it. MCP imports of a live server config are likewise gone.
