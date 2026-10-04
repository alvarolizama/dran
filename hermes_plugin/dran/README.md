# Dran memory — plugin Hermes

Memoria compartida multi-agente respaldada por tu instancia de Dran. El plugin
es transporte delgado: dedupe, trust, search híbrido y extracción de facts
viven server-side en Dran (`/api/memory`).

## Un plugin, un archivo de config, dos superficies

No hay un segundo plugin ni una segunda instalación: las dos superficies viven
en **este** directorio y leen/escriben el **mismo**
`$HERMES_HOME/dran/config.json` (+ el token en el `.env` del perfil).

- **Runtime** (`__init__.py`): el MemoryProvider (sus tools salen de
  `get_tool_schemas()`) y las tools de agente que registra `register(ctx)`.
  Headless por construcción: archivos + `DRAN_API_KEY`, sin UI propia.
- **Panel** (`config_schema.py`): Hermes lo lee **del disco, al lado de este
  archivo** (`plugins/memory/__init__.py::find_provider_dir` →
  `get_provider_config_schema`) y lo renderiza como el panel de configuración
  del proveedor de memoria. Escribe **ese mismo** `config.json`.

El panel se direcciona **por nombre de proveedor**, y por eso no puede vivir en
otro plugin: pertenece al proveedor que configura. Como el pedido del panel
viaja con el perfil (`?profile=<nombre>`), configura **el perfil que el app
tenga seleccionado, remotos incluidos** — sin plugin extra y sin código extra.

No hay un segundo archivo de config ni una segunda credencial: **un solo token**
(`DRAN_API_KEY`, el `api_token` de la cuenta) para las dos superficies (W9/A10).

> **Single-workspace (W5):** la instancia de Dran ES el workspace — no hay
> elección de workspace ni matriz workspaces×nivel. Toda llamada apunta a la
> instancia; ya no existe un setting `workspace` en la config del plugin.

## Configuración — el panel de memoria del perfil

El plugin trae `config_schema.py`, así que Hermes renderiza el panel solo. En el
**app desktop**: **Settings → Memory & Context** → elegí **Memory provider:
`dran`** y el panel de Dran aparece **justo debajo** (fields: API key, Base
URL, Write scope, Group slug, Auto recall, Auto capture, Max recall results,
Recall char budget, Recall cadence). Guarda campo por campo (autosave).

Por **perfil**, remotos incluidos: el panel se pide con el perfil activo
(`GET/PUT /api/memory/providers/dran/config?surface=declared&profile=<perfil>`),
así que si el app está conectado a un gateway remoto, estás editando **la config
de ESE perfil** — la que vive en el `config.json` de su host. Nada extra que
instalar del lado del app: alcanza con que el plugin esté instalado y con
`memory.provider: dran` en ese perfil.

También funciona `hermes memory setup` → elegir "dran" (CLI, mismo archivo).

Se persiste en `$HERMES_HOME/dran/config.json` (la credencial al `.env` del
perfil — `DRAN_API_KEY`, único hogar del token, compartido por el runtime y
todas las tools).

## La instancia es el workspace

El agente guarda sus facts y páginas en la instancia que sirve su `base_url`,
sin más. La credencial define el alcance: el token lee y escribe **exactamente
lo que su dueño** (lo privado del dueño, lo público, y lo compartido con él).

### El destino de escritura: `scope`

