# MCP-tool-wrapping agent pattern (Copilot)

When an agent needs access to ALL MCP tools (not a hand-picked subset), define
the `tools/0` callback by converting `MCP.tool_schemas/0` to OpenAI
function-calling format rather than re-declaring each tool inline. Then delegate
`execute_tool/3` back through `MCP.process_message/1` instead of reimplementing
each tool's logic.

This is the pattern `Dran.Agent.Copilot` uses. It differs from the
inline-tools pattern (Curator, LinkGardener, Research) where each agent defines
its own 4-5 narrow tools.

## When to use this pattern

- The agent should be able to call any of the 18 MCP tools.
- The agent is conversational (chat-driven, not a batch job).
- You don't want to duplicate or drift from MCP tool execution logic.

## tools/0 — conversion + done

```elixir
@impl true
def tools do
  mcp_tools =
    MCP.tool_schemas()
    |> Enum.map(fn schema ->
      %{
        "type" => "function",
        "function" => %{
          "name" => schema["name"],
          "description" => schema["description"],
          "parameters" => schema["inputSchema"]
        }
      }
    end)

  mcp_tools ++ [done_tool()]
end
```

Key points:

- `MCP.tool_schemas/0` returns the `@tools` list from `lib/dran/mcp.ex` —
  each entry has `name`, `description`, `inputSchema` (JSON Schema).
- The OpenAI format wraps these under `function.parameters` (not
  `function.inputSchema`).
