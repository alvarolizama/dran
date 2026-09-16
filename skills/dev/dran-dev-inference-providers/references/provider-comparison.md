# Provider comparison — embeddings & rerank (OpenRouter / Fireworks / QwenCloud / Cohere / Jina)

Distilled from provider docs and live pricing. Use when picking a provider,
wiring a multi-provider client, or predicting billing shape. Prices are
per 1M input tokens unless noted, and VOLATILE — re-verify on the vendor's
pricing page before quoting a number in a reply.

## Format-first classification (group by shape, not vendor)

Integration cost is set by the wire-format and modality class, not by who
sells it. Classify candidates into these classes BEFORE comparing prices;
each class has a distinct integration cost:

1. **OpenAI-compatible text, resizable dims (MRL)** — `POST {base}/embeddings`,
   Bearer, `{model, input, dimensions}`. Passthrough for any OpenAI-shape
   client. Instances: Fireworks serverless (`fireworks/qwen3-embedding-8b`,
   `fireworks/voyage-4-*`), QwenCloud compatible-mode (`text-embedding-v3/v4`,
   `qwen3.7-text-embedding`), OpenRouter (`openai/text-embedding-3-*`,
   `qwen/qwen3-embedding-*`, `google/gemini-embedding-*`, `baai/bge-m3`,
   `voyageai/voyage-4-*`).
2. **OpenAI-compatible legacy BERT** — short-context, cheapest
   (Fireworks `nomic-ai/nomic-embed-text-v1.5`, `thenlper/gte-*`,
   ~$0.008–0.02/M). Invoked by HuggingFace-style id and NEVER listed by the
   vendor's `/models` endpoint — register them manually; discovery cannot
   find them.
3. **Native non-compatible** — DashScope native text-embedding
   (`{input: {texts: [...]}, parameters: {...}}` → `output.embeddings[]`),
   Cohere `/v2/embed`, Google Vertex, Bedrock. Need a translating adapter
   per family. Only pick when compatible-mode lacks a needed feature.
4. **Multimodal fused (text+image+video in one vector)** — QwenCloud
   `qwen3-vl-embedding` (2B/8B, dims 256–2560) exists ONLY via DashScope
   native MultiModalEmbedding (blocks `{text|image|video}`, `enable_fusion`;
   limits: ≤20 elements, ≤5 images, video URL only). Fireworks
   `voyage-multimodal-3-5` is OpenAI-compatible if the input travels as
   blocks. Either way the client's input contract must accept block arrays
   first — the cheapest multimodal path is the OpenAI-compatible one.

## Embeddings (OpenAI-shape instances)

All class-1/2 providers are OpenAI wire format (`{model, input}` →
`data[].embedding`); differences are path, extras, and cost.

| Provider | Path | Extras | Notes |
| --- | --- | --- | --- |
| OpenRouter | `POST /api/v1/embeddings` | `provider` routing object | Strips vendor-specific params (`task_type`, `input_type`); pin provider or go direct when you need them. Lists embedding models at `GET /api/v1/embeddings/models`, NOT `/models` |
| Fireworks | `POST /inference/v1/embeddings` | `dimensions`, `input_type`, `normalize`, `prompt_template` | Qwen3 vectors NOT L2-normalized — normalize before cosine. 4B/0.6B Qwen3 sizes require a dedicated deployment; only 8B is serverless |
| QwenCloud (compatible) | `POST /compatible-mode/v1/embeddings` | `dimensions` | Batch and token caps are per MODEL, not provider-wide — see table below |

Price anchors (Qwen3-Embedding-8B class): OpenRouter ~$0.01, QwenCloud
text-embedding-v4 / qwen3.7-text-embedding ~$0.07, Fireworks ~$0.10.
OpenRouter is the price leader but routes through upstream providers with
the stripping caveat.

### QwenCloud per-model limits (compatible-mode)

Never quote one provider-wide batch cap — check the model row:

| Model | Batch (inputs/request) | Max tokens/request | Dimensions |
| --- | --- | --- | --- |
| `qwen3.7-text-embedding` | 20 | 128,000 | 256–2560 (default 1024) |
| `qwen3.7-text-embedding-flash` | cheaper tier of the above | — | same family |
| `text-embedding-v4` | 10 | 8,192 | 64–2048 (default 1024) |
| `text-embedding-v3` | 50 | — | 512–1024 |

A `dimensions` value legal on one model (e.g. 128 on v4) is a hard 4xx on
another (qwen3.7 floor is 256).

## Rerank

Two API flavors exist; billing units differ per provider — this is the
main trap.

