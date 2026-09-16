"""Tests for the Dran Hermes plugin.

Two surfaces are covered:

1. `register(ctx)` — the module must register the memory provider AND the
   knowledge toolset. Exercised with a fake ctx, so no
   Hermes install is required.
2. `_DranClient` — the write paths must carry the `X-Hermes-Agent` header, and
   the knowledge endpoints must hit the documented REST routes.

Run: python3 -m pytest hermes_plugin/tests/ -q
"""

from __future__ import annotations

import json
import sys
import types
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest
from unittest import mock

# Import the plugin module directly from the repo (no Hermes import needed for
# the parts under test). `agent.memory_provider` is a Hermes module — stub it so
# the import works in a plain venv.
_PLUGIN_DIR = Path(__file__).resolve().parents[1] / "dran"


def _load_plugin_module():
    if "agent.memory_provider" not in sys.modules:
        agent = types.ModuleType("agent")
        memory_provider = types.ModuleType("agent.memory_provider")

        class MemoryProvider:  # minimal stand-in for the real contract
            pass

        class RecallStatus:
            def __init__(self, provider_label="", count=0):
                self.provider_label = provider_label
                self.count = count

        memory_provider.MemoryProvider = MemoryProvider
        memory_provider.RecallStatus = RecallStatus
        agent.memory_provider = memory_provider
        sys.modules["agent"] = agent
        sys.modules["agent.memory_provider"] = memory_provider

    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "dran_plugin_under_test", _PLUGIN_DIR / "__init__.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def plugin():
    return _load_plugin_module()


class FakeCtx:
    """Records what register(ctx) registers."""

    def __init__(self, config=None):
        self.config = config or {}
        self.providers = []
        self.tools = []

    def register_memory_provider(self, provider):
        self.providers.append(provider)

    def register_tool(self, name, toolset, schema, handler, **kwargs):
        self.tools.append(
            {"name": name, "toolset": toolset, "schema": schema, "handler": handler}
        )


# ── register(ctx) ────────────────────────────────────────────────────────────
# P8: the plugin exposes tools and keeps the memory provider.

def test_register_registers_memory_provider_and_tools(plugin):
    ctx = FakeCtx()
    plugin.register(ctx)

    assert len(ctx.providers) == 1, "the memory provider must stay registered"
    names = [t["name"] for t in ctx.tools]
    assert names == [
        "dran_search",
        "dran_list_pages",
        "dran_get_page",
        "dran_create_page",
        "dran_update_page",
        "dran_delete_page",
        "dran_get_links",
        "dran_create_relation",
        "dran_delete_relation",
        "dran_lint_brain",
        "dran_rename_slug",
        "dran_reaugment_page",
        "dran_generate_cluster_summaries",
        "dran_start_worker",
        "dran_get_worker_session",
        "dran_stats",
    ]
    assert len(set(names)) == len(names), "no duplicate tool names"


def test_every_registered_tool_has_valid_schema(plugin):
    ctx = FakeCtx()
    plugin.register(ctx)

    for tool in ctx.tools:
        schema = tool["schema"]
        assert isinstance(schema, dict)
        assert schema["name"] == tool["name"]
        params = schema.get("parameters", {})
        assert isinstance(params, dict), f"{tool['name']}: parameters must be an object"
        assert tool["toolset"] == "dran"
        assert callable(tool["handler"])


def test_register_does_not_drop_provider_when_tool_registration_fails(plugin):
    """A tool registration failure must not cost the memory provider."""

    class ExplodingCtx(FakeCtx):
        def register_tool(self, *args, **kwargs):
            raise RuntimeError("toolset rejected")

    ctx = ExplodingCtx()
    plugin.register(ctx)
    assert len(ctx.providers) == 1


# ── X-Hermes-Agent on every write ────────────────────────────────────────────
# P8: agent identity is attributed server-side on writes.

def test_client_sends_x_hermes_agent_header(plugin):
    client = plugin._DranClient("http://dran.test", "key", "personal",
                                agent_identity="coder")
    assert client._headers()["X-Hermes-Agent"] == "coder"


def test_client_omits_header_when_identity_empty(plugin):
    client = plugin._DranClient("http://dran.test", "key", "personal")
    assert "X-Hermes-Agent" not in client._headers()


@pytest.mark.parametrize(
    "method,fn_name,args",
    [
        ("POST", "create_page", {"title": "T", "body": "B"}),
        ("PUT", "update_page", {"title": "T2"}),
        ("DELETE", "delete_page", {}),
        ("POST", "create_relation", {"source_slug": "a", "target_slug": "b"}),
    ],
)
def test_write_paths_carry_the_header(plugin, method, fn_name, args):
    client = plugin._DranClient("http://dran.test", "key", "personal",
                                agent_identity="coder")
    captured = {}

    def fake_request(m, path, payload=None, timeout=None):
        captured["method"] = m
        captured["path"] = path
        captured["headers"] = client._headers()
        return {"data": {"slug": "x", "id": "1"}}

    client.request = fake_request  # type: ignore[assignment]

    fn = getattr(client, fn_name)
    if fn_name in ("update_page", "delete_page"):
        fn("slug-x", **args)
    else:
        fn(**args)

    assert captured["method"] == method
    assert captured["headers"]["X-Hermes-Agent"] == "coder", (
        f"{fn_name} must attribute the write to the Hermes profile"
    )


