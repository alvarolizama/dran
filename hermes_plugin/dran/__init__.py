"""Dran memory provider for Hermes.

Shared multi-agent memory store backed by a Dran workspace over its REST
API. The plugin is deliberately thin: dedupe, trust scoring, hybrid search
and fact extraction all live server-side (Dran). This module only handles
transport, identity, prefetch caching, tool plumbing and session ingest.

Contract: agent.memory_provider.MemoryProvider (Hermes).
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

from agent.memory_provider import MemoryProvider, RecallStatus

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "http://localhost:4000"
DEFAULT_WORKSPACE = "personal"
# Built-in page types — Dran keeps exactly FOUR. A workspace may ADD its own
# through `workspace_page_types`; the effective set (built-in ∪ custom) is
# served by `GET /api/agent/config` and discovered at runtime by
# `_effective_page_types()`. This tuple is the offline fallback only.
BUILTIN_PAGE_TYPES = ("note", "entity", "concept", "reference")
# Effective-type cache: workspace -> (monotonic timestamp, slug list).
_TYPE_CACHE: Dict[str, Any] = {}
# Canonical config path (what the dashboard's generic panel writes):
# $HERMES_HOME/dran/config.json — same convention as other memory providers.
# Legacy pre-schema installs kept it at $HERMES_HOME/dran_memory.json; still
# read as a fallback so nothing breaks on upgrade.
CONFIG_FILENAME = "dran_memory.json"
CANONICAL_CONFIG_DIR = "dran"
CANONICAL_CONFIG_FILENAME = "config.json"
# Single-source-of-truth credential: profile .env's DRAN_API_KEY, the same
# var the plugin resolves for its REST calls.
API_KEY_ENV_VAR = "DRAN_API_KEY"
REQUEST_TIMEOUT = 5.0
INGEST_TIMEOUT = 30.0
MAX_PREFETCH_CHARS = 800
MAX_INGEST_MESSAGES = 40
MAX_INGEST_CHARS = 12_000
# How often the auto-discovered agent config (memory workspace) is refreshed
# from the server, seconds. 0 = once per session (initialize).
CONFIG_REFRESH_SECS = 300
# Recall query depth: how many recent turns are concatenated into the
# search query. Short follow-ups ("and why?") recall nothing on their own.
RECALL_QUERY_TURNS = 3
# Circuit breaker: after N consecutive failures, sleep before retrying.
BREAKER_THRESHOLD = 3
BREAKER_COOLDOWN_SECS = 60.0
# HTTP retry (idempotent GETs only): attempts and backoff between them.
HTTP_RETRY_ATTEMPTS = 2
HTTP_RETRY_BACKOFF_SECS = 0.5
# Connected services (cliente delgado del REST /api/services). El connect link
# dura 10 minutos server-side; el wait es corto y acotado: NUNCA bloquea el turno
# más de SERVICE_WAIT_MAX_SECS y nunca duerme más que el cap.
SERVICE_WAIT_DEFAULT_SECS = 15.0
SERVICE_WAIT_MAX_SECS = 30.0
SERVICE_WAIT_POLL_SECS = 2.0
# Ingest cursor state file (per profile): session_id -> messages digested.
INGEST_CURSOR_FILE = "dran_memory_cursor.json"


def _default_config() -> dict:
    return {
        "base_url": DEFAULT_BASE_URL,
        "api_key": "",
        "workspace": DEFAULT_WORKSPACE,
        "auto_recall": True,
        "auto_capture": True,
        "max_recall_results": 5,
        "max_recall_chars": 800,
        "recall_cadence": 1,
    }


def _resolve_secret() -> str:
    """Resolve DRAN_API_KEY from the active profile's secret scope.

    Hermes loads the ACTIVE PROFILE's .env at startup (load_hermes_dotenv
    runs before plugins are discovered). Under a multiplexing gateway
    get_secret resolves the routed profile's scope and never falls through
    to os.environ; otherwise it degrades to os.environ (single-profile
    deployments inject credentials via the process env — systemd, op run).
    """
    try:
        from agent.secret_scope import get_secret
        val = get_secret(API_KEY_ENV_VAR, "")
    except Exception:
        val = os.environ.get(API_KEY_ENV_VAR, "")
    return (val or "").strip()


def _config_paths(hermes_home: str) -> list:
    """Config candidates, most canonical first."""
    home = Path(hermes_home)
    return [
        home / CANONICAL_CONFIG_DIR / CANONICAL_CONFIG_FILENAME,
        home / CONFIG_FILENAME,
    ]


def _read_raw_config(hermes_home: str) -> dict:
    """Config as stored on disk — NO secret resolution (round-trip safe)."""
    config = _default_config()
    for path in _config_paths(hermes_home):
        if not path.exists():
            continue
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                config.update({k: v for k, v in raw.items() if v is not None})
            break  # first existing file wins
        except Exception:
            logger.debug("Failed to parse %s", path, exc_info=True)
    return config


def _load_dran_config(hermes_home: str) -> dict:
    config = _read_raw_config(hermes_home)

    config["base_url"] = str(config.get("base_url") or DEFAULT_BASE_URL).strip().rstrip("/")
    # Single-source-of-truth for the credential: omit api_key (or leave the
    # ${DRAN_API_KEY} placeholder) and it resolves from the profile .env —
    # the same var the plugin resolves. A literal
    # key in the JSON still wins (per-agent overrides).
    api_key = str(config.get("api_key") or "").strip()
    if api_key in ("", "${DRAN_API_KEY}", "${env:DRAN_API_KEY}"):
        api_key = _resolve_secret()
    config["api_key"] = api_key
    # W5 (single-workspace): the value is informational only — Dran decides
    # nothing by it and the plugin sends it nowhere. Kept so old config files
    # load without edits.
    config["workspace"] = str(config.get("workspace") or DEFAULT_WORKSPACE).strip()
    # El destino por defecto del perfil: los campos «Write scope» / «Group slug»
    # del panel se guardan en el MISMO config.json que el runtime lee, así que
    # acá se normalizan (vocabulario cerrado) y el cliente los usa en las ALTAS.
    scope = str(config.get("scope") or "private").strip().lower()
    config["scope"] = scope if scope in ("private", "public", "group") else "private"
    config["scope_group"] = str(config.get("scope_group") or "").strip()
    config["auto_recall"] = bool(config.get("auto_recall", True))
    config["auto_capture"] = bool(config.get("auto_capture", True))
    try:
        config["max_recall_results"] = max(1, min(20, int(config.get("max_recall_results", 5))))
    except (TypeError, ValueError):
        config["max_recall_results"] = 5
    try:
        config["max_recall_chars"] = max(100, int(config.get("max_recall_chars", 800)))
    except (TypeError, ValueError):
        config["max_recall_chars"] = 800
    try:
        config["recall_cadence"] = max(1, min(10, int(config.get("recall_cadence", 1))))
    except (TypeError, ValueError):
        config["recall_cadence"] = 1
    return config


def _save_dran_config(values: dict, hermes_home: str) -> None:
    # Round-trip through the RAW on-disk config: _load_dran_config resolves
    # DRAN_API_KEY from the profile's secret scope, and persisting that
    # resolved value would copy the secret into plaintext JSON — breaking
    # the single-source-of-truth (.env stays the only home of the key).
    config_path = _config_paths(hermes_home)[0]
    existing = _read_raw_config(hermes_home)
    existing.update({k: v for k, v in (values or {}).items() if v is not None})
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(existing, indent=2), encoding="utf-8")


class _DranClient:
    """Minimal REST client for Dran's /api/memory endpoints.

    Idempotent GETs get one retry with short backoff; everything tracks a
    per-instance circuit breaker (after BREAKER_THRESHOLD consecutive
    failures all calls fast-fail until the cooldown elapses) so a down
    Dran doesn't add a timeout to every turn.
    """

    def __init__(self, base_url: str, api_key: str, workspace: str = "",
                 agent_identity: str = "", timeout: float = REQUEST_TIMEOUT,
                 default_scope: str = "private", default_group: str = ""):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        # El destino por defecto del PERFIL (panel: «Write scope» / «Group slug»).
        # Lo usan SÓLO las altas: una edición sin `scope` no mueve el destino
        # (el servidor sólo re-traduce cuando la petición lo declara).
        self.default_scope = (default_scope or "private").strip().lower()
        self.default_group = (default_group or "").strip()
        self.workspace = workspace
        self.agent_identity = agent_identity
        self.timeout = timeout
        self._failures = 0
        self._breaker_open_until = 0.0

    def _headers(self) -> Dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if self.agent_identity:
            headers["X-Hermes-Agent"] = self.agent_identity
        return headers

    def _breaker_allows(self) -> bool:
        return time.monotonic() >= self._breaker_open_until

    def _record_success(self) -> None:
        self._failures = 0
        self._breaker_open_until = 0.0

    def _record_failure(self) -> None:
        self._failures += 1
        if self._failures >= BREAKER_THRESHOLD:
            self._breaker_open_until = time.monotonic() + BREAKER_COOLDOWN_SECS
            logger.warning("Dran circuit breaker open for %.0fs after %d failures",
                           BREAKER_COOLDOWN_SECS, self._failures)

    def request(self, method: str, path: str, payload: Any = None,
                timeout: float | None = None) -> Any:
        if not self._breaker_allows():
            raise ConnectionError("dran unreachable (circuit breaker open)")

        attempts = HTTP_RETRY_ATTEMPTS if method.upper() == "GET" else 1
        last_exc: Exception | None = None

        for attempt in range(attempts):
            try:
                return self._request_once(method, path, payload, timeout)
            except urllib.error.HTTPError as exc:
                # 4xx (except 429) is the server answering — retrying won't
                # change the answer. Surface it; the 409 near-duplicate
                # handling lives in add_memory.
                if 400 <= exc.code < 500 and exc.code != 429:
                    self._record_success()
                    raise
                last_exc = exc
                self._record_failure()
            except Exception as exc:
                last_exc = exc
                self._record_failure()

            if attempt + 1 < attempts:
                time.sleep(HTTP_RETRY_BACKOFF_SECS * (attempt + 1))

        assert last_exc is not None
        raise last_exc

    def _request_once(self, method: str, path: str, payload: Any,
                      timeout: float | None) -> Any:
        url = f"{self.base_url}{path}"
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(url, data=body, method=method,
                                     headers=self._headers())
        with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
            raw = resp.read().decode("utf-8")
        self._record_success()
        if not raw:
            return {}
        return json.loads(raw)

    # -- Memory endpoints ------------------------------------------------

    def add_memory(self, content: str, source_session: str = "", force: bool = False) -> dict:
        payload: Dict[str, Any] = {"content": content}
        if source_session:
            payload["source_session"] = source_session
        if force:
            payload["force"] = True
        try:
            return self.request("POST", "/api/memory", payload)
        except urllib.error.HTTPError as exc:
            if exc.code == 409:
                # Near-duplicate grey zone: Dran returns the stored fact +
                # the submitted text so the agent can decide (update/force).
                raw = exc.read().decode("utf-8", "replace")
                try:
                    return json.loads(raw)
                except ValueError:
                    raise
            raise

    def update_memory(self, memory_id: str, content: str) -> dict:
        """Rewrite a fact in place; trust/feedback counters are preserved."""
        return self.request("PATCH", f"/api/memory/{memory_id}", {
            "content": content, 
        })

    def search(self, query: str, limit: int = 5) -> list:
        from urllib.parse import urlencode
        qs = urlencode({"q": query, "limit": limit})
        data = self.request("GET", f"/api/memory/search?{qs}")
        return data.get("data", [])

    # -- Knowledge endpoints (used by the plugin tools) ------------------

    def search_pages(self, query: str, strategy: str = "auto", limit: int = 10) -> list:
        from urllib.parse import urlencode
        qs = urlencode({"q": query, 
                        "strategy": strategy, "limit": limit})
        try:
            data = self.request("GET", f"/api/search?{qs}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return []  # no results
            raise
        return data.get("data", []) if isinstance(data, dict) else []

    def list_pages(self, page_type: str = "", limit: int = 20) -> list:
        from urllib.parse import urlencode
        params = {"limit": limit}
        if page_type:
            params["type"] = page_type
        data = self.request("GET", f"/api/knowledge-pages?{urlencode(params)}")
        return data.get("data", []) if isinstance(data, dict) else []

    def list_page_types(self) -> dict:
        """Effective page types of the instance (built-in ∪ custom) with their
        full definitions. W5: Dran is single-workspace — any legacy slug path
        answers the instance, so the configured value only names the call."""
        from urllib.parse import quote
        slug = quote(str(self.workspace or "instance"), safe="")
        try:
            data = self.request("GET", f"/api/workspaces/{slug}/page-types")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return {"page_types": [], "page_type_defs": []}
            raise
        payload = data.get("data") if isinstance(data, dict) else None
        if not isinstance(payload, dict):
            return {"page_types": [], "page_type_defs": []}
        return payload

    def get_page(self, slug: str) -> Optional[dict]:
        from urllib.parse import urlencode
        qs = urlencode({"include": "body"})
        try:
            data = self.request("GET", f"/api/knowledge-pages/{slug}?{qs}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        return data.get("data") if isinstance(data, dict) else None

    def create_page(self, title: str, body: str = "", page_type: str = "note",
                    tags: Optional[List[str]] = None, summary: str = "",
                    meta: Optional[dict] = None,
                    visibility: str = "private") -> dict:
        payload: Dict[str, Any] = {
            "title": title, "body": body,
            "page_type": page_type,
            # Per-item visibility: private (default) | public | shared.
            # Memories are NOT settable here — Dran rejects the param (422).
            "visibility": visibility,
        }
        if tags:
            payload["tags"] = tags
        if summary:
            payload["summary"] = summary
        if meta:
            payload["meta"] = meta
        return self.request("POST", "/api/knowledge-pages", payload)

    def update_page(self, slug: str, **fields: Any) -> dict:
        from urllib.parse import urlencode
        payload = {k: v for k, v in fields.items() if v is not None}
        return self.request("PUT", f"/api/knowledge-pages/{slug}",
                            payload)

    def delete_page(self, slug: str) -> bool:
        from urllib.parse import urlencode
        try:
            self.request("DELETE",
                         f"/api/knowledge-pages/{slug}")
            return True
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return False
            raise

    def get_links(self, slug: str) -> dict:
        from urllib.parse import urlencode
        try:
            data = self.request("GET", f"/api/knowledge-pages/{slug}/links")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return {}
            raise
        return data.get("data", data) if isinstance(data, dict) else {}

    def create_relation(self, source_slug: str, target_slug: str, relation_type: str = "related",
                        description: str = "") -> dict:
        payload: Dict[str, Any] = {
            "source_slug": source_slug,
            "target_slug": target_slug, "relation_type": relation_type,
        }
        if description:
            payload["description"] = description
        return self.request("POST", "/api/relations", payload)

    def delete_relation(self, source_slug: str, target_slug: str,
                        relation_type: str = "") -> bool:
        from urllib.parse import urlencode
        params = {"source_slug": source_slug,
                  "target_slug": target_slug}
        if relation_type:
            params["relation_type"] = relation_type
        try:
            self.request("DELETE", f"/api/relations?{urlencode(params)}")
            return True
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return False
            raise

    def lint_brain(self) -> dict:
        from urllib.parse import urlencode
        data = self.request("GET", f"/api/lint")
        return data.get("data", data) if isinstance(data, dict) else {}

    def rename_slug(self, slug: str, new_slug: str) -> dict:
        from urllib.parse import urlencode
        return self.request(
            "POST",
            f"/api/knowledge-pages/{slug}/rename",
            {"new_slug": new_slug},
        )

    def reaugment_page(self, slug: str) -> dict:
        from urllib.parse import urlencode
        return self.request(
            "POST",
            f"/api/knowledge-pages/{slug}/reaugment",
        )

    def generate_cluster_summaries(self) -> dict:
        return self.request("POST", "/api/cluster-summaries", {})

    def start_worker(self, worker_type: str, input: str = "") -> dict:
        payload = {"worker_type": worker_type, "input": input}
        return self.request("POST", "/api/workers", payload)

    def get_worker_session(self, session_id: str) -> Optional[dict]:
        from urllib.parse import urlencode
        try:
            data = self.request(
                "GET",
                f"/api/workers/{session_id}",
            )
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        return data.get("data") if isinstance(data, dict) else None

    # -- Goals / Tasks / Plans (W2, contrato de superficies) --------------
    #
    # Transporte delgado del REST nuevo: el destino de una escritura viaja como
    # `scope` (mismo vocabulario que la API: "private" | "public" | un grupo por
    # su slug) y NUNCA como estado del cliente. El uuid es la dirección canónica
    # y el slug el atajo legible: los dos viajan en el mismo segmento.

    def _goal_scope(self, scope: str = "", group: str = "", use_default: bool = False) -> Any:
        """El `scope` de la API: string, o `{"group": slug}` cuando hay grupo.

        La declaración de la HERRAMIENTA se toma como un todo: si trae `scope` o
        `group`, eso manda y el default del perfil no se mezcla. El default
        (`self.default_scope` / `self.default_group`, del panel) aplica SÓLO
        cuando la herramienta no declara destino — y sólo en las ALTAS
        (`use_default=True`). Un `group` declarado gana sobre el string, y un
        grupo sin slug NO cae a `private` en silencio: viaja como está y el
        servidor lo rechaza (422, W6/P20).
        """
        scope = (scope or "").strip()
        group = (group or "").strip()

        if not scope and not group and use_default:
            scope, group = self.default_scope, self.default_group

        if group:
            return {"group": group}
        return scope or None

    def list_groups(self) -> list:
        """Los grupos del dueño de la credencial: `[{slug, name}]`.

        Es lo que permite elegir el destino por NOMBRE (`GET /api/groups` devuelve
        las membresías del lector, no el catálogo de la instancia) y después
        escribir con `group=<slug>`.
        """
        data = self.request("GET", "/api/groups")
        return data.get("data", []) if isinstance(data, dict) else []

    def list_goals(self, status: str = "", limit: int = 50) -> list:
        from urllib.parse import urlencode
        params: Dict[str, Any] = {"limit": limit}
        if status:
            params["status"] = status
        data = self.request("GET", f"/api/goals?{urlencode(params)}")
        return data.get("data", []) if isinstance(data, dict) else []

    def get_goal(self, goal_id: str) -> Optional[dict]:
        try:
            data = self.request("GET", f"/api/goals/{goal_id}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        return data.get("data") if isinstance(data, dict) else None

    def create_goal(self, title: str, **fields: Any) -> dict:
        payload = {"title": title}
        payload.update({k: v for k, v in fields.items() if v is not None and v != ""})
        return self.request("POST", "/api/goals", payload)

    def update_goal(self, goal_id: str, **fields: Any) -> dict:
        payload = {k: v for k, v in fields.items() if v is not None}
        return self.request("PUT", f"/api/goals/{goal_id}", payload)

    def delete_goal(self, goal_id: str) -> bool:
        try:
            self.request("DELETE", f"/api/goals/{goal_id}")
            return True
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return False
            raise

    def list_goal_tasks(self, goal_id: str) -> list:
        try:
            data = self.request("GET", f"/api/goals/{goal_id}/tasks")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return []
            raise
        return data.get("data", []) if isinstance(data, dict) else []

    def list_tasks(self, goal: str = "", status: str = "", limit: int = 100) -> list:
        from urllib.parse import urlencode
        params: Dict[str, Any] = {"limit": limit}
        if goal:
            params["goal"] = goal
        if status:
            params["status"] = status
        data = self.request("GET", f"/api/tasks?{urlencode(params)}")
        return data.get("data", []) if isinstance(data, dict) else []

    def get_task(self, task_id: str) -> Optional[dict]:
        try:
            data = self.request("GET", f"/api/tasks/{task_id}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        return data.get("data") if isinstance(data, dict) else None

    def create_task(self, title: str, **fields: Any) -> dict:
        payload = {"title": title}
        payload.update({k: v for k, v in fields.items() if v is not None and v != ""})
        return self.request("POST", "/api/tasks", payload)

    def capture(self, title: str, **fields: Any) -> dict:
        """Captura rápida: sin `goal`, el servidor la manda a la bandeja."""
        payload = {"title": title}
        payload.update({k: v for k, v in fields.items() if v is not None and v != ""})
        return self.request("POST", "/api/capture", payload)

    def update_task(self, task_id: str, **fields: Any) -> dict:
        payload = {k: v for k, v in fields.items() if v is not None}
        return self.request("PUT", f"/api/tasks/{task_id}", payload)

    def move_task(self, task_id: str, **fields: Any) -> dict:
        """Columna y/o goal: la ÚNICA puerta del move (respeta lock_version)."""
        payload = {k: v for k, v in fields.items() if v is not None}
        return self.request("POST", f"/api/tasks/{task_id}/move", payload)

    def delete_task(self, task_id: str) -> bool:
        try:
            self.request("DELETE", f"/api/tasks/{task_id}")
            return True
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return False
            raise

    def list_plans(self, status: str = "", limit: int = 50) -> list:
        from urllib.parse import urlencode
        params: Dict[str, Any] = {"limit": limit}
        if status:
            params["status"] = status
        data = self.request("GET", f"/api/plans?{urlencode(params)}")
        return data.get("data", []) if isinstance(data, dict) else []

    def get_plan(self, plan_id: str) -> Optional[dict]:
        try:
            data = self.request("GET", f"/api/plans/{plan_id}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        if not isinstance(data, dict):
            return None
        plan = data.get("data")
        if isinstance(plan, dict) and data.get("progress") is not None:
            plan = dict(plan)
            plan["progress"] = data["progress"]
        return plan

    def create_plan(self, title: str, **fields: Any) -> dict:
        payload = {"title": title}
        payload.update({k: v for k, v in fields.items() if v is not None and v != ""})
        return self.request("POST", "/api/plans", payload)

    def update_plan(self, plan_id: str, **fields: Any) -> dict:
        payload = {k: v for k, v in fields.items() if v is not None}
        return self.request("PUT", f"/api/plans/{plan_id}", payload)

    def set_plan_checklist(self, plan_id: str, items: Any,
                           lock_version: Any = None) -> dict:
        payload: Dict[str, Any] = {"checklist": items}
        if lock_version is not None:
            payload["lock_version"] = lock_version
        return self.request("PUT", f"/api/plans/{plan_id}/checklist", payload)

    def toggle_checklist(self, target: str, resource_id: str,
                         index: Any = None, text: str = "",
                         lock_version: Any = None) -> dict:
        """La MISMA puerta para los dos contenedores (plan y task)."""
        payload: Dict[str, Any] = {"target": target, "id": resource_id}
        if index is not None:
            payload["index"] = index
        if text:
            payload["text"] = text
        if lock_version is not None:
            payload["lock_version"] = lock_version
        return self.request("POST", "/api/checklist/toggle", payload)

    def delete_plan(self, plan_id: str) -> bool:
        try:
            self.request("DELETE", f"/api/plans/{plan_id}")
            return True
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return False
            raise

    def stats(self) -> dict:
        data = self.request("GET", "/api/workspaces")
        return data.get("data", data) if isinstance(data, dict) else {}

    def feedback(self, memory_id: str, helpful: bool) -> dict:
        return self.request("POST", "/api/memory/feedback", {
            "id": memory_id, "helpful": helpful, 
        })

    def ingest(self, transcript: str, source_session: str = "") -> dict:
        payload = {"transcript": transcript}
        if source_session:
            payload["source_session"] = source_session
        return self.request("POST", "/api/memory/ingest", payload,
                            timeout=INGEST_TIMEOUT)

    def ping(self) -> bool:
        try:
            self.request("GET", "/api/workspaces", timeout=3.0)
            return True
        except Exception:
            return False

    def agent_config(self, timeout: float = 3.0) -> Optional[dict]:
        """GET /api/agent/config — the agent's server-side self-description.

        Returns {agent, workspaces, page_types, access_levels} for an agent
        API key, None otherwise (older Dran, non-agent key, or transport
        failure — callers fall back to unvalidated local config).

        Each workspace carries its EFFECTIVE page types (`page_types`, string
        slugs) and their full definitions (`page_type_defs`: slug, label,
        plural, path, icon, color, meta_fields, builtin) — built-ins first,
        then the workspace's custom types. `page_types` at the top level is
        the union across every workspace the key reaches. The plugin reads
        them instead of hardcoding the type list.
        """
        try:
            data = self.request("GET", "/api/agent/config", timeout=timeout)
            return data.get("data") or None
        except Exception:
            return None

    # -- Services endpoints (cliente delgado del REST /api/services) ------
    #
    # El catálogo de toolkits viaja como DATO: el plugin NO registra una tool
    # por toolkit. Estas llamadas son transporte puro — toda la lógica (qué
    # toolkit, qué tool, la conexión OAuth) vive server-side. La identidad es
    # la credencial: NUNCA viaja un user_id ni un session_id en el body.

    def list_services(self) -> dict:
        """GET /api/services -> {"configured": bool, "data": [...]}.

        `status` es ACTIVE | INITIALIZING | INITIATED | EXPIRED | INACTIVE,
        o null cuando nunca se conectó; `identity` puede ser null. Sin key
        de Composio el server responde {"configured": false, "data": []}.
        """
        data = self.request("GET", "/api/services")
        return data if isinstance(data, dict) else {}

    def connect_service(self, toolkit: str) -> dict:
        """POST /api/services/:toolkit/connect -> el link hosted (redirect_url).

        El link dura 10 minutos: vencido se pide uno NUEVO, nunca se reintenta.
        """
        from urllib.parse import quote
        seg = quote(str(toolkit or "").strip(), safe="")
        return self.request("POST", f"/api/services/{seg}/connect", {})

    def list_service_tools(self, toolkit: str, slug: str = "") -> Optional[dict]:
        """GET /api/services/:toolkit/tools[?slug=…] -> catálogo de tools.

        Sin `slug`, la lista liviana (slug, name, description). Con `slug`,
        la tool completa (input_parameters, output_parameters).
        """
        from urllib.parse import quote, urlencode
        seg = quote(str(toolkit or "").strip(), safe="")
        path = f"/api/services/{seg}/tools"
        if slug:
            path += "?" + urlencode({"slug": slug})
        data = self.request("GET", path)
        return data.get("data") if isinstance(data, dict) else None

    def search_service_tools(self, use_case: str) -> Optional[dict]:
        """GET /api/services/search?q=… -> búsqueda por caso de uso."""
        from urllib.parse import urlencode
        qs = urlencode({"q": use_case})
        data = self.request("GET", f"/api/services/search?{qs}")
        return data.get("data") if isinstance(data, dict) else None

    def execute_service(self, toolkit: str, tool_slug: str, arguments: Any) -> dict:
        """POST /api/services/execute -> corre una tool del toolkit.

        Fail-closed: cuando el toolkit no está ACTIVE el server responde 409
        {"errors": {"code": "not_connected"}, "connect_url": …} y el handler
        devuelve ese link (nunca simula éxito).
        """
        return self.request("POST", "/api/services/execute", {
            "toolkit": toolkit,
            "tool_slug": tool_slug,
            "arguments": arguments if isinstance(arguments, dict) else {},
        })


def _services_line(payload: Any) -> str:
    """Una línea compacta del inventario: estado + identidad del proveedor.

    Ej. "Dran services: gmail ACTIVE (alvaro@gmail.com), github not connected".
    Sin secretos y sin ids crudos de vendor (`trs_…`, `ca_…`, `ac_…`): sólo el
    toolkit, su estado y la identidad que el usuario reconoce. Devuelve "" sin
    key configurada (el server responde configured:false) o sin servicios.
    """
    if not isinstance(payload, dict) or not payload.get("configured"):
        return ""
    parts: List[str] = []
    for svc in payload.get("data") or []:
        if not isinstance(svc, dict):
            continue
        toolkit = str(svc.get("toolkit") or "").strip()
        if not toolkit:
            continue
        label = str(svc.get("status") or "").strip().upper()
        identity = svc.get("identity")
        if bool(svc.get("connected")) and label == "ACTIVE":
            piece = f"{toolkit} ACTIVE"
            if identity:
                piece += f" ({identity})"
        elif label:
            piece = f"{toolkit} {label.lower()}"
        else:
            piece = f"{toolkit} not connected"
        parts.append(piece)
    if not parts:
        return ""
    return "Dran services: " + ", ".join(parts)


class DranMemoryProvider(MemoryProvider):
    """Hermes memory provider backed by a Dran workspace."""

    def __init__(self):
        self._config: Dict[str, Any] = {}
        self._client: _DranClient | None = None
        self._session_id = ""
        self._agent_identity = ""
        self._agent_context = "primary"
        self._prefetch_lock = threading.Lock()
        self._prefetch_cache: str = ""
        self._prefetch_count = 0
        self._worker: threading.Thread | None = None
        # Recall efficiency: turn counter (cadence) + fingerprint of the
        # last injected fact set (skip re-injecting identical context).
        # The counter starts armed (huge) so the FIRST recall always fires;
        # prefetch resets it to 0 after each actual injection.
        self._turns_since_inject = 1_000_000
        self._last_injected_ids: frozenset = frozenset()
        self._last_search_query = ""

    # -- Core lifecycle ----------------------------------------------------

    @property
    def name(self) -> str:
        return "dran"

    def is_available(self) -> bool:
        self._config = _load_dran_config(self._hermes_home())
        return bool(self._config.get("api_key"))

    def unavailable_reason(self) -> str:
        return ("Dran memory is not configured — set api_key (and optionally "
                "base_url / workspace) via `hermes memory setup` or "
                f"$HERMES_HOME/{CANONICAL_CONFIG_DIR}/{CANONICAL_CONFIG_FILENAME}")

    # -- Config surface (dashboard panel + `hermes memory setup`) -------------

    def get_config_schema(self):
        return [
            {"key": "api_key", "description": "Dran API key per agent (Settings → API Keys → Create key)", "secret": True},
            {"key": "base_url", "description": "Dran instance URL", "default": DEFAULT_BASE_URL},
            {"key": "workspace", "description": "Workspace used by both the memory provider and the knowledge tools (pages/relations/workers); must be reachable by the key", "default": DEFAULT_WORKSPACE},
            {"key": "auto_recall", "description": "Inject relevant memories at turn start", "default": "true", "choices": ["true", "false"]},
            {"key": "auto_capture", "description": "Ingest transcript at session end", "default": "true", "choices": ["true", "false"]},
            {"key": "max_recall_results", "description": "Memories injected per turn (1-20)", "default": "5", "type": "integer", "minimum": 1, "maximum": 20},
            {"key": "max_recall_chars", "description": "Max chars of memory context injected per turn", "default": "800", "type": "integer", "minimum": 100},
            {"key": "recall_cadence", "description": "Min turns between recall searches (1 = every turn)", "default": "1", "type": "integer", "minimum": 1, "maximum": 10},
        ]

    def save_config(self, values, hermes_home):
        """Write non-secret setup values to the canonical dran config."""
        _save_dran_config(values or {}, hermes_home)

    def initialize(self, session_id: str, **kwargs) -> None:
        self._session_id = session_id
        self._agent_identity = str(kwargs.get("agent_identity") or "")
        self._agent_context = str(kwargs.get("agent_context") or "primary")
        self._config = _load_dran_config(kwargs.get("hermes_home") or self._hermes_home())
        self._client = _DranClient(
            self._config["base_url"],
            self._config["api_key"],
            self._config["workspace"],
            agent_identity=self._agent_identity,
            default_scope=self._config["scope"],
            default_group=self._config["scope_group"],
        )
        # The memory workspace is a LOCAL choice (dran_memory.json). The
        # background probe validates it against the server: if the key cannot
        # reach it (revoked matrix edit), fall back to the first permitted
        # workspace so memory keeps working instead of silently failing.
        self._workspace_resolved_at = 0.0
        # Validate connection in the background — never block agent startup.
        threading.Thread(target=self._probe_connection, daemon=True).start()

    def _resolve_workspace(self, force: bool = False) -> None:
        """Validate the local workspace choice against the agent's key.

        The choice itself is made in Hermes (dran_memory.json); Dran only
        defines which workspaces the key may reach. If the configured
        workspace is not among them, fall back to the first permitted one
        and log it loudly.
        """
        if not self._client:
            return
        now = time.monotonic()
        if not force and now - self._workspace_resolved_at < CONFIG_REFRESH_SECS:
            return
        self._workspace_resolved_at = now
        config = self._client.agent_config()
        if not config:
            self._workspace_resolved_at = 0.0  # retry next turn — server unreachable
            return
        allowed = _workspace_slugs(config)
        current = self._client.workspace
        if current in allowed:
            return  # local choice is permitted — done
        fallback = allowed[0] if allowed else current
        self._client.workspace = fallback
        logger.warning(
            "Dran memory: workspace %r is not permitted for this key "
            "(allowed: %s) — falling back to %r. Fix it in Dran → Settings → "
            "API Keys or pin another workspace in dran_memory.json",
            current, ", ".join(allowed) or "none", fallback,
        )

    def _probe_connection(self) -> None:
        if not self._client:
            return
        ok = self._client.ping()
        if ok:
            self._resolve_workspace(force=True)
            logger.info("Dran memory: connected to %s (workspace=%s, agent=%s)",
                        self._config["base_url"], self._client.workspace,
                        self._agent_identity or "?")
        else:
            logger.warning("Dran memory: cannot reach %s — recall/capture disabled this session",
                           self._config["base_url"])

    # -- System prompt + prefetch -------------------------------------------

    def system_prompt_block(self) -> str:
        return (
            "Shared memory: a Dran workspace stores durable facts shared by all "
            "your agents. Relevant memories are injected automatically at turn "
            "start. When the user states a durable fact (decision, preference, "
            "project fact), offer to store it with dran_memory_add. "
            "Rate a memory helpful/unhelpful with dran_memory_feedback. "
            "Connected services: the user's mail, calendar, issues/pull requests, "
            "chat messages and files are reachable through the dran_services tools "
            "once they connect. Connecting a service returns a link you paste for "
            "the user as a markdown link. The current inventory is injected "
            "automatically at turn start — do not poll for it."
        )

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if not (self._config.get("auto_recall") and self._client and query and query.strip()):
            return

        # Cadence (Honcho-style): skip the SEARCH itself on off-turns — an
        # unchanged query would return the same facts anyway. The counter
        # resets on every actual injection (prefetch).
        cadence = max(1, int(self._config.get("recall_cadence", 1) or 1))
        self._turns_since_inject += 1
        if self._turns_since_inject < cadence:
            return
        if self._worker and self._worker.is_alive():
            return  # a recall is already in flight — skip, next turn will retry

        self._last_injected = 0  # a new recall cycle starts

        # Multi-turn query: short follow-ups ("and why?") recall nothing on
        # their own; concatenating recent turns gives the search context.
        # The raw query is the user's new message; this provider keeps no
        # message history, so the caller-provided query is enriched with the
        # last completed search query (stable conversational thread).
        enriched = self._enrich_query(query.strip())

        client = self._client
        last_query = enriched

        def work():
            try:
                # cheap refresh window — picks up server-side workspace edits
                self._resolve_workspace()
                results = client.search(enriched,
                                        limit=self._config["max_recall_results"])
                text, injected_ids = self._format_results(results)
                # Inventario de servicios: MISMA pasada y MISMA cadencia que la
                # memoria — a lo sumo un GET /api/services por ventana de
                # prefetch, nunca uno por turno ni en el camino crítico del turno.
                try:
                    services_line = _services_line(client.list_services())
                except Exception:
                    services_line = ""
                if services_line:
                    text = f"{text}\n{services_line}" if text else services_line
                    # Si cambia el inventario, se re-inyecta aunque el set de
                    # hechos sea idéntico.
                    injected_ids = injected_ids | {f"__services__:{services_line}"}
                with self._prefetch_lock:
                    self._prefetch_cache = text
                    self._prefetch_count = len(results)
                    self._prefetch_ids = injected_ids
                self._last_search_query = last_query
            except Exception:
                logger.debug("Dran prefetch failed", exc_info=True)

        self._worker = threading.Thread(target=work, daemon=True)
        self._worker.start()

    def _enrich_query(self, query: str) -> str:
        parts = []
        prev = getattr(self, "_last_search_query", "")
        if prev:
            parts.append(prev)
        parts.append(query)
        enriched = " ".join(parts)
        # Keep the NEW message dominant: truncate from the front.
        return enriched[-300:]

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        with self._prefetch_lock:
            cached = self._prefetch_cache
            injected_ids = getattr(self, "_prefetch_ids", frozenset())
            # Recall contract: recall_status must reflect ONLY the LAST
            # prefetch — keep the count after consuming the cache.
            self._last_injected = self._prefetch_count
            self._prefetch_cache = ""
            self._prefetch_count = 0
            self._prefetch_ids = frozenset()

        self._turns_since_inject = 0

        # Injected-set dedupe: if the fact set is identical to what the
        # previous turn already received, skip re-injecting — pure token
        # savings, the agent already has this context.
        if cached and injected_ids and injected_ids == self._last_injected_ids:
            logger.debug("Dran recall: fact set unchanged, skipping injection")
            self._last_injected = 0
            return ""

        if injected_ids:
            self._last_injected_ids = injected_ids

        return cached or ""

    def recall_status(self) -> Optional[RecallStatus]:
        count = getattr(self, "_last_injected", 0)
        if count <= 0:
            return None
        return RecallStatus(provider_label="dran", count=count)

    # -- Tools ---------------------------------------------------------------

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return [
            {
                "name": "dran_memory_search",
                "description": "Search the shared Dran memory for durable facts about the user's projects, preferences and decisions.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Natural-language query"}
                    },
                    "required": ["query"],
                },
            },
            {
                "name": "dran_memory_add",
                "description": "Store a durable, atomic fact in the shared Dran memory. One fact per call, self-contained sentence. On a near-duplicate (HTTP 409) the fact is NOT stored: either refine the existing fact with dran_memory_update, or re-call with force=true when it is genuinely a different fact.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "content": {"type": "string", "description": "The fact, one standalone sentence"},
                        "force": {"type": "boolean", "description": "Store even when a near-duplicate (0.88-0.95 similarity) exists. Only after reviewing the near-duplicate."},
                    },
                    "required": ["content"],
                },
            },
            {
                "name": "dran_memory_update",
                "description": "Rewrite an existing memory in place — trust score and feedback history are preserved. Preferred over storing a near-duplicate as a new fact: when a stored fact needs refinement or correction, update it.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "memory_id": {"type": "string"},
                        "content": {"type": "string", "description": "The corrected fact, one standalone sentence"},
                    },
                    "required": ["memory_id", "content"],
                },
            },
            {
                "name": "dran_memory_feedback",
                "description": "Rate a memory as helpful or unhelpful (trains its trust score).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "memory_id": {"type": "string"},
                        "helpful": {"type": "boolean"},
                    },
                    "required": ["memory_id", "helpful"],
                },
            },
        ]

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        try:
            if tool_name == "dran_memory_search":
                query = str((args or {}).get("query", "")).strip()
                if not query:
                    return json.dumps({"error": "query is required"})
                results = self._client.search(query, limit=10) if self._client else []
                return json.dumps({"results": [
                    {"id": r.get("id"), "content": r.get("content"),
                     "score": r.get("score"), "created_by": r.get("created_by")}
                    for r in results
                ]})

            if tool_name == "dran_memory_add":
                args = args or {}
                content = str(args.get("content", "")).strip()
                force = bool(args.get("force", False))
                if not content:
                    return json.dumps({"error": "content is required"})
                if self._agent_context != "primary":
                    return json.dumps({"error": "memory writes are disabled in this context"})
                if not self._config.get("auto_capture"):
                    return json.dumps({"skipped": "auto_capture disabled"})
                data = self._client.add_memory(
                    content, source_session=self._session_id, force=force,
                ) if self._client else {}
                if data.get("near_duplicate"):
                    existing = data.get("data") or {}
                    return json.dumps({
                        "stored": False,
                        "near_duplicate": True,
                        "existing_id": existing.get("id"),
                        "existing_content": existing.get("content"),
                        "submitted": data.get("submitted"),
                        "hint": "refine with dran_memory_update(existing_id, merged content) "
                                "or re-add with force=true if genuinely different",
                    })
                dup = bool(data.get("duplicate"))
                memory = data.get("data") or {}
                return json.dumps({
                    "stored": True,
                    "duplicate": dup,
                    "id": memory.get("id"),
                    "note": "fact already existed" if dup else "fact stored",
                })

            if tool_name == "dran_memory_update":
                memory_id = str((args or {}).get("memory_id", ""))
                content = str((args or {}).get("content", "")).strip()
                if not memory_id or not content:
                    return json.dumps({"error": "memory_id and content are required"})
                if self._agent_context != "primary":
                    return json.dumps({"error": "memory writes are disabled in this context"})
                data = self._client.update_memory(memory_id, content) if self._client else {}
                memory = data.get("data") or {}
                return json.dumps({
                    "updated": True,
                    "id": memory.get("id"),
                    "content": memory.get("content"),
                    "trust_score": memory.get("trust_score"),
                })

            if tool_name == "dran_memory_feedback":
                memory_id = str((args or {}).get("memory_id", ""))
                helpful = bool((args or {}).get("helpful", True))
                if not memory_id:
                    return json.dumps({"error": "memory_id is required"})
                if self._agent_context != "primary":
                    return json.dumps({"error": "memory writes are disabled in this context"})
                data = self._client.feedback(memory_id, helpful) if self._client else {}
                return json.dumps({"rated": True, "data": data.get("data")})

            return json.dumps({"error": f"unknown tool {tool_name}"})
        except Exception as exc:
            logger.warning("Dran memory tool %s failed: %s", tool_name, exc)
            return json.dumps({"error": f"dran memory unavailable: {exc}"})

    # -- Session end ----------------------------------------------------------

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        if self._agent_context != "primary":
            return  # subagent/cron sessions must not pollute shared memory
        if not (self._config.get("auto_capture") and self._client):
            return
        try:
            # Ingest cursor: only send the messages not yet digested for
            # this session. A session that ends twice (crash, /exit +
            # resume) re-sends the full transcript otherwise — the server
            # dedupes facts, but the LLM extraction cost is paid again.
            cursor = self._load_ingest_cursor()
            key = self._session_id or "adhoc"
            already = int(cursor.get(key, 0))

            window = messages[-MAX_INGEST_MESSAGES:]
            delta = window[already:] if already < len(window) else []

            # Nothing new since the last ingest for this session.
            if not delta:
                return

            transcript = self._transcript_text(delta)
            if not transcript:
                return

            data = self._client.ingest(transcript, source_session=self._session_id)
            cursor[key] = len(window)
            self._save_ingest_cursor(cursor)
            logger.info("Dran memory ingest: created=%s duplicates=%s (delta=%d msgs)",
                        data.get("created", 0), data.get("duplicates", 0), len(delta))
        except Exception:
            logger.warning("Dran memory ingest failed (session continues)", exc_info=True)

    def _cursor_path(self):
        from pathlib import Path
        return Path(self._hermes_home()) / INGEST_CURSOR_FILE

    def _load_ingest_cursor(self) -> dict:
        try:
            raw = self._cursor_path().read_text(encoding="utf-8")
            data = json.loads(raw)
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def _save_ingest_cursor(self, cursor: dict) -> None:
        try:
            # Prune: keep only the 20 most recent sessions.
            if len(cursor) > 20:
                cursor = dict(sorted(cursor.items(), key=lambda kv: kv[1])[-20:])
            self._cursor_path().write_text(json.dumps(cursor), encoding="utf-8")
        except Exception:
            logger.debug("Dran ingest cursor write failed", exc_info=True)

    def shutdown(self) -> None:
        if self._worker and self._worker.is_alive():
            self._worker.join(timeout=2.0)

    # -- Helpers ----------------------------------------------------------------

    def _format_results(self, results: list) -> tuple[str, frozenset]:
        """Format recall results under the char budget.

        Returns ``(text, injected_ids)`` — the ids feed the injected-set
        dedupe in prefetch(). Whole lines are dropped when the budget is
        hit (never a truncated fact mid-sentence).
        """
        if not results:
            return "", frozenset()

        budget = int(self._config.get("max_recall_chars", MAX_PREFETCH_CHARS) or MAX_PREFETCH_CHARS)
        header = "Relevant shared memories (Dran):"
        lines: list[str] = []
        ids: list[str] = []

        for r in results:
            content = str(r.get("content", "")).strip()
            if not content:
                continue
            line = f"- [{r.get('created_by', '?')}] {content}"
            projected = len(header) + 1 + len("\n".join(lines + [line]))
            if lines and projected > budget:
                break  # budget exhausted — stop at the last whole line
            lines.append(line)
            ids.append(str(r.get("id", "")))

        if not lines:
            return "", frozenset()

        return "\n".join([header] + lines), frozenset(ids)

    def _transcript_text(self, messages: List[Dict[str, Any]]) -> str:
        parts = []
        for m in messages[-MAX_INGEST_MESSAGES:]:
            role = str(m.get("role", "?"))
            content = str(m.get("content", "") or "")
            if content:
                parts.append(f"{role}: {content}")
        text = "\n".join(parts)
        return text[:MAX_INGEST_CHARS]

    @staticmethod
    def _hermes_home() -> str:
        try:
            from hermes_constants import get_hermes_home
            return str(get_hermes_home())
        except Exception:
            return os.path.expanduser("~/.hermes")


# ── Plugin tools (register(ctx)) ──────────────────────────────────────────
#
# The plugin ships BOTH surfaces from one module:
#
#   * the memory provider (dran memory recall/capture) — unchanged, above
#   * a toolset for agent consumption
#
# Hermes' memory-provider loader accepts a directory plugin whose module
# exposes `register(ctx)`: it hands the module a collector that captures
# `register_memory_provider(provider)` and forwards every other
# `register_*` call to a real PluginContext. So `register(ctx)` below
# registers the provider AND the tools in one pass, and the plugin also
# works when loaded through normal plugin discovery.
#
# Every write goes through _DranClient, which puts the Hermes profile name
# in the `X-Hermes-Agent` header; Dran persists it as `agent_name` on the
# written content (server-side attribution).

_TOOLSET = "dran"


def _deep_merge(base: dict, override: dict) -> dict:
    """Merge plugin config over the provider's config (provider wins on scalars)."""
    merged = dict(base or {})
    for key, value in (override or {}).items():
        merged[key] = value
    return merged


