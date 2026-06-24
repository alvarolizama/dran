# Plan: Integrate inference API into Dran

Status: draft — implementation not started.

This plan adds **embeddings**, **reranking**, and **document-to-markdown conversion** to Dran using the OpenAI-compatible inference server.

Each phase has acceptance criteria and a test deliverable. We validate the business logic before adding new UI or MCP tools.

---

## Phase 0 — Adapter & health check

Goal: a small, reliable HTTP client for the inference API. Use `Req` (already a dependency). Keep all model names and endpoints configurable.

### Tasks

1. Create `lib/dran/inference.ex` (behaviour + implementation):
   - `embed/2` — text → vector
   - `rerank/3` — query + docs → ranked indexes
   - `chat/2` — OpenAI chat completions (used by MarkItDown wrapper)
2. Create `lib/dran/inference/markitdown.ex` wrapper that builds the chat request with a `file` content part.
3. Add runtime config for `:dran, :inference` using env vars:
   - `DRAN_INFERENCE_API_URL`
   - `DRAN_INFERENCE_API_KEY`
   - optional per-capability model names (`DRAN_INFERENCE_EMBEDDING_MODEL`, `DRAN_INFERENCE_RERANK_MODEL`, `DRAN_INFERENCE_MARKITDOWN_MODEL`)
4. Add a boot-time health check that warns if the configured URL is unreachable or the configured model is missing.

### Acceptance criteria

- [ ] `mix compile --warnings-as-errors` passes with no new warnings.
- [ ] `Dran.Inference.models()` returns the list of available models from the configured server.
- [ ] `Dran.Inference.embed(model, "hola mundo")` returns a vector and the dimension count.
- [ ] `Dran.Inference.MarkItDown.to_markdown/1` returns markdown when given a supported file.
- [ ] HTTP errors/timeouts are converted to `{:error, reason}` tuples, never raised.
- [ ] All credentials come from env vars; no literals in the code.

### Test deliverable

`test/dran/inference_test.exs` — mock Req with `Req.Test`, assert request shapes and response parsing.

---

## Phase 1 — Embeddings & semantic search

Goal: pages can be found by meaning, not just keywords. Uses the existing `pgvector` extension.

### Tasks

1. Add migration: `ALTER TABLE pages ADD COLUMN embedding vector(d)`.
   - Dimension `d` must match the configured embedding model (Qwen3-Embedding).
   - Determine dimension at migration time from config or default to 1024.
2. Add `Dran.Embeddings` module:
   - `text_for_page/1` — build indexable text from title + body + summary + tags.
   - `hash_text/1` — SHA256 of text for change detection.
3. Add `Dran.Embeddings.Worker`:
   - Schedule async embedding generation via `Task.Supervisor`.
   - In tests, allow `schedule_async: false` to keep the sandbox happy.
4. Hook into page lifecycle:
   - On `Brain.create_page/1` and `Brain.update_page/2`, if inference URL is set, schedule embedding generation.
   - Only regenerate if `embedding_hash` changed.
5. Add `Brain.semantic_search/2` and `Brain.hybrid_search/2`.
   - Semantic: vector search with cosine distance.
   - Hybrid: combine FTS rank + vector rank using Reciprocal Rank Fusion (RRF).
6. Add REST endpoint: `GET /api/search/semantic`.
7. Add MCP tool: `semantic_search`.
8. UI: show a "semantic" toggle on the search page and use results for "related pages" suggestions.

### Acceptance criteria

- [ ] New pages automatically get an embedding after save (async).
- [ ] Editing a page without changing body/title does not regenerate the embedding.
- [ ] `Brain.semantic_search("cómo descansar", context: "personal")` returns pages ordered by cosine distance.
- [ ] `Brain.hybrid_search/2` returns FTS + vector fused results.
- [ ] MCP `semantic_search` tool is listed and callable.
- [ ] Existing pages can be back-filled with a mix task: `mix dran.embeddings --context personal`.

### Test deliverable

- `test/dran/embeddings_test.exs`
- `test/dran/brain/hybrid_search_test.exs`
- `test/dran_web/api/search_controller_test.exs` (semantic endpoint)
- MCP `semantic_search` test under the MCP test suite.