def test_memory_writes_carry_the_header(plugin):
    client = plugin._DranClient("http://dran.test", "key", "personal",
                                agent_identity="coder")
    captured = {}

    def fake_request(m, path, payload=None, timeout=None):
        captured["headers"] = client._headers()
        captured["path"] = path
        return {"data": {}}

    client.request = fake_request  # type: ignore[assignment]
    client.add_memory("a fact")
    assert captured["headers"]["X-Hermes-Agent"] == "coder"
    assert captured["path"] == "/api/memory"


# ── Knowledge endpoints: REST routes ─────────────────────────────────────────
# P8: the tools talk to the documented Dran REST surface.

def test_tool_calls_hit_documented_routes(plugin):
    ctx = FakeCtx(config={"api_key": "k", "base_url": "http://dran.test",
                          "workspace": "personal"})
    import os
    with mock.patch.object(plugin, "_load_dran_config", lambda _home: {}), \
            mock.patch.object(os.path, "expanduser", lambda p: p):
        plugin.register(ctx)

        handlers = {t["name"]: t["handler"] for t in ctx.tools}
        routes = []

        def fake_request(m, path, payload=None, timeout=None):
            routes.append((m, path))
            if m == "GET":
                return {"data": []}
            return {"data": {"slug": "s", "id": "1"}}

        with mock.patch.object(plugin, "_client_for") as client_for:
            client = plugin._DranClient("http://dran.test", "k", "personal")
            client.request = fake_request  # type: ignore[assignment]
            client_for.return_value = client

            handlers["dran_search"]({"query": "elixir"}, ctx=ctx)
            handlers["dran_list_pages"]({}, ctx=ctx)
            handlers["dran_create_page"]({"title": "T"}, ctx=ctx)
            handlers["dran_get_links"]({"slug": "s"}, ctx=ctx)
            handlers["dran_create_relation"](
                {"source_slug": "a", "target_slug": "b"}, ctx=ctx
            )
            handlers["dran_lint_brain"]({}, ctx=ctx)
            handlers["dran_start_worker"]({"worker_type": "curator"}, ctx=ctx)
            handlers["dran_get_worker_session"]({"session_id": "abc"}, ctx=ctx)
            handlers["dran_stats"]({}, ctx=ctx)

        paths = [p for _, p in routes]
        assert any(p.startswith("/api/search?") for p in paths), paths
        assert any(p.startswith("/api/knowledge-pages?") for p in paths), paths
        assert any(p.startswith("/api/knowledge-pages/s/links?") for p in paths), paths
        assert "/api/relations" in paths, paths
        assert any(p.startswith("/api/lint?") for p in paths), paths
        assert "/api/workers" in paths, paths
        assert any(p.startswith("/api/workers/abc?") for p in paths), paths
        assert "/api/workspaces" in paths, paths

        # The workspace is always pinned in the query string.
        for _, path in routes:
            if "?" in path and path.startswith("/api/"):
                qs = parse_qs(urlparse(path).query)
                if "workspace" in qs:
                    assert qs["workspace"] == ["personal"]


def test_tool_handler_errors_are_json_not_raised(plugin):
    ctx = FakeCtx()
    plugin.register(ctx)
    handlers = {t["name"]: t["handler"] for t in ctx.tools}

    with mock.patch.object(plugin, "_client_for", return_value=None):
        out = handlers["dran_search"]({"query": "x"}, ctx=ctx)
    payload = json.loads(out)
    assert "error" in payload


def test_tool_handler_rejects_missing_required_args(plugin):
    ctx = FakeCtx()
    plugin.register(ctx)
    handlers = {t["name"]: t["handler"] for t in ctx.tools}

    with mock.patch.object(plugin, "_client_for") as client_for:
        client_for.return_value = plugin._DranClient("http://dran.test", "k", "personal")
        assert "error" in json.loads(handlers["dran_search"]({}, ctx=ctx))
        assert "error" in json.loads(handlers["dran_get_page"]({}, ctx=ctx))
        assert "error" in json.loads(
            handlers["dran_create_relation"]({"source_slug": "a"}, ctx=ctx)
        )


# ── Result trimming ──────────────────────────────────────────────────────────

def test_trim_results_keeps_agent_name_and_bounds_body(plugin):
    long_body = "x" * 5000
    rows = plugin._trim_results([
        {"id": "1", "slug": "s", "title": "T", "body": long_body,
         "agent_name": "coder", "created_by": "coder", "noise": "drop me"},
    ])
    assert len(rows) == 1
    assert rows[0]["agent_name"] == "coder"
    assert len(rows[0]["body"]) == 600
    assert "noise" not in rows[0]
