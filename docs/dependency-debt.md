# Dran — dependency debt

Measured with `mix hex.outdated` and `mix deps.audit` on the commit that
introduced this file. The rule of this repo: **patch/minor updates only
inside the ranges `mix.exs` declares** — anything bigger is inventory, not
work, and lands here with the reason it stays.

## Updated in this pass (inside the declared ranges)

| Package | From → To | Note |
|---|---|---|
| phoenix | 1.8.9 → 1.8.15 | patch stream |
| phoenix_live_view | 1.2.3 → 1.2.12 | patch stream |
| phoenix_live_reload | 1.6.2 → 1.7.0 | dev |
| postgrex | 0.22.2 → 0.22.4 | patch |
| pgvector | 0.4.0 → 0.4.2 | patch |
| req | 0.6.2 → 0.7.4 | minor (range allows) |
| swoosh | 1.26.1 → 1.28.1 | minor (range allows) |
| bandit | 1.12.4 → 1.12.5 | patch |
| lazy_html | 0.1.11 → 0.1.13 | test |
| sobelow | 0.15.0 → 0.16.0 | dev/test — audit tooling |
| telemetry_metrics | 1.1.0 → 1.2.0 | minor (range allows) |

`mix deps.audit` → **No vulnerabilities found.** `mix test` green at the
baseline (1293 passed / 65 skipped).

## Staying behind (with the reason)

| Package | Current → Latest | Reason |
|---|---|---|
| `mdex` | 0.13.1 → 0.14.2 | `mix.exs` pins `~> 0.13.1` (exact minor): markdown rendering is the page body path; a minor bump there is a behavior risk for every body, not a chore. Bump it as its own task with the page-types tests read first. |
| `phoenix_live_dashboard` | 0.8.7 → 0.9.1 | range `~> 0.8.3` excludes 0.9; the dashboard is dev-only surface, zero user impact — not worth a range bump in a cleanup pass. |
| `dns_cluster` | 0.2.0 → 0.3.1 | range `~> 0.2.0` excludes 0.3; release-only clustering helper, dev/local runs don't touch it. |

## Known debt beyond hex

None recorded this pass: `mix deps.audit` is clean and the plugin's Python
side pins its deps in `hermes_plugin/dran/requirements`-style imports only
(stdlib + the runner's API).

## How to read this file

Re-run `mix hex.outdated` after any `mix.exs` range change and re-audit
`mix deps.audit`. A package moves to the "Updated" table only when the suite
and the audit stay green — no exception for patch releases of security
tooling (sobelow included: it must run against the code, so its own update
travels with the suite that uses it).