Flavor A (Cohere style, the common one): `{model, query, documents[],
top_n}` → `{results: [{index, relevance_score, document?}]}`.

| Provider | Path | Unit | Notes |
| --- | --- | --- | --- |
| OpenRouter | `POST /api/v1/rerank` | per SEARCH (Cohere) or per token (Qwen) | Same request = same charge whether 5 or 500 docs |
| Fireworks | `POST /inference/v1/rerank` | per token (~$0.20/1M) | Also reachable via `/embeddings` + `return_logits` for batching |
| QwenCloud | `POST /compatible-api/v1/reranks` ⚠️ plural | per token (~$0.10/1M) | Extra `instruct` param; native DashScope API has a different nested shape (`input`/`parameters`) |
| Cohere direct | `POST /v2/rerank` | per search (~$2/1K) | OpenRouter proxies the same shape |
| Jina | `POST /v1/rerank` | per token | Same Cohere shape |

Flavor B (embeddings-as-reranker, Fireworks): format prompts as
`<Instruct>: {instruction}\n<Query>: {query}\n<Document>: {doc}`, POST to
`/embeddings` with `return_logits: [false_id, true_id]` and
`normalize: true`; `data[].embedding` returns `[prob_no, prob_yes]` and
`prob_yes` is the relevance score. Enables parallel batching of large
candidate sets.

(Dran itself has NO rerank capability — this section is reference depth
for comparing providers, not a config surface.)

## Qwen3 instruct plumbing

The reranker's task `instruct` only passes natively on QwenCloud; on
Fireworks/OpenRouter there is no param — prefix it into the prompt yourself
using the Qwen3 format `<Instruct>: ...\n<Query>: ...` (Flavor B) or the
document field (Flavor A). Divergence otherwise silently degrades ranking
quality with no error.

## Client design rules (multi-provider)

- Parameterize the path suffix (`embeddings` vs `rerank` vs `reranks`);
  never hardcode — QwenCloud's plural breaks it.
- **Never fall back across upstream embedding models**: vector spaces are
  incompatible between models, so a silent fallback corrupts the client's
  vector index with no visible error. Restrict embedding fallback to other
  credentials serving the SAME upstream model — or the same weights family
  with matching dims (qwen3-embedding-8b across Fireworks / OpenRouter /
  Qwen text-embedding-v4). Same-model multi-credential redundancy is always
  safe.
- Billing shape drives the billing code, not the model: Cohere-family
  models report per-search, not tokens — a per-token proxy ledger needs a
  per-request fallback for them.
- Normalize L2 yourself for any Qwen3-family output unless the provider
  documents unit vectors (OpenAI/Nomic do; Qwen3 does not).
- Batch caps are provider-structural AND per-model (QwenCloud table above).
  When chunking for a cap, reassemble order via `data[].index` from the
  response — never assume echo order.
- Model discovery is not uniform: OpenRouter embeddings live at
  `/embeddings/models`, Fireworks legacy BERT ids appear in no listing at
  all — a `/models`-only discovery loop silently drops both.
- Per-search billing is size-blind: with small docs a token-billed
  provider (Fireworks/Qwen) is usually cheaper per request; with very long
  docs the per-search flat fee wins. Compute both before picking.
- **Gateway-side provider catalogs are code, not user data**: the catalog
  (key, base_url, dialect, capabilities) lives in a compile-time module
  seeded/upserted into the DB at boot; the DB stores only what the user
  contributes (API keys/credentials) and relations (aliases, routing,
  pricing). A data migration matching existing rows onto catalog entries by
  normalized base_url (trim slash, downcase) must dedupe duplicates FIRST —
  survivor = row with most credentials, re-point FKs, delete dupes — and
  create the unique index on key only after the merge. Deleting a builtin
  must be blocked in the UI: the boot sync re-creates it and the cascade
  deletes the user's keys. "Activating" a catalog provider = attaching a
  credential, nothing more; the admin list shows only providers that have
  one (seeded builtins without keys stay invisible).
- **Dialects, not per-endpoint URL fields, are the extension point**: one
  base_url per provider with the adapter deriving `/chat/completions`,
  `/models`, `/embeddings`; a dialect (openai / openrouter) only deviates
  where the surface actually differs (OpenRouter lists embedding models at
  `/embeddings/models`). Per-service URL overrides, if allowed at all,
  belong to user-created custom providers only — and when they exist, drop
  the separate capabilities picker: derive capabilities from what the user
  configured (an explicit embeddings URL ⇒ embedding capability), one
  source of truth.
