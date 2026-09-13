# Dran Inference API Reference

Dran consumes an **OpenAI-compatible** local/VPN inference server for two capabilities:

- **Embeddings** — semantic search, dedupe, auto-relations, memory linking.
- **Chat / text generation** — page summaries, cluster summaries, workers, memory fact extraction.

Connection is configured with two environment variables (see `.env.example`):

```bash
DRAN_INFERENCE_API_URL=http://<inference-host>:8000/v1
DRAN_INFERENCE_API_KEY=<your-key>
```

Optional: `DRAN_INFERENCE_TIMEOUT` (ms, default 30000), `DRAN_EMBEDDING_BODY_LIMIT` (chars, default 10000).

> Never commit the real hostname or key. Leave them in `.env`.

## Model selection

Model names are **not** environment variables. Dran reads the server's model
list, stores it in Settings (admin UI → Models), and health-checks from there:

```
GET /v1/models  →  saved to Settings (model_embedding, model_chat)
```

Typical models on the reference server: `Qwen3-Embedding`, `Qwen3.5-9B`.
Model IDs can change between server restarts — re-sync from the admin Models
page when they do.

Without `DRAN_INFERENCE_API_URL`, Dran runs degraded: no semantic search,
embeddings, summaries, or workers — everything else works.

## Endpoints consumed

| Capability | Endpoint |
| --- | --- |
| Embeddings | `POST /v1/embeddings` |
| Chat / text generation | `POST /v1/chat/completions` |

## Embeddings

`POST /v1/embeddings`

### Request

```json
{
  "model": "Qwen3-Embedding",
  "input": "text to embed"
}
```

### Response

```json
{
  "object": "list",
  "data": [
    {
      "object": "embedding",
      "index": 0,
      "embedding": [-0.012, 0.034, "..."]
    }
  ],
  "model": "Qwen3-Embedding",
  "usage": {"prompt_tokens": 4, "total_tokens": 4}
}
```

### How Dran uses it

- One embedding per page from `slug` + `title` + `summary` + `body`; stored
  in a `pgvector` column; cosine distance (`<=>`) for semantic search.
- An `embedding_hash` skips re-computation when the page did not change.
- Memories embed at ingest (same vector powers dedupe + `informs`/`semantic`
  relation derivation — no extra inference calls).

## Chat / text generation

`POST /v1/chat/completions`

### Request

```json
{
  "model": "Qwen3.5-9B",
  "messages": [{"role": "user", "content": "..."}]
}
```

### Response

```json
{
  "choices": [
    {"message": {"role": "assistant", "content": "..."}}
  ]
}
```

### How Dran uses it

- **Page summaries** — one-line machine-owned summary per page (nightly backfill).
- **Cluster summaries** — LLM summary per graph cluster.
- **Workers** — curator, link_gardener, graph_rag reasoning steps.
- **Memory fact extraction** — session transcripts are distilled server-side
  into atomic facts at `/api/memory/ingest`; the transcript is never persisted.
