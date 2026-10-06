"""Dran's memory-provider panel — only what the MEMORY half needs.

Pure data only (this module is loaded by path from the web server; it must
not import the agent runtime). It renders ONE file — the same
``$HERMES_HOME/dran/config.json`` the headless runtime (``__init__.py``)
reads — so the panel is a view over the runtime's config, never a second
source of truth (contract W9 / A10).

Everything that is NOT memory lives in ``plugin.yaml``'s ``config_schema``
instead, i.e. the plugins hub's settings gear (Capabilities → Plugins → Dran),
where the plugin is also turned on and off. There is no overlap between the
two surfaces except the credential, which is the same ``DRAN_API_KEY`` in the
profile ``.env`` on both sides — one file, so the two fields cannot diverge.

Two levers shape this panel, and only the panel — the runtime reads the same
keys whatever the flags say:

* ``inline=True`` — one row of the COMPACT panel rendered under
  ``memory.provider``. That panel paints the inline subset **flat, in
  declared order**: it draws no group headers.
* ``group`` — the section the modal **"Full config…"** files the field under
  (first-seen order). The button only exists while at least ONE field is
  non-``inline``; with every field inline there is no modal and the group
  names are labels nobody sees.

Every field here is ``inline``, so the panel shows exactly these six rows and
no modal appears: the memory behaviour, nothing else. ``group`` stays declared
so the day a field needs the modal, the sections are already in place.

Field semantics:

* ``api_key`` — secret, lives in the profile ``.env`` (single source of
  truth, shared with the runtime, every tool, and the plugins hub card). It is
  the ACCOUNT's ``api_token`` (W3: one credential per user,
  ``users.api_token``), never read back. Kept here as well as on the card
  because this panel and ``hermes memory setup`` are the doors a memory-only
  operator walks through, and the provider cannot answer without it.
* ``auto_recall`` / ``auto_capture`` / ``max_recall_results`` /
  ``max_recall_chars`` / ``recall_cadence`` — the recall behaviour the
  provider reads on every turn.
"""

from plugins.memory.config_schema import (
    KIND_BOOL,
    KIND_NUMBER,
    KIND_SECRET,
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
            description="Dran account token (Settings → Account → API token). "
            "One credential per account (W3): the same token backs the runtime "
            "and the tools. Every write is attributed to the account, plus the "
            "X-Hermes-Agent profile header as the agent name.",
            env_key="DRAN_API_KEY",
            placeholder="dran_… (paste from Dran → Settings → Account)",
            inline=True,
            group="Connection",
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
