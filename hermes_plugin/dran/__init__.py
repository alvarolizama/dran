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
    config["workspace"] = str(config.get("workspace") or DEFAULT_WORKSPACE).strip()
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

    def __init__(self, base_url: str, api_key: str, workspace: str,
                 agent_identity: str = "", timeout: float = REQUEST_TIMEOUT):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
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
        payload: Dict[str, Any] = {"workspace": self.workspace, "content": content}
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
            "content": content, "workspace": self.workspace,
        })

    def search(self, query: str, limit: int = 5) -> list:
        from urllib.parse import urlencode
        qs = urlencode({"q": query, "workspace": self.workspace, "limit": limit})
        data = self.request("GET", f"/api/memory/search?{qs}")
        return data.get("data", [])

    # -- Knowledge endpoints (used by the plugin tools) ------------------

    def search_pages(self, query: str, strategy: str = "auto", limit: int = 10) -> list:
        from urllib.parse import urlencode
        qs = urlencode({"q": query, "workspace": self.workspace,
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
        params = {"workspace": self.workspace, "limit": limit}
        if page_type:
            params["type"] = page_type
        data = self.request("GET", f"/api/knowledge-pages?{urlencode(params)}")
        return data.get("data", []) if isinstance(data, dict) else []

    def list_page_types(self) -> dict:
        """Effective page types of the workspace (built-in ∪ custom) with their
        full definitions, via GET /api/workspaces/:slug/page-types."""
        from urllib.parse import quote
        slug = quote(str(self.workspace), safe="")
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
        qs = urlencode({"workspace": self.workspace, "include": "body"})
        try:
            data = self.request("GET", f"/api/knowledge-pages/{slug}?{qs}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        return data.get("data") if isinstance(data, dict) else None

    def create_page(self, title: str, body: str = "", page_type: str = "note",
                    tags: Optional[List[str]] = None, summary: str = "",
                    meta: Optional[dict] = None) -> dict:
        payload: Dict[str, Any] = {
            "workspace": self.workspace, "title": title, "body": body,
            "page_type": page_type,
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
        return self.request("PUT", f"/api/knowledge-pages/{slug}?{urlencode({'workspace': self.workspace})}",
                            payload)

    def delete_page(self, slug: str) -> bool:
        from urllib.parse import urlencode
        try:
            self.request("DELETE",
                         f"/api/knowledge-pages/{slug}?{urlencode({'workspace': self.workspace})}")
            return True
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return False
            raise

    def get_links(self, slug: str) -> dict:
        from urllib.parse import urlencode
        try:
            data = self.request("GET", f"/api/knowledge-pages/{slug}/links?{urlencode({'workspace': self.workspace})}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return {}
            raise
        return data.get("data", data) if isinstance(data, dict) else {}

    def create_relation(self, source_slug: str, target_slug: str, relation_type: str = "related",
                        description: str = "") -> dict:
        payload: Dict[str, Any] = {
            "workspace": self.workspace, "source_slug": source_slug,
            "target_slug": target_slug, "relation_type": relation_type,
        }
        if description:
            payload["description"] = description
        return self.request("POST", "/api/relations", payload)

    def delete_relation(self, source_slug: str, target_slug: str,
                        relation_type: str = "") -> bool:
        from urllib.parse import urlencode
        params = {"workspace": self.workspace, "source_slug": source_slug,
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
        data = self.request("GET", f"/api/lint?{urlencode({'workspace': self.workspace})}")
        return data.get("data", data) if isinstance(data, dict) else {}

    def rename_slug(self, slug: str, new_slug: str) -> dict:
        from urllib.parse import urlencode
        return self.request(
            "POST",
            f"/api/knowledge-pages/{slug}/rename?{urlencode({'workspace': self.workspace})}",
            {"new_slug": new_slug},
        )

    def reaugment_page(self, slug: str) -> dict:
        from urllib.parse import urlencode
        return self.request(
            "POST",
            f"/api/knowledge-pages/{slug}/reaugment?{urlencode({'workspace': self.workspace})}",
        )

    def generate_cluster_summaries(self) -> dict:
        return self.request("POST", "/api/cluster-summaries", {"workspace": self.workspace})

    def start_worker(self, worker_type: str, input: str = "") -> dict:
        payload = {"workspace": self.workspace, "worker_type": worker_type, "input": input}
        return self.request("POST", "/api/workers", payload)

    def get_worker_session(self, session_id: str) -> Optional[dict]:
        from urllib.parse import urlencode
        try:
            data = self.request(
                "GET",
                f"/api/workers/{session_id}?{urlencode({'workspace': self.workspace})}",
            )
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        return data.get("data") if isinstance(data, dict) else None

    def stats(self) -> dict:
        data = self.request("GET", "/api/workspaces")
        return data.get("data", data) if isinstance(data, dict) else {}

    def feedback(self, memory_id: str, helpful: bool) -> dict:
        return self.request("POST", "/api/memory/feedback", {
            "id": memory_id, "helpful": helpful, "workspace": self.workspace,
        })

    def ingest(self, transcript: str, source_session: str = "") -> dict:
        payload = {"workspace": self.workspace, "transcript": transcript}
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
            "Rate a memory helpful/unhelpful with dran_memory_feedback."
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
    ]


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
            data = client.create_page(
                title=title,
                body=str(args.get("body") or ""),
                page_type=page_type,
                tags=list(args.get("tags") or []),
                summary=str(args.get("summary") or ""),
            )
            page = data.get("data") or {}
            return json.dumps({"created": True, "slug": page.get("slug"), "id": page.get("id")})

        if tool_name == "dran_update_page":
            slug = str(args.get("slug", "")).strip()
            if not slug:
                return json.dumps({"error": "slug is required"})
            fields = {k: args.get(k) for k in ("title", "body", "summary", "tags") if args.get(k) is not None}
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

        return json.dumps({"error": f"unknown tool {tool_name}"})
    except Exception as exc:
        logger.warning("Dran plugin tool %s failed: %s", tool_name, exc)
        return json.dumps({"error": f"dran unavailable: {exc}"})


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
