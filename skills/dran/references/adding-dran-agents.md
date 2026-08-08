# Adding a new Dran agent (Engine.Behaviour pattern)

Dran agents run on `Dran.Agent.Engine` and implement the
`Dran.Agent.Engine.Behaviour` behaviour. The established pattern (Curator,
Research, Ingest, QA, LinkGardener, WeeklyReview) is:

1. **Create `lib/dran/agent/<name>.ex`** with `@behaviour Dran.Agent.Engine.Behaviour`.
2. **Define a `State` struct** inside the module — holds `session`, `module`,
   `messages`, `step`, `pages_created`, `opts`, plus any agent-specific tracking
   fields (e.g. `duplicate_pairs` for Curator, `stats` for WeeklyReview).
3. **Implement the callbacks:**
   - `agent_type/0` → a string like `"weekly_review"`, `"curator"`.
   - `tools/0` → OpenAI-compatible function schemas (list of `%{"type" =>
     "function", "function" => %{...}}` maps). Each tool needs `name`,
     `description`, `parameters` (JSON schema).
   - `system_prompt/0` → the LLM system prompt (accept `_opts \\ []`).
   - `build_messages/3` → `[%{"role" => "system", ...}, %{"role" => "user",
     ...}]`.
   - `init_state/3` → returns the initial `State` struct.
   - `execute_tool/3` → pattern-matches on tool name string, returns
     `{{:ok, result}, new_state}` or `{{:error, reason}, new_state}`.
   - `summarize_result/1` (optional) → maps tool results to summary maps.
   - `gathered_summary/1` (optional) → human-readable nudge when the LLM
     stalls.
4. **Add a public `run/3`** that delegates to
   `Dran.Agent.Engine.run(__MODULE__, input, context_id, opts)`.
5. **Add `run_scheduled/0`** for cron-triggered runs — resolves the default
   context via `Auth.default_context_slug/0` + `Brain.get_context_by_slug/1`,
   then calls `run("scheduled <description>", ctx.id)`.
6. **Register in `start_agent_by_type`** in `lib/dran/mcp.ex` — add a clause:
   ```elixir
   defp start_agent_by_type("<agent_type>", input, context_id, opts),
     do: Agent.<Module>.run(input, context_id, opts)
   ```

## Tool implementation patterns

### Tools that gather data (no LLM call)

Tools like `gather_stats` or `find_duplicates` query the DB directly via
`Ecto.Query` and return a structured map. Key points:

- Read `context_id` from `state.session.context_id`.
- Use `fragment("?->>'field_name'", p.meta)` to extract JSONB meta fields in
  queries.
- Store the result in state for `gathered_summary/1` to reference later.
- Return `{{:ok, result_map}, %{state | stats: result_map}}`.

### Tools that create pages

Follow the `create_report` / `create_review_page` pattern:

- Validate required args (return `{{:error, "msg"}, state}` if missing).
- Build `page_attrs` map with `context_id`, `title`, `body`, `page_type`,
  `created_by`, `owner`, and `meta`.
- Call `Brain.create_page/1`.
- On success: broadcast via `Phoenix.PubSub.broadcast(Dran.PubSub,
  "agents:#{session.id}", {:page_created, page})` and increment
  `pages_created`.
- On error: format changeset errors with the `format_changeset_errors/1`
  helper (traverse_errors pattern — copy from Curator).

## Testing pattern

### Unit tests (direct execute_tool)

Call `execute_tool/3` directly with a hand-built `State`. No LLM, no engine,
no HTTP stubs needed. Build the session and state with helper functions:

```elixir
defp build_session(context_id) do
  struct(%Session{
    id: Ecto.UUID.generate(),
    context_id: context_id,
    agent_type: "<type>",
    input: "test run",
    status: "running"
  })
end

defp build_state(context_id, attrs \\ []) do
  struct(%AgentModule.State{session: build_session(context_id), ...}, attrs)
end
```

Then assert on the `{:ok, result}` tuple and the returned `new_state`.

Seed pages with `insert_page!` — a helper that directly inserts `%Page{}`
structs via `Repo.insert!`. Set `embedding_hash` to avoid re-augmentation.

### E2E tests (Req.Test stub + Agent counter)

The LLM is stubbed with `Req.Test.stub(Dran.Inference.Client, fn conn -> ... end)`.
The stub must serve different responses on consecutive calls (step 0 → tool A,
step 1 → tool B, etc). **Critical: use an Elixir `Agent` process as a counter,
not `Process.put/get`** — tool execution happens inside spawned Tasks, so
process dictionary doesn't survive across calls.

```elixir
{:ok, counter} = Agent.start_link(fn -> 0 end)

Req.Test.stub(Dran.Inference.Client, fn conn ->
  case conn.request_path do
    "/v1/embeddings" ->
      Req.Test.json(conn, %{"data" => [%{"embedding" => List.duplicate(0.0, 1024)}]})

    "/v1/chat/completions" ->
      step = Agent.get_and_update(counter, fn s -> {s, s + 1} end)
      tool_call = case step do
        0 -> %{"function" => %{"name" => "first_tool", "arguments" => "{}"}}
        1 -> %{"function" => %{"name" => "second_tool", "arguments" => ~s({"body": "..."})}}
        _ -> %{"function" => %{"name" => "done", "arguments" => ~s({"summary": "..."})}}
      end
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"tool_calls" => [tool_call]}}]})
  end
end)
```

The `/v1/embeddings` endpoint must be stubbed because `Brain.create_page`
triggers async embedding generation — answer with a 1024-dim zero vector.

The inference env setup (copy from curator_test):

```elixir
Application.put_env(:dran, :inference,
  base_url: "http://localhost:8000/v1",
  api_key: "test-key",
  chat_model: "test-chat-model",
  embedding_model: "Qwen3-Embedding",
  markitdown_model: "MarkItDown",
  timeout: 5_000,
  req_plug: {Req.Test, Dran.Inference.Client},
  schedule_async: false
)
```

Also call `ensure_queue_started(:chat)` and `ensure_queue_started(:embed)`
to start the inference queue GenServers (copy from curator_test).

After `Agent.run(...)`, poll for session completion with an `eventually/1`
helper (retry loop with `Process.sleep(100)`, 50 attempts). Then assert on
the session status, summary, and any created pages.

### Running tests

```bash
# Port 4000 may be in use by a dev server — override with PORT:
PORT=4099 mix test test/dran/agent/<agent>_test.exs
```

If `mix compile` fails on a *different* file (e.g. a LiveView another agent
is editing in parallel), that is not your error — verify your own file
compiles with `MIX_ENV=test mix compile` or check that the failing file is
not yours.