def _client_for(ctx) -> Optional[_DranClient]:
    """Build a client from plugin config, falling back to the memory provider config.

    Uses the same `workspace` for both surfaces of the plugin: the memory
    provider's facts and the knowledge tools' pages/relations/workers. One
    setting, one workspace.
    """
    config: Dict[str, Any] = {}
    try:
        config = dict(ctx.config or {})
    except Exception:
        config = {}
    try:
        config = _deep_merge(config, _load_dran_config(os.path.expanduser("~/.hermes")))
    except Exception:
        pass
    api_key = config.get("api_key") or _resolve_secret()
    if not api_key:
        return None
    return _DranClient(
        config.get("base_url") or DEFAULT_BASE_URL,
        api_key,
        config.get("workspace") or DEFAULT_WORKSPACE,
        default_scope=str(config.get("scope") or "private"),
        default_group=str(config.get("scope_group") or ""),
    )


def _workspace_slugs(config: Optional[dict]) -> List[str]:
    """Workspace slugs a key may reach, from an /api/agent/config payload."""
    if not config:
        return []
    slugs = []
    for ws in config.get("workspaces") or []:
        if isinstance(ws, dict):
            slug = str(ws.get("slug") or "").strip()
            if slug:
                slugs.append(slug)
    return slugs


# Timeout for the discovery probe used while BUILDING tool descriptions: the
# plugin must not stall session start on a slow/unreachable Dran.
TYPE_DISCOVERY_TIMEOUT = 2.0


