# Instalar los skills de Dran (Hermes)

Dran ships **one suite of skills**, versioned with this repo:

| Suite | Path | Who loads it | What it is for |
|---|---|---|---|
| **Agent flows** (8) | `skills/` | an agent operating a Dran instance | router + one flow per operation: knowledge, relations, workers, memory, goals, plans, services |

The agent flows are thin clients over the plugin tools (`dran_*`,
`dran_memory_*`) — they teach the call sequences, not the internals. Nothing
about changing Dran's code ships here.

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

**Invariant:** every registered tool has a home in a flow, and no flow
describes a tool the plugin does not register. Measure both sides before
adding or keeping a line:

```bash
# the toolset the plugin really registers (46: 42 dran_* + 4 dran_memory_*)
grep -oE '"name": "dran_[a-z_]+"' hermes_plugin/dran/__init__.py | sort -u | wc -l
# the names each skill of the suite claims, to diff against the line above
grep -rhoE '\bdran_[a-z_]+' skills/*/SKILL.md | sort -u
# the REST surface under every tool
grep -nE '^\s+(live|get|post|put|patch|delete) "' lib/dran_web/router.ex
```

The three commands are the audit: the second list must contain every name of the
first (no hole) and nothing the first lacks (no phantom).

## How Hermes discovers a skill

Two mechanisms exist. They are **not** equivalent:

| | `skills.external_dirs` (what Dran uses) | `ctx.register_skill()` (plugin API) |
|---|---|---|
| Shows up in `<available_skills>` | **yes** — the agent sees it and loads it on its own | **no** — explicit `skill_view()` only |
| Install | symlink + one config line | automatic at plugin load |
| Names | `dran`, `dran-knowledge-flow` | namespaced `dran:dran` |
| Retracted on unload | no | yes |

Dran uses `external_dirs` **on purpose**: the activation line in `soul.md`
("when operating the Dran workspace… load the `dran` skill") only works
because the agent can *see* the skills. Registering them through the plugin
would remove them from the catalog and the activation line would point at
nothing.

## Install

```bash
# The whole suite (8)
mkdir -p ~/Workspace/Skills
for s in dran dran-knowledge-flow dran-memory-flow \
         dran-relations-flow dran-workers-flow dran-goal-flow \
         dran-plan-flow dran-services-flow; do
  ln -sfn /path/to/dran/skills/$s ~/Workspace/Skills/$s
done
```

Point the profile at that directory (once):

```yaml
# ~/.hermes/profiles/<profile>/config.yaml
skills:
  external_dirs:
    - ~/Workspace/Skills
```

Restart the Hermes session. Verify:

```bash
hermes skills list | grep dran          # should list 8
```

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
| `dran-<flow>` | an agent operation flow (knowledge, relations, workers, memory, goals, plans, services) |

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
