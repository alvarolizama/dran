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
        "dran_list_page_types",
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
        # Goals, tasks y planes (contrato de superficies, W2) — en el orden en
        # que `_tool_schemas()` los declara.
        "dran_list_goals",
        "dran_get_goal",
        "dran_create_goal",
        "dran_update_goal",
        "dran_delete_goal",
        "dran_list_tasks",
        "dran_create_task",
        "dran_capture",
        "dran_get_task",
        "dran_update_task",
        "dran_move_task",
        "dran_delete_task",
        "dran_list_plans",
        "dran_get_plan",
        "dran_create_plan",
        "dran_update_plan",
        "dran_set_plan_checklist",
        "dran_toggle_checklist",
        "dran_delete_plan",
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
            handlers["dran_list_page_types"]({}, ctx=ctx)
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
        assert "/api/workspaces/personal/page-types" in paths, paths
        # La ruta REAL del router es `GET /knowledge-pages/:slug/links` (el slug
        # viaja en el path, sin query): la assert vieja esperaba `…?` y quedaba
        # roja contra un plugin que llamaba bien. Se corrige contra el router.
        assert "/api/knowledge-pages/s/links" in paths, paths
        assert "/api/relations" in paths, paths
        assert "/api/lint" in paths, paths
        assert "/api/workers" in paths, paths
        assert "/api/workers/abc" in paths, paths
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


# ── Effective page types (no hardcoded vocabulary) ───────────────────────────
# P-plugin: the plugin reads the workspace's effective types from
# /api/agent/config instead of hardcoding the retired 8-type list.

_AGENT_CONFIG = {
    "agent": {"id": "1", "name": "hermes"},
    "page_types": ["note", "entity", "concept", "reference", "recipe"],
    "workspaces": [
        {"slug": "personal",
         "page_types": ["note", "entity", "concept", "reference", "recipe"]},
        {"slug": "work",
         "page_types": ["note", "entity", "concept", "reference"]},
    ],
}


class _FakeConfigClient:
    """Stand-in client whose agent_config returns a canned payload."""

    def __init__(self, workspace, payload):
        self.workspace = workspace
        self._payload = payload

    def agent_config(self, timeout=3.0):
        return self._payload


# The vocabulary the new model RETIRED — asserted ABSENT. Written one slug per
# line so a grep for the old type list does not match this negative assertion.
_RETIRED_TYPES = {
    "food",
    "technical",
    "knowledge",
    "idea",
}


def _with_config(plugin, payload, workspace="personal"):
    plugin._TYPE_CACHE.clear()
    return mock.patch.object(
        plugin, "_client_for",
        return_value=_FakeConfigClient(workspace, payload),
    )


def test_effective_page_types_read_from_agent_config(plugin):
    with _with_config(plugin, _AGENT_CONFIG):
        assert plugin._effective_page_types() == [
            "note", "entity", "concept", "reference", "recipe",
        ]
        assert plugin._effective_page_types("work") == [
            "note", "entity", "concept", "reference",
        ]


def test_effective_page_types_fall_back_to_the_four_builtins(plugin):
    """No client, unreachable server or non-agent key -> the 4 built-ins."""
    with mock.patch.object(plugin, "_client_for", return_value=None):
        plugin._TYPE_CACHE.clear()
        assert list(plugin.BUILTIN_PAGE_TYPES) == [
            "note", "entity", "concept", "reference",
        ]
        assert plugin._effective_page_types() == list(plugin.BUILTIN_PAGE_TYPES)

    with _with_config(plugin, None):
        assert plugin._effective_page_types() == list(plugin.BUILTIN_PAGE_TYPES)


def test_tool_descriptions_render_the_effective_types(plugin):
    with _with_config(plugin, _AGENT_CONFIG):
        schemas = {s["name"]: s for s in plugin._tool_schemas()}
    listed = schemas["dran_list_pages"]["description"]
    listed_types = schemas["dran_list_page_types"]["description"]
    created = schemas["dran_create_page"]["parameters"]["properties"]["page_type"]
    for slug in ("note", "entity", "concept", "reference", "recipe"):
        assert slug in listed
        assert slug in listed_types
        assert slug in created["description"]
    # No trace of the retired TYPES in the rendered vocabulary. "knowledge"
    # still appears as prose ("List knowledge pages") — that is the domain
    # noun, not a page type, so compare the rendered type lists instead.
    rendered = (
        listed.split("page type (", 1)[1].rstrip(").")
        + " "
        + created["description"].split(": ", 1)[1]
    )
    rendered_types = [t.strip() for t in rendered.split("|") if t.strip()]
    for retired in _RETIRED_TYPES:
        assert retired not in rendered_types, rendered_types