Cada escritura declara a dónde va con **`scope`** (W6, Rules#5) — el
vocabulario de la **intención**, no la columna de almacenamiento:

| `scope` | Qué significa |
|---|---|
| `private` (default) | Solo la cuenta dueña del token. |
| `public` | Todos en la instancia. |
| `group` + slug | Solo los miembros de ese grupo. |

El servidor traduce `scope` a `visibility` + un share en `content_shares`,
**valida la membresía y falla cerrado (422)** si el grupo no existe o no es
tuyo. El grupo viaja por **slug** (su identidad estable y copiable);
`GET /api/groups` (W7) lista los grupos donde sos miembro. En el panel, el
default del perfil se elige con los campos **Write scope** y **Group slug**
(el slug solo aplica cuando el scope es `group`).

La misma respuesta trae los **page types efectivos** de la instancia
(`page_types` y `page_type_defs`: los 4 built-in — `note`, `entity`, `concept`,
`reference` — más los tipos custom que la instancia declare). El plugin los lee
para renderizar el vocabulario en sus tools en vez de hardcodear la lista, y
valida `page_type` contra ellos antes de crear una página (fail-closed); sin
servidor cae a los 4 built-in.

La tool `dran_list_page_types` expone esa lista al agente con las definiciones
completas (slug, label, plural, path, icon, color, meta fields) vía
`GET /api/workspaces/instance/page-types` — alcanzable por cualquier token con
read, no solo por agent keys (a diferencia de `/api/agent/config`).

## Setup (por perfil de Hermes)

1. En Dran → Settings → **Account**: copia el **API token** de la cuenta. Es la
   credencial única (W3, `users.api_token`): **no crea un actor**. El
   `created_by` de cada recuerdo lo resuelve el servidor — el header
   `X-Hermes-Agent` si viene, si no el **email de la cuenta** — y
   `owner_user_id` es la cuenta dueña del token.
2. Guarda el token **una sola vez** en el `.env` del perfil:

   ```bash
   # ~/.hermes/profiles/<perfil>/.env
   DRAN_API_KEY=dran_sk_...
   ```

   Ese mismo valor lo consume el plugin entero (memory provider + tools).
3. Configura el resto desde el **app desktop**: **Settings → Memory & Context**
   → elegí Memory provider **`dran`** y completá el panel que aparece justo
   debajo (o `hermes memory setup` → "dran"). El token pégalo en el campo del
   panel — va al `.env`, no al JSON.
   **Perfil remoto**: lo mismo con el app apuntando a ese perfil; el panel
   escribe la config de ESE host (el perfil viaja en el pedido).

   Editada a mano, la config vive en `$HERMES_HOME/dran/config.json`:

   ```json
   {
     "base_url": "http://localhost:4000",
     "scope": "private",
     "scope_group": "",

     "auto_recall": true,
     "auto_capture": true,
     "max_recall_results": 5,
     "max_recall_chars": 800,
     "recall_cadence": 1
   }
   ```

   (`api_key` se resuelve desde `DRAN_API_KEY`; un literal en el JSON gana,
   para overrides por agente.)

   | Key | Default | Qué controla |
   |---|---|---|
   | `scope` | `private` | Destino por escritura del perfil: `private` \| `public` \| `group` (+ `scope_group`) |
   | `max_recall_results` | 5 | Facts por recall (1–20) |
   | `max_recall_chars` | 800 | Budget de caracteres inyectados por turno — corta en hechos completos, nunca a media frase |
   | `recall_cadence` | 1 | Mínimo de turnos entre búsquedas de recall. 1 = cada turno; 2+ se salta la búsqueda (y sus tokens) en los turnos off |

4. Instala el plugin en el perfil (symlink — la fuente vive en este repo):

   ```bash
   ln -s ~/Workspace/Repos/alvarolizama/dran/hermes_plugin/dran \
         ~/.hermes/profiles/<perfil>/plugins/dran
   ```

5. Reinicia la sesión de Hermes y verifica: "¿qué recuerdas de ...?"

## Qué hace

| Hook | Comportamiento |
|---|---|
| `queue_prefetch` | Recall en background → `GET /api/memory/search`. La query se enriquece con la conversación reciente (seguimientos cortos como "¿y eso por qué?" también recuerdan); la cadence salta la búsqueda en turnos off |
| `prefetch` | Inyecta el cache sin bloquear el turno. Si el set de facts es idéntico al ya inyectado, **no re-inyecta** (ahorro de tokens); el presupuesto de chars corta en hechos completos |
| `system_prompt_block` | Instrucción corta: ofrece guardar hechos durables con `dran_memory_add` |
| tools | `dran_memory_search`, `dran_memory_add` (con `force` y manejo de 409 near-duplicate), `dran_memory_update`, `dran_memory_feedback` |
| `on_session_end` | POST al ingest de Dran **solo con el delta de mensajes** (cursor por sesión en `$HERMES_HOME/dran_memory_cursor.json`): una sesión que termina dos veces no re-paga la extracción LLM. El transcript nunca se persiste |

### Robustez de transporte

- **Retry**: los GET idempotentes reintentan una vez con backoff; los 4xx
  (salvo 429) no se reintentan — el servidor ya respondió.
- **Circuit breaker**: tras 3 fallos consecutivos, todas las llamadas
  fallan rápido durante 60 s — un Dran caído no agrega un timeout a cada
  turno. Cualquier éxito rearma el contador.

## Tools del plugin

Desde la v1.1 el módulo expone `register(ctx)`, que registra **dos
superficies en el mismo plugin**: el memory provider (arriba) y un toolset
`dran` con las operaciones de conocimiento (cliente delgado sobre la API
REST de Dran):
estas tools son el consumo del agente.

| Tool | Qué hace |
|---|---|
| `dran_search` | Busca páginas (fts / fuzzy / semantic / hybrid) |
| `dran_list_pages` | Lista páginas, filtrable por tipo (los válidos son los efectivos de la instancia, leídos de `/api/agent/config`) |
| `dran_list_page_types` | Lista los page types efectivos (4 built-in + custom) con sus definiciones — slug, label, plural, path, icon, color, meta fields — vía `GET /api/workspaces/instance/page-types` |
| `dran_get_page` | Lee el cuerpo completo por slug |
| `dran_create_page` / `dran_update_page` / `dran_delete_page` | Ciclo de vida de páginas (`page_type` se valida fail-closed contra los tipos efectivos de la instancia) |
| `dran_get_links` | Relaciones entrantes/salientes de una página |
| `dran_create_relation` / `dran_delete_relation` | Relaciones tipadas y dirigidas |
| `dran_start_worker` / `dran_get_worker_session` | Dispara y sondea curator / link_gardener / graph_rag |
| `dran_lint_brain` | Auditoría estructural (read-only) |
| `dran_stats` | Números del dashboard |

### Goals, tasks y planes (contrato de superficies)

El contenedor de trabajo y el plan, cada uno cliente delgado de una ruta del
REST. El **destino de una escritura** se declara con `scope` (`private` —
default — o `public`) o con `group` (el slug del grupo donde el dueño es
miembro): el servidor valida la membresía y falla cerrado con 422. En el **alta**
de un goal o un plan, si la herramienta no declara destino se aplica el default
del perfil (los campos *Write scope* / *Group slug* del panel); una **edición** no
mueve el destino salvo que lo declare. Para elegir el grupo por nombre hay
`dran_list_groups` (`GET /api/groups` → `[{slug, name}]` de tus membresías): el
slug es lo que después viaja en `group`.

| Tool | Ruta que golpea |
|---|---|
| `dran_list_groups` | `GET /api/groups` — tus grupos (membresías del lector) para elegir el destino por nombre |
| `dran_list_goals` / `dran_get_goal` | `GET /api/goals`, `GET /api/goals/:id` (+ sus tasks) |
| `dran_create_goal` / `dran_update_goal` / `dran_delete_goal` | `POST`, `PUT`, `DELETE /api/goals[/:id]` |
| `dran_list_tasks` / `dran_get_task` | `GET /api/tasks`, `GET /api/tasks/:id` |
| `dran_create_task` | `POST /api/tasks` — sin `goal` aterriza en el **goal bandeja** del dueño |
| `dran_capture` | `POST /api/capture` — la captura rápida, misma bandeja |
| `dran_update_task` | `PUT /api/tasks/:id` — contenido, **nunca** `status`/`goal_id` (eso es del move) |
| `dran_move_task` | `POST /api/tasks/:id/move` — columna, posición y/o goal, atómico, con `lock_version` (409 al desfase) |
| `dran_delete_task` | `DELETE /api/tasks/:id` |
| `dran_list_plans` / `dran_get_plan` | `GET /api/plans`, `GET /api/plans/:id` (+ su checklist y el progreso DERIVADO) |
| `dran_create_plan` / `dran_update_plan` / `dran_delete_plan` | `POST`, `PUT`, `DELETE /api/plans[/:id]` |
| `dran_set_plan_checklist` | `PUT /api/plans/:id/checklist` — reemplaza el array ordenado |
| `dran_toggle_checklist` | `POST /api/checklist/toggle` — tacha/destacha UN ítem de un plan o de una task (`{"target": "plan"\|"task", "id", "index"\|"text"}`) |

El plan es una **entidad** (tabla `plans`, dueño + visibilidad), no un tipo de
página: sus pasos son el mismo checklist jsonb `[%{text, done}]` de la task, y
`plan` no se declara como tipo de página custom (el vocabulario es uno solo).

### Servicios (las apps del usuario)

Cada persona conecta SUS apps (Gmail, calendario, GitHub, Slack…) y su agente las
usa. Cinco tools fijas, thin clients de `/api/services` — **el catálogo viaja como
DATO**, así que el número de tools no crece con los toolkits conectados (no hay
`dran_gmail_*` ni equivalentes).

| Tool | Ruta que golpea |
|---|---|
| `dran_services` | `GET /api/services` — qué expone la instancia y qué tiene conectado ESTE lector, con el estado del ciclo de vida y la identidad del proveedor |
| `dran_services_connect` | `POST /api/services/:toolkit/connect` — el link hospedado que el agente le pega al usuario (vive 10 minutos: vencido se pide uno NUEVO) |
| `dran_services_tools` | `GET /api/services/:toolkit/tools[?slug=]` o `GET /api/services/search?q=` — descubrir por toolkit, por tool concreta o por caso de uso |
| `dran_services_run` | `POST /api/services/execute` — ejecutar; sin conexión `ACTIVE` el 409 llega con su `connect_url` (fail-closed, nunca un éxito falso) |
| `dran_services_wait` | `GET /api/services` en bucle corto (tope 30 s) hasta `ACTIVE`, para no ejecutar antes de tiempo |

El inventario entra en el prefetch (misma pasada y misma cadencia que el recall:
a lo sumo un `GET /api/services` por ventana) y la línea estática del provider
nombra los disparadores, así que el agente sabe que la capacidad existe sin
pedir la lista.

Cada tool escribe por `_DranClient`, así que **todo write lleva
`X-Hermes-Agent`** con el nombre del perfil. El handler recibe `(args, **kw)`
— Hermes no pasa el nombre de la tool — así que `register()` ata el nombre
por closure (`_make_handler`).

## Identidad y contextos

- `initialize` recibe `agent_identity` (nombre del perfil) → header
  `X-Hermes-Agent` en cada request. Dran lo persiste server-side como
  `agent_name` del contenido escrito; si el header falta, el `created_by` es el
  **email de la cuenta** dueña del token. `owner_user_id` = la cuenta dueña del
  token (W3: una sola credencial, `users.api_token`). El header es atribución,
  no autorización: nunca amplía acceso.
- `agent_context != "primary"` (subagent, cron): prefetch permitido,
  **writes deshabilitados** — los agentes secundarios no contaminan la
  memoria compartida.

## Tests

```bash
python3 -m pytest hermes_plugin/tests/ -q
```

Cubren el registro (provider + tools, schemas válidos, un fallo de tool no
cuesta el provider), el header en cada path de escritura, las rutas REST, el
manejo de errores como JSON y la **discovery de page types efectivos** desde
`/api/agent/config` (con fallback a los 4 built-in y rechazo fail-closed de un
tipo retirado al crear).
