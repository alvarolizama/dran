"""Dran's declared config surface — the DESKTOP PANEL half of the plugin.

Pure data only (this module is loaded by path from the web server; it must
not import the agent runtime). It renders ONE file — the same
``$HERMES_HOME/dran/config.json`` the headless runtime (``__init__.py``)
reads — so the panel is a view over the runtime's config, never a second
source of truth (contract W9 / A10). Field semantics match the memory
provider and the knowledge tools:

* Two levers shape the DESKTOP surface, and only the surface — the runtime
  reads the same keys whatever the flags say:

  - ``inline=True`` — one row of the COMPACT panel rendered under
    ``memory.provider``. That panel paints the inline subset **flat, in
    declared order**: it draws no group headers.
  - ``group`` — the section the modal **"Full config…"** files the field
    under (first-seen order). The button only exists while at least ONE field
    is non-``inline``; with every field inline there is no modal and the group
    names are labels nobody sees.

  Hence the split: the panel carries what a user comes here to change
  (credential, write destination, the seven tool switches — 11 rows) and the
  recall tuning knobs live in the grouped modal. ``group`` stays on the inline
  fields too, so the modal shows the WHOLE surface, grouped, in one screen.

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
            description="Default destination of this profile's GOAL and PLAN "
            "writes — the vocabulary of the intention (W6). A tool that declares "
            "its own `scope`/`group` wins over this default, and edits never "
            "move a destination. The server translates it to visibility + a "
            "share and validates group membership, failing closed (422). "
            "private: only your account (default). public: everyone on the "
            "instance. group: only the members of the group whose slug you set "
            "below (an empty or unknown slug fails closed, never private in "
            "silence).",
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
            description="Slug of the group this profile's goal and plan writes go to "
            "when Write scope is 'group'. List your groups with GET /api/groups "
            "(or the agent tool `dran_list_groups`) — the slug is the group's "
            "stable, copyable id (W7). An unknown slug fails closed (422).",
            placeholder="e.g. research-team",
            inline=True,
            group="Write destination",
        ),
        # ── Tools: una superficie por grupo ────────────────────────────────
        # Las 46 knowledge tools son SIETE superficies, y cada grupo tiene DOS
        # interruptores sobre la misma cosa: este campo (que el panel escribe
        # como `tools.<group>` en el JSON) y un TOOLSET de Hermes
        # (`dran_pages`, `dran_goals`, `dran_tasks`, `dran_plans`,
        # `dran_services`, `dran_skills`, `dran_brain`) que el operador corta
        # con `hermes tools disable dran_pages`, `platform_toolsets` o
        # `agent.disabled_toolsets` — por perfil y por plataforma.
        #
        # Un grupo apagado esconde sus tools del modelo Y del catálogo de
        # tool_search, y sus llamadas se rechazan sin efecto. Aplica a la
        # PRÓXIMA sesión: la que está en vuelo conserva su superficie (el
        # prompt no se reescribe a mitad de conversación).
        ProviderField(
            key="pages",
            label="Pages & relations",
            kind=KIND_BOOL,
            description="Search, list, read, create, update, delete and relink "
            "knowledge pages (dran_search, dran_*_page, dran_rename_slug, "
            "dran_reaugment_page, dran_*_relation, dran_get_links). "
            "Hermes toolset: dran_pages.",
            default="true",
            inline=True,
            group="Tools",
        ),
        ProviderField(
            key="goals",
            label="Goals",
            kind=KIND_BOOL,
            description="The container of work: list, read, create, update and "
            "delete goals, plus dran_list_groups (the destination slugs a goal "
            "or plan write can target). Hermes toolset: dran_goals.",
            default="true",
            inline=True,
            group="Tools",
        ),
        ProviderField(
            key="tasks",
            label="Tasks & capture",
            kind=KIND_BOOL,
            description="List, read, create, update, move and delete tasks, plus "
            "dran_capture (quick capture: a task into the inbox goal). "
            "Hermes toolset: dran_tasks.",
            default="true",
            inline=True,
            group="Tools",
        ),
        ProviderField(
            key="plans",
            label="Plans & checklists",
            kind=KIND_BOOL,
            description="List, read, create, update and delete plans, and tick "
            "their checklist (dran_set_plan_checklist, dran_toggle_checklist). "
            "Hermes toolset: dran_plans.",
            default="true",
            inline=True,
            group="Tools",
        ),
        ProviderField(
            key="services",
            label="Connected services",
            kind=KIND_BOOL,
            description="Inspect the connected services, emit a connect link, "
            "DISCOVER a toolkit's tool catalog and run one of its tools "
            "(dran_services*). The catalog travels as data — never one tool per "
            "toolkit. Hermes toolset: dran_services.",
            default="true",
            inline=True,
            group="Tools",
        ),
        ProviderField(
            key="skills",
            label="Remote skills",
            kind=KIND_BOOL,
            description="List the workspace's skills, load one body by slug, and "
            "save or delete one (dran_skills, dran_skill, dran_skill_save, "
            "dran_skill_delete). Hermes toolset: dran_skills.",
            default="true",
            inline=True,
            group="Tools",
        ),
        ProviderField(
            key="brain",
            label="Brain & workers",
            kind=KIND_BOOL,
            description="The agent-side brain: start an autonomous worker "
            "session and read it back, regenerate cluster summaries, audit the "
            "workspace's structure and read the dashboard numbers "
            "(dran_start_worker, dran_get_worker_session, "
            "dran_generate_cluster_summaries, dran_lint_brain, dran_stats). "
            "Hermes toolset: dran_brain.",
            default="true",
            inline=True,
            group="Tools",
        ),
        # ── Memory: los knobs de recall, en el modal ───────────────────────
        # NO son `inline`: no son fila del panel compacto, y por eso obligan a
        # que exista el botón "Full config…", donde el renderer agrupa por
        # `group` (Connection / Write destination / Tools / Memory, en orden de
        # primera aparición). El runtime los lee igual: la partición es de la
        # UI, no del archivo.
        ProviderField(
            key="auto_recall",
            label="Auto recall",
            kind=KIND_BOOL,
            description="Inject relevant memories at turn start.",
            default="true",
            group="Memory",
        ),
        ProviderField(
            key="auto_capture",
            label="Auto capture",
            kind=KIND_BOOL,
            description="Ingest the session transcript at session end (facts "
            "extracted server-side; transcript never persisted).",
            default="true",
            group="Memory",
        ),
        ProviderField(
            key="max_recall_results",
            label="Max recall results",
            kind=KIND_NUMBER,
            description="Memories injected per turn (1–20).",
            default="5",
            group="Memory",
        ),
        ProviderField(
            key="max_recall_chars",
            label="Recall char budget",
            kind=KIND_NUMBER,
            description="Max characters of memory context injected per turn. "
                        "Whole facts are dropped when the budget is hit.",
            default="800",
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
            group="Memory",
        ),
    ),
)
