# Local/self-hosted embedding model selection for Dran

Use when the user asks which embedding model to run, whether to embed a
model in-process (Bumblebee), or how a model swap affects the database.
Dran is multilingual (Spanish workspaces) — that constraint drives every
row below. Note: rerank was removed from the codebase; reranker model
knowledge is informational only, never configure or re-add it.

## Decision table (embeddings, self-hosted)

| Model | Params | Dims (MRL) | Context | CPU? | Fit for Dran |
| --- | --- | --- | --- | --- | --- |
| EmbeddingGemma-300M | 300M | 768 (→512/256/128) | 2K | excellent (built for it, QAT checkpoints) | Best CPU/local option; needs task prefixes |
| multilingual-e5-small | 118M | 384 | 512 | excellent | Lightest acceptable multilingual |
| bge-m3 | 568M | 1024 | 8K | usable, ~4x slower than small models | Hybrid dense+sparse, heavier |
| Qwen3-Embedding-0.6B | 600M | 1024 | 32K | OK but decoder-based (heavier per token) | Current provider choice |

Hard rules:
- NEVER propose English-only embedders (bge-*-en-v1.5, MiniLM, e5-en,
  gte-small-en) — Dran embeds Spanish content; quality drops silently.
- Embedding models cannot "hallucinate" — they are deterministic vector
  maps. Answer that question by redirecting to retrieval false-positives
  and the LLM chat side, not the embedder.

## EmbeddingGemma-300M specifics (verified on HF)

Weights: fp32 1.21GB · fp16 617MB (what Ollama ships, 622MB blob) ·
INT8 ONNX 309MB · Q4 ONNX 197MB (QAT, MTEB 69.31 vs 69.67 full — negligible
loss). Runs <200MB RAM quantized. MTEB multilingual v2: 61.15 (768d).

Two traps:
- Requires task-specific input prefixes — queries `task: <task> | query:
  <text>`, docs `title: <title|none> | text: <body>`. The serving layer
  (Ollama) does NOT add them; if the model is adopted, prefix formatting
  belongs in `Dran.Embeddings.text_for_page/1` (docs) and the search query
  path. Skipping prefixes silently costs accuracy — no error is raised.
- Gemma license (not Apache/MIT) — fine for personal/self-hosted Dran,
  flag it if commercial redistribution ever matters.

## Serving options, ranked

1. **Ollama sidecar** (recommended local path): `ollama pull
   embeddinggemma`, point `DRAN_INFERENCE_API_URL=http://<host>:11434/v1`.
   OpenAI-compatible `/v1/embeddings`; zero Dran code changes beyond dims.
2. **vLLM/SGLang** on a GPU box: same wire format, existing provider list.
3. **In-process Bumblebee** — do NOT recommend: no official EmbeddingGemma
   support (custom Gemma-3 pooling + prefixes + dense head by hand),
   adds bumblebee/nx/exla compile toolchain to the deploy image, and
   ~0.5–1GB RAM resident in the BEAM against Dran's inference-lives-
   outside-the-node architecture.

## Model swap = dims migration (the real cost)

Dran's pgvector embedding column is 1024 dims. Any model whose output
differs (Gemma 768, mE5 384) requires: resize the vector column →
`mix dran.embeddings` backfill re-embeds everything (embedding_hash skips
unchanged pages only across same-model runs; a model change always
re-embeds). Prefer MRL-truncatable models (Gemma, Qwen3) if a future dims
reduction is likely — truncate + re-normalize, no re-embed needed.

## CPU viability rule of thumb

Embedding encoders are single-pass — CPU-friendly, especially ONNX INT8
(~2.7–3.4x speedup; e5-small-class ≈ 2.5ms/query on server CPU).
Cross-encoder rerankers are per-(query,chunk)-pair over ~300–500-token
sequences — CPU cost scales with candidate count, which is why rerank
stayed out of Dran's CPU-friendly design.
