---
name: dran-dev-plugin
description: "Use when adding or changing a tool in the Dran Hermes plugin (hermes_plugin/dran)."
---

# Dran plugin surface — tools, manifest, gates

The plugin is the agent's only surface into Dran (`dran_*` tools), and each tool
is a **thin client over the REST API**. New capability = new REST route first,
then a tool that calls it; never business logic in Python.

## One plugin, two halves, one config file

Do not split it: `__init__.py` is the runtime (the memory provider + the agent
tools registered by `register(ctx)`), `config_schema.py` is the desktop panel.
Both read/write the SAME `$HERMES_HOME/dran/config.json` and the same
`DRAN_API_KEY` (= the account's `users.api_token`).

## Where a tool lives

| Piece | Where |
|---|---|
| Schema list | `hermes_plugin/dran/__init__.py` → `_tool_schemas()` |
| Dispatch by name | `hermes_plugin/dran/__init__.py` → the handler table (`_make_handler(name)`) |
| HTTP method per tool | `_DranClient` methods (use `request/4`) |
| Manifest declaration | `hermes_plugin/dran/plugin.yaml` → `provides_tools` |

`register(ctx)` walks `_tool_schemas()` and calls `ctx.register_tool` once per
schema — so the manifest and the schemas are two halves of ONE list.

## The manifest rule (the linde that cost W9)

`provides_tools` lists **exactly** the tools registered by `register()`:

- registered but not declared → `✗ declared tools — undeclared tools registered` → **fails**;
- declared but not registered → warning;
- the four `dran_memory_*` tools come from the memory provider's
  `get_tool_schemas()`, NOT from `register()` → they must stay OUT of the list.

## Gates (both are real; run them, don't argue with them)

```bash
hermes plugins validate hermes_plugin/dran   # manifest + capability probe + collisions
cd hermes_plugin && pytest -q                # the tool→REST route pins
```

`pytest` **does** run in this environment (mise python). Do not repeat the older
"no hay pytest, no se puede correr la suite" limit — it is stale.

`tests/test_plugin.py::test_tool_calls_hit_documented_routes` invokes a handler per
tool and asserts the REST path it produced. When adding a tool: invoke its handler
there and assert the path against `lib/dran_web/router.ex`. A red assert in that
test usually means the assert is older than the route (the plugin path matched the
router while the expectation still had a `?query` shape) — fix the expectation
against the router, never delete the assert.

## Checklist

- [ ] The route exists in `lib/dran_web/router.ex` before the tool calls it
- [ ] Schema added to `_tool_schemas()` and dispatch wired
- [ ] `plugin.yaml provides_tools` updated (and nothing else added)
- [ ] `test_tool_calls_hit_documented_routes` covers the new tool
- [ ] `hermes plugins validate hermes_plugin/dran` → Validation passed
- [ ] `cd hermes_plugin && pytest -q` → 0 failed
- [ ] `hermes_plugin/dran/README.md` lists the new tool