def _effective_page_types(workspace: str = "", timeout: float | None = None) -> List[str]:
    """The page types to offer: the workspace's EFFECTIVE types.

    Best effort, never fatal: `/api/agent/config` serves the effective set
    (the 4 built-in ∪ the workspace's custom `workspace_page_types`, already
    implemented server-side in W2). When Dran is unreachable or the key is
    not an agent key, fall back to the 4 built-in types — the plugin never
    hardcodes a workspace's custom vocabulary, and never invents a field.

    `workspace` selects one workspace's set (its `page_types`); empty means
    the union across every workspace the key reaches (`data.page_types`).
    Cached for CONFIG_REFRESH_SECS (same cadence as the workspace probe) so
    rendering tool descriptions never pays a round-trip per call.
    """
    now = time.monotonic()
    cached = _TYPE_CACHE.get(workspace)
    if cached and now - cached[0] < CONFIG_REFRESH_SECS:
        return list(cached[1])
    types = _fetch_effective_page_types(workspace, timeout)
    _TYPE_CACHE[workspace] = (now, types)
    return list(types)


def _fetch_effective_page_types(workspace: str = "",
                                timeout: float | None = None) -> List[str]:
    """Uncached discovery — see `_effective_page_types` for the contract."""
    client = _client_for(_PLUGIN_CTX)
    if client is None:
        return list(BUILTIN_PAGE_TYPES)
    config = client.agent_config(timeout=timeout or TYPE_DISCOVERY_TIMEOUT)
    if not config:
        return list(BUILTIN_PAGE_TYPES)
    workspaces = config.get("workspaces") or []
    if workspace:
        for ws in workspaces:
            if isinstance(ws, dict) and str(ws.get("slug") or "") == workspace:
                types = [str(t) for t in (ws.get("page_types") or []) if t]
                if types:
                    return types
                break  # known workspace, empty set — do not fall back to the union
    types = [str(t) for t in (config.get("page_types") or []) if t]
    if not types:
        for ws in workspaces:
            if isinstance(ws, dict):
                types.extend(
                    str(t) for t in (ws.get("page_types") or []) if t
                )
    seen: List[str] = []
    for t in list(BUILTIN_PAGE_TYPES) + types:
        if t not in seen:
            seen.append(t)
    return seen