def test_create_page_rejects_a_type_outside_the_effective_set(plugin):
    """Fail-closed: a retired type never reaches the API."""
    ctx = FakeCtx()

    class Exploding(_FakeConfigClient):
        def create_page(self, **kwargs):  # pragma: no cover - must not run
            raise AssertionError("the API must not be called")

    with mock.patch.object(plugin, "_client_for",
                           return_value=Exploding("personal", _AGENT_CONFIG)):
        plugin._TYPE_CACHE.clear()
        out = json.loads(plugin._handle_plugin_tool(
            "dran_create_page", {"title": "T", "page_type": "idea"}, ctx=ctx))

    assert "unknown page type" in out["error"]
    assert out["effective_page_types"] == [
        "note", "entity", "concept", "reference", "recipe",
    ]


def test_create_page_accepts_a_custom_workspace_type(plugin):
    ctx = FakeCtx()
    captured = {}

    class Recording(_FakeConfigClient):
        def create_page(self, **kwargs):
            captured.update(kwargs)
            return {"data": {"slug": "s", "id": "1"}}

    with mock.patch.object(plugin, "_client_for",
                           return_value=Recording("personal", _AGENT_CONFIG)):
        plugin._TYPE_CACHE.clear()
        out = json.loads(plugin._handle_plugin_tool(
            "dran_create_page", {"title": "T", "page_type": "recipe"}, ctx=ctx))

    assert out["created"] is True
    assert captured["page_type"] == "recipe"


# ── Goals / tasks / plans (contrato de superficies, W2) ──────────────────────
# P10/P11: las tools del contenedor de trabajo y del plan son cliente DELGADO de
# las rutas del router, y el `scope` viaja con el vocabulario del REST
# (string del vocabulario, o el grupo anidado) — nunca como estado del cliente.

_WORK_TOOL_CALLS = [
    ("dran_list_goals", {"status": "active"}),
    ("dran_get_goal", {"id": "s"}),
    ("dran_create_goal", {"title": "Meta", "scope": "public"}),
    ("dran_update_goal", {"id": "s", "status": "done"}),
    ("dran_delete_goal", {"id": "s"}),
    ("dran_list_tasks", {"goal": "s", "status": "done"}),
    ("dran_create_task", {"title": "T", "goal": "s"}),
    ("dran_get_task", {"id": "1"}),
    ("dran_capture", {"title": "Idea suelta"}),
    ("dran_update_task", {"id": "1", "priority": "high"}),
    ("dran_move_task", {"id": "1", "status": "done", "lock_version": 3}),
    ("dran_delete_task", {"id": "1"}),
    ("dran_list_plans", {}),
    ("dran_get_plan", {"id": "s"}),
    ("dran_create_plan", {"title": "Lanzamiento", "group": "equipo", "checklist": ["uno"]}),
    ("dran_update_plan", {"id": "s", "status": "active"}),
    ("dran_set_plan_checklist", {"id": "s", "checklist": ["uno", "dos"]}),
    ("dran_toggle_checklist", {"target": "task", "id": "1", "index": 0}),
    ("dran_delete_plan", {"id": "s"}),
]


def _record_work_routes(plugin):
    """Corre las 18 tools de trabajo con un cliente falso y devuelve lo llamados."""
    ctx = FakeCtx(config={"api_key": "k", "base_url": "http://dran.test",
                          "workspace": "personal"})
    import os
    with mock.patch.object(plugin, "_load_dran_config", lambda _home: {}), \
            mock.patch.object(os.path, "expanduser", lambda p: p):
        plugin.register(ctx)
        handlers = {t["name"]: t["handler"] for t in ctx.tools}
        routes = []

        def fake_request(m, path, payload=None, timeout=None):
            routes.append((m, path, payload))
            if m == "GET":
                return {"data": [], "progress": {"done": 0, "total": 0, "percent": 0}}
            return {"data": {"id": "1", "slug": "s", "checklist": []},
                    "progress": {"done": 0, "total": 0, "percent": 0}}

        with mock.patch.object(plugin, "_client_for") as client_for:
            client = plugin._DranClient("http://dran.test", "k", "personal")
            client.request = fake_request  # type: ignore[assignment]
            client_for.return_value = client

            answers = {}
            for name, args in _WORK_TOOL_CALLS:
                answers[name] = json.loads(handlers[name](args, ctx=ctx))

    return routes, answers


