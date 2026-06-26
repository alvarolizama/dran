# Dran Inference API Reference

Dran consumes an **OpenAI-compatible** local/VPN inference server for several capabilities used to organize information and data:

- **Embeddings** (`Qwen3-Embedding`) for semantic search.
- **Reranking** (`Qwen3-Reranker`) for better search result ordering.
- **Document-to-Markdown** (`MarkItDown`) for extracting text from uploaded files.
- **Chat / text generation** (`Ornith-1.0-9B`) for summaries, tags, agents, and image descriptions.
- **Audio transcription** (`Qwen3-ASR`) for converting audio files to text.

Connection is configured with two environment variables:

```bash
DRAN_INFERENCE_API_URL=http://<inference-host>:8000/v1
DRAN_INFERENCE_API_KEY=<your-...n
> Never commit the real hostname or key. Leave them in `.env`.

## Capabilities

| Capability | HTTP endpoint | Typical model |
| ---------- | -------------- | --------------- |
| Embeddings | `POST /v1/embeddings` | `Qwen3-Embedding` |
| Reranking | `POST /v1/rerank` | `Qwen3-Reranker` |
| Document → Markdown | `POST /v1/chat/completions` with file part | `MarkItDown` |
| Chat / text generation | `POST /v1/chat/completions` | `Ornith-1.0-9B` |
| Audio transcription | `POST /v1/audio/transcriptions` | `Qwen3-ASR` |
| Image description | `POST /v1/chat/completions` with image part | `Ornith-1.0-9B` |

You can list available models with:

```bash
curl -sS http://<inference-host>:8000/v1/models \
  -H "Authorization: Bearer $DRAN_...onse shape:

```json
{
  "object": "list",
  "data": [
    {"id": "Qwen3-Embedding", "object": "model", "owned_by": "omlx"},
    {"id": "Qwen3-Reranker", "object": "model", "owned_by": "omlx"},
    {"id": "MarkItDown", "object": "model", "owned_by": "omlx"},
    {"id": "Qwen3.5-9B", "object": "model", "owned_by": "omlx"},
    {"id": "Qwen3-ASR", "object": "model", "owned_by": "omlx"}
  ]
}
```

> Model names can change between restarts. Dran should read the configured model names from env vars and verify them at boot time.

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
  "usage": {
    "prompt_tokens": 4,
    "total_tokens": 4
  }
}
```

### Notes for Dran

- Generate one embedding per page from a concatenation of `slug`, `title`, `summary`, and `body`.
- Store the vector in a `pgvector` column on `pages`.
- Use cosine distance (`embedding <=> query_vector`) for semantic search.
- Cache an `embedding_hash` of the indexed text so Dran only re-computes when the page actually changes.
- Do **not** generate embeddings synchronously in the HTTP request — use `Task.Supervisor` for the MVP and migrate to Oban in production.

## Reranking

`POST /v1/rerank`

The reranker takes a query and a list of candidate texts and returns relevance scores. It improves the final ordering of FTS/vector hits before they are shown to the user.

### Expected request shape

```json
{
  "model": "Qwen3-Reranker",
  "query": "how does pattern matching work in Elixir",
  "documents": [
    "Page one text...",
    "Page two text..."
  ]
}
```

### Expected response shape

```json
{
  "results": [
    {"index": 1, "relevance_score": 0.92},
    {"index": 0, "relevance_score": 0.34}
  ]
}
```

> Verify the exact field names against your server before shipping. Some rerankers return `data` with `score` or `relevance_score`.

### Notes for Dran

- Use for hybrid search: search FTS + vector, fuse with RRF, then rerank top-K.
- Limit input to small snippets (title + first ~500 chars of body). Dran controls the chunking.

## Document → Markdown (MarkItDown)

`MarkItDown` is consumed through `/v1/chat/completions`, not its own endpoint. Send the file bytes as a content part.

### Request

```json
{
  "model": "MarkItDown",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "Convert this file to Markdown."},
        {
          "type": "file",
          "file": {
            "filename": "notes.pdf",
            "file_data": "<base64-encoded file bytes>",
            "content_type": "application/pdf"
          }
        }
      ]
    }
  ]
}
```

### Response

```json
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "# Notes\n\nConverted markdown..."
      }
    }
  ]
}
```

> MarkItDown must be tested with a real file before shipping. Do not assume every model labelled for document conversion follows this exact payload shape.

### Notes for Dran

- Hook this into the ingest pipeline after a file is downloaded.
- Convert PDF, DOCX, PPTX and TXT uploaded via `ingest_url` or the editor.
- **MarkItDown does NOT accept URLs** — the content part requires base64-encoded file bytes in `file.file_data`. To ingest a URL that returns HTML, Dran must download the page first and pass the raw bytes (or use a chat-completion fallback to convert/clean HTML to markdown).
- Sanitize the resulting markdown before storing it in the page body.
- Keep the original file as an `artifact`/`reference` and store the extracted markdown in a `note` or `artifact` page.

## Configuration shape for Dran

```elixir
config :dran, :inference,
  base_url: System.fetch_env!("DRAN_INFERENCE_API_URL"),
  api_key: System.fetch_env!("DRAN_INFERENCE_API_KEY"),
  embedding_model: System.get_env("DRAN_INFERENCE_EMBEDDING_MODEL", "Qwen3-Embedding"),
  rerank_model: System.get_env("DRAN_INFERENCE_RERANK_MODEL", "Qwen3-Reranker"),
  markitdown_model: System.get_env("DRAN_INFERENCE_MARKITDOWN_MODEL", "MarkItDown"),
  chat_model: System.get_env("DRAN_INFERENCE_CHAT_MODEL", "Ornith-1.0-9B"),
  asr_model: System.get_env("DRAN_INFERENCE_ASR_MODEL", "Qwen3-ASR"),
  vision_model: System.get_env("DRAN_INFERENCE_VISION_MODEL", "Ornith-1.0-9B")
```

This keeps model names configurable without code changes when the server restarts with different IDs.
