# Dran — security review

Audit of the `sobelow` findings with the house config
(`.sobelow-conf`: `exit: :medium`, `threshold: :low`), run at the commit
introducing this file (sobelow 0.16.0, after W4's dependency pass). Method
per the contract: **type every finding first** — read the code around each
line, verdict it (real / false positive / accepted by design), and only then
touch. Every verdict here carries the evidence that produced it.

## Verdict summary

| Verdict | Count |
|---|---|
| Fixed (real, low-risk) | 7 |
| Accepted by design (with reason) | 4 |
| Disappeared with 0.16 / already gone | 9 |

`mix sobelow --exit low` after the pass: **11 findings**, all typed below —
down from 20 at the start of the audit.

## Fixed

### 1–3. `DOS.BinToAtom` — `lib/dran/inference/config.ex:37,38,42`
**Verdict: real (dead branch).** `model_or_setting/1` interpolated
`:"#{key}_model"` to read a config keyword nobody ever sets:
`load_from_env/0` emits only `base_url`, `api_key`, `timeout`,
`embedding_dimensions`, `embedding_body_limit` — never `embedding_model` /
`chat_model`. The branch always returned `nil` (and the atom was built from
interpolation). The models live in the **Settings table** (Admin → Models
writes `model_chat` / `model_embedding`).
**Fix:** read `Dran.Settings.get("model_chat" | "model_embedding")`
directly; the dead branch is gone.
**Evidence:** `mix test test/dran/inference_test.exs` → 8 passed (the 3
tests that depended on the dead keyword now seed Settings — that rewrite is
part of this fix).

### 4–5. `DOS.StringToAtom` — `lib/dran_web/live/search_live.ex:60,101`
**Verdict: real (borderline).** `search_mode` comes from an allowlist
(`handle_event "set_mode" … when mode in @mode_strings`), so no hostile
input reached `String.to_atom` — but the conversion itself was avoidable.
**Fix:** a compile-time map `@mode_atoms` built from the same `@search_modes`
allowlist; the strategy lookup is `Map.fetch!(@mode_atoms, mode)` — zero
runtime conversion.
**Evidence:** full suite green at baseline; `grep -c "String.to_atom"
lib/dran_web/live/search_live.ex` → 0.

### 6–7. `DOS.StringToAtom` — `lib/dran_web/components/layouts.ex:294,618`
**Verdict: real (atom-table growth with owner input).** The keys were
`String.to_atom(page_type_path(...))` of **custom page types**, which the
owner declares at runtime — each new path minted a permanent atom. The path
format is validated fail-closed (`^[a-z0-9][a-z0-9_-]*$`), but the set is
unbounded, so the clean form is no atom at all.
**Fix:** `compute_counts` now keys `type_counts` by the path **string**, and
`type_atom/2` (the badge lookup) returns the same string — producer and
consumer share it, nothing converts at runtime.
**Evidence:** `mix test test/dran_web/components/sidebar_nav_test.exs` → 27
passed.

### 8. `DOS.StringToAtom` — `lib/dran_web/live/workspace_settings_live.ex:1607`
**Verdict: real (same class).** The tuning keys come from the module
allowlists `@brain_keys`/`@advanced_keys` (not user input), but the fix costs
nothing.
**Fix:** `@tuning_atoms` — a compile-time string→atom map from the same two
allowlists; `assign_settings_form` reads it with `Map.fetch!/2`.
**Evidence:** `mix test test/dran_web/live/instance_settings_access_test.exs`
→ 16 passed.

### 9. `DOS.StringToAtom` — `lib/dran/release.ex:268`
**Verdict: accepted-with-fix (operator input, allowlisted anyway).**
`MIX_ENV` is host-operator input, not web input — but the allowlist is free
and closes the case where a stray value mints an atom.
**Fix:** `@mix_envs %{"dev" => :dev, "test" => :test, "prod" => :prod}`;
anything else falls back to `:prod` (the safe default for a release).
**Evidence:** `mix compile --warnings-as-errors` exit 0.

## Accepted by design

### 10. `SQL.Query` — `lib/dran/knowledge.ex:1357` (`transitive_part_of_candidates/1`)
**Verdict: false positive.** The "interpolation" sobelow sees is the
heredoc SQL; the only value travels as `$1::uuid` with the parameter bound
through `Ecto.Adapters.SQL.query(Repo, sql, [Ecto.UUID.dump!(workspace_id)])`
— `Ecto.UUID.dump!` rejects anything that is not a UUID **before** the call.
The literals in the query (`'part_of'`, depth limit 2) are constants.
**Evidence:** read of `lib/dran/knowledge.ex:1326-1360`; no string
interpolation of any runtime value.

### 11. `RCE.CodeModule` — `lib/dran/release.ex:165` (`Code.eval_file`)
**Verdict: accepted.** `eval_seed_file/1` evaluates exactly one path:
`Application.app_dir(@app, "priv/repo/seeds.exs")` — a file that ships
inside the release, called from `seed_demo/0`, which **refuses to run
inside a release** (`release?/0` guard raises). The evaluable file is not
reachable from any request.
**Evidence:** read of `lib/dran/release.ex:143-168`; `grep -n
eval_seed_file` shows the single fixed-path caller.

### 12–13. `Traversal.FileModule` — `lib/dran/uploads.ex:58,61`
**Verdict: false positive.** The stored path is
`{workspace_id}/{sha256[:2]}/{sha256}.{ext}`: the directory components are a
validated UUID binary id and a hex prefix of the **content hash**; the
extension comes from `extension/2`, which either matches the fixed
`valid_extensions/0` allowlist or falls back to `ext_from_mime/1` (closed
clause list) or `"bin"`. The attacker-controlled `filename` never reaches
the path — only the slug of the created page does. `File.mkdir_p!` /
`File.write!` build their path entirely from trusted components.
**Evidence:** read of `lib/dran/uploads.ex:33-61`; extension allowlist at
`:89-91`.

### 14. `Traversal.FileModule` — `lib/dran_web/page_edit.ex:401`
**Verdict: false positive.** `File.read!(path)` reads the temp file that
`Phoenix.LiveView` itself created for the upload
(`consume_uploaded_entry` hands us `%{path: path}` generated by the
framework from its own tmp dir, not from client input).
**Evidence:** read of `lib/dran_web/page_edit.ex:393-405`.

### 15–19. `XSS.Raw` — `page_components.ex:651`, `home_live.ex:488,856,1359`, `search_live.ex:465`
**Verdict: accepted, with one hardened.** All five render markdown-derived
HTML through `raw/1`; the gate is the render pipeline, not the raw call:
- `page_components.ex:651` and `home_live.ex:856,1359` — the HTML comes
  from the MDEx pipeline with `render: [unsafe: false]` plus an explicit
  `sanitize:` config (which is also why raw `<iframe>` in a body never
  renders). The error path escapes the body instead of rendering it.
- `search_live.ex:465` and `home_live.ex:488` — the `excerpt` carries
  `ts_headline` highlight tags (fts) or body-derived text (fuzzy); both now
  pass through `HTMLSanitizer.sanitize_to_string/1` before `raw/1`.
  **home_live.ex:488 was hardened in this pass** (it rendered the excerpt
  raw, same contract as search_live — the sanitizer is now the same).
**Evidence:** read of the three render sites + `@markdown_options`
(`lib/dran_web/components/page_components.ex:588-600`,
`lib/dran_web/live/home_live.ex:1407-1425`); suite green.

## Flagged for the record (not a finding of this pass)

### `Config.HTTPS` — `config/prod.exs:16`
**Verdict: accepted, documented.** `force_ssl` is compile-time in Phoenix;
the repo ships a BUILD-time switch (`DISABLE_FORCE_SSL=1` build arg +
`PHX_SCHEME=http` runtime) for plain-HTTP deploys behind a VPN without a
TLS terminator. The README documents it (Production → HTTPS). The finding
fires whenever that build flag is on; the deploy decides.
**Evidence:** read of `config/prod.exs:10-20`, README § Production.

## Credential finding (from the repo cleanup, W2)

`sc.txt` — a libcurl cookie jar holding a **live `_dran_key` cookie** for
`127.0.0.1` — was found in the working tree and treated as a security
finding, not a temp file: the file is deleted and `.gitignore` no longer
ignores cookie jars (a reappearance is a finding). **Open item for the
owner:** rotate/revoke that `_dran_key` — deleting the file does not
invalidate the cookie (ledger `?01`).

## The gate

- `mix sobelow --exit low` → 11 findings, every one typed above (9 were the
  `String.to_atom`/`BinToAtom` family this pass eliminated; the `XSS.Raw`
  set shrank by the home_live hardening).
- The precommit gate keeps running with `--exit medium` — nothing in the
  accepted set is medium or above.
- `mix precommit` exit 0 — 1293 passed / 65 skipped (baseline intact, no
  test relaxed).
