# Instalar los skills de Dran (Hermes)

Dran ships **two suites of skills**, both versioned with this repo:

| Suite | Path | Who loads it | What it is for |
|---|---|---|---|
| **Agent flows** (5) | `skills/` | an agent operating a Dran instance | router + one flow per operation: knowledge, relations, workers, memory |
| **Dev skills** (7) | `skills/dev/` | someone changing this repo's code | page types, auth surface, slug policy, settings, UI tweaks, inference, actor model |

The agent flows are thin clients over the plugin tools (`dran_*`,
`dran_memory_*`) — they teach the call sequences, not the internals. The dev
skills are the opposite: they assume you are editing `lib/`.

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
# 1. Agent flows (5) — the everyday suite
mkdir -p ~/Workspace/Skills
for s in dran dran-knowledge-flow dran-memory-flow \
         dran-relations-flow dran-workers-flow; do
  ln -sfn /path/to/dran/skills/$s ~/Workspace/Skills/$s
done

# 2. Dev skills (7) — only when you work on this repo
for s in /path/to/dran/skills/dev/dran-dev-*; do
  ln -sfn "$s" ~/Workspace/Skills/$(basename "$s")
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
hermes skills list | grep dran          # should list 12
```

## Descriptions must stay ≤ 60 characters

Hermes truncates every skill description to **60 chars** in the
`<available_skills>` index (`agent/skill_utils.py: SKILL_PROMPT_DESC_LIMIT`).
The description is the routing signal — a truncated one loses exactly the
part that tells the agent *when* to load the skill. Keep the frontmatter
`description:` at 60 characters or fewer, and put the detail in the body.

Check the whole suite:

```bash
for f in skills/*/SKILL.md skills/dev/*/SKILL.md; do
  d=$(grep -m1 '^description:' "$f" | sed 's/^description: *//; s/^"//; s/"$//')
  printf '%-34s %2d %s\n' "$f" "${#d}" "$([ ${#d} -le 60 ] && echo ok || echo TOO-LONG)"
done
```

## Naming convention

| Prefix | Meaning |
|---|---|
| `dran` | the router |
| `dran-<flow>` | an agent operation flow (knowledge, relations, workers, memory) |
| `dran-dev-<topic>` | a developer skill for this repo |

The `dran-dev-` prefix matters: without it, developer notes compete with the
operational flows in the agent's index, and the agent picks "how Dran works
internally" when it should have picked "how to use it".

## What does NOT ship as a skill

- **MCP**: there is no MCP server any more. If you find a skill mentioning
  `mcp_dran_*` or `mcp_servers`, it is stale — the plugin tools and the REST
  API replaced it.
