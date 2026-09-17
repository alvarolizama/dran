"""Dran's declared config surface — rendered by the generic desktop panel.

Pure data only (this module is loaded by path from the web server; it must
not import the agent runtime). Field semantics match the memory provider:

* ``workspace`` — the agent's workspace CHOICE, used by BOTH surfaces this
  plugin provides: the memory provider (facts) and the knowledge toolset
  (pages, relations, workers). One setting, one workspace: a page created by
  ``dran_create_page`` lands in the same workspace the facts go to. Made
  here, in Hermes, from the workspaces the agent's Dran API key may reach
  (Settings → API Keys matrix); the provider validates it against
  ``GET /api/agent/config`` and falls back to the first permitted workspace
  if the key loses access.
* ``api_key`` — secret, lives in the profile ``.env`` (single source of truth,
  shared with the plugin tools). Never read back.
"""

from plugins.memory.config_schema import (
    KIND_BOOL,
    KIND_NUMBER,
    KIND_SECRET,
    KIND_TEXT,
    STORAGE_FLAT_JSON,
    ProviderConfigSchema,
    ProviderField,
)

CONFIG_SCHEMA = ProviderConfigSchema(
    name="dran",
    label="Dran",
    storage=STORAGE_FLAT_JSON,
    fields=(
        ProviderField(
            key="api_key",
            label="API key",
            kind=KIND_SECRET,
            description="Dran API key per agent (Settings → API Keys → Create key). "
            "Attribution: every stored fact is credited to this key's agent.",
            env_key="DRAN_API_KEY",
            placeholder="dran_… (paste from Dran → Settings → API Keys)",
            inline=True,
            group="Connection",
        ),
        ProviderField(
            key="base_url",
            label="Base URL",
            kind=KIND_TEXT,
            description="Dran instance URL.",
            default="http://localhost:4000",
            placeholder="http://localhost:4000",
            inline=True,
            group="Connection",
        ),
        ProviderField(
            key="workspace",
            label="Workspace",
            kind=KIND_TEXT,
            description="Workspace used by BOTH surfaces of this plugin: the memory "
            "provider (facts) and the knowledge tools (pages, relations, workers). "
            "A page created by dran_create_page lands in this same workspace. Must "
            "be one the API key can reach (Dran → Settings → API Keys matrix).",
            default="personal",
            placeholder="personal",
            inline=True,
            group="Memory",
        ),
        ProviderField(
            key="auto_recall",
            label="Auto recall",
            kind=KIND_BOOL,
            description="Inject relevant memories at turn start.",
            default="true",
            inline=True,
            group="Memory",
        ),
        ProviderField(
            key="auto_capture",
            label="Auto capture",
            kind=KIND_BOOL,
            description="Ingest the session transcript at session end (facts "
            "extracted server-side; transcript never persisted).",
            default="true",
            inline=True,
            group="Memory",
        ),
        ProviderField(
            key="max_recall_results",
            label="Max recall results",
            kind=KIND_NUMBER,
            description="Memories injected per turn (1–20).",
            default="5",
            inline=True,
            group="Memory",
        ),
        ProviderField(
            key="max_recall_chars",
            label="Recall char budget",
            kind=KIND_NUMBER,
            description="Max characters of memory context injected per turn. "
                        "Whole facts are dropped when the budget is hit.",
            default="800",
            inline=True,
            group="Memory",
        ),
        ProviderField(
            key="recall_cadence",
            label="Recall cadence (turns)",
            kind=KIND_NUMBER,
            description="Minimum turns between recall searches. 1 = every turn; "
                        "2+ skips the search (and its tokens) on off-turns. "
                        "An unchanged fact set is never re-injected regardless.",
            default="1",
            inline=True,
            group="Memory",
        ),
    ),
)
