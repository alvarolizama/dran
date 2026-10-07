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

import io
import json
import os
import re
import sys
import time
import types
import urllib.error
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


@pytest.fixture(autouse=True)
def hermetic_dran_home(plugin, tmp_path, monkeypatch):
    """Ningún test lee el config REAL del usuario.

    El gate de grupos resuelve el home del perfil en cada llamada: sin esto, un
    `~/.hermes/dran/config.json` con un grupo apagado cambiaría el resultado de
    toda la suite. Cada test arranca con un home vacío — todo ON por default.
    """
    home = tmp_path / "hermes_home"
    home.mkdir()
    monkeypatch.setattr(plugin, "_active_hermes_home", lambda: str(home))
    # La tarjeta se lee del config.yaml del perfil ACTIVO cuando la llamada no
    # trae ctx: que ningún test lea el config real del usuario (misma razón que
    # el home hermético), y que el `register()` previo no se filtre entre tests.
    monkeypatch.setitem(sys.modules, "hermes_cli", None)
    monkeypatch.setattr(plugin, "_PLUGIN_CTX", None)
    plugin._TOGGLES_CACHE.clear()
    plugin._MEMORY_CACHE.clear()
    return home


class FakeCtx:
    """Records what register(ctx) registers."""

    def __init__(self, config=None):
        self.config = config or {}
        self.providers = []
        self.tools = []
        self.prompt_sections = []
        self.skills = []

    def register_memory_provider(self, provider):
        self.providers.append(provider)

    def register_tool(self, name, toolset, schema, handler, **kwargs):
        self.tools.append(
            {"name": name, "toolset": toolset, "schema": schema, "handler": handler,
             "check_fn": kwargs.get("check_fn")}
        )

    def register_system_prompt_section(self, section_id, content, **kwargs):
        self.prompt_sections.append({"id": section_id, "content": content, **kwargs})

    def register_skill(self, name, path, description="", frontmatter=None):
        self.skills.append(
            {"name": name, "path": Path(path), "description": description,
             "frontmatter": frontmatter}
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
        "dran_list_groups",
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
        # Servicios conectados — cliente delgado del REST /api/services. UNA
        # tool de descubrimiento (el catálogo es DATO), NUNCA una por toolkit.
        "dran_services",
        "dran_services_connect",
        "dran_services_tools",
        "dran_services_run",
        "dran_services_wait",
        # Skills remotos (contrato de skills remotos, W4) — 4 tools FIJAS y el
        # catálogo como DATO: el cuerpo viaja por tool y nunca se baja a disco.
        "dran_skills",
        "dran_skill",
        "dran_skill_save",
        "dran_skill_delete",
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
        # Un TOOLSET por grupo: es la superficie que el operador corta desde
        # `hermes tools disable dran_<group>` / platform_toolsets.
        group = plugin._TOOL_TO_GROUP[tool["name"]]
        assert tool["toolset"] == f"dran_{group}"
        assert callable(tool["handler"])
        assert callable(tool["check_fn"]), f"{tool['name']}: sin gate de grupo"


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
    ("dran_list_groups", {}),
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
    """Las 19 tools golpean las rutas que el router sirve (una por verbo)."""
    routes, answers = _record_work_routes(plugin)
    verbs = {(m, p) for m, p, _ in routes}

    for expected in [
        ("GET", "/api/groups"),
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


def test_profile_default_destination_applies_to_creates_only(plugin):
    """El default del perfil («Write scope»/«Group slug») es REAL, no config muerta.

    El argumento de la herramienta manda; el default aplica a las ALTAS de goal y
    plan, y una EDICIÓN sin destino no manda `scope` (no re-declara la
    visibilidad de algo que ya vive en otro lado).
    """
    def payload_for(default_scope, default_group, tool, args):
        routes = []

        def fake_request(m, path, payload=None, timeout=None):
            routes.append((m, path, payload))
            return {"data": {"id": "1", "slug": "s"}}

        client = plugin._DranClient("http://dran.test", "k", "personal",
                                    default_scope=default_scope,
                                    default_group=default_group)
        client.request = fake_request  # type: ignore[assignment]
        out = json.loads(plugin._handle_work_tool(client, tool, args))
        assert "error" not in out, out
        return routes[0][2]

    # Alta con default de grupo: nace compartido con ese grupo, sin que la tool
    # lo declare.
    assert payload_for("group", "equipo", "dran_create_goal",
                       {"title": "Meta"})["scope"] == {"group": "equipo"}
    assert payload_for("public", "", "dran_create_plan",
                       {"title": "Plan"})["scope"] == "public"
    # El argumento de la tool gana sobre el default del perfil.
    assert payload_for("group", "equipo", "dran_create_goal",
                       {"title": "Meta", "scope": "private"})["scope"] == "private"
    assert payload_for("private", "", "dran_create_goal",
                       {"title": "Meta", "group": "otro"})["scope"] == {"group": "otro"}
    # Una edición no manda el campo: el destino declarado no se mueve.
    assert "scope" not in payload_for("group", "equipo", "dran_update_goal",
                                     {"id": "s", "title": "Otro"})


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
        def _goal_scope(self, scope, group, **kw):
            return None

        def toggle_checklist(self, *a, **kw):
            raise urllib.error.HTTPError(
                "http://dran.test/api/checklist/toggle", 409, "Conflict",
                {}, io.BytesIO(b'{"errors":{"detail":"checklist changed elsewhere"}}'))

    out = json.loads(plugin._handle_work_tool(Conflict(), "dran_toggle_checklist",
                                              {"target": "plan", "id": "s", "index": 0}))
    assert out["error"] == "stale"
    assert out["status"] == 409


# ── Servicios conectados (cliente delgado del REST /api/services) ────────────
# El catálogo viaja como DATO, NUNCA como una tool por toolkit: hay UNA tool de
# descubrimiento y UNA de ejecución. El inventario se inyecta con la MISMA
# cadencia que la memoria (a lo sumo un GET /api/services por ventana).

_SERVICE_TOOL_NAMES = {
    "dran_services",
    "dran_services_connect",
    "dran_services_tools",
    "dran_services_run",
    "dran_services_wait",
}

_SERVICES_PAYLOAD = {
    "configured": True,
    "data": [
        {"toolkit": "gmail", "name": "Gmail", "connected": True,
         "status": "ACTIVE", "identity": "alvaro@gmail.com"},
        {"toolkit": "github", "name": "GitHub", "connected": False,
         "status": None, "identity": None},
    ],
}


def test_services_tools_registered_and_declared(plugin):
    ctx = FakeCtx()
    plugin.register(ctx)
    names = {t["name"] for t in ctx.tools}
    assert _SERVICE_TOOL_NAMES <= names, _SERVICE_TOOL_NAMES - names

    manifest = (_PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
    declared = set(re.findall(r"^\s*-\s+(dran_[a-z_]+)\s*$", manifest, re.M))
    assert _SERVICE_TOOL_NAMES <= declared, _SERVICE_TOOL_NAMES - declared


def test_no_per_toolkit_service_tool_exists(plugin):
    """El catálogo es DATO: no hay `dran_gmail_*` ni equivalentes."""
    ctx = FakeCtx()
    plugin.register(ctx)
    names = [t["name"] for t in ctx.tools]
    per_toolkit = re.compile(
        r"^dran_(gmail|slack|github|gitlab|jira|linear|notion|drive|calendar|"
        r"outlook|discord|telegram|asana|trello|sheets|docs)(_|$)"
    )
    offenders = [n for n in names if per_toolkit.match(n)]
    assert offenders == [], offenders
    # Una sola puerta de descubrimiento, una sola de ejecución.
    assert names.count("dran_services_tools") == 1
    assert names.count("dran_services_run") == 1


def test_system_prompt_block_names_service_triggers(plugin):
    """El anuncio de capacidad no necesita servidor: sólo texto estático."""
    block = plugin.DranMemoryProvider().system_prompt_block().lower()
    for trigger in ("mail", "calendar", "issues", "messages", "files"):
        assert trigger in block, trigger
    assert "dran_services" in block
    assert "injected" in block  # el inventario llega solo, no se poletea


class _FakeServiceClient:
    """Cliente falso: cuenta GET /api/services y sirve un inventario canned."""

    def __init__(self, services_payload, memories=None):
        self.workspace = "personal"
        self._services = services_payload
        self._memories = memories or []
        self.service_calls = 0
        self.search_calls = 0

    def agent_config(self, timeout=3.0):
        return None

    def search(self, query, limit=5):
        self.search_calls += 1
        return list(self._memories)

    def list_services(self):
        self.service_calls += 1
        return self._services


def _armed_provider(plugin, client, *, cadence=1):
    provider = plugin.DranMemoryProvider()
    provider._config = {"auto_recall": True, "recall_cadence": cadence,
                        "max_recall_results": 5, "max_recall_chars": 800}
    provider._client = client
    provider._turns_since_inject = 1_000_000
    provider._workspace_resolved_at = 0.0
    return provider


def test_services_inventory_is_injected_in_prefetch(plugin):
    client = _FakeServiceClient(_SERVICES_PAYLOAD)
    provider = _armed_provider(plugin, client, cadence=1)

    provider.queue_prefetch("hola", session_id="s1")
    provider.shutdown()  # join the background recall pass
    text = provider.prefetch("hola", session_id="s1")

    assert "Dran services:" in text
    assert "gmail ACTIVE (alvaro@gmail.com)" in text
    assert "github not connected" in text
    assert client.service_calls == 1


def test_services_inventory_respects_cadence_and_dedupe(plugin):
    """Dos prefetches en la MISMA ventana: a lo sumo un GET /api/services."""
    client = _FakeServiceClient(_SERVICES_PAYLOAD)
    provider = _armed_provider(plugin, client, cadence=3)

    provider.queue_prefetch("uno", session_id="s1")
    provider.shutdown()
    provider.prefetch("uno", session_id="s1")

    provider.queue_prefetch("dos", session_id="s1")  # dentro de la ventana
    provider.shutdown()
    text = provider.prefetch("dos", session_id="s1")

    assert client.service_calls == 1, "one GET /api/services per prefetch window"
    assert text == ""


def test_services_inventory_absent_when_not_configured(plugin):
    assert plugin._services_line({"configured": False, "data": []}) == ""
    assert plugin._services_line({}) == ""


def test_services_connect_returns_redirect_url(plugin):
    ctx = FakeCtx()

    class Client:
        def connect_service(self, toolkit):
            return {"data": {"toolkit": toolkit,
                             "redirect_url": "https://dran.test/connect/abc",
                             "expires_in": 600}}

    with mock.patch.object(plugin, "_client_for", return_value=Client()):
        out = json.loads(plugin._handle_plugin_tool(
            "dran_services_connect", {"toolkit": "gmail"}, ctx=ctx))

    assert out["redirect_url"] == "https://dran.test/connect/abc"
    assert out["toolkit"] == "gmail"
    assert out["expires_in"] == 600


def test_services_run_surfaces_not_connected_409(plugin):
    """Fail-closed: el 409 not_connected devuelve el connect_url, no un falso éxito."""
    ctx = FakeCtx()

    class NotConnected:
        def execute_service(self, toolkit, tool_slug, arguments):
            raise urllib.error.HTTPError(
                "http://dran.test/api/services/execute", 409, "Conflict", {},
                io.BytesIO(json.dumps({
                    "errors": {"detail": "gmail is not connected",
                               "code": "not_connected"},
                    "toolkit": "gmail",
                    "connect_url": "https://dran.test/connect/xyz",
                }).encode()))

    with mock.patch.object(plugin, "_client_for", return_value=NotConnected()):
        out = json.loads(plugin._handle_plugin_tool(
            "dran_services_run",
            {"toolkit": "gmail", "tool_slug": "GMAIL_SEND_EMAIL",
             "arguments": {"to": "a@b.c"}}, ctx=ctx))

    assert out["status"] == 409
    assert out["code"] == "not_connected"
    assert out["connect_url"] == "https://dran.test/connect/xyz"
    assert "error" in out


def test_services_wait_returns_when_active(plugin):
    ctx = FakeCtx()

    class Client:
        def list_services(self):
            return {"configured": True, "data": [
                {"toolkit": "gmail", "connected": True, "status": "ACTIVE"}]}

    with mock.patch.object(plugin, "_client_for", return_value=Client()):
        out = json.loads(plugin._handle_plugin_tool(
            "dran_services_wait", {"toolkit": "gmail"}, ctx=ctx))

    assert out["active"] is True
    assert out["status"] == "ACTIVE"


def test_services_wait_times_out_with_expiry_hint(plugin):
    """No llega a ACTIVE: dice que el link expira y hay que reemitir uno nuevo."""
    ctx = FakeCtx()

    class Client:
        def list_services(self):
            return {"configured": True, "data": [
                {"toolkit": "gmail", "connected": False, "status": "INITIATED"}]}

    with mock.patch.object(plugin, "_client_for", return_value=Client()):
        out = json.loads(plugin._handle_plugin_tool(
            "dran_services_wait", {"toolkit": "gmail", "timeout_seconds": 0},
            ctx=ctx))

    assert out["active"] is False
    assert "10 minutes" in out["hint"]
    assert "expires" in out["hint"]


def test_services_tools_hit_documented_routes(plugin):
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
            if path.startswith("/api/services/search"):
                return {"data": {"query": "x", "primary_tool_slugs": []}}
            if path.startswith("/api/services/gmail/tools"):
                return {"data": {"toolkit": "gmail", "tools": []}}
            if path == "/api/services":
                return {"configured": True, "data": []}
            if path == "/api/services/execute":
                return {"data": {"toolkit": "gmail", "tool_slug": "X", "result": {}}}
            return {"data": {"toolkit": "gmail",
                             "redirect_url": "https://d.test/c", "expires_in": 600}}

        with mock.patch.object(plugin, "_client_for") as client_for:
            client = plugin._DranClient("http://dran.test", "k", "personal")
            client.request = fake_request  # type: ignore[assignment]
            client_for.return_value = client

            handlers["dran_services"]({}, ctx=ctx)
            handlers["dran_services_connect"]({"toolkit": "gmail"}, ctx=ctx)
            handlers["dran_services_tools"](
                {"toolkit": "gmail", "slug": "GMAIL_SEND_EMAIL"}, ctx=ctx)
            handlers["dran_services_tools"]({"use_case": "send an email"}, ctx=ctx)
            handlers["dran_services_run"](
                {"toolkit": "gmail", "tool_slug": "GMAIL_SEND_EMAIL",
                 "arguments": {"to": "a@b.c"}}, ctx=ctx)
            handlers["dran_services_wait"](
                {"toolkit": "gmail", "timeout_seconds": 0}, ctx=ctx)

    paths = [p for _, p, _ in routes]
    assert ("GET", "/api/services") in [(m, p) for m, p, _ in routes]
    assert ("POST", "/api/services/gmail/connect") in [(m, p) for m, p, _ in routes]
    assert any(p.startswith("/api/services/gmail/tools?slug=") for p in paths), paths
    assert any(p.startswith("/api/services/search?q=") for p in paths), paths
    assert ("POST", "/api/services/execute") in [(m, p) for m, p, _ in routes]

    # La identidad es la credencial: nunca viaja un user_id/session_id.
    execute = [pl for _, p, pl in routes if p == "/api/services/execute"][0]
    assert "user_id" not in execute and "session_id" not in execute
    assert execute["toolkit"] == "gmail"
    assert execute["arguments"] == {"to": "a@b.c"}


# ── Skills remotos (contrato de skills remotos, W4) ──────────────────────────
#
# P11: las 4 tools se registran y el manifiesto las declara (el invariante de la
#      suite mide los dos lados).
# P12: `initialize()` calienta el índice ANTES del build del prompt y la sección
#      es fail-open (con Dran caído queda vacía y el prompt no se rompe).
# P13: `dran_skill` enmarca el cuerpo con slug/versión/hash y responde
#      `unchanged` cuando el hash de la sesión no cambió.

_SKILL_TOOL_NAMES = {"dran_skills", "dran_skill", "dran_skill_save", "dran_skill_delete"}


def test_skills_tools_registered_and_declared(plugin):
    ctx = FakeCtx()
    plugin.register(ctx)
    names = {t["name"] for t in ctx.tools}
    assert _SKILL_TOOL_NAMES <= names, _SKILL_TOOL_NAMES - names

    manifest = (_PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
    declared = set(re.findall(r"^\s*-\s+(dran_[a-z_]+)\s*$", manifest, re.M))
    assert _SKILL_TOOL_NAMES <= declared, _SKILL_TOOL_NAMES - declared


def test_no_per_skill_tool_exists(plugin):
    """El catálogo es DATO: no se genera una tool por skill.

    El plugin registra ESTÁTICO al cargarse, así que una tool por skill sería una
    lista que el servidor no puede cambiar sin reiniciar el perfil — la misma
    lección que servicios ya cerró.
    """
    ctx = FakeCtx()
    plugin.register(ctx)
    names = [t["name"] for t in ctx.tools]

    assert sorted(n for n in names if n.startswith("dran_skill")) == [
        "dran_skill", "dran_skill_delete", "dran_skill_save", "dran_skills"]
    assert "dran_skill_weekly_review" not in names


def test_skills_pointer_registered_for_the_local_listing(plugin):
    """El plugin registra UNA fila en `skills_list`: la que contesta «listar skills».

    La suite se SIRVE, no se instala, así que el listado local no tiene ni un
    `dran-*`: el pedido «listar skills» caía en un registro donde Dran no existía.
    `ctx.register_skill` pone la fila (aparece en `skills_list`, se carga con
    `skill_view`, NO se copia a `~/.hermes/skills/` y no entra en el índice del
    prompt). Es un puntero al catálogo vivo, no un cuerpo de la suite.
    """
    ctx = FakeCtx()
    plugin.register(ctx)

    [pointer] = ctx.skills
    assert pointer["name"] == plugin.POINTER_SKILL_NAME
    assert pointer["path"] == plugin.POINTER_SKILL_PATH
    assert pointer["description"] == plugin.POINTER_SKILL_DESCRIPTION
    assert pointer["path"].exists(), "el SKILL.md registrado tiene que existir"
    assert _PLUGIN_DIR in pointer["path"].parents, "el puntero vive dentro del plugin"
    # Hermes corta la descripción a 60 chars en el índice: el disparo entra entero.
    assert len(pointer["description"]) <= 60, len(pointer["description"])
    assert pointer["description"].startswith("Use when asked to list skills")


def test_pointer_skill_file_matches_what_the_plugin_registers(plugin):
    """El SKILL.md y lo que `register()` registra son la MISMA verdad.

    Un archivo que diga otra cosa (o un nombre de disparo distinto) es la deriva
    clásica: el listado mostraría una descripción y el cuerpo hablaría de otra.
    """
    text = plugin.POINTER_SKILL_PATH.read_text(encoding="utf-8")
    frontmatter = text.split("---")[1]
    name_match = re.search(r"^name:\s*(.+)$", frontmatter, re.M)
    description_match = re.search(r'^description:\s*"?(.+?)"?\s*$', frontmatter, re.M)
    assert name_match is not None and description_match is not None, \
        "el frontmatter del puntero necesita name y description"

    assert name_match.group(1).strip() == plugin.POINTER_SKILL_NAME
    assert description_match.group(1) == plugin.POINTER_SKILL_DESCRIPTION
    # El cuerpo tiene que traer LA ruta, no una promesa: la tool diferida se
    # alcanza por el puente y la query es en inglés (una en español no matchea).
    assert "tool_search" in text
    assert "dran_skills" in text
    assert "dran_skill" in text


def test_pointer_failure_does_not_cost_the_rest_of_the_plugin(plugin):
    """Fail-open: sin el archivo (install que no copió `skills/`) el plugin carga."""

    class NoPointerCtx(FakeCtx):
        def register_skill(self, *args, **kwargs):
            raise FileNotFoundError("skills/dran-skills-index/SKILL.md")

    ctx = NoPointerCtx()
    plugin.register(ctx)

    assert len(ctx.providers) == 1
    assert len(ctx.tools) == 46
    assert len(ctx.prompt_sections) == 1


def test_skills_prompt_section_registered_always_and_fail_open(plugin):
    """La sección se registra SIEMPRE, en `after_memory` y bajo el tope de 4000."""
    ctx = FakeCtx()
    plugin.register(ctx)

    [section] = ctx.prompt_sections
    assert section["id"] == "dran-skills"
    assert section["position"] == "after_memory"
    assert 0 < section["max_chars"] <= 4_000
    assert callable(section["content"])

    # Sin skills legibles (o con Dran caído) el bloque es "": Hermes lo descarta
    # y el prompt no se rompe.
    plugin._SKILLS_INDEX = {"skills": [], "loaded_at": 0.0}
    assert plugin._skills_prompt_section({}) == ""


def test_prompt_section_describes_existence_not_content(plugin):
    """Una línea por skill y el listado vivo por tool: el cuerpo NO entra acá."""
    plugin._SKILLS_INDEX = {
        "skills": [
            {"slug": "weekly-review", "version": 2, "description": "Cómo revisar la semana",
             "content_hash": "abc", "body": "CUERPO QUE NO DEBE APARECER"},
        ],
        "loaded_at": 0.0,
    }

    text = plugin._skills_prompt_section({})
    assert "weekly-review" in text
    assert "v2" in text
    assert "Cómo revisar la semana" in text
    assert "dran_skills" in text  # el listado VIVO es la tool
    assert "dran_skill" in text
    assert "CUERPO QUE NO DEBE APARECER" not in text
    assert len(text) <= plugin.SKILLS_SECTION_MAX_CHARS


def test_prompt_section_truncates_by_budget_never_overflows(plugin):
    """El bloque que se pasa del tope lo OMITE Hermes ENTERO: acá se corta.

    Con muchas skills el corte es explícito y declara cuántas quedaron fuera —
    nunca una sección que se pasa y desaparece sin decir nada.
    """
    plugin._SKILLS_INDEX = {
        "skills": [{"slug": f"skill-{i:04d}", "version": 1, "description": "x" * 60}
                   for i in range(500)],
        "loaded_at": 0.0,
    }

    text = plugin._skills_prompt_section({})
    assert len(text) <= plugin.SKILLS_SECTION_MAX_CHARS
    assert "more" in text
    assert "dran_skills" in text


def test_initialize_warms_the_index_before_the_prompt(plugin):
    """P12: el caché se llena en `initialize()` — el build del prompt lee el caché."""

    class WarmClient:
        def __init__(self):
            self.calls = 0

        def list_skills(self, limit=None, timeout=None):
            self.calls += 1
            return [{"slug": "sembrado", "version": 1, "description": "d"}]

    client = WarmClient()
    provider = plugin.DranMemoryProvider()
    plugin._SKILL_HASHES = {"viejo": "hash-de-otra-sesion"}

    with mock.patch.object(plugin, "_load_dran_config",
                           lambda _home: {"base_url": "http://dran.test", "api_key": "k",
                                          "workspace": "personal", "scope": "private",
                                          "scope_group": ""}), \
            mock.patch.object(plugin, "_DranClient", return_value=client), \
            mock.patch.object(plugin.DranMemoryProvider, "_probe_connection", lambda self: None):
        provider.initialize("sess-1")

    assert client.calls == 1
    assert plugin._SKILLS_INDEX["skills"][0]["slug"] == "sembrado"
    # La sesión arranca sin hashes cargados: lo de la sesión anterior no cuenta.
    assert plugin._SKILL_HASHES == {}


def test_initialize_leaves_the_index_empty_when_dran_is_down(plugin):
    """Con Dran caído el caché queda vacío: la sección se descarta, sin excepción."""

    class BrokenClient:
        def list_skills(self, limit=None, timeout=None):
            raise ConnectionError("dran unreachable")

    provider = plugin.DranMemoryProvider()

    with mock.patch.object(plugin, "_load_dran_config",
                           lambda _home: {"base_url": "http://dran.test", "api_key": "k",
                                          "workspace": "personal", "scope": "private",
                                          "scope_group": ""}), \
            mock.patch.object(plugin, "_DranClient", return_value=BrokenClient()), \
            mock.patch.object(plugin.DranMemoryProvider, "_probe_connection", lambda self: None):
        provider.initialize("sess-down")

    assert plugin._SKILLS_INDEX["skills"] == []
    assert plugin._skills_prompt_section({}) == ""


def _skills_plugin(plugin):
    """Registra las tools con un cliente falso y devuelve (handlers, rutas, skills)."""
    ctx = FakeCtx(config={"api_key": "k", "base_url": "http://dran.test",
                          "workspace": "personal"})
    import os
    with mock.patch.object(plugin, "_load_dran_config", lambda _home: {}), \
            mock.patch.object(os.path, "expanduser", lambda p: p):
        plugin.register(ctx)
        handlers = {t["name"]: t["handler"] for t in ctx.tools}

    routes = []
    detail = {"/api/skills/weekly": {"slug": "weekly", "name": "weekly",
                                     "description": "cómo revisar", "version": 3,
                                     "content_hash": "hash3", "body": "# cuerpo",
                                     "visibility": "private"}}

    def fake_request(m, path, payload=None, timeout=None):
        routes.append((m, path, payload))
        if m == "GET" and path.startswith("/api/skills?"):
            return {"data": [{"slug": "weekly", "version": 3, "content_hash": "hash3",
                              "description": "cómo revisar", "visibility": "private"}]}
        if m == "GET" and path in detail:
            return {"data": detail[path]}
        if m == "POST":
            return {"data": {"slug": payload["slug"], "version": 1,
                             "content_hash": "hash-nuevo",
                             "visibility": payload.get("visibility", "private")}}
        if m == "PUT":
            return {"data": {"slug": "weekly", "version": 4, "content_hash": "hash4",
                             "visibility": "private"}}
        if m == "DELETE":
            return {}
        raise urllib.error.HTTPError(path, 404, "not found", None, None)

    client = plugin._DranClient("http://dran.test", "k", "personal")
    client.request = fake_request  # type: ignore[assignment]
    return handlers, routes, detail, client, ctx


def test_skill_tools_hit_documented_routes(plugin):
    handlers, routes, _detail, client, ctx = _skills_plugin(plugin)
    plugin._SKILL_HASHES = {}

    with mock.patch.object(plugin, "_client_for", return_value=client):
        index = json.loads(handlers["dran_skills"]({}, ctx=ctx))
        load = json.loads(handlers["dran_skill"]({"slug": "weekly"}, ctx=ctx))
        again = json.loads(handlers["dran_skill"]({"slug": "weekly"}, ctx=ctx))
        created = json.loads(handlers["dran_skill_save"](
            {"slug": "nuevo", "description": "d", "body": "# x", "visibility": "public"},
            ctx=ctx))
        updated = json.loads(handlers["dran_skill_save"](
            {"slug": "weekly", "description": "d2", "body": "# y"}, ctx=ctx))
        deleted = json.loads(handlers["dran_skill_delete"]({"slug": "weekly"}, ctx=ctx))

    verbs = {(m, p) for m, p, _ in routes}
    assert ("GET", "/api/skills?limit=200") in verbs
    assert ("GET", "/api/skills/weekly") in verbs
    assert ("POST", "/api/skills") in verbs
    assert ("PUT", "/api/skills/weekly") in verbs
    assert ("DELETE", "/api/skills/weekly") in verbs

    # El índice NUNCA trae el cuerpo; el detalle sí, y viene enmarcado.
    assert "body" not in index["skills"][0]
    assert load["body"] == "# cuerpo"
    assert load["version"] == 3
    assert load["content_hash"] == "hash3"
    assert load["frame"].startswith("[dran skill weekly")
    assert "hash3"[:12] in load["frame"]

    # P13: el mismo hash de la SESIÓN no re-inyecta el cuerpo.
    assert again["status"] == "unchanged"
    assert "body" not in again

    assert created["created"] is True and created["slug"] == "nuevo"
    assert updated["updated"] is True and updated["version"] == 4
    assert deleted["deleted"] is True

    # El alta manda el vocabulario del destino, nunca estado del cliente.
    create_payload = [pl for m, p, pl in routes if (m, p) == ("POST", "/api/skills")][0]
    assert create_payload["visibility"] == "public"
    assert "owner_user_id" not in create_payload


def test_skill_body_survives_a_new_load_after_saving(plugin):
    """Guardar limpia el hash de la sesión: el próximo `dran_skill` trae el cuerpo."""
    handlers, _routes, _detail, client, ctx = _skills_plugin(plugin)
    plugin._SKILL_HASHES = {"weekly": "hash3"}

    with mock.patch.object(plugin, "_client_for", return_value=client):
        handlers["dran_skill_save"](
            {"slug": "weekly", "description": "d2", "body": "# y"}, ctx=ctx)
        reloaded = json.loads(handlers["dran_skill"]({"slug": "weekly"}, ctx=ctx))

    assert reloaded.get("body") == "# cuerpo"
    assert reloaded.get("status") != "unchanged"


def test_dran_skills_searches_with_q_and_marks_the_query(plugin):
    """`dran_skills(q=...)` filtra en el SERVIDOR y devuelve sólo lo que matchea."""
    handlers, _routes, _detail, client, ctx = _skills_plugin(plugin)
    paths = []

    def fake_request(m, path, payload=None, timeout=None):
        paths.append(path)
        # El server nuevo YA filtró: devuelve sólo la fila que matchea.
        return {"data": [
            {"slug": "revision-semanal", "version": 1, "description": "cerrar la semana"},
        ]}

    client.request = fake_request

    with mock.patch.object(plugin, "_client_for", return_value=client):
        out = json.loads(handlers["dran_skills"]({"q": "SEMANAL"}, ctx=ctx))

    assert "q=SEMANAL" in paths[0]
    assert [s["slug"] for s in out["skills"]] == ["revision-semanal"]
    assert out["query"] == "SEMANAL"
    # Filtrado o no, el índice sigue viajando SIN cuerpos.
    assert "body" not in out["skills"][0]


def test_dran_skills_never_widens_when_the_server_ignores_q(plugin):
    """Contra un Dran sin `q`, el filtro del cliente evita reportar de más.

    Este fake IGNORA `q` y devuelve su catálogo completo: sin el filtro del
    cliente, el agente reportaría la fila que no matchea como resultado de la
    búsqueda.
    """
    handlers, _routes, _detail, client, ctx = _skills_plugin(plugin)

    def old_server(m, path, payload=None, timeout=None):
        return {"data": [
            {"slug": "revision-semanal", "version": 1, "description": "cerrar la semana"},
            {"slug": "informe-mensual", "version": 1, "description": "los numeros"},
        ]}

    client.request = old_server

    with mock.patch.object(plugin, "_client_for", return_value=client):
        out = json.loads(handlers["dran_skills"]({"q": "semanal"}, ctx=ctx))

    assert [s["slug"] for s in out["skills"]] == ["revision-semanal"]


def test_dran_skills_without_q_is_the_live_catalog(plugin):
    """Sin `q` el listado es el catálogo vivo completo, sin el campo `query`."""
    handlers, routes, _detail, client, ctx = _skills_plugin(plugin)

    with mock.patch.object(plugin, "_client_for", return_value=client):
        out = json.loads(handlers["dran_skills"]({}, ctx=ctx))

    assert [s["slug"] for s in out["skills"]] == ["weekly"]
    assert "query" not in out
    assert ("GET", "/api/skills?limit=200") in {(m, p) for m, p, _ in routes}


def test_skills_discovery_is_a_trigger_not_a_side_note(plugin):
    """El disparo: listar y elegir ANTES de arrancar — en el bloque y en la tool.

    La sección del prompt y la descripción de `dran_skills` son los dos lugares
    donde el modelo decide. Si dicen «llamá si está viejo» en vez de «listá antes
    de arrancar», el discovery queda librado a que el bloque le parezca
    sospechoso.
    """
    plugin._SKILLS_INDEX = {
        "skills": [{"slug": "weekly", "version": 1, "description": "d"}],
        "loaded_at": 0.0,
    }
    text = plugin._skills_prompt_section({})

    assert "BEFORE starting" in text
    assert "dran_skills" in text
    assert "q=" in text  # el filtro se anuncia donde el modelo lo va a leer

    [schema] = [s for s in plugin._tool_schemas() if s["name"] == "dran_skills"]
    assert "BEFORE starting" in schema["description"]
    assert "q" in schema["parameters"]["properties"]

    # El pedido de LISTADO es el otro disparo: la lista local no trae la suite
    # (se sirve, no se instala), así que el bloque y la tool tienen que decir que
    # el catálogo ES la lista — y nombrar la fila puntero que sí se ve.
    assert "LIST the skills" in text
    assert "dran-skills-index" in text
    assert "tool_search" in text  # las 4 tools están diferidas: hay que decirlo
    assert "LIST the skills" in schema["description"]
    assert "served, not installed" in schema["description"]


def test_skill_tools_reject_missing_arguments_without_calling_the_api(plugin):
    class ExplodingClient:
        def request(self, *args, **kwargs):
            raise AssertionError("no debe llamarse al API sin argumentos válidos")

    cases = [
        ("dran_skill", {}),
        ("dran_skill", {"slug": "  "}),
        ("dran_skill_save", {"slug": "x"}),
        ("dran_skill_save", {"slug": "x", "description": "d", "body": "# y",
                             "visibility": "amigos"}),
        ("dran_skill_delete", {}),
    ]

    for name, args in cases:
        out = json.loads(plugin._handle_skill_tool(ExplodingClient(), name, args))
        assert "error" in out, (name, args, out)


def test_skill_not_found_is_an_error_never_an_invented_body(plugin):
    """Un slug fuera del scope del lector es 404: no existe O no se puede leer."""
    handlers, _routes, _detail, client, ctx = _skills_plugin(plugin)
    plugin._SKILL_HASHES = {}

    with mock.patch.object(plugin, "_client_for", return_value=client):
        out = json.loads(handlers["dran_skill"]({"slug": "ajeno-privado"}, ctx=ctx))

    assert "error" in out
    assert "ajeno-privado" in out["error"]
    assert "body" not in out


# ── Grupos: un interruptor por superficie (panel + toolset) ──────────────────
# Dos caminos al MISMO interruptor:
#   * el panel del plugin — `tools.<group>` en $HERMES_HOME/dran/config.json,
#     leído por el `check_fn` de cada tool y por el guard del handler;
#   * el operador — un TOOLSET de Hermes por grupo (`dran_pages`, `dran_goals`,
#     ...), así `hermes tools disable dran_pages`, `platform_toolsets` y
#     `agent.disabled_toolsets` cortan la misma superficie.

def _write_dran_config(plugin, home, payload):
    """El panel escribe $HERMES_HOME/dran/config.json — el test hace lo mismo."""
    path = Path(home) / "dran" / "config.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    plugin._TOGGLES_CACHE.clear()
    return path


def test_group_table_covers_every_registered_tool(plugin):
    """El mapeo es total: un tool sin grupo volvería al switch todo-o-nada."""
    ctx = FakeCtx()
    plugin.register(ctx)
    registered = {t["name"] for t in ctx.tools}

    assert plugin._TOOL_GROUP_NAMES == (
        "pages", "goals", "tasks", "plans", "services", "skills", "brain",
    )
    assert set(plugin._TOOL_TO_GROUP) == registered
    assert sum(len(tools) for _n, tools in plugin._TOOL_GROUPS) == len(registered)


def _card_schema_keys() -> list:
    """Claves de nivel superior del `config_schema` de plugin.yaml.

    Se lee el FUENTE (sin PyYAML, que sólo existe dentro de Hermes): acá
    interesa QUÉ claves declara la tarjeta, no cómo las resuelve el parser.
    """
    source = (_PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
    block = source.split("\nconfig_schema:\n", 1)[1]
    return [match.group(1) for match in re.finditer(r"^  ([a-z_]+):$", block, re.M)]


def test_every_group_has_a_toggle_in_the_card_schema(plugin):
    """La tabla (runtime) y la TARJETA (plugin.yaml) no derivan.

    Los siete toggles dejaron el panel de memoria: viven en la tarjeta del
    plugin, con claves PLANAS (`pages`, no `tools.pages`) porque
    `plugins_settings.py` guarda las dotted anidadas y las re-lee planas — el
    formulario mostraría el default sobre el valor guardado.
    """
    declared = _card_schema_keys()
    for group in plugin._TOOL_GROUP_NAMES:
        assert group in declared, f"la tarjeta no declara el toggle del grupo {group}"

    panel = (_PLUGIN_DIR / "config_schema.py").read_text(encoding="utf-8")
    assert 'group="Tools"' not in panel, "los toggles volvieron al panel de memoria"
    for group in plugin._TOOL_GROUP_NAMES:
        assert f"tools.{group}" not in declared, "clave dotted: el formulario mentiría"


def test_card_declares_the_connection_and_the_destination(plugin):
    """Instancia y destino también son de la tarjeta; el token va al MISMO .env."""
    declared = _card_schema_keys()

    assert declared[:5] == ["api_key", "base_url", "scope", "scope_group", "memory"]
    source = (_PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
    assert "env: DRAN_API_KEY" in source, "el secret de la tarjeta debe resolver al mismo var"
    assert "choices:" in source, "Write scope se elige, no se escribe"


def test_memory_toggle_defaults_on_and_the_json_wins(plugin, hermetic_dran_home):
    """El switch de memoria: ausente = encendido, y el JSON legacy gana por clave."""
    assert plugin._memory_enabled() is True

    ctx = FakeCtx(config={"memory": False})
    assert plugin._memory_enabled(ctx) is False

    _write_dran_config(plugin, hermetic_dran_home, {"memory": True})
    plugin._MEMORY_CACHE.clear()
    assert plugin._memory_enabled(ctx) is True, "el JSON del panel gana por clave"


def test_memory_toggle_gates_the_provider_and_its_tools(plugin, hermetic_dran_home, monkeypatch):
    """Apagado: el provider no está disponible, sus tools salen del listado y niegan la llamada.

    Hermes no agrega un provider que no está disponible (`agent_init`:
    `if _mp and _mp.is_available()`), así que no hay recall ni captura; y una
    sesión en vuelo —que conserva su lista de tools— recibe el error
    estructurado en vez de un efecto.
    """
    card = FakeCtx(config={"memory": False, "api_key": "dran_card"})
    # El proveedor NO recibe ctx: resuelve la tarjeta del perfil activo (acá, el
    # ctx capturado en register(), porque el entorno de test no tiene hermes_cli).
    monkeypatch.setattr(plugin, "_PLUGIN_CTX", card)

    provider = plugin.DranMemoryProvider()

    assert plugin._memory_enabled() is False
    assert plugin._memory_enabled(card) is False
    assert provider.is_available() is False, "con el switch apagado no se carga"
    assert "switched OFF" in provider.unavailable_reason()
    assert provider.get_tool_schemas() == [], "las cuatro tools de memoria salen del listado"
    assert provider.system_prompt_block() == ""
    assert provider.prefetch("cualquiera") == ""

    denied = json.loads(provider.handle_tool_call("dran_memory_search", {"query": "hola"}))
    assert "tool disabled" in denied["error"]

    # Encendido, la misma instancia vuelve a exponer su superficie.
    monkeypatch.setattr(plugin, "_PLUGIN_CTX", FakeCtx(config={"memory": True, "api_key": "dran_card"}))
    plugin._MEMORY_CACHE.clear()  # en producción el cambio del archivo la invalida

    assert provider.is_available() is True
    assert len(provider.get_tool_schemas()) == 4


def _declared_panel_fields():
    """(key, inline, group) de cada ProviderField, en orden declarado.

    Se lee el FUENTE, no se importa: `config_schema.py` importa
    `plugins.memory.config_schema`, que sólo existe dentro de un Hermes
    instalado (misma razón que el test de los toggles).
    """
    source = (_PLUGIN_DIR / "config_schema.py").read_text(encoding="utf-8")
    parts = re.split(r'\n\s*key="([a-z_]+)"', source)[1:]
    fields = []
    for key, body in zip(parts[::2], parts[1::2]):
        group = re.search(r'group="([^"]+)"', body)
        fields.append((key, "inline=True" in body, group.group(1) if group else None))
    return fields


def test_memory_panel_keeps_only_the_memory_surface(plugin):
    """Bajo `memory.provider` se ve SÓLO lo de memoria — y ni la credencial.

    Todos los campos son `inline`, así que el panel compacto los pinta planos
    y no aparece el botón "Full config…": lo que el usuario ve ahí es
    exactamente esta lista. El token vive en la tarjeta del plugin (escribe el
    mismo `DRAN_API_KEY` del `.env` que resuelve el proveedor), así que no hay
    nada que pueda divergir entre las dos superficies.
    """
    fields = _declared_panel_fields()

    assert [key for key, _inline, _group in fields] == [
        "auto_recall", "auto_capture",
        "max_recall_results", "max_recall_chars", "recall_cadence",
    ]
    assert all(is_inline for _key, is_inline, _group in fields), "un campo no-inline abriría el modal"
    assert all(group for _key, _inline, group in fields), "un campo sin grupo cae en 'Other'"

    panel = (_PLUGIN_DIR / "config_schema.py").read_text(encoding="utf-8")
    assert 'key="api_key"' not in panel, "la credencial no se declara en las dos superficies"
    assert "scope" not in [key for key, _i, _g in fields], "el destino ya no es del panel"


# ── La TARJETA llega al runtime (no sólo a las tools) ────────────────────────

def test_card_settings_reach_the_runtime(plugin, hermetic_dran_home):
    """Instancia y destino de la tarjeta llegan al proveedor.

    El proveedor NO recibe `ctx` (se registra una vez por perfil), así que si
    la resolución leyera sólo el JSON, mover `base_url` a la tarjeta lo dejaba
    apuntando al default de localhost.
    """
    ctx = FakeCtx(config={
        "base_url": "https://dran.example",
        "scope": "group",
        "scope_group": "research-team",
        "api_key": "dran_card",
    })

    config = plugin._load_dran_config(str(hermetic_dran_home), ctx)

    assert config["base_url"] == "https://dran.example"
    assert config["scope"] == "group"
    assert config["scope_group"] == "research-team"
    assert config["api_key"] == "dran_card"


def test_card_is_read_from_the_captured_ctx_without_a_config_door(plugin, hermetic_dran_home, monkeypatch):
    """Sin `hermes_cli` (o sin ctx en la llamada) manda el ctx de `register()`."""
    monkeypatch.setattr(plugin, "_PLUGIN_CTX", FakeCtx(config={"base_url": "https://solo-ctx.example"}))

    assert plugin._load_dran_config(str(hermetic_dran_home))["base_url"] == "https://solo-ctx.example"


def test_panel_json_wins_over_the_card_per_key(plugin, hermetic_dran_home):
    """Un config.json ya escrito no cambia de sentido bajo el usuario."""
    _write_dran_config(plugin, hermetic_dran_home, {"base_url": "https://viejo.example"})
    ctx = FakeCtx(config={"base_url": "https://nuevo.example", "scope": "public"})

    config = plugin._load_dran_config(str(hermetic_dran_home), ctx)

    assert config["base_url"] == "https://viejo.example"  # el JSON gana
    assert config["scope"] == "public"                    # la clave que el JSON no tiene: la tarjeta


def test_builtin_defaults_never_outrank_the_card(plugin, hermetic_dran_home):
    """El JSON materializa defaults: si ganaran por merge, la tarjeta no serviría.

    Un `config.json` que sólo trae un knob de memoria NO debe arrastrar
    `base_url` al default de localhost por el hecho de existir.
    """
    _write_dran_config(plugin, hermetic_dran_home, {"auto_recall": False})
    ctx = FakeCtx(config={"base_url": "https://dran.example"})

    config = plugin._load_dran_config(str(hermetic_dran_home), ctx)

    assert config["base_url"] == "https://dran.example"
    assert config["auto_recall"] is False


def test_group_toggles_read_the_flat_card_keys(plugin, hermetic_dran_home):
    """El switch de la tarjeta apaga el grupo; el JSON del panel sigue ganando."""
    ctx = FakeCtx(config={"pages": False, "goals": True})
    plugin._TOGGLES_CACHE.clear()

    assert plugin._group_toggles(ctx)["pages"] is False
    assert plugin._group_toggles(ctx)["tasks"] is True

    _write_dran_config(plugin, hermetic_dran_home, {"tools": {"pages": True}})
    plugin._TOGGLES_CACHE.clear()

    assert plugin._group_toggles(ctx)["pages"] is True, "el JSON del panel gana por clave"


def test_group_toggles_read_the_legacy_nested_card(plugin, hermetic_dran_home):
    """Una tarjeta escrita en el molde viejo (`tools: {…}`) sigue gobernando."""
    ctx = FakeCtx(config={"tools": {"skills": False}})
    plugin._TOGGLES_CACHE.clear()

    assert plugin._group_toggles(ctx)["skills"] is False


def test_group_gate_reads_the_panel_config(plugin, hermetic_dran_home):
    _write_dran_config(plugin, hermetic_dran_home, {"tools": {"pages": False}})

    assert plugin._group_enabled("pages") is False
    assert plugin._group_enabled("tasks") is True
    assert plugin._group_enabled("brain") is True


def test_group_gate_is_fail_open(plugin, hermetic_dran_home):
    """Sin config (o con basura) todo sigue prendido: esto no es un guard de seguridad."""
    assert plugin._group_toggles() == {g: True for g in plugin._TOOL_GROUP_NAMES}

    for payload in ({"tools": {"pages": "no"}}, {"tools": "no"}, {"tools": {"otra": False}}):
        _write_dran_config(plugin, hermetic_dran_home, payload)
        assert plugin._group_enabled("pages") is True, payload


def test_ctx_config_and_disk_config_merge_per_key(plugin, hermetic_dran_home):
    """`plugins.entries.dran.settings` y el panel del perfil no se pisan en bloque."""
    _write_dran_config(plugin, hermetic_dran_home, {"tools": {"plans": False}})
    ctx = FakeCtx(config={"tools": {"tasks": False}})

    toggles = plugin._group_toggles(ctx)
    assert toggles["tasks"] is False
    assert toggles["plans"] is False
    assert toggles["pages"] is True


def test_disk_config_wins_over_ctx_config_on_conflict(plugin, hermetic_dran_home):
    """El panel del perfil manda: es el que el usuario acaba de tocar."""
    _write_dran_config(plugin, hermetic_dran_home, {"tools": {"tasks": True}})
    ctx = FakeCtx(config={"tools": {"tasks": False}})

    assert plugin._group_toggles(ctx)["tasks"] is True


def test_disabled_group_check_fn_hides_its_tools(plugin, hermetic_dran_home):
    """`check_fn` False = Hermes saca la tool del prompt Y del catálogo de tool_search."""
    ctx = FakeCtx()
    plugin.register(ctx)
    checks = {t["name"]: t["check_fn"] for t in ctx.tools}

    _write_dran_config(plugin, hermetic_dran_home, {"tools": {"pages": False}})
    assert checks["dran_create_page"]() is False
    assert checks["dran_create_task"]() is True

    # Encender de nuevo no necesita reiniciar nada: el veredicto es de la config.
    _write_dran_config(plugin, hermetic_dran_home, {"tools": {"pages": True}})
    assert checks["dran_create_page"]() is True


def test_group_check_fn_is_marked_uncached(plugin, monkeypatch):
    """Sin `no_cache_check_fn` Hermes serviría el último True por ~60 s tras apagar."""
    calls = []

    def no_cache_check_fn(fn):
        calls.append(fn)
        return fn

    fake_registry = types.ModuleType("tools.registry")
    setattr(fake_registry, "no_cache_check_fn", no_cache_check_fn)
    fake_tools = types.ModuleType("tools")
    fake_tools.__path__ = []
    monkeypatch.setitem(sys.modules, "tools", fake_tools)
    monkeypatch.setitem(sys.modules, "tools.registry", fake_registry)

    check = plugin._make_group_check("pages")

    assert calls == [check]
    assert check.__name__ == "dran_group_pages_enabled"


def test_disabled_group_refuses_the_call_before_the_client(plugin, hermetic_dran_home):
    """El dispatch de Hermes NO re-evalúa check_fn: el guard tiene que negarse solo.

    Un prompt congelado a mitad de sesión todavía conoce la tool, así que el
    único cierre real está en el handler — y antes de construir el cliente.
    """
    ctx = FakeCtx()
    plugin.register(ctx)
    handlers = {t["name"]: t["handler"] for t in ctx.tools}

    _write_dran_config(plugin, hermetic_dran_home, {"tools": {"pages": False, "tasks": True}})

    with mock.patch.object(plugin, "_client_for",
                           side_effect=AssertionError("no debe construir cliente")):
        out = json.loads(handlers["dran_create_page"]({"title": "x"}, ctx=ctx))

    assert out["group"] == "pages"
    assert "disabled" in out["error"]
    assert "dran_pages" in out["hint"]


def test_toggle_cache_follows_the_file(plugin, hermetic_dran_home):
    """El cache es por firma del archivo: editar el JSON cambia el veredicto."""
    path = _write_dran_config(plugin, hermetic_dran_home, {"tools": {"pages": False}})
    assert plugin._group_enabled("pages") is False

    path.write_text(json.dumps({"tools": {"pages": True}}), encoding="utf-8")
    future = time.time() + 5
    os.utime(path, (future, future))

    assert plugin._group_enabled("pages") is True
