"""Dran's memory-provider panel — only what the MEMORY half needs.

Pure data only (this module is loaded by path from the web server; it must
not import the agent runtime). It renders ONE file — the same
``$HERMES_HOME/dran/config.json`` the headless runtime (``__init__.py``)
reads — so the panel is a view over the runtime's config, never a second
source of truth (contract W9 / A10).

Everything that is NOT memory lives in ``plugin.yaml``'s ``config_schema``
instead, i.e. the plugins hub's settings gear (Capabilities → Plugins → Dran),
where the plugin is also turned on and off — the credential included. This
panel declares NO field that is not recall behaviour, so nothing here can
diverge from the card.

Two levers shape this panel, and only the panel — the runtime reads the same
keys whatever the flags say:

* ``inline=True`` — one row of the COMPACT panel rendered under
  ``memory.provider``. That panel paints the inline subset **flat, in
  declared order**: it draws no group headers.
* ``group`` — the section the modal **"Full config…"** files the field under
  (first-seen order). The button only exists while at least ONE field is
  non-``inline``; with every field inline there is no modal and the group
  names are labels nobody sees.

Every field here is ``inline``, so the panel shows exactly these five rows and
no modal appears: the recall behaviour, nothing else. ``group`` stays declared
so the day a field needs the modal, the sections are already in place.

Field semantics: ``auto_recall`` / ``auto_capture`` / ``max_recall_results`` /
``max_recall_chars`` / ``recall_cadence`` — what the provider reads on every
turn.

The credential is NOT here: it is the card's ``api_key`` secret, which writes
the profile's ``DRAN_API_KEY`` — and ``_resolve_secret()`` reads that same var,
so the provider keeps working with the token configured in one place only.
"""

from plugins.memory.config_schema import (
    KIND_BOOL,
    KIND_NUMBER,
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
