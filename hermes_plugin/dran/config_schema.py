"""Dran's declared config surface — the DESKTOP PANEL half of the plugin.

Pure data only (this module is loaded by path from the web server; it must
not import the agent runtime). It renders ONE file — the same
``$HERMES_HOME/dran/config.json`` the headless runtime (``__init__.py``)
reads — so the panel is a view over the runtime's config, never a second
source of truth (contract W9 / A10). Field semantics match the memory
provider and the knowledge tools:

* ``scope`` / ``scope_group`` — the DEFAULT destination of this profile's
  writes, in the vocabulary of the INTENTION (contract W6 / Rules#5):
  ``private`` (default) | ``public`` | ``group`` + the target group's slug.
  The server translates it to ``visibility`` + ``content_shares``, validates
  membership and fails closed (422). The group travels as its SLUG — its
  stable, copyable id; ``GET /api/groups`` lists the groups you belong to.
* ``api_key`` — secret, lives in the profile ``.env`` (single source of
  truth, shared with the runtime and every tool). It is the ACCOUNT's
  ``api_token`` (W3: one credential per user, ``users.api_token``), never
  read back.
"""

from plugins.memory.config_schema import (
    KIND_BOOL,
    KIND_NUMBER,
    KIND_SECRET,
    KIND_SELECT,
    KIND_TEXT,
    STORAGE_FLAT_JSON,
    ProviderConfigSchema,
    ProviderField,
    ProviderFieldOption,
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
            key="scope",
            label="Write scope",
            kind=KIND_SELECT,
            description="Default destination of this profile's writes — the "
            "vocabulary of the intention (W6). The server translates it to "
            "visibility + a share and validates group membership, failing "
            "closed (422). private: only your account (default). public: "
            "everyone on the instance. group: only the members of the group "
            "whose slug you set below.",
            default="private",
            options=(
                ProviderFieldOption(
                    "private",
                    "Private — only my account",
                    "Default: the write is visible to you alone.",
                ),
                ProviderFieldOption(
                    "public",
                    "Public — everyone on the instance",
                ),
                ProviderFieldOption(
                    "group",
                    "Group — its members only",
                    "The target group is identified by its slug (below).",
                ),
            ),
            inline=True,
            group="Write destination",
        ),
        ProviderField(
            key="scope_group",
            label="Group slug",
            kind=KIND_TEXT,
            description="Slug of the group this profile's writes go to when "
            "Write scope is 'group'. List your groups with GET /api/groups — "
            "the slug is the group's stable, copyable id (W7).",
            placeholder="e.g. research-team",
            inline=True,
            group="Write destination",
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
