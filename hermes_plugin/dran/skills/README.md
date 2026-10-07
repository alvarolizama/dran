# Los skills de Dran (Hermes)

Dran ships **one suite of nine skills**, versioned with this repo, and they all
live **inside the plugin**:

| Suite | Path | Who loads it | What it is for |
|---|---|---|---|
| **The router** (`loader`) | `hermes_plugin/dran/skills/loader/` | an agent operating a Dran instance, from either door | the entry of the suite + the index of the catalog. Registered as the local row `dran:loader` |
| **Agent flows** (8) | `hermes_plugin/dran/skills/<slug>/` | the same agent | one flow per operation: `knowledge-flow`, `relations-flow`, `workers-flow`, `memory-flow`, `goal-flow`, `plan-flow`, `services-flow`, `skills-flow` |

They live with the PLUGIN because they document its tool surface — the router
cannot end up describing an older version of the client — and the slugs carry no
`dran-` prefix: the namespace is the host's (`dran:<slug>` when the plugin
registers them, which is why `dran:dran-knowledge-flow` would read twice).

The flows are thin clients over the plugin tools (`dran_*`, `dran_memory_*`) —
they teach the call sequences, not the internals. Nothing about changing Dran's
code ships here.

## Who serves the suite: the PLUGIN, not the API

These files are the suite, and the suite lives with the plugin: the plugin
registers them as local rows (`dran:<slug>`, loadable with `skill_view`, no
network) and its prompt block points at them.

**Dran does NOT serve them.** The instance's catalog (`GET /api/skills`) carries
the workspace's skills — what a reader created — and nothing else. The nine suite
slugs are simply RESERVED on the server (`422` on a colliding create), so a user
skill can never take the same address and the suite can never be shadowed or
drifted: there is one copy of these bytes, in this directory.

Therefore:

- editing one of these files and redeploying the PLUGIN is the only way to change
  the suite (`hermes plugins update dran` on the profile);
- `dran_skills` / `dran_skill` never return the suite — an agent reads it locally
  with `skill_view("dran:<slug>")` (that is what the prompt block says);
- the mirror under `$HERMES_HOME/dran/skills/` only reconciles the workspace's
  skills, so it no longer carries nine copies of the suite.

Contract and examples: `Dran.Skills` (`lib/dran/skills.ex`) and the
`/api/skills` routes in `lib/dran_web/router.ex`.

## What the suite covers (the app's real surface)

The suite is audited against the code that ships with it — nothing else:

| Skill | Real surface | Source of truth |
|---|---|---|
| `loader` | connection, auth, attribution, the readback rule + the tool-to-flow map + the index of the catalog | `hermes_plugin/dran/skills/loader/SKILL.md` (also the local row the plugin registers), `hermes_plugin/dran/__init__.py`, `lib/dran_web/router.ex` |
| `knowledge-flow` | pages: CRUD, types, rename, reaugment, lint, stats, cluster summaries | `lib/dran/knowledge.ex`, `lib/dran/page_augmenter.ex` |
| `relations-flow` | typed relations — 13 types, 5 of them settable by hand | `lib/dran/relation.ex` |
| `workers-flow` | the 3 workers + what the 7 scheduled jobs are | `lib/dran/worker/`, `lib/dran/jobs.ex` |
| `memory-flow` | memory REST (`/api/memory*`) + the provider tools | `lib/dran_web/controllers/api/memory_controller.ex`, `lib/dran/memory.ex` |
| `goal-flow` | goals · tasks · capture · board · destination (`scope`/grupo) | `lib/dran/goals.ex`, `lib/dran/tasks.ex` |
| `plan-flow` | plans (entidad propia) · su checklist y el `progress` derivado | `lib/dran/plans.ex` |
| `services-flow` | the user's own apps: connect (`/api/services/:toolkit/connect`), state, discovery (`…/tools`, `…/search`), execute | `lib/dran/services.ex`, `lib/dran/composio.ex`, `lib/dran_web/controllers/api/service_controller.ex` |
| `skills-flow` | the skills Dran SERVES to agents: the live catalog (`dran_skills`, `q` to search), one body by tool (`dran_skill`, `unchanged` by hash), create/update and delete after the ASK, and the on-disk mirror reconciled by checksum (`dran_skill_sync`) | `lib/dran/skills.ex`, `lib/dran_web/controllers/api/skill_controller.ex` |

**Invariant:** every registered tool has a home in a flow, and no flow
describes a tool the plugin does not register. Measure both sides before
adding or keeping a line:

```bash
# the toolset the plugin really registers (51: 47 dran_* + 4 dran_memory_*)
grep -oE '"name": "dran_[a-z_]+"' hermes_plugin/dran/__init__.py | sort -u | wc -l
# every registered tool also has an OFF GROUP (`_TOOL_GROUPS`), which is what
# the panel toggles and what names the Hermes toolsets `dran_<group>`
grep -c '("pages"\|("goals"\|("tasks"\|("plans"\|("services"\|("skills"\|("brain"' hermes_plugin/dran/__init__.py
# the names each skill of the suite claims (exact tool names, backticked), to
# diff against the line above — prose suffixes (dran_memory_*) and repo paths
# (lib/dran_web/…) are not tool claims, and neither are the TOOLSET names the
# router lists (`dran_pages`, `dran_goals`, `dran_tasks`, `dran_plans`,
# `dran_brain`): they are dropped by name here. The ROUTER is included: it lives
# with the plugin now, and half the tool table is in its body.
grep -rhoE '`dran_[a-z_]+`' hermes_plugin/dran/skills/*/SKILL.md | tr -d '`' \
  | grep -vxE 'dran_pages|dran_goals|dran_tasks|dran_plans|dran_brain' | sort -u
