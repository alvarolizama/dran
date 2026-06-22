# Capture Batch Recipe (verified)

This is the exact pattern that worked in production on 2026-06-21 for
capturing the 4-page Bön mantram set in Dran
(`yungdrung-bon`, `om-bom-namaha`, `so-ma-ma-ra-yo-dza`, `yeshe-walmo`).
Verified graph: 4 pages, 10 relations, 0 orphans, 0 broken.

## The plan BEFORE you write any code

For every capture batch, write down:

1. **Pages** (slug + page_type + meta.kind + 1-line description)
2. **Wikilinks** (which page wikilinks to which — auto-creates `related`)
3. **Typed relations** (source → target, type) — these you must call explicitly
4. **Validation targets** (which slugs will you `get_links` after)

Skipping step 3 is the most common cause of "user says the typed relation
is missing." See HARD RULE #2 in SKILL.md.

## Working example (4 pages, 10 relations)

| # | Slug | Type | meta.kind | Wikilinks out |
|---|---|---|---|---|
| 1 | `yungdrung-bon` | concept | discipline | → yeshe-walmo, om-bom-namaha, so-ma-ma-ra-yo-dza |
| 2 | `om-bom-namaha` | concept | technique | → yungdrung-bon |
| 3 | `so-ma-ma-ra-yo-dza` | concept | technique | → yungdrung-bon, om-bom-namaha |
| 4 | `yeshe-walmo` | entity | person | → yungdrung-bon, om-bom-namaha, so-ma-ma-ra-yo-dza |

Wikilinks auto-create 7× `related` relations.

| Typed relation | Why it can't be a wikilink |
|---|---|
| `so-ma-ma-ra-yo-dza --part_of--> yeshe-walmo` | The mantram is the seed of the deity — semantic, not just "mentioned together" |

**Result:** 7 wikilink `related` + 1 typed `part_of` + back-edges (the
madre wikilinks to all children, which auto-creates another 2 inbound
`related` per child) = **10 relations total**.

## Order of operations

```
1. Create madre first (yungdrung-bon) — base of the graph
2. Create children with wikilinks to madre + peers
3. Fix any broken wikilinks surfaced by lint (update_page)
4. create_relation for typed connections
5. get_links on EVERY page, both sides of every relation
6. lint() → 0 orphans, 0 broken
7. stats() → confirm relation count moved as expected
```

## Validation output (from the actual capture)

```
=== STATS ===
Total pages: 4
Total relations: 10
Orphan pages: 0
Broken wikilinks: 0

=== LINT ===
Orphan pages (no inbound links): 0
Broken wikilinks: 0

=== LINKS yungdrung-bon (madre) ===
Outbound (3): related → yeshe-walmo, related → om-bom-namaha, related → so-ma-ma-ra-yo-dza
Inbound (3): related from each child

=== LINKS so-ma-ma-ra-yo-dza ===
Outbound (3): related → yungdrung-bon, related → om-bom-namaha, part_of → yeshe-walmo
Inbound (2): related from yeshe-walmo, related from yungdrung-bon
```

## Common directional gap to watch

The most common failure: `get_links(A)` shows `related → B`, but
`get_links(B)` does NOT show `related from A` because B's body never
mentioned A.

**Fix in the planning step:** for every wikilink A → B, ask "should B
also mention A?" If yes, add `[[A]]` to B's body. If no (e.g. B is a
foundational concept that doesn't need to know about every note that
mentions it), leave it — but document the asymmetry.

## Production gotchas (June 2026)

- `Error: context 'personal' not found` → seeds never ran on this VPS.
  Fix once: `bin/setup` or `mix run priv/repo/seeds.exs` on the server.
  Don't try to work around it by passing a different context.
- `Error: source_id: has already been taken` → you tried to create a
  relation that already exists. `get_links` first. This is **expected
  and good** when re-running a script — it means the relation is there.
- 401 → token missing or wrong. `echo ${MCP_DRAN_API_KEY:0:4}` (4 chars
  only, never the full token).
