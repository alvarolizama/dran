#!/bin/bash
# Smoke test: verify MCP schema served by the running dev server.
# Usage: ./scripts/mcp_smoke.sh [host] [token]
set -u
HOST="${1:-http://localhost:4000}"
TOKEN="${2:-dran-token}"
URL="$HOST/api/mcp"
FAIL=0

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
expected = ["search","semantic_search","create_page","update_page","get_page","delete_page",
            "create_todo","update_todo","create_relation","delete_relation","get_links",
            "list_pages","stats","lint","rename_slug","reaugment_page","ingest_url",
            "start_agent","get_agent_session"]
missing = [t for t in expected if t not in tools]
extra = [t for t in tools if t not in expected]
if missing: print("MISSING:", missing); sys.exit(1)
if extra: print("EXTRA:", extra)

# Check start_agent enum has all 6 agent types
enum = tools['start_agent']['inputSchema']['properties']['agent_type'].get('enum', [])
print("start_agent enum:", enum)
want = {"research","ingest","ask","curator","link_gardener","weekly_review"}
if set(enum) != want:
    print("FAIL: enum mismatch, want", sorted(want)); sys.exit(1)

# Check semantic_search is marked deprecated in description
desc = tools['semantic_search']['description'].lower()
if 'deprecat' not in desc:
    print("FAIL: semantic_search not marked deprecated"); sys.exit(1)
print("semantic_search deprecation: OK")

# Spot-check intent-oriented descriptions
checks = {
    'search': 'first',
    'get_page': 'after search',
    'update_page': 'replac',
    'update_todo': 'merg',
}
for name, needle in checks.items():
    if needle not in tools[name]['description'].lower():
        print(f"WARN: {name} description missing '{needle}':")
        print("   ", tools[name]['description'][:120])
print("descriptions spot-check: done")
print("ALL CHECKS PASSED")
PY