# the REST surface under every tool
grep -nE '^\s+(live|get|post|put|patch|delete) "' lib/dran_web/router.ex
```

The three commands are the audit: the second list must contain every name of the
first (no hole) and nothing the first lacks (no phantom).

## How Hermes discovers a skill

| | `skills.external_dirs` (**retired**) | `ctx.register_skill()` (**the router only**) | the plugin prompt block + tools (**the flows**) |
|---|---|---|---|
| Shows up in `skills_list` | yes — one row per skill | **yes** — nine rows: `dran:loader` + `dran:<flow>` | no — the local list never carries the workspace's skills |
| Shows up in the agent's catalog | yes — it loads the skill on its own | no — explicit `skill_view()` only | **yes** — one line per skill in the prompt section, loaded by tool |
| Install | symlink + one config line | automatic at plugin load | none (the suite ships with the plugin) |
| Body on disk | yes (a second copy) | yes — the same files the plugin registers | **only in the plugin's mirror** — the body arrives by tool; `$HERMES_HOME/dran/skills/` keeps a copy for offline + checksum reconciliation, never as a local skill |
| Retracted on unload | no | yes | yes — the section is rebuilt per session (the mirror survives: it is the plugin's cache, not a registration) |

The suite **used** to be installed locally as well. It is not any more: the plugin
already puts the catalog in front of the agent — one line per skill in the prompt
block, the live list and `q=` search through `dran_skills`, and the body through
`dran_skill` — so a local copy of the flows was a second source of the same bytes,
able to drift, and their bodies never needed to live on disk. The activation line
in `soul.md` keeps working because the agent *sees* the skills in the block.

**The mirror is not that local install coming back.** Since the plugin caches the
bodies it loads in `$HERMES_HOME/dran/skills/` (SKILL.md + `manifest.json` with the
hashes), a body IS on disk again — but nothing is *registered*: it does not enter
`skills_list`, it is not symlinked into `~/.hermes/skills/`, and **the remote always
wins** (the body is fetched on every load; the file only answers while Dran does
not). `dran_skill_sync` reconciles it by checksum — the index the prompt already
fetches carries every `content_hash` — and can push a local edit fast-forward only.
Contract: `hermes_plugin/dran/README.md` § «El espejo en disco».

## The nine local rows (the suite)

`hermes skills list | grep dran` used to be empty, and that was the design. It now
shows NINE rows — `dran:loader` plus `dran:<flow>` for the eight flows — and they are
there because **"list the skills" runs the LOCAL listing** (`skills_list`): that is
where the answer has to exist. The plugin registers them with `ctx.register_skill`
(`hermes_plugin/dran/skills/<slug>/SKILL.md`), reading the description from each
file's frontmatter, so the listing cannot say something the body does not.

- `dran:loader` IS the router — entry map, connection, general rules, the route to
  the live catalog (`tool_search` with an English query → `dran_skills` →
  `dran_skill`) — so the same row answers "what can I do with Dran" and "list the
  skills".
- Each file is the **only** copy of its body: the plugin registers these local rows
  and the prompt block points at them, so there is one source of bytes for the
  listing, the block and the agent's `skill_view` — nothing to drift. The rows are
  retracted when the plugin unloads and are never copied to `~/.hermes/skills/`.
- The router's description is the trigger and stays ≤60 chars (Hermes truncates
  there): `Use when asked to list skills or operate Dran.`
- Note the trap the rows exist to close: the five skill tools are **deferred** by
  Hermes (every plugin tool is), and the bridge's catalog cuts descriptions to
  ~60 chars — so a query has to be English (`"dran skills"`) and an empty search
  result is a miss, not a missing capability.


## Retiring the local install

If a profile still carries the old setup, remove both halves and confirm:

```bash
rm -f ~/Workspace/Skills/dran ~/Workspace/Skills/dran-*
hermes skills list | grep dran   # nine rows afterwards: dran:loader + dran:<flow>
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
for f in hermes_plugin/dran/skills/*/SKILL.md; do
  d=$(grep -m1 '^description:' "$f" | sed 's/^description: *//; s/^"//; s/"$//')
  printf '%-34s %2d %s\n' "$f" "${#d}" "$([ ${#d} -le 60 ] && echo ok || echo TOO-LONG)"
done
```

## Naming convention

| Name | Meaning |
|---|---|
| `loader` | the router: the entry of the suite + the index of the catalog |
| `<operation>-flow` | an agent operation flow (knowledge, relations, workers, memory, goals, plans, services, skills) |

No name carries a system prefix: the namespace is the host's (`dran:loader`,
`dran:knowledge-flow` in `skills_list`) and the slugs on the wire are those same
bare names — RESERVED on the server, where a `dran-` prefix would only add noise
to the address.

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