def _tool_schemas() -> List[Dict[str, Any]]:
    """Tool schemas exposed to the agent.

    The page-type vocabulary is DISCOVERED, not hardcoded: the descriptions
    render the effective types of the plugin's workspace, read from
    `/api/agent/config` (built-in ∪ custom), with the 4 built-ins as the
    offline fallback.
    """
    _schemas_client = _client_for(_PLUGIN_CTX)
    _types = _effective_page_types(
        _schemas_client.workspace if _schemas_client is not None else "",
        timeout=TYPE_DISCOVERY_TIMEOUT,
    )
    _types_doc = ", ".join(_types)
    _types_enum = " | ".join(_types)
    return [
        {
            "name": "dran_search",
            "description": "Search knowledge pages in the Dran workspace (full-text, fuzzy, semantic or hybrid). Use this first to find anything already written.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                    "strategy": {"type": "string", "enum": ["auto", "fts", "fuzzy", "semantic", "hybrid"],
                                 "description": "Search strategy (default auto)"},
                    "limit": {"type": "integer", "description": "Max results (default 10)"},
                },
                "required": ["query"],
            },
        },
        {
            "name": "dran_list_pages",
            "description": f"List knowledge pages, optionally filtered by page type ({_types_doc}).",
            "parameters": {
                "type": "object",
                "properties": {
                    "page_type": {"type": "string", "description": "Optional page type filter"},
                    "limit": {"type": "integer", "description": "Max results (default 20)"},
                },
            },
        },
        {
            "name": "dran_list_page_types",
            "description": (
                "List the workspace's effective page types — the 4 built-in types "
                f"({_types_doc}) plus any custom types the workspace declares — with "
                "each type's slug, label, plural, path, icon, color and meta fields. "
                "Call this before dran_create_page when the page type was not "
                "specified, then pick the best fit from the returned definitions."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "dran_get_page",
            "description": "Read the full body of a page by slug.",
            "parameters": {
                "type": "object",
                "properties": {"slug": {"type": "string", "description": "Page slug"}},
                "required": ["slug"],
            },
        },
        {
            "name": "dran_create_page",
            "description": "Create a knowledge page in the Dran workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "body": {"type": "string", "description": "Page body (markdown)"},
                    "page_type": {"type": "string", "description": f"One of the workspace's effective page types: {_types_enum}"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "summary": {"type": "string"},
                    "visibility": {"type": "string", "enum": ["private", "public", "shared"],
                                   "description": "Read visibility. private (default): only the key's owner. "
                                   "public: everyone on the instance. shared: only explicit share targets "
                                   "(managed from the Dran web UI)."},
                },
                "required": ["title"],
            },
        },
        {
            "name": "dran_update_page",
            "description": "Update fields of an existing page by slug (only the fields you pass change).",
            "parameters": {
                "type": "object",
                "properties": {
                    "slug": {"type": "string"},
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                    "summary": {"type": "string"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "visibility": {"type": "string", "enum": ["private", "public", "shared"],
                                   "description": "Change the page's read visibility."},
                },
                "required": ["slug"],
            },
        },
        {
            "name": "dran_delete_page",
            "description": "Delete a page by slug.",
            "parameters": {
                "type": "object",
                "properties": {"slug": {"type": "string"}},
                "required": ["slug"],
            },
        },
        {
            "name": "dran_get_links",
            "description": "Get the inbound and outbound relations of a page (graph exploration).",
            "parameters": {
                "type": "object",
                "properties": {"slug": {"type": "string"}},
                "required": ["slug"],
            },
        },
        {
            "name": "dran_create_relation",
            "description": "Create a typed, directed relation between two pages.",
            "parameters": {
                "type": "object",
                "properties": {
                    "source_slug": {"type": "string"},
                    "target_slug": {"type": "string"},
                    "relation_type": {"type": "string", "description": "e.g. related, references, depends_on, part_of"},
                    "description": {"type": "string"},
                },
                "required": ["source_slug", "target_slug"],
            },
        },
        {
            "name": "dran_delete_relation",
            "description": "Delete a relation between two pages.",
            "parameters": {
                "type": "object",
                "properties": {
                    "source_slug": {"type": "string"},
                    "target_slug": {"type": "string"},
                    "relation_type": {"type": "string"},
                },
                "required": ["source_slug", "target_slug"],
            },
        },
        {
            "name": "dran_lint_brain",
            "description": "Structural hygiene audit of the workspace (read-only): orphans, broken embeds, missing metadata.",
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "dran_rename_slug",
            "description": "Rename a page's slug. Rewrites ![[old-slug]] embeds across the workspace, so ask the user before doing it.",
            "parameters": {
                "type": "object",
                "properties": {
                    "slug": {"type": "string", "description": "Current slug"},
                    "new_slug": {"type": "string", "description": "New slug (lowercase-hyphen)"},
                },
                "required": ["slug", "new_slug"],
            },
        },
        {
            "name": "dran_reaugment_page",
            "description": "Re-run the augmentation pipeline for a page (refresh embedding, summary, relations). Use after a body change when inference was offline.",
            "parameters": {
                "type": "object",
                "properties": {"slug": {"type": "string"}},
                "required": ["slug"],
            },
        },
        {
            "name": "dran_generate_cluster_summaries",
            "description": "Regenerate the nightly cluster summaries of the workspace on demand.",
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "dran_start_worker",
            "description": "Start an autonomous worker session and return immediately (session_id + track_url). worker_type: 'curator' (duplicate/conflicting pages → report), 'link_gardener' (relation proposals for orphans), 'graph_rag' (GraphRAG answer). Poll with dran_get_worker_session.",
            "parameters": {
                "type": "object",
                "properties": {
                    "worker_type": {"type": "string", "enum": ["curator", "link_gardener", "graph_rag"]},
                    "input": {"type": "string", "description": "Worker input (a question for graph_rag, a focus note otherwise)"},
                },
                "required": ["worker_type"],
            },
        },
        {
            "name": "dran_get_worker_session",
            "description": "Poll an autonomous worker session: status (pending/running/done/failed), summary, pages_created and the ordered steps. Poll until status is 'done' or 'failed'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "UUID returned by dran_start_worker"},
                },
                "required": ["session_id"],
            },
        },
        {
            "name": "dran_stats",
            "description": "Dashboard numbers for the Dran workspace: page counts by type, memory count, relations.",
            "parameters": {"type": "object", "properties": {}},
        },
        # ── Goals, tasks y planes (contrato de superficies) ────────────────
        #
        # El contenedor de trabajo y el plan: tools delgadas sobre el REST
        # (/api/goals, /api/tasks, /api/plans). El destino de una escritura se
        # declara con `scope` (`private` | `public`) o con `group` (el slug del
        # grupo donde el dueño es miembro) — se valida server-side y falla
        # cerrado con 422. Sin destino en una ALTA se aplica el default del
        # perfil («Write scope» / «Group slug» del panel).
        {
            "name": "dran_list_groups",
            "description": "List the groups the agent's owner belongs to (name + slug). Use it to pick a destination BEFORE writing with group scope: the slug is what `group` takes.",
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "dran_list_goals",
            "description": "List the goals the agent's owner can read (own ∪ public ∪ shared), optionally filtered by status.",
            "parameters": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "enum": ["draft", "active", "on_hold", "done", "archived"],
                               "description": "Optional status filter"},
                    "limit": {"type": "integer", "description": "Max results (default 50)"},
                },
            },
        },
        {
            "name": "dran_get_goal",
            "description": "Read one goal by uuid or slug (mine, public, or shared with me), with its tasks.",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Goal uuid or slug"}},
                "required": ["id"],
            },
        },
        {
            "name": "dran_create_goal",
            "description": "Create a goal (the WHAT: container of work). Destinations: private (default), public, or a group by slug.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Goal title"},
                    "summary": {"type": "string", "description": "One-line summary"},
                    "body": {"type": "string", "description": "Markdown body"},
                    "horizon": {"type": "string", "enum": ["someday", "day", "week", "month", "quarter", "year"]},
                    "status": {"type": "string", "enum": ["draft", "active", "on_hold", "done", "archived"]},
                    "due_on": {"type": "string", "description": "Due date (YYYY-MM-DD)"},
                    "scope": {"type": "string", "enum": ["private", "public"],
                              "description": "Write destination (default private)"},
                    "group": {"type": "string", "description": "Group slug to share with (overrides scope)"},
                },
                "required": ["title"],
            },
        },
        {
            "name": "dran_update_goal",
            "description": "Update a goal's fields (by uuid or slug). The owner is resolved server-side; a share never grants write.",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "Goal uuid or slug"},
                    "title": {"type": "string"},
                    "summary": {"type": "string"},
                    "body": {"type": "string"},
                    "status": {"type": "string", "enum": ["draft", "active", "on_hold", "done", "archived"]},
                    "horizon": {"type": "string"},
                    "due_on": {"type": "string", "description": "YYYY-MM-DD"},
                    "progress_manual": {"type": "integer", "description": "0-100 override for a goal without tasks"},
                    "pinned": {"type": "boolean"},
                    "archived": {"type": "boolean"},
                    "scope": {"type": "string", "enum": ["private", "public"], "description": "Re-declare the destination"},
                    "group": {"type": "string", "description": "Group slug to share with"},
                },
                "required": ["id"],
            },
        },
        {
            "name": "dran_delete_goal",
            "description": "Delete a goal by uuid or slug: its tasks (FK delete_all) and its graph edges go with it. Irreversible.",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Goal uuid or slug"}},
                "required": ["id"],
            },
        },
        {
            "name": "dran_list_tasks",
            "description": "List tasks the agent's owner can read (visibility is inherited from the goal), optionally filtered by goal (uuid or slug) and/or status.",
            "parameters": {
                "type": "object",
                "properties": {
                    "goal": {"type": "string", "description": "Goal uuid or slug"},
                    "status": {"type": "string", "enum": ["backlog", "todo", "in_progress", "done", "cancelled"]},
                    "limit": {"type": "integer", "description": "Max results (default 100)"},
                },
            },
        },
        {
            "name": "dran_create_task",
            "description": "Create a task. Without `goal` it lands in the owner's inbox goal (created lazily) — that is the quick-capture path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Task title"},
                    "goal": {"type": "string", "description": "Goal uuid or slug; omit for the inbox"},
                    "body": {"type": "string"},
                    "priority": {"type": "string", "enum": ["low", "medium", "high", "urgent"]},
                    "due_date": {"type": "string", "description": "YYYY-MM-DD"},
                    "checklist": {"type": "array", "items": {"type": "string"},
                                  "description": "Ordered steps; each becomes {text, done:false}"},
                },
                "required": ["title"],
            },
        },
        {
            "name": "dran_capture",
            "description": "Quick capture: one task into the owner's inbox goal, no goal needed. Use it when the user drops a thought to deal with later.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "What to capture"},
                    "priority": {"type": "string", "enum": ["low", "medium", "high", "urgent"]},
                    "due_date": {"type": "string", "description": "YYYY-MM-DD"},
                },
                "required": ["title"],
            },
        },
        {
            "name": "dran_get_task",
            "description": "Read one task by uuid, with its checklist and lock_version (needed to move it safely).",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Task uuid"}},
                "required": ["id"],
            },
        },
        {
            "name": "dran_update_task",
            "description": "Update a task's content (title, body, priority, due date, assignee, checklist, recurrence, archived). Status and goal changes go through dran_move_task.",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "Task uuid"},
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                    "priority": {"type": "string", "enum": ["low", "medium", "high", "urgent"]},
                    "due_date": {"type": "string", "description": "YYYY-MM-DD"},
                    "assignee_id": {"type": "integer", "description": "User id"},
                    "checklist": {"type": "array", "items": {"type": "string"},
                                  "description": "Replaces the whole checklist (ordered steps)"},
                    "recurrence": {"type": "string", "enum": ["none", "daily", "weekly", "monthly"]},
                    "archived": {"type": "boolean"},
                },
                "required": ["id"],
            },
        },
        {
            "name": "dran_move_task",
            "description": "Move a task: column (status), position (before_id/after_id) and/or goal (uuid or slug), atomically. Pass lock_version to avoid clobbering a concurrent move (409 when stale).",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "Task uuid"},
                    "status": {"type": "string", "enum": ["backlog", "todo", "in_progress", "done", "cancelled"]},
                    "goal": {"type": "string", "description": "Target goal uuid or slug"},
                    "before_id": {"type": "string", "description": "Put it above this task"},
                    "after_id": {"type": "string", "description": "Put it below this task"},
                    "lock_version": {"type": "integer", "description": "Expected version (from a prior read)"},
                },
                "required": ["id"],
            },
        },
        {
            "name": "dran_delete_task",
            "description": "Delete a task by uuid and its graph edges.",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Task uuid"}},
                "required": ["id"],
            },
        },
        {
            "name": "dran_list_plans",
            "description": "List the plans the agent's owner can read (own ∪ public ∪ shared). A plan is a first-class entity: its steps live in an ordered checklist.",
            "parameters": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "enum": ["draft", "active", "on_hold", "done", "archived"]},
                    "limit": {"type": "integer", "description": "Max results (default 50)"},
                },
            },
        },
        {
            "name": "dran_get_plan",
            "description": "Read one plan by uuid or slug, with its checklist and derived progress (done/total).",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Plan uuid or slug"}},
                "required": ["id"],
            },
        },
        {
            "name": "dran_create_plan",
            "description": "Create a plan with its ordered steps. Destinations: private (default), public, or a group by slug.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Plan title"},
                    "summary": {"type": "string"},
                    "body": {"type": "string", "description": "Markdown body"},
                    "status": {"type": "string", "enum": ["draft", "active", "on_hold", "done", "archived"]},
                    "due_on": {"type": "string", "description": "YYYY-MM-DD"},
                    "checklist": {"type": "array", "items": {"type": "string"},
                                  "description": "The steps, in order"},
                    "scope": {"type": "string", "enum": ["private", "public"],
                              "description": "Write destination (default private)"},
                    "group": {"type": "string", "description": "Group slug to share with (overrides scope)"},
                },
                "required": ["title"],
            },
        },
        {
            "name": "dran_update_plan",
            "description": "Update a plan's fields (by uuid or slug). The checklist has its own tool (dran_set_plan_checklist / dran_toggle_checklist).",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "Plan uuid or slug"},
                    "title": {"type": "string"},
                    "summary": {"type": "string"},
                    "body": {"type": "string"},
                    "status": {"type": "string", "enum": ["draft", "active", "on_hold", "done", "archived"]},
                    "due_on": {"type": "string", "description": "YYYY-MM-DD"},
                    "archived": {"type": "boolean"},
                    "scope": {"type": "string", "enum": ["private", "public"], "description": "Re-declare the destination"},
                    "group": {"type": "string", "description": "Group slug to share with"},
                },
                "required": ["id"],
            },
        },
        {
            "name": "dran_set_plan_checklist",
            "description": "Replace a plan's whole checklist with an ordered list of steps (same canonical shape as a task's checklist).",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "Plan uuid or slug"},
                    "checklist": {"type": "array", "items": {"type": "string"},
                                  "description": "The steps, in order"},
                    "lock_version": {"type": "integer", "description": "Expected version (409 when stale)"},
                },
                "required": ["id", "checklist"],
            },
        },
        {
            "name": "dran_toggle_checklist",
            "description": "Check or uncheck ONE checklist item of a plan or a task, by index (0-based) or by its text. Same door for both containers.",
            "parameters": {
                "type": "object",
                "properties": {
                    "target": {"type": "string", "enum": ["plan", "task"], "description": "Which container holds the checklist"},
                    "id": {"type": "string", "description": "Plan/task uuid (or a plan slug)"},
                    "index": {"type": "integer", "description": "0-based item index"},
                    "text": {"type": "string", "description": "Item text (case-insensitive) instead of index"},
                    "lock_version": {"type": "integer", "description": "Expected version (409 when stale)"},
                },
                "required": ["target", "id"],
            },
        },
        {
            "name": "dran_delete_plan",
            "description": "Delete a plan by uuid or slug and its graph edges. Irreversible.",
            "parameters": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Plan uuid or slug"}},
                "required": ["id"],
            },
        },
        # ── Servicios conectados (cliente delgado del REST /api/services) ──
        #
        # El catálogo viaja como DATO, nunca como una tool por toolkit: hay UN
        # descubrimiento (`dran_services_tools`) y UNA ejecución
        # (`dran_services_run`). Conectar devuelve un link hosted que el agente
        # le pega al usuario; el inventario se inyecta solo al inicio del turno.
        {
            "name": "dran_services",
            "description": "List the user's connected services (mail, calendar, issues/pull requests, chat, files) with each toolkit's connection state and account identity. This is the inventory — read it before assuming a service is available.",
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "name": "dran_services_connect",
            "description": "Get the hosted connection link for a service toolkit; the user opens it to authorize. Show it to the user as a markdown link. The link expires after 10 minutes — when it expires, call this again for a fresh one instead of retrying the old link.",
            "parameters": {
                "type": "object",
                "properties": {
                    "toolkit": {"type": "string", "description": "Service toolkit to connect (e.g. gmail)"},
                },
                "required": ["toolkit"],
            },
        },
        {
            "name": "dran_services_tools",
            "description": "Discover the tools a service exposes, or search the catalog by use case. With `toolkit`, list its tools (add `slug` for one tool's full input/output schema). With `use_case`, search the whole catalog for the best tool slugs for a task. The catalog is data — always discover through this tool, there is no per-toolkit tool.",
            "parameters": {
                "type": "object",
                "properties": {
                    "toolkit": {"type": "string", "description": "List this service's tools"},
                    "slug": {"type": "string", "description": "One tool's full schema (with toolkit)"},
                    "use_case": {"type": "string", "description": "Search the catalog by use case instead of a toolkit"},
                },
            },
        },
        {
            "name": "dran_services_run",
            "description": "Run one tool of a connected service: pass the toolkit, the tool_slug (from dran_services_tools) and its arguments. If the service is not connected it fails closed with a connect link to show the user — it never pretends to succeed.",
            "parameters": {
                "type": "object",
                "properties": {
                    "toolkit": {"type": "string", "description": "Service toolkit (e.g. gmail)"},
                    "tool_slug": {"type": "string", "description": "Tool slug (e.g. GMAIL_SEND_EMAIL)"},
                    "arguments": {"type": "object", "description": "Tool arguments object, per the tool's input schema"},
                },
                "required": ["toolkit", "tool_slug"],
            },
        },
        {
            "name": "dran_services_wait",
            "description": "After the user opens a connect link, poll briefly until that service becomes ACTIVE. Short cap (default 15s, max 30s, a check every ~2s) — it never blocks longer than the cap. If it does not reach ACTIVE in time, the connect link has expired: re-emit a new one with dran_services_connect.",
            "parameters": {
                "type": "object",
                "properties": {
                    "toolkit": {"type": "string", "description": "Service toolkit to wait for"},
                    "timeout_seconds": {"type": "integer", "description": "Max seconds to wait (default 15, max 30)"},
                },
                "required": ["toolkit"],
            },
        },
    ]


