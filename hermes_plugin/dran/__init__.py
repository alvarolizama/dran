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
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

from agent.memory_provider import MemoryProvider, RecallStatus

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "http://localhost:4000"
DEFAULT_WORKSPACE = "personal"
CONFIG_FILENAME = "dran_memory.json"
REQUEST_TIMEOUT = 5.0
INGEST_TIMEOUT = 30.0
MAX_PREFETCH_CHARS = 800
MAX_INGEST_MESSAGES = 40
MAX_INGEST_CHARS = 12_000


def _default_config() -> dict:
    return {
        "base_url": DEFAULT_BASE_URL,
        "api_key": "",
        "workspace": DEFAULT_WORKSPACE,
        "auto_recall": True,
        "auto_capture": True,
        "max_recall_results": 5,
    }


def _load_dran_config(hermes_home: str) -> dict:
    config = _default_config()
    config_path = Path(hermes_home) / CONFIG_FILENAME
    if config_path.exists():
        try:
            raw = json.loads(config_path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                config.update({k: v for k, v in raw.items() if v is not None})
        except Exception:
            logger.debug("Failed to parse %s", config_path, exc_info=True)

    config["base_url"] = str(config.get("base_url") or DEFAULT_BASE_URL).strip().rstrip("/")
    config["api_key"] = str(config.get("api_key") or "").strip()
    config["workspace"] = str(config.get("workspace") or DEFAULT_WORKSPACE).strip()
    config["auto_recall"] = bool(config.get("auto_recall", True))
    config["auto_capture"] = bool(config.get("auto_capture", True))
    try:
        config["max_recall_results"] = max(1, min(20, int(config.get("max_recall_results", 5))))
    except Exception:
        config["max_recall_results"] = 5
    return config


def _save_dran_config(values: dict, hermes_home: str) -> None:
    config_path = Path(hermes_home) / CONFIG_FILENAME
    existing = _load_dran_config(hermes_home)
    existing.update({k: v for k, v in (values or {}).items() if v is not None})
    config_path.write_text(json.dumps(existing, indent=2), encoding="utf-8")


class _DranClient:
    """Minimal REST client for Dran's /api/memory endpoints."""

    def __init__(self, base_url: str, api_key: str, workspace: str,
                 agent_identity: str = "", timeout: float = REQUEST_TIMEOUT):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.workspace = workspace
        self.agent_identity = agent_identity
        self.timeout = timeout

    def _headers(self) -> Dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if self.agent_identity:
            headers["X-Hermes-Agent"] = self.agent_identity
        return headers

    def request(self, method: str, path: str, payload: Any = None,
                timeout: float | None = None) -> Any:
        url = f"{self.base_url}{path}"
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(url, data=body, method=method,
                                     headers=self._headers())
        with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
            raw = resp.read().decode("utf-8")
        if not raw:
            return {}
        return json.loads(raw)

    # -- Memory endpoints ------------------------------------------------

    def add_memory(self, content: str, source_session: str = "") -> dict:
        payload = {"workspace": self.workspace, "content": content}
        if source_session:
            payload["source_session"] = source_session
        return self.request("POST", "/api/memory", payload)

    def search(self, query: str, limit: int = 5) -> list:
        from urllib.parse import urlencode
        qs = urlencode({"q": query, "workspace": self.workspace, "limit": limit})
        data = self.request("GET", f"/api/memory/search?{qs}")
        return data.get("data", [])

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
                f"$HERMES_HOME/{CONFIG_FILENAME}")

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
        # Validate connection in the background — never block agent startup.
        threading.Thread(target=self._probe_connection, daemon=True).start()

    def _probe_connection(self) -> None:
        if not self._client:
            return
        ok = self._client.ping()
        if ok:
            logger.info("Dran memory: connected to %s (workspace=%s, agent=%s)",
                        self._config["base_url"], self._config["workspace"],
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
        if self._worker and self._worker.is_alive():
            return  # a recall is already in flight — skip, next turn will retry

        self._last_injected = 0  # a new recall cycle starts
        def work():
            try:
                results = self._client.search(query.strip(),
                                              limit=self._config["max_recall_results"])
                text = self._format_results(results)
                with self._prefetch_lock:
                    self._prefetch_cache = text
                    self._prefetch_count = len(results)
            except Exception:
                logger.debug("Dran prefetch failed", exc_info=True)

        self._worker = threading.Thread(target=work, daemon=True)
        self._worker.start()

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        with self._prefetch_lock:
            cached = self._prefetch_cache
            # Recall contract: recall_status must reflect ONLY the LAST
            # prefetch — keep the count after consuming the cache.
            self._last_injected = self._prefetch_count
            self._prefetch_cache = ""
            self._prefetch_count = 0
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
                "description": "Store a durable, atomic fact in the shared Dran memory. One fact per call, self-contained sentence.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "content": {"type": "string", "description": "The fact, one standalone sentence"}
                    },
                    "required": ["content"],
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
                content = str((args or {}).get("content", "")).strip()
                if not content:
                    return json.dumps({"error": "content is required"})
                if self._agent_context != "primary":
                    return json.dumps({"error": "memory writes are disabled in this context"})
                if not self._config.get("auto_capture"):
                    return json.dumps({"skipped": "auto_capture disabled"})
                data = self._client.add_memory(content, source_session=self._session_id) if self._client else {}
                dup = bool(data.get("duplicate"))
                memory = data.get("data") or {}
                return json.dumps({
                    "stored": True,
                    "duplicate": dup,
                    "id": memory.get("id"),
                    "note": "fact already existed" if dup else "fact stored",
                })

            if tool_name == "dran_memory_feedback":
                memory_id = str((args or {}).get("memory_id", ""))
                helpful = bool((args or {}).get("helpful", True))
                if not memory_id:
                    return json.dumps({"error": "memory_id is required"})
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
            transcript = self._transcript_text(messages)
            if not transcript:
                return
            data = self._client.ingest(transcript, source_session=self._session_id)
            logger.info("Dran memory ingest: created=%s duplicates=%s",
                        data.get("created", 0), data.get("duplicates", 0))
        except Exception:
            logger.warning("Dran memory ingest failed (session continues)", exc_info=True)

    def shutdown(self) -> None:
        if self._worker and self._worker.is_alive():
            self._worker.join(timeout=2.0)

    # -- Helpers ----------------------------------------------------------------

    def _format_results(self, results: list) -> str:
        if not results:
            return ""
        lines = ["Relevant shared memories (Dran):"]
        for r in results:
            content = str(r.get("content", "")).strip()
            if content:
                lines.append(f"- [{r.get('created_by', '?')}] {content}")
        text = "\n".join(lines)
        return text[:MAX_PREFETCH_CHARS]

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
