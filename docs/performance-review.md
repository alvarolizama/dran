# Dran — performance review

Every claim in this file was measured with `EXPLAIN (ANALYZE, COSTS OFF)`
against the **dev database on this working tree** (2026-10-04). That base is
small — 8 pages, 13 relations, 2 tasks, 107 indexes in `public` — so the
plans say `Seq Scan` almost everywhere and the execution times are
microseconds. The value of the measurement is the **plan structure** (which
index a query can and cannot use), not the absolute cost; the volume verdict
is explicit in each row. **Q6 (2026-10-05)** is the exception: it measured a
synthetic dataset with production-like cardinality, inserted and analyzed
inside a transaction that was rolled back — noted in its own block.

## The hot queries of the listings, measured

### Q1 — the pages list (`PagesLive`, `Knowledge.list_pages`)
`WHERE workspace_id = $1 AND archived = false ORDER BY inserted_at DESC LIMIT 50`

- **Plan (measured):** Seq Scan on knowledge_pages → quicksort → Limit;
  Execution Time **0.050 ms** with 8 rows.
- **Indexes that serve it:** `knowledge_pages_workspace_id_archived_index`
  (workspace_id, archived) filters; the sort is not covered by any index.
- **Verdict: no index added.** The only defensible candidate would be
  `(workspace_id, archived, inserted_at DESC)` — it would make the sort
  free at volume. It is NOT created here: with the dev base at 8 rows the
  EXPLAIN cannot demonstrate a win (the planner prefers the seq scan at any
  small size), and a migration the contract requires to be justified cannot
  be justified by a measurement that shows none. If page volume becomes a
  real pain point, that is the index to try first, measured against the
  production-volume base.

### Q2 — the FTS search (`/search`, `Knowledge.search`)
`WHERE search_vector @@ plainto_tsquery(...) ORDER BY ts_rank(...) DESC`

- **Plan (measured):** Sort on `ts_rank` over a Seq Scan — the GIN index
  `knowledge_pages_search_idx (search_vector)` exists and the planner picks
  the seq scan only because the table is tiny; at volume the GIN serves the
  `@@` filter and the ranking sorts the hits (bounded by LIMIT 20).
- **Verdict: covered.** No change.

### Q3 — a page's links (detail sidebar, `dran_get_links`)
`WHERE r.source_id = (SELECT id FROM knowledge_pages …)`

- **Plan (measured):** Index Scan using `relations_source_id_source_type_index`;
  `Index Cond: (source_id = InitPlan)`.
- **Verdict: covered.** No change.

### Q4 — the board's goals with their task counts
`goals LEFT JOIN tasks … GROUP BY g.id ORDER BY inserted_at`

- **Plan (measured):** Hash Right Join on `t.goal_id` → GroupAggregate →
  Sort. `tasks_goal_id_index (goal_id)` exists (plus the composite
  `goal_id_status_position` the board columns use).
- **Verdict: covered.** No change.

### Q5 — `transitive_part_of_candidates/1` (the recursive raw SQL)
- **Plan (measured):** the recursion enters via
  `relations_source_id_source_type_index` (Index Cond on `source_id = p.id`);
  the second arm scans `relations` filtered by `relation_type = 'part_of'`
  and the WorkTable joins — the planner chooses a seq scan there at this
  size. The final joins hash/sort on slugs.
- **Verdict: covered for now.** The depth is capped (`depth < 2`), so the
  recursion is bounded regardless of volume; a `relations (relation_type,
  source_id)` covering index could help the second arm at volume, but
  measuring that win needs a relations table two orders of magnitude
  bigger than this one — not created here.

### Q6 — the group-filtered listing (W3, contract `grupo-credencial`)

`Dran.ContentVisibility.filter/3` with `{:group, gid}` — lo que ve una
credencial de grupo (`GET /api/knowledge-pages` con un token de grupo):

```sql
WHERE workspace_id = $1 AND archived = false AND visibility = 'shared'
  AND EXISTS (SELECT 1 FROM content_shares s
               WHERE s.resource_type = 'page' AND s.resource_id = p.id
                 AND s.user_group_id = $2)
ORDER BY updated_at DESC LIMIT 50
```

**Medido sobre un dataset sintético de cardinalidad realista** (20.008
`knowledge_pages`, 5.000 `content_shares`, un grupo), insertado, `ANALYZE`-ado y
consultado DENTRO de una transacción que se revierte: el árbol y la base de dev
quedan intactos. Método distinto al del resto del archivo por una razón medida —
la base de `dran_dev` tiene **8 páginas y 0 grupos**, y un EXPLAIN de este
filtro ahí no dice nada.

- **Plan (medido):** `Nested Loop Semi Join`. El `EXISTS` correlacionado lo
  resuelve `Index Scan using content_shares_resource_type_resource_id_index`
  (`Index Cond: resource_type + resource_id`, `Filter: user_group_id`), 50
  index searches para las 50 filas del LIMIT; la lista la sirve
  `knowledge_pages_context_updated_at_idx` en `Index Scan Backward`, así que el
  costo es O(limit), no O(tabla).
- **Tiempos (misma corrida):** grupo **0.295 ms** / 161 buffers. El lector de
  CUENTA —el mismo listado con `{:reader, id}` y su `ANY(group_ids)`— **0.625 ms**
  / 57 buffers: su variante arma un SubPlan hash sobre un `Seq Scan` completo de
  `content_shares`. El modo de lectura del grupo es el más barato de los dos.
- **Antes/después del índice triple:** con
  `content_shares_resource_type_resource_id_user_group_id_index` → **0.295 ms**;
  con ese índice DROP-eado dentro de la transacción → **0.152 ms**, el MISMO
  plan y los MISMOS 161 buffers. La diferencia es ruido de caché (ambos por
  debajo del milisegundo) y prueba lo que importa: **el planificador no usa el
  índice triple para esta consulta** — le basta el de dos columnas y filtra
  `user_group_id` en memoria.
- **Verdict: no index added.** El índice que un `EXISTS` por grupo necesitaría
  (`content_shares (resource_type, resource_id, user_group_id)`) **ya existe**
  desde una ola anterior, y la medición dice que ni siquiera hace falta: el de
  dos columnas sirve el `EXISTS` por fila y el `LIMIT 50` corta la búsqueda.
  Crear otro sería un índice sin medición que lo justifique (constraint 9), y
  esta ola corre UNA sola migración (constraint 10).

## What was NOT touched

- **No migration created.** `git diff priv/repo/migrations` on this pass is
  empty: every candidate index fails the contract's bar (an EXPLAIN that
  demonstrates a win on the data that exists), and Q1's sort candidate is
  documented above instead of shipped on faith.
- **No query rewritten.** The measured queries keep their semantics; the
  security pass touched no read path either.
- **Indexes exist where the plan says they matter**: GIN on `search_vector`
  (FTS), GIN trigram on `title` (fuzzy), HNSW on `embedding` (semantic),
  btree `(workspace_id, archived[, page_type])` (the listings), btree on
  both relation endpoints, btree `(goal_id[, status, position])` (the
  board).

## Re-measuring

Re-run the EXPLAIN of Q1/Q5 against a base with production-like volume
before creating any index; the queries are quoted in
`lib/dran/knowledge.ex` (`list_pages/1`, `fts_search/2`,
`transitive_part_of_candidates/1`). A win that shows only in a bigger base
must be measured in a bigger base.
