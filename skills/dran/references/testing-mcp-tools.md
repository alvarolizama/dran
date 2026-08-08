# Testing MCP tools via the public JSON-RPC entrypoint

When writing ExUnit tests that exercise Dran MCP tools (the same path the HTTP
controller uses), do **not** try to call `Dran.MCP.execute_tool/2` directly — it
is `defp` (private). The public entrypoint is **`Dran.MCP.process_message/1`**,
which takes a JSON-RPC map and returns a JSON-RPC response map.

## Minimal call_tool helper

```elixir
defp call_tool(name, args) do
  msg = %{
    "jsonrpc" => "2.0",
    "method" => "tools/call",
    "id" => 1,
    "params" => %{"name" => name, "arguments" => args}
  }

  %{"result" => %{"content" => [%{"text" => text}]}} = MCP.process_message(msg)
  text
end
```

The result text is a plain string (success messages or `"Error: ..."` strings).
Assert on it with `=~` / `refute ... =~`.

## Setup (mirror brain_test.exs)

```elixir
use Dran.DataCase, async: false   # async: false — inference env is global

setup do
  # Disable inference so create_page doesn't call external APIs.
  Application.put_env(:dran, :inference,
    base_url: nil, api_key: nil, embedding_model: nil,
    rerank_model: nil, markitdown_model: nil,
    timeout: 100, schedule_async: false
  )

  context =
    Brain.get_context_by_slug("personal") ||
      elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

  {:ok, context: context}
end
```

Restore the original `:inference` env in `on_exit` to avoid leaking state into
other tests (see `brain_test.exs` for the full restore pattern).

## Reaugmentation test pattern

`dran_reaugment_page` clears `embedding_hash` to `nil` then schedules async
augmentation. To test the "clears embedding_hash" behavior without the async
side effects:

```elixir
# Seed a non-nil hash, call the tool, assert nil.
Ecto.Changeset.change(page, embedding_hash: "some-old-hash") |> Repo.update!()
result = call_tool("dran_reaugment_page", %{context: "personal", "slug" => slug})
assert result =~ "Reaugmentation scheduled"
assert is_nil(Repo.get!(Page, page.id).embedding_hash)
```

## Common pitfalls

- **Port 4000 in use.** If `mix test` fails with `:eaddrinuse` on port 4000, a
  dev server (or stale `beam.smp` process) is holding it. **Two fixes:**
  1. Kill it: `lsof -ti:4000 | xargs kill -9`.
  2. Override the port: `PORT=4002 mix test ...` — the runtime config reads
     `System.get_env("PORT", "4000")`, so any value works. This is the
     non-destructive option when you don't want to kill the dev server.
  The `config/test.exs` sets port 4002, but `config/runtime.exs` overrides it
  at boot, so you must pass `PORT=` explicitly to the test command.
- **Dran source drifted from your last read.** After subagents edit
  `lib/dran/mcp.ex` (e.g. description/enum tuning), re-read the file before
  patching it yourself — the `enum` in `@tools`, the `@moduledoc` one-liners,
  and the `start_agent_by_type` dispatch all change together.

## Live smoke test (schema served by a running server)

ExUnit tests validate the schema as compiled in the test env. To verify the
**actual running dev server** serves the same schema (catches drift between
code edits and a server that hasn't been restarted), use the smoke script:

```bash
# From the Dran repo (canonical copy: scripts/mcp_smoke.sh)
./scripts/mcp_smoke.sh                                    # defaults: localhost:4000, dran-token
./scripts/mcp_smoke.sh http://dran.example.com <token>    # custom host/token
```

It checks `initialize` (server name/version + `mcp-session-id` header) and
`tools/list` (all 18 tools present, `dran_start_agent` enum has all 6 agent types,
key descriptions carry intent hints). Note: `semantic_search` was removed in
v4.0.0 — the count is now 18 (was 19).
A copy is bundled with this skill at `scripts/mcp_smoke.sh`.

**Expected failure mode:** if you edit `lib/dran/mcp.ex` but don't restart
`mix phx.server`, the smoke test still passes against the OLD schema (the
running BEAM serves the old code). Recompile + restart before trusting a green
run. The canonical version lives in the Dran repo; the copy here is for
convenience when the repo isn't at hand.
- **`async: false`** is required because the `:inference` Application env is
  global and tests mutate it in setup.
- The `process_message/1` result for a tool call is always
  `%{"result" => %{"content" => [%{"text" => text}]}}` — never an `{:error, _}`
  tuple. Errors are encoded as strings inside `text`.