- The engine requires a `done` tool to finish the session. MCP does NOT expose
  `done` as a tool (it's an agent-loop concept), so append it separately.
- Total tool count: 18 (MCP) + 1 (done) = 19.

## execute_tool/3 — delegate to MCP

```elixir
@impl true
def execute_tool("done", _args, %State{} = state) do
  {{:ok, :done}, state}
end

def execute_tool(tool, args, %State{} = state) do
  args = args || %{}
  args = inject_context(args, state)   # see below

  msg = %{
    "jsonrpc" => "2.0",
    "method" => "tools/call",
    "id" => 1,
    "params" => %{"name" => tool, "arguments" => args}
  }

  case MCP.process_message(msg) do
    %{"result" => %{"content" => [%{"text" => text} | _]}} ->
      if String.starts_with?(text, "Error:") do
        {{:error, text}, state}
      else
        sources = extract_sources(text, state.sources)
        {{:ok, text}, %{state | sources: sources}}
      end

    %{"error" => %{"message" => reason}} ->
      {{:error, reason}, state}

    _ ->
      {{:error, "unexpected MCP response"}, state}
  end
end
```

Key points:

- Route `done` directly (don't send it to MCP — MCP doesn't know about it).
- Build a `tools/call` JSON-RPC envelope and pass it to
  `MCP.process_message/1`. This reuses ALL of MCP's execute_tool logic
  (context lookup, Brain calls, error formatting) without duplication.
- MCP always returns text in `result.content[0].text`. MCP tool errors are
  returned as strings prefixed with `"Error:"` (not as JSON-RPC error objects)
  — check the prefix to distinguish success from failure.
- Guard against `nil` args (the LLM may omit arguments for parameterless
  tools).

## Context injection

Most MCP tools require a `"context"` parameter (the context slug). The LLM
often omits it. Inject it from `session.meta`:

```elixir
defp inject_context(args, %State{} = state) do
  if Map.has_key?(args, "context") do
    args
  else
    context_slug = get_in(state.session.meta, ["context_slug"]) || "personal"
    Map.put(args, "context", context_slug)
  end
end
```

- Only inject when `"context"` is absent — don't override an explicit value.
- Default to `"personal"` (Drans's default context) when meta is nil/empty.
- The `dran_get_agent_session` tool is the one exception: it takes
  `session_id`, not `context`. Injecting `context` is harmless (MCP ignores
  extra args).

## Conversational state (session.meta)

Unlike batch agents (research, curator), the copilot is stateless per message.
Each user message starts a fresh `Agent.Session`. Pass context via
`session.meta`:

```elixir
meta = %{
  "context_slug" => "personal",
  "page_slug" => "current-page-slug",   # optional
  "history" => [%{"role" => "user", "content" => "..."}, ...]  # last 10
}
```

`build_messages/2` reads these from `session.meta`:

```elixir
def build_messages(input, session) do
  history = get_in(session.meta, ["history"]) || []
  # take last 10, map to {role, content} maps
  context_slug = get_in(session.meta, ["context_slug"]) || "personal"
  page_slug = get_in(session.meta, ["page_slug"])

  system = system_prompt() <> "\nContexto actual: #{context_slug}"
  system = if page_slug, do: system <> "\nPágina actual: #{page_slug}", else: system

  [%{"role" => "system", "content" => system}] ++ history_msgs ++ [%{"role" => "user", "content" => input}]
end
```

## Registration

The copilot is NOT registered in `start_agent_by_type` in `lib/dran/mcp.ex`
because it's not started via `dran_start_agent`. It's started directly by
`Chat.Server` (or any caller) via:

```elixir
Dran.Agent.Copilot.run(input, context_id, meta: meta)
```

If a future agent wraps MCP tools AND should be startable via
`dran_start_agent`, add it to `start_agent_by_type` as usual.

## Testing

### Unit tests (no LLM, no inference)

Test `execute_tool/3` directly with a hand-built `State` and a real DB
context. MCP's `process_message/1` hits the database, so use `Dran.DataCase`:

```elixir
test "dran_get_page returns page content", %{context: ctx} do
  create_page!(ctx, %{title: "My Page", slug: "my-page", body: "hello"})

  session = build_session(context_id: ctx.id, meta: %{"context_slug" => ctx.slug})
  state = build_state(session: session)

  {{:ok, result}, _} = Copilot.execute_tool("dran_get_page", %{"slug" => "my-page"}, state)
  assert result =~ "hello"
end
```

- Create a real context with `Brain.create_context/1` (unique slug per test).
- Set `session.meta["context_slug"]` to the context's slug so context
  injection works.
- Assert on the text content returned by MCP (markdown strings, not maps).
- For error cases, assert on the `{:error, msg}` tuple and that `msg =~`
  the expected error fragment.

### Key test assertions for the conversion

```elixir
# tools/0 returns 19 schemas (18 MCP + done)
assert length(Copilot.tools()) == 19

# All 18 MCP tool names are present
for name <- ["dran_search", "dran_get_page", ...] do
  assert name in names
end

# Each tool has correct OpenAI structure
for tool <- Copilot.tools() do
  assert tool["type"] == "function"
  assert is_binary(tool["function"]["name"])
  assert is_map(tool["function"]["parameters"])
end

# MCP.tool_schemas/0 returns the raw @tools list (18 entries)
assert length(MCP.tool_schemas()) == 18
```

## Gotchas

- **`done` tool is NOT in MCP.** It must be appended separately in `tools/0`
  and handled separately in `execute_tool/3`. Forgetting it means the engine
  can never finish the session.
- **MCP returns errors as text, not JSON-RPC error objects.** A tool that
  fails (e.g. page not found) returns `{"result": {"content": [{"text":
  "Error: page 'x' not found"}]}}`. Check `String.starts_with?(text, "Error:")`.
- **`context` injection is required.** The LLM frequently omits the
  `context` parameter. Without injection, every tool call fails with
  "context not found".
- **`build_messages/2` takes 2 args, not 3.** The behaviour callback is
  `build_messages(String.t(), Session.t())`. The engine checks
  `function_exported?(module, :build_messages, 3)` first and falls back to
  arity 2. The copilot uses arity 2.
- **`nil` args.** Some LLMs pass `nil` instead of `{}` for parameterless
  tools. Guard with `args = args || %{}`.