def test_work_tools_hit_the_documented_routes(plugin):
    """Las 18 tools golpean las rutas que el router sirve (una por verbo)."""
    routes, answers = _record_work_routes(plugin)
    verbs = {(m, p) for m, p, _ in routes}

    for expected in [
        ("GET", "/api/goals?limit=50&status=active"),
        ("GET", "/api/goals/s"),
        ("GET", "/api/goals/s/tasks"),
        ("POST", "/api/goals"),
        ("PUT", "/api/goals/s"),
        ("DELETE", "/api/goals/s"),
        ("GET", "/api/tasks?limit=100&goal=s&status=done"),
        ("POST", "/api/tasks"),
        ("GET", "/api/tasks/1"),
        ("POST", "/api/tasks/1/move"),
        ("PUT", "/api/tasks/1"),
        ("DELETE", "/api/tasks/1"),
        ("POST", "/api/capture"),
        ("GET", "/api/plans?limit=50"),
        ("GET", "/api/plans/s"),
        ("POST", "/api/plans"),
        ("PUT", "/api/plans/s"),
        ("DELETE", "/api/plans/s"),
        ("PUT", "/api/plans/s/checklist"),
        ("POST", "/api/checklist/toggle"),
    ]:
        assert expected in verbs, (expected, sorted(verbs))

    # Ninguna tool falló: la respuesta es la fila (o el sobre de borrado).
    for name, answer in answers.items():
        assert "error" not in answer, (name, answer)


def test_work_tools_send_the_scope_vocabulary_not_client_state(plugin):
    """El destino viaja como `scope` del REST: string del vocabulario o grupo."""
    routes, _ = _record_work_routes(plugin)
    payloads = {}
    for _method, path, payload in routes:
        if isinstance(payload, dict):
            payloads.setdefault(path, []).append(payload)

    goal = payloads["/api/goals"][0]
    assert goal["title"] == "Meta"
    assert goal["scope"] == "public"

    plan = payloads["/api/plans"][0]
    assert plan["scope"] == {"group": "equipo"}
    assert plan["checklist"] == ["uno"]

    move = payloads["/api/tasks/1/move"][0]
    assert move["status"] == "done"
    assert move["lock_version"] == 3

    toggle = payloads["/api/checklist/toggle"][0]
    assert toggle == {"target": "task", "id": "1", "index": 0}

    # Un update sin scope NO manda el campo: el destino no se re-declara solo.
    goal_update = payloads["/api/goals/s"][0]
    assert "scope" not in goal_update


def test_work_tools_reject_missing_arguments_without_calling_the_api(plugin):
    """Fail-closed en el cliente: sin título/id no hay llamada."""
    ctx = FakeCtx(config={"api_key": "k", "base_url": "http://dran.test",
                          "workspace": "personal"})

    class Exploding:
        def __getattr__(self, _name):
            raise AssertionError("the API must not be called")

    with mock.patch.object(plugin, "_client_for", return_value=Exploding()):
        for name, args in [
            ("dran_create_goal", {}),
            ("dran_create_task", {}),
            ("dran_capture", {}),
            ("dran_get_task", {}),
            ("dran_create_plan", {}),
            ("dran_get_goal", {}),
            ("dran_update_task", {}),
            ("dran_move_task", {}),
            ("dran_set_plan_checklist", {"id": "s"}),
            ("dran_toggle_checklist", {"target": "plan", "id": "s"}),
            ("dran_toggle_checklist", {"target": "goal", "id": "s", "index": 0}),
        ]:
            out = json.loads(plugin._handle_work_tool(
                plugin._client_for(None), name, args))
            assert "error" in out, (name, out)


def test_toggle_checklist_surfaces_a_stale_lock_as_a_conflict(plugin):
    """409 del lock optimista: la tool lo dice, no lo esconde."""
    import io
    import urllib.error

    class Conflict:
        def _goal_scope(self, scope, group):
            return None

        def toggle_checklist(self, *a, **kw):
            raise urllib.error.HTTPError(
                "http://dran.test/api/checklist/toggle", 409, "Conflict",
                {}, io.BytesIO(b'{"errors":{"detail":"checklist changed elsewhere"}}'))

    out = json.loads(plugin._handle_work_tool(Conflict(), "dran_toggle_checklist",
                                              {"target": "plan", "id": "s", "index": 0}))
    assert out["error"] == "stale"
    assert out["status"] == 409
