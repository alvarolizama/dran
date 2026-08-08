#!/bin/bash
# Smoke test: verify the live MCP schema served by a running Dran server.
# Catches schema-vs-code drift (enum values, deprecations, description hints).
# Canonical copy lives in the Dran repo at scripts/mcp_smoke.sh; if they
# diverge, the repo version wins.
#
# Usage: ./mcp_smoke.sh [host] [token]
set -u
HOST="${1:-http://localhost:4000}"
TOKEN="${2:-dran-token}"
URL="$HOST/api/mcp"

hdr=(-H "Content-Type: application/json" -H "Accept: application/json" -H "Authorization: Bearer $TOKEN")

echo "== 1. initialize =="
INIT=$(curl -s -D /tmp/mcp_init_headers "${hdr[@]}" -X POST "$URL" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0.1"}}}')
echo "$INIT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('server:', d['result']['serverInfo']['name'], d['result']['serverInfo']['version']); print('protocol:', d['result']['protocolVersion'])" || { echo "FAIL initialize"; echo "$INIT"; exit 1; }
grep -i "mcp-session-id" /tmp/mcp_init_headers | head -1 || true

echo "== 2. tools/list =="
TOOLS=$(curl -s "${hdr[@]}" -X POST "$URL" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
echo "$TOOLS" > /tmp/mcp_tools.json
python3 - <<'PY'
import json, sys
d = json.load(open('/tmp/mcp_tools.json'))
tools = {t['name']: t for t in d['result']['tools']}
print(f"tool count: {len(tools)}")
expected = ["dran_search","dran_create_page","dran_update_page","dran_get_page","dran_delete_page",
            "dran_create_todo","dran_update_todo","dran_create_relation","dran_delete_relation","dran_get_links",
            "dran_list_pages","dran_get_stats","dran_lint_brain","dran_rename_slug","dran_reaugment_page",
            "dran_ingest_url","dran_start_agent","dran_get_agent_session"]
missing = [t for t in expected if t not in tools]
extra = [t for t in tools if t not in expected]
if missing: print("MISSING:", missing); sys.exit(1)
if extra: print("EXTRA:", extra)

# Check start_agent enum has all 6 agent types
enum = tools['dran_start_agent']['inputSchema']['properties']['agent_type'].get('enum', [])
print("start_agent enum:", enum)
want = {"research","ingest","ask","curator","link_gardener","weekly_review"}
if set(enum) != want:
    print("FAIL: enum mismatch, want", sorted(want)); sys.exit(1)

# Spot-check intent-oriented descriptions
checks = {
    'dran_search': 'first',
    'dran_get_page': 'after',
    'dran_update_page': 'replac',
    'dran_update_todo': 'merg',
}
for name, needle in checks.items():
    if needle not in tools[name]['description'].lower():
        print(f"WARN: {name} description missing '{needle}':")
        print("   ", tools[name]['description'][:120])
print("descriptions spot-check: done")
print(f"tool count check: expected {len(expected)}, got {len(tools)}")
if len(tools) != len(expected):
    print(f"FAIL: tool count mismatch (expected {len(expected)}, got {len(tools)})"); sys.exit(1)
print("ALL CHECKS PASSED")
PY