# Las tools del contenedor de trabajo y del plan (contrato de superficies):
# goals, tasks, la captura rápida y el checklist. Se despachan juntas para que
# el dispatcher principal no crezca con 18 ramas, y cada una es un cliente
# delgado de una ruta del REST.
_WORK_TOOLS = frozenset({
    "dran_list_groups",
    "dran_list_goals", "dran_get_goal", "dran_create_goal", "dran_update_goal",
    "dran_delete_goal",
    "dran_list_tasks", "dran_create_task", "dran_get_task", "dran_capture",
    "dran_update_task", "dran_move_task", "dran_delete_task",
    "dran_list_plans", "dran_get_plan", "dran_create_plan", "dran_update_plan",
    "dran_set_plan_checklist", "dran_toggle_checklist", "dran_delete_plan",
})

# Servicios conectados (cliente delgado del REST /api/services): listar, emitir
# el link de conexión, descubrir el catálogo, ejecutar y esperar a ACTIVE. Se
# despachan juntas por la misma razón que las de trabajo: el dispatcher principal
# no crece con una rama por tool.
_SERVICES_TOOLS = frozenset({
    "dran_services",
    "dran_services_connect",
    "dran_services_tools",
    "dran_services_run",
    "dran_services_wait",
})


def _handle_plugin_tool(tool_name: str, args: Dict[str, Any], **kwargs: Any) -> str:
    """Handler body for the `dran_*` knowledge tools.

    Hermes dispatches every tool as ``handler(args, **kwargs)`` — it does not
    pass the tool name. `register()` therefore binds the name per tool with a
    closure (see `_make_handler`).
    """
    args = args or {}
    try:
        client = _client_for(kwargs.get("ctx") or _PLUGIN_CTX)
        if client is None:
            return json.dumps({"error": "dran not configured (set api_key in the plugin or memory config)"})

        if tool_name == "dran_search":
            query = str(args.get("query", "")).strip()
            if not query:
                return json.dumps({"error": "query is required"})
            results = client.search_pages(query,
                                          strategy=str(args.get("strategy") or "auto"),
                                          limit=int(args.get("limit") or 10))
            return json.dumps({"results": _trim_results(results)})

        if tool_name == "dran_list_pages":
            pages = client.list_pages(page_type=str(args.get("page_type") or ""),
                                      limit=int(args.get("limit") or 20))
            return json.dumps({"pages": _trim_results(pages)})

        if tool_name == "dran_list_page_types":
            return json.dumps(client.list_page_types())

        if tool_name == "dran_get_page":
            slug = str(args.get("slug", "")).strip()
            if not slug:
                return json.dumps({"error": "slug is required"})
            page = client.get_page(slug)
            if page is None:
                return json.dumps({"error": f"page not found: {slug}"})
            return json.dumps(page)

        if tool_name == "dran_create_page":
            title = str(args.get("title", "")).strip()
            if not title:
                return json.dumps({"error": "title is required"})
            page_type = str(args.get("page_type") or "note").strip()
            # Fail-closed against the workspace's EFFECTIVE types (built-in ∪
            # custom) so a retired type never reaches the API. The list comes
            # from /api/agent/config (best effort: the 4 built-ins offline).
            available = _effective_page_types(client.workspace)
            if page_type not in available:
                return json.dumps({
                    "error": f"unknown page type {page_type!r}",
                    "effective_page_types": available,
                })
            visibility = str(args.get("visibility") or "private").strip()
            if visibility not in ("private", "public", "shared"):
                return json.dumps({"error": "visibility must be private | public | shared"})
            data = client.create_page(
                title=title,
                body=str(args.get("body") or ""),
                page_type=page_type,
                tags=list(args.get("tags") or []),
                summary=str(args.get("summary") or ""),
                visibility=visibility,
            )
            page = data.get("data") or {}
            return json.dumps({"created": True, "slug": page.get("slug"), "id": page.get("id")})

        if tool_name == "dran_update_page":
            slug = str(args.get("slug", "")).strip()
            if not slug:
                return json.dumps({"error": "slug is required"})
            fields = {k: args.get(k) for k in ("title", "body", "summary", "tags", "visibility") if args.get(k) is not None}
            if not fields:
                return json.dumps({"error": "nothing to update"})
            data = client.update_page(slug, **fields)
            page = data.get("data") or {}
            return json.dumps({"updated": True, "slug": page.get("slug"), "version": page.get("version")})

        if tool_name == "dran_delete_page":
            slug = str(args.get("slug", "")).strip()
            if not slug:
                return json.dumps({"error": "slug is required"})
            return json.dumps({"deleted": client.delete_page(slug), "slug": slug})

        if tool_name == "dran_get_links":
            slug = str(args.get("slug", "")).strip()
            if not slug:
                return json.dumps({"error": "slug is required"})
            return json.dumps(client.get_links(slug))

        if tool_name == "dran_create_relation":
            source = str(args.get("source_slug", "")).strip()
            target = str(args.get("target_slug", "")).strip()
            if not source or not target:
                return json.dumps({"error": "source_slug and target_slug are required"})
            data = client.create_relation(source, target,
                                          relation_type=str(args.get("relation_type") or "related"),
                                          description=str(args.get("description") or ""))
            return json.dumps({"created": True, "data": data.get("data")})

        if tool_name == "dran_delete_relation":
            source = str(args.get("source_slug", "")).strip()
            target = str(args.get("target_slug", "")).strip()
            if not source or not target:
                return json.dumps({"error": "source_slug and target_slug are required"})
            return json.dumps({"deleted": client.delete_relation(
                source, target, str(args.get("relation_type") or ""))})

        if tool_name == "dran_lint_brain":
            return json.dumps(client.lint_brain())

        if tool_name == "dran_rename_slug":
            slug = str(args.get("slug", "")).strip()
            new_slug = str(args.get("new_slug", "")).strip()
            if not slug or not new_slug:
                return json.dumps({"error": "slug and new_slug are required"})
            data = client.rename_slug(slug, new_slug)
            return json.dumps({
                "renamed": True,
                "from": data.get("renamed_from"),
                "to": data.get("renamed_to"),
            })

        if tool_name == "dran_reaugment_page":
            slug = str(args.get("slug", "")).strip()
            if not slug:
                return json.dumps({"error": "slug is required"})
            data = client.reaugment_page(slug)
            return json.dumps({"scheduled": True, "data": data.get("data")})

        if tool_name == "dran_generate_cluster_summaries":
            data = client.generate_cluster_summaries()
            return json.dumps({"data": data.get("data")})

        if tool_name == "dran_start_worker":
            worker_type = str(args.get("worker_type", "")).strip()
            if worker_type not in ("curator", "link_gardener", "graph_rag"):
                return json.dumps({"error": "worker_type must be curator, link_gardener or graph_rag"})
            data = client.start_worker(worker_type, str(args.get("input") or ""))
            session = data.get("data") or {}
            return json.dumps({
                "started": True,
                "session_id": session.get("id"),
                "status": session.get("status"),
                "track_url": session.get("track_url"),
                "hint": "poll with dran_get_worker_session(session_id)",
            })

        if tool_name == "dran_get_worker_session":
            session_id = str(args.get("session_id", "")).strip()
            if not session_id:
                return json.dumps({"error": "session_id is required"})
            session = client.get_worker_session(session_id)
            if session is None:
                return json.dumps({"error": f"worker session not found: {session_id}"})
            return json.dumps(session)

        if tool_name == "dran_stats":
            return json.dumps(client.stats())

        if tool_name in _WORK_TOOLS:
            return _handle_work_tool(client, tool_name, args)

        if tool_name in _SERVICES_TOOLS:
            return _handle_services_tool(client, tool_name, args)

        return json.dumps({"error": f"unknown tool {tool_name}"})
    except Exception as exc:
        logger.warning("Dran plugin tool %s failed: %s", tool_name, exc)
        return json.dumps({"error": f"dran unavailable: {exc}"})