---

## Phase 2 — Reranker

Goal: search results are reordered by the reranker before being returned.

### Tasks

1. Add `Dran.Inference.rerank/3` and a `Dran.Rerank` module.
2. Add `Brain.reranked_search/2`:
   - Get top-K candidates from FTS and/or vector search.
   - Send query + candidate snippets to the reranker.
   - Return final order based on relevance scores.
3. Add env flag `DRAN_INFERENCE_USE_RERANK=true`.
4. Optionally add `?rerank=true` query param to search endpoints.

### Acceptance criteria

- [ ] With `DRAN_INFERENCE_USE_RERANK=true`, search calls the reranker and the final list follows its scores.
- [ ] With the flag off, search behaves exactly as before.
- [ ] Rerank errors fall back to the original ordering, with a logged warning.

### Test deliverable

`test/dran/rerank_test.exs` with mocked rerank response.

---

## Phase 3 — Rich file ingest (MarkItDown)

Goal: PDFs, DOCX, PPTX and TXT uploads produce searchable Markdown pages instead of just stored files.

### Tasks

1. Accept file uploads directly (not just via ingest URL).
   - Add a controller endpoint or extend `ingest_url` for `multipart/form-data`.
   - Store the original as an `artifact` page and/or reference.
2. Add `Dran.Ingest.Converter`:
   - Read bytes and MIME type.
   - Call `Dran.Inference.MarkItDown.to_markdown/1`.
   - Return markdown or `{:error, :unsupported_mime}`.
3. Create a `note` or `artifact` page with the converted markdown body and link it to the original file.
4. Sanitize markdown before storage (GFM + basic HTML allowed, script tags stripped).
5. Trigger automatic embedding generation for the resulting pages.

### Acceptance criteria

- [ ] A PDF uploaded via `POST /api/ingest` returns a page whose body starts with the extracted markdown.
- [ ] unsupported MIME types return a clear 422 error.
- [ ] Files larger than `UPLOADS_MAX_SIZE` are rejected.
- [ ] Conversion failures surface as page-level errors, not crashes.

### Test deliverable

- `test/dran/ingest/converter_test.exs` — mock MarkItDown responses.
- `test/dran_web/api/ingest_controller_test.exs` — multipart upload flow.

---

## Phase 4 — Optional chat helpers for organization

Goal: optional, only if you decide you want it after the first three phases. Use the inference server for small organization tasks.

### Tasks

1. Add `Dran.Summaries.summarize_page/1` to suggest a one-line `summary` for a page.
2. Add `Dran.Summaries.suggest_tags/1` and `suggest_wikilinks/1` for faster capture.
3. UI: buttons on page edit to "Suggest summary" and "Suggest tags".

### Acceptance criteria

- [ ] Suggestions are shown inline and the user must confirm before saving.
- [ ] Inference failures show a friendly error instead of crashing the form.

### Test deliverable

`test/dran/summaries_test.exs`

> This phase is intentionally out of scope for the MVP. If you never want chat, skip it entirely.

---

## Cross-cutting concerns

- **Name env vars by capability, not implementation.** Already in place with `DRAN_INFERENCE_API_*`; add capability names for model selection.
- **Async processing.** Never block an HTTP request waiting for the inference server. Use a supervision tree from day one.
- **Back-fill.** Each phase ships with a mix task or script to run the new logic on existing data.
- **Privacy.** All inference calls stay inside the VPN. Do not log prompts or embeddings longer than necessary.
- **Docs sync.** Whenever a new MCP tool is added, update `mcp.ex`, `README.md`, `docs_live.ex`, and `SKILL.md`.
- **Security scan.** Before every commit, grep for literals of VPN domains, internal IPs, tokens, or keys.

---

## Suggested order of execution

1. Phase 0 (adapter + config + model discovery)
2. Phase 1 (embeddings + semantic search) — big win, enables everything below
3. Phase 3 (MarkItDown ingest) — makes uploaded documents useful
4. Phase 2 (reranker) — small quality boost on top of search
5. Phase 4 (chat summaries) — only if you want it

If you want the first PR to be small and merge-friendly, ship Phase 0 first. If you want a big MVP, combine Phase 0 + Phase 1.
