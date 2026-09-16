---
name: dran-dev-inference-providers
description: "Use when configuring Dran embeddings/chat provider."
version: 2.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, inference, embeddings, dashscope]
    related_skills: [dran]
---

# dran-dev-inference-providers — embeddings compatibility for Dran

Dran's inference client speaks the OpenAI wire format through ONE
`base_url` + Bearer key, for embeddings and chat. (Rerank support was
removed from the codebase outright — do not configure, re-add, or
"fix" rerank; search orders by FTS/RRF/semantic distance alone.) This
skill says which providers fit and how to smoke-test one with Dran's
real code before touching deployment config.

## Always-on rules

- **Present embedding backend options grouped by wire format and
  modality class, never by vendor** — the format class (OpenAI-compatible
  text / legacy BERT / native non-compatible / multimodal fused) determines
  the integration cost; vendor rows only add detail inside a class. See the
  format-first classification in `references/provider-comparison.md`.
- **Never propose English-only embedders** (bge-*-en, MiniLM, e5-en,
  gte-small-en) — Dran embeds Spanish/multilingual content and quality
  drops silently. Multilingual check first, efficiency second
  (`references/local-model-selection.md`).
- **A model swap that changes output dims is a migration, not a config
  edit** — Dran's pgvector column is 1024 dims; different dims means
  column resize + full re-embed backfill. Say this cost in the reply,
  not after the user picks the model.
- **Never test a provider via `mix run` with the full app started** — the
  Endpoint grabs port 4000 (`:eaddrinuse` under the dev server) and the
  app dies before your probe runs. Use `mix run --no-start` + start only
  `:req` and `Dran.Inference.QueueSupervisor`.
- **When a probe needs the full app** (Repo, Settings — e.g. settings-backed
  config), start it on a free port: `PORT=<free> mix run -e '...'` —
  `--no-start` can't help there, and without the override the Endpoint
  races the dev server for 4000. Phoenix.LiveViewTest cannot drive a
  LiveView from `mix run -e` (macro requiring test-endpoint config);
  verify UI changes through the test suite instead.
- **Never quote vendor pricing in a reply from memory or a prior session's
  table** — pricing pages are volatile and per-provider units differ
  (per-search vs per-token); re-verify on the vendor's pricing page in the
  same session, and mark the response's unit explicitly.
- **Pass API keys via env var** in probes, never inline in the command or
  a file — keys echoed into shell history outlive the session.
- **One `base_url` for every capability**: embeddings and chat cannot
  point at different providers; pick a host that serves both.
- **The user removes features rather than adapting providers** when an
  integration fights the architecture — after any such cut, update this
  skill the same day so it stops teaching the removed surface.

## Wire formats (`lib/dran/inference/client.ex`)

| Call | Endpoint | Payload shape | Reads from response |
| --- | --- | --- | --- |
| Embeddings | `POST {base}/embeddings` | OpenAI: `{model, input: [..], dimensions: 1024}` | `data[].embedding` sorted by `index` |
| Chat | `POST {base}/chat/completions` | OpenAI | `choices[].message` |

Embedding model resolves from Settings (`model_embedding`) with
app-config fallback; dimensions default 1024. The Queue has exactly two
capabilities: `:embed` and `:chat`.

## Provider fit

- **DashScope / QwenCloud** (`https://dashscope-intl.aliyuncs.com/compatible-mode/v1`):
  embeddings as-is (`qwen3.7-text-embedding`, dims 256–2560, 1024 ok —
  verified live). The compatible-mode host also serves OpenAI-shape
  chat completions.
- **SiliconFlow** (`https://api.siliconflow.cn/v1`): OpenAI embeddings
  as-is (`Qwen/Qwen3-Embedding-*`).
- **vLLM / SGLang local**: `/v1/embeddings` OpenAI-shape.
- Any other OpenAI-compatible host fits embeddings.

## Local / self-hosted model selection

Which embedding model fits Dran (multilingual constraint), EmbeddingGemma
weights/prefix traps, Ollama sidecar vs in-process Bumblebee verdict, and
the dims-migration cost of a model swap: `references/local-model-selection.md`.

## Multi-provider comparison

Cross-provider paths, wire formats, pricing, and billing-unit traps for
embeddings and rerank (OpenRouter / Fireworks / QwenCloud / Cohere / Jina)
live in `references/provider-comparison.md` — consult it when picking a
provider or designing a multi-provider client.

## Where embeddings are used

- Structural: semantic search, curator duplicate detection, suggested
  relations, graph_rag. Chat: summaries, tags, workers, titles — full
  consumer map and trigger chains in `references/chat-model-consumers.md`.

## Smoke-test recipe (real code, no app boot)

```bash
export PROVIDER_KEY=...
mix run --no-start -e '
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Dran.Inference.QueueSupervisor.start_link([])
Application.put_env(:dran, :inference, [
  base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
  api_key: System.get_env("PROVIDER_KEY"),
  embedding_model: "qwen3.7-text-embedding",
  timeout: 30_000
])
{:ok, vec} = Dran.Inference.embed("smoke test")
IO.puts("EMBED dims: #{length(vec)}")
'
```

Expect: `EMBED dims: 1024`.

## Config recipe (deployment)

```
DRAN_INFERENCE_API_URL=https://dashscope-intl.aliyuncs.com/compatible-mode/v1
DRAN_INFERENCE_API_KEY=<key>
```
Settings: `model_embedding=qwen3.7-text-embedding`.