def _handle_work_tool(client: Any, tool_name: str, args: Dict[str, Any]) -> str:
    """Goals, tasks, planes y checklist: cliente delgado del REST (W2).

    Devuelve respuestas acotadas (id/slug/título/estado y, cuando importa, el
    checklist) y traduce los errores que el agente necesita distinguir: 404
    (fuera de su alcance o no existe) y 409 (perdió la carrera del
    `lock_version`) — nunca inventa un resultado.
    """
    from urllib.parse import quote

    def seg(key: str = "id") -> str:
        return quote(str(args.get(key, "")).strip(), safe="")

    def fields(*keys: str) -> Dict[str, Any]:
        return {k: args[k] for k in keys if args.get(k) is not None and args.get(k) != ""}

    def scope(*, use_default: bool = False) -> Dict[str, Any]:
        resolved = client._goal_scope(args.get("scope"), args.get("group"),
                                      use_default=use_default)
        return {"scope": resolved} if resolved is not None else {}

    def conflict(exc: "urllib.error.HTTPError") -> str:
        return json.dumps({"error": "stale", "status": exc.code,
                           "hint": "read it again and retry with the new lock_version"})

    try:
        if tool_name == "dran_list_groups":
            groups = client.list_groups()
            return json.dumps({
                "groups": [{"slug": g.get("slug"), "name": g.get("name")} for g in groups],
                "hint": "para escribir en un grupo, pasá `group` con ese slug",
            })

        if tool_name == "dran_list_goals":
            goals = client.list_goals(status=str(args.get("status") or ""),
                                      limit=int(args.get("limit") or 50))
            return json.dumps({"goals": [_brief(g) for g in goals]})

        if tool_name == "dran_get_goal":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            goal = client.get_goal(seg())
            if goal is None:
                return json.dumps({"error": "goal not found"})
            tasks = client.list_goal_tasks(seg())
            body = dict(goal)
            body["tasks"] = [_brief(t) for t in tasks]
            return json.dumps(body)

        if tool_name == "dran_create_goal":
            title = str(args.get("title", "")).strip()
            if not title:
                return json.dumps({"error": "title is required"})
            data = client.create_goal(
                title,
                **fields("summary", "body", "horizon", "status", "due_on"),
                **scope(use_default=True),
            )
            return json.dumps({"created": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_update_goal":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            data = client.update_goal(
                seg(),
                **fields("title", "summary", "body", "status", "horizon", "due_on",
                         "progress_manual", "pinned", "archived"),
                **scope(),
            )
            return json.dumps({"updated": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_delete_goal":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            return json.dumps({"deleted": client.delete_goal(seg())})

        if tool_name == "dran_list_tasks":
            tasks = client.list_tasks(goal=str(args.get("goal") or ""),
                                      status=str(args.get("status") or ""),
                                      limit=int(args.get("limit") or 100))
            return json.dumps({"tasks": [_brief(t) for t in tasks]})

        if tool_name == "dran_create_task":
            title = str(args.get("title", "")).strip()
            if not title:
                return json.dumps({"error": "title is required"})
            data = client.create_task(
                title,
                **fields("goal", "body", "priority", "due_date", "checklist"),
            )
            return json.dumps({"created": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_capture":
            title = str(args.get("title", "")).strip()
            if not title:
                return json.dumps({"error": "title is required"})
            data = client.capture(title, **fields("priority", "due_date"))
            return json.dumps({"captured": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_get_task":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            task = client.get_task(seg())
            if task is None:
                return json.dumps({"error": "task not found"})
            return json.dumps(_brief(task))

        if tool_name == "dran_update_task":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            data = client.update_task(
                seg(),
                **fields("title", "body", "priority", "due_date", "assignee_id",
                         "checklist", "recurrence", "archived"),
            )
            return json.dumps({"updated": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_move_task":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            try:
                data = client.move_task(
                    seg(),
                    **fields("status", "goal", "before_id", "after_id", "lock_version"),
                )
            except urllib.error.HTTPError as exc:
                if exc.code == 409:
                    return conflict(exc)
                raise
            return json.dumps({"moved": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_delete_task":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            return json.dumps({"deleted": client.delete_task(seg())})

        if tool_name == "dran_list_plans":
            plans = client.list_plans(status=str(args.get("status") or ""),
                                      limit=int(args.get("limit") or 50))
            return json.dumps({"plans": [_brief(p) for p in plans]})

        if tool_name == "dran_get_plan":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            plan = client.get_plan(seg())
            if plan is None:
                return json.dumps({"error": "plan not found"})
            return json.dumps(plan)

        if tool_name == "dran_create_plan":
            title = str(args.get("title", "")).strip()
            if not title:
                return json.dumps({"error": "title is required"})
            data = client.create_plan(
                title,
                **fields("summary", "body", "status", "due_on", "checklist"),
                **scope(use_default=True),
            )
            return json.dumps({"created": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_update_plan":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            data = client.update_plan(
                seg(),
                **fields("title", "summary", "body", "status", "due_on", "archived"),
                **scope(),
            )
            return json.dumps({"updated": True, **_brief(data.get("data") or {})})

        if tool_name == "dran_set_plan_checklist":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            checklist = args.get("checklist")
            if checklist is None:
                return json.dumps({"error": "checklist is required"})
            try:
                data = client.set_plan_checklist(seg(), checklist,
                                                 lock_version=args.get("lock_version"))
            except urllib.error.HTTPError as exc:
                if exc.code == 409:
                    return conflict(exc)
                raise
            return json.dumps(_checklist_answer(data))

        if tool_name == "dran_toggle_checklist":
            target = str(args.get("target", "")).strip()
            if target not in ("plan", "task"):
                return json.dumps({"error": "target must be plan or task"})
            if args.get("index") is None and not str(args.get("text") or "").strip():
                return json.dumps({"error": "index or text is required"})
            try:
                data = client.toggle_checklist(
                    target,
                    seg(),
                    index=args.get("index"),
                    text=str(args.get("text") or ""),
                    lock_version=args.get("lock_version"),
                )
            except urllib.error.HTTPError as exc:
                if exc.code == 409:
                    return conflict(exc)
                raise
            return json.dumps(_checklist_answer(data))

        if tool_name == "dran_delete_plan":
            if not str(args.get("id", "")).strip():
                return json.dumps({"error": "id is required"})
            return json.dumps({"deleted": client.delete_plan(seg())})

        return json.dumps({"error": f"unknown tool {tool_name}"})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            detail = json.loads(raw).get("errors", {}).get("detail")
        except ValueError:
            detail = None
        return json.dumps({"error": detail or f"dran answered HTTP {exc.code}",
                           "status": exc.code})


def _coerce_wait_timeout(value: Any) -> float:
    """El cap del wait: default ~15s, máximo 30s, nunca negativo."""
    try:
        secs = float(value)
    except (TypeError, ValueError):
        return SERVICE_WAIT_DEFAULT_SECS
    return max(0.0, min(SERVICE_WAIT_MAX_SECS, secs))


def _services_http_error(exc: "urllib.error.HTTPError", toolkit: str = "") -> str:
    """Traduce el error del REST conservando lo que el agente necesita.

    El 409 `not_connected` trae el `connect_url`: se devuelve para que el
    agente se lo muestre al usuario — fail-closed, nunca un falso éxito.
    """
    raw = exc.read().decode("utf-8", "replace")
    try:
        body = json.loads(raw)
    except ValueError:
        body = {}
    if not isinstance(body, dict):
        body = {}
    errors = body.get("errors")
    if not isinstance(errors, dict):
        errors = {}
    out: Dict[str, Any] = {
        "error": errors.get("detail") or f"dran answered HTTP {exc.code}",
        "status": exc.code,
    }
    if errors.get("code"):
        out["code"] = errors["code"]
    if body.get("toolkit") or toolkit:
        out["toolkit"] = body.get("toolkit") or toolkit
    connect_url = body.get("connect_url")
    if connect_url:
        out["connect_url"] = connect_url
        out["hint"] = ("the service is not connected — show this link to the user "
                       "so they can connect it, then retry")
    return json.dumps(out)


def _handle_services_tool(client: Any, tool_name: str, args: Dict[str, Any]) -> str:
    """Servicios conectados: cliente delgado del REST /api/services.

    El catálogo viaja como DATO (`dran_services_tools`), nunca como una tool
    por toolkit. Las respuestas van acotadas y el 409 `not_connected` se
    traduce con su connect_url — fail-closed, nunca un falso éxito.
    """
    try:
        if tool_name == "dran_services":
            payload = client.list_services()
            if not isinstance(payload, dict):
                payload = {}
            services = []
            for svc in payload.get("data") or []:
                if not isinstance(svc, dict):
                    continue
                services.append({
                    "toolkit": svc.get("toolkit"),
                    "name": svc.get("name"),
                    "description": svc.get("description"),
                    "connected": bool(svc.get("connected")),
                    "status": svc.get("status"),
                    "identity": svc.get("identity"),
                })
            return json.dumps({
                "configured": bool(payload.get("configured")),
                "services": services,
            })

        if tool_name == "dran_services_connect":
            toolkit = str(args.get("toolkit", "")).strip()
            if not toolkit:
                return json.dumps({"error": "toolkit is required"})
            data = client.connect_service(toolkit)
            payload = data.get("data") if isinstance(data, dict) else None
            payload = payload if isinstance(payload, dict) else {}
            redirect_url = payload.get("redirect_url")
            if not redirect_url:
                return json.dumps({"error": "no connect link returned", "toolkit": toolkit})
            return json.dumps({
                "toolkit": payload.get("toolkit") or toolkit,
                "redirect_url": redirect_url,
                "expires_in": payload.get("expires_in"),
                "hint": ("show the user this link as a markdown link; it expires "
                         "after ~10 minutes — if it expires, call dran_services_connect "
                         "again for a fresh one"),
            })

        if tool_name == "dran_services_tools":
            toolkit = str(args.get("toolkit") or "").strip()
            slug = str(args.get("slug") or "").strip()
            use_case = str(args.get("use_case") or "").strip()
            if toolkit:
                catalog = client.list_service_tools(toolkit, slug=slug)
                if catalog is None:
                    return json.dumps({"error": f"unknown toolkit: {toolkit}",
                                       "toolkit": toolkit})
                return json.dumps(catalog)
            if use_case:
                found = client.search_service_tools(use_case)
                if found is None:
                    return json.dumps({"error": "search unavailable"})
                return json.dumps(found)
            return json.dumps({
                "error": "toolkit or use_case is required",
                "hint": "call dran_services first to see the available toolkits",
            })

        if tool_name == "dran_services_run":
            toolkit = str(args.get("toolkit", "")).strip()
            tool_slug = str(args.get("tool_slug", "")).strip()
            if not toolkit or not tool_slug:
                return json.dumps({"error": "toolkit and tool_slug are required"})
            try:
                data = client.execute_service(toolkit, tool_slug, args.get("arguments"))
            except urllib.error.HTTPError as exc:
                return _services_http_error(exc, toolkit)
            payload = data.get("data") if isinstance(data, dict) else None
            return json.dumps(payload if isinstance(payload, dict) else {})

        if tool_name == "dran_services_wait":
            toolkit = str(args.get("toolkit", "")).strip()
            if not toolkit:
                return json.dumps({"error": "toolkit is required"})
            timeout = _coerce_wait_timeout(args.get("timeout_seconds"))
            deadline = time.monotonic() + timeout
            status = None
            while True:
                payload = client.list_services()
                rows = payload.get("data") if isinstance(payload, dict) else None
                for svc in rows or []:
                    if isinstance(svc, dict) and str(svc.get("toolkit") or "") == toolkit:
                        status = svc.get("status")
                        break
                if str(status or "").upper() == "ACTIVE":
                    return json.dumps({"toolkit": toolkit, "status": "ACTIVE",
                                       "active": True})
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(SERVICE_WAIT_POLL_SECS, remaining))
            return json.dumps({
                "toolkit": toolkit,
                "status": status,
                "active": False,
                "hint": (f"still {status or 'INITIATED'} after waiting {timeout:.0f}s — "
                         "the connect link expires after 10 minutes; re-emit a new one "
                         "with dran_services_connect and ask the user to open it"),
            })

        return json.dumps({"error": f"unknown tool {tool_name}"})
    except urllib.error.HTTPError as exc:
        return _services_http_error(exc, str(args.get("toolkit") or ""))


def _brief(row: Any) -> Dict[str, Any]:
    """La fila resumida de un goal/task/plan: lo que el agente necesita para decidir."""
    if not isinstance(row, dict):
        return {}
    keys = ("id", "slug", "title", "status", "priority", "due_date", "due_on",
            "goal_id", "lock_version", "checklist", "visibility", "owner_user_id",
            "archived")
    return {k: row[k] for k in keys if k in row}


def _checklist_answer(data: Any) -> Dict[str, Any]:
    """Respuesta del checklist: la fila, su checklist y el progreso si vino."""
    payload = data.get("data") if isinstance(data, dict) else None
    out: Dict[str, Any] = {"data": _brief(payload or {})}
    if isinstance(data, dict) and isinstance(payload, dict):
        out["checklist"] = payload.get("checklist")
    if isinstance(data, dict) and data.get("progress") is not None:
        out["progress"] = data["progress"]
    return out


def _trim_results(results: Any, *, body_chars: int = 600) -> list:
    """Keep tool answers bounded: long bodies are truncated, never dropped."""
    if not isinstance(results, list):
        return []
    out = []
    for item in results:
        if not isinstance(item, dict):
            continue
        row = {k: item.get(k) for k in
               ("id", "slug", "title", "page_type", "summary", "tags",
                "score", "created_by", "agent_name", "updated_at")}
        body = item.get("body")
        if isinstance(body, str) and body:
            row["body"] = body[:body_chars]
        out.append({k: v for k, v in row.items() if v is not None})
    return out


_PLUGIN_CTX: Any = None


def _make_handler(tool_name: str):
    """Bind a tool name to the shared handler (Hermes calls handler(args, **kw))."""

    def _handler(args: Dict[str, Any], **kwargs: Any) -> str:
        return _handle_plugin_tool(tool_name, args, **kwargs)

    _handler.__name__ = f"dran_tool_{tool_name}"
    return _handler


def register(ctx) -> None:
    """Register the memory provider AND the knowledge tools.

    Called by the memory-provider loader (plugins/memory) and by normal plugin
    discovery. Both surfaces live in this module by design: one credential, one
    config, one X-Hermes-Agent identity for recall and for tool writes.
    """
    global _PLUGIN_CTX
    _PLUGIN_CTX = ctx

    # 1) Memory provider — the original surface, unchanged.
    try:
        ctx.register_memory_provider(DranMemoryProvider())
    except Exception as exc:  # never let the tool registration cost the provider
        logger.warning("Dran plugin: could not register memory provider: %s", exc)

    # 2) Knowledge tools — each write carries X-Hermes-Agent.
    for schema in _tool_schemas():
        name = schema["name"]
        try:
            ctx.register_tool(
                name=name,
                toolset=_TOOLSET,
                schema=schema,
                handler=_make_handler(name),
                description=schema.get("description", ""),
                emoji="🧠",
            )
        except Exception as exc:
            logger.warning("Dran plugin: could not register tool %s: %s", name, exc)
