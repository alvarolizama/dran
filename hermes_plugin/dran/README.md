# Dran memory — plugin Hermes

Memoria compartida multi-agente respaldada por tu instancia de Dran. El plugin
es transporte delgado: dedupe, trust, search híbrido y extracción de facts
viven server-side en Dran (`/api/memory`).

## Un plugin, dos archivos de config, dos superficies

No hay un segundo plugin ni una segunda instalación: las dos superficies viven
en **este** directorio, comparten **un solo token** (`DRAN_API_KEY` en el
`.env` del perfil) y reparten la configuración así:

| Qué | Dónde se edita | Dónde se guarda |
|---|---|---|
| **Runtime** (`__init__.py`) | — | — |
| **Tarjeta**: instancia, destino de escritura, los 7 toggles, token | **Capabilities → Plugins → Dran → engranaje** (o el TUI) | `plugins.entries.dran.settings` del perfil (`config.yaml`); el token al `.env` |
| **Panel de memoria**: recall (auto recall/capture, topes, cadencia) | **Settings → Memory & Context** → `Memory provider: dran` | `$HERMES_HOME/dran/config.json` |

- **Runtime** (`__init__.py`): el MemoryProvider (sus tools salen de
  `get_tool_schemas()`) y las tools de agente que registra `register(ctx)`.
  Headless por construcción: archivos + `DRAN_API_KEY`, sin UI propia.
- **Tarjeta** (`plugin.yaml` → `config_schema`): declarada en el manifiesto,
  así que la fila del plugin en el hub — donde el plugin también se
  activa/desactiva — gana su engranaje de settings. Claves **planas**
  (`pages`, no `tools.pages`): `plugins_settings.py` guarda las dotted
  anidadas y las re-lee planas, así que una clave dotted mostraría el default
  sobre el valor guardado.
- **Panel** (`config_schema.py`): Hermes lo lee **del disco, al lado de este
  archivo** (`plugins/memory/__init__.py::find_provider_dir` →
  `get_provider_config_schema`) y lo renderiza como el panel de configuración
  del proveedor de memoria. Escribe **su** `config.json`.

**Precedencia, por clave:** defaults ← tarjeta ← `config.json` (gana). El JSON
es lo que el panel de memoria escribió históricamente y lo que un archivo
editado a mano sigue diciendo: un setup ya existente no cambia de sentido.

El panel se direcciona **por nombre de proveedor**, y por eso no puede vivir en
otro plugin: pertenece al proveedor que configura. Como el pedido del panel
viaja con el perfil (`?profile=<nombre>`), configura **el perfil que el app
tenga seleccionado, remotos incluidos** — sin plugin extra y sin código extra.
La tarjeta también es por perfil: el runtime lee la del perfil activo, y el
proveedor — que no recibe `ctx` — la resuelve por `get_hermes_home()`.

No hay un segundo archivo de config para la credencial: **un solo token**
(`DRAN_API_KEY`, el `api_token` de la cuenta) para las dos superficies (W9/A10).

> **Single-workspace (W5):** la instancia de Dran ES el workspace — no hay
> elección de workspace ni matriz workspaces×nivel. Toda llamada apunta a la
> instancia; ya no existe un setting `workspace` en la config del plugin.

## Configuración — la tarjeta del plugin y el panel de memoria

**La tarjeta** (`plugin.yaml` → `config_schema`): **Capabilities → Plugins →
Dran → engranaje** (el mismo engranaje aparece sólo si el manifiesto declara
`config_schema`; el TUI tiene la misma puerta). Ahí viven la instancia, el
destino de escritura, la credencial y los **siete toggles** de tools. Se guarda
por campo, en `plugins.entries.dran.settings` del perfil (`config.yaml`); el
token va al `.env` por la ruta de credenciales, nunca al YAML.

**El panel de memoria** (`config_schema.py`): **Settings → Memory & Context** →
elegí **Memory provider: `dran`** y el panel de Dran aparece **justo debajo**,
con **sólo** lo de memoria — API key, Auto recall, Auto capture, Max recall
results, Recall char budget, Recall cadence. Los seis campos son `inline`, así
que se listan en orden, sin cabeceras y **sin** el botón "Full config…".
Guarda campo por campo (autosave), en `$HERMES_HOME/dran/config.json`.

Por **perfil**, remotos incluidos: el panel se pide con el perfil activo
(`GET/PUT /api/memory/providers/dran/config?surface=declared&profile=<perfil>`),
así que si el app está conectado a un gateway remoto, estás editando **la config
de ESE perfil** — la que vive en el `config.json` de su host. Nada extra que
instalar del lado del app: alcanza con que el plugin esté instalado y con
`memory.provider: dran` en ese perfil. La tarjeta es igual de perfil-scoped: el
runtime lee la del perfil activo, y el proveedor — que no recibe `ctx` — la
resuelve por `get_hermes_home()`.

También funciona `hermes memory setup` → elegir "dran" (CLI): camina el schema
del **proveedor**, así que pregunta la credencial, la instancia y los knobs de
recall, y escribe el `config.json` — que gana por clave sobre la tarjeta.

**Precedencia, por clave:** defaults ← tarjeta ← `config.json` (gana). El JSON
es lo que el panel escribió históricamente y lo que un archivo editado a mano
sigue diciendo: un setup ya existente no cambia de sentido bajo el usuario.
Mover un valor a la tarjeta no lo borra del JSON — si querés que la tarjeta
mande, sacá la clave del JSON.

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
`GET /api/groups` (W7) lista los grupos donde sos miembro. En la **tarjeta del
plugin**, el default del perfil se elige con los campos **Write scope** y
**Group slug** (el slug solo aplica cuando el scope es `group`).

**Si tu token es el de un GRUPO, no configures nada.** Un grupo puede tener su
propia credencial (`Admin → Groups → Token`): esa credencial ya está atada a su
grupo, así que el servidor **impone** el destino — con o sin `scope`, todo lo que
escribas cae en el grupo, y cualquier otro destino (`public`, `private`, otro
grupo) es `422`, nunca un `private` en silencio. La lectura es igual de acotada:
**exactamente lo compartido a ese grupo**, sin lo público de la instancia ni lo
privado ajeno. Los campos **Write scope** / **Group slug** del perfil quedan sin
efecto (son del token de cuenta), y no hace falta llamar a `GET /api/groups`
para elegir destino.

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
3. Configura el resto desde el **app desktop**:
   - **Capabilities → Plugins → Dran → engranaje**: instancia (`base_url`),
     destino de escritura (`scope` + `scope_group`) y los **siete toggles** de
     tools. El token, si lo cargás acá, va al **mismo** `.env` que el paso 2.
   - **Settings → Memory & Context** → elegí Memory provider **`dran`**: el
     panel que aparece justo debajo tiene **sólo** los knobs de recall (Auto
     recall, Auto capture, Max recall results, Recall char budget, Recall
     cadence) y el campo del token.

   La alternativa CLI es `hermes memory setup` → "dran": pregunta credencial,
   instancia y knobs de recall, y escribe el `config.json`.
   **Perfil remoto**: lo mismo con el app apuntando a ese perfil; la tarjeta y
   el panel escriben la config de ESE host (el perfil viaja en el pedido).

   Editada a mano, la config de memoria vive en `$HERMES_HOME/dran/config.json`:

   ```json
   {
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
superficies en el mismo plugin**: el memory provider (arriba) y las
operaciones de conocimiento (cliente delgado sobre la API REST de Dran):
estas tools son el consumo del agente.

Desde la v1.5 esas tools viven en **SIETE toolsets de Hermes, uno por
superficie** — `dran_pages`, `dran_goals`, `dran_tasks`, `dran_plans`,
`dran_services`, `dran_skills`, `dran_brain` — en vez del único `dran`
todo-o-nada, y cada superficie se apaga desde la tarjeta del plugin o desde
`hermes tools` (ver [Apagar superficies](#apagar-superficies-el-switch-por-grupo)).

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
del perfil (los campos *Write scope* / *Group slug* de la tarjeta); una **edición** no
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

### Skills (las instrucciones que el agente carga por tool)

Un **skill** es instrucciones para un agente — no conocimiento que se lee. Vive
sólo en Dran (tabla `skills`, con dueño y visibilidad por ítem) y viaja por tool:
**nada se copia a disco** (nada de `external_dirs` ni `register_skill`), el
cuerpo muere con la sesión y no hay índice anónimo (sin lector no hay scope).
Cuatro tools FIJAS y el catálogo como DATO — una tool por skill sería una lista
que el servidor no puede cambiar sin reiniciar el perfil.

| Tool | Ruta que golpea |
|---|---|
| `dran_skills` | `GET /api/skills` — el catálogo VIVO del lector (slug, descripción, versión, hash, destino), **sin cuerpos** |
| `dran_skill` | `GET /api/skills/:slug` — el cuerpo enmarcado con slug, versión y `content_hash`; `unchanged` cuando el hash no cambió desde la última carga de la SESIÓN |
| `dran_skill_save` | `POST`/`PUT /api/skills[/:slug]` — slug nuevo crea, existente edita versionado (misma puerta y misma validación server-side que la web) |
| `dran_skill_delete` | `DELETE /api/skills/:slug` |

El descubrimiento no depende de la red en el camino crítico: `initialize()`
(que corre ANTES del build del prompt) calienta el caché del índice, y la
sección de prompt `dran-skills` —posición `after_memory`, `max_chars` 3000 bajo
el tope de 4000— renderiza una línea por skill desde ESE caché y manda a
`dran_skills` para el listado vivo, porque el bloque se congela por sesión. La
sección se registra SIEMPRE y con Dran caído devuelve `""`: Hermes la descarta y
el prompt no se rompe (fail-open).

Cada tool escribe por `_DranClient`, así que **todo write lleva
`X-Hermes-Agent`** con el nombre del perfil. El handler recibe `(args, **kw)`
— Hermes no pasa el nombre de la tool — así que `register()` ata el nombre
por closure (`_make_handler`).

### Apagar superficies (el switch por grupo)

Las 46 tools son **siete superficies**, y cada una tiene **dos interruptores
sobre la misma cosa** — la tabla `_TOOL_GROUPS` de `__init__.py` es la única
fuente de verdad de a qué grupo pertenece cada tool:

1. **La tarjeta del plugin** (Desktop/TUI → Capabilities → Plugins → Dran →
   engranaje; cada toggle es una clave **plana** — `pages`, `goals`, …). Escribe
   `plugins.entries.dran.settings` en el `config.yaml` del perfil, y el plugin lo
   aplica con un `check_fn` por tool: Hermes saca las tools del grupo del prompt
   **y del catálogo de `tool_search`**. El interruptor legacy —`tools.<group>` en
   `$HERMES_HOME/dran/config.json`, lo que escribía el panel de memoria— se sigue
   leyendo y sigue **ganando por clave**: un config ya escrito no cambia de
   sentido. Un grupo ausente, un JSON ilegible o un valor que no es booleano
   dejan el grupo **encendido** (fail-open: esto es comodidad del operador, no
   una frontera de seguridad).
2. **El operador, desde Hermes** — un TOOLSET por grupo:

   ```bash
   hermes tools disable dran_pages dran_brain   # por plataforma (cli, telegram, ...)
   hermes tools enable  dran_pages
   ```

   `dran_pages` … `dran_brain` son toolsets de plugin normales: también se
   pueden cortar por `platform_toolsets.<plataforma>` o
   `agent.disabled_toolsets` en `config.yaml`.

Los dos switches son independientes y no se pisan: el de Hermes decide **qué
ve el modelo**; el de la tarjeta además **niega la llamada** en el handler. Esa
segunda mitad es necesaria porque Hermes no re-evalúa el `check_fn` al
despachar (`tools/registry.py::dispatch`) y el prompt de una sesión en vuelo
está congelado: si el modelo llama igual a una tool apagada, recibe un error
estructurado (`{"error": "tool disabled: the '<group>' group is off…"}`) y
ningún efecto. Los tests leen la tarjeta como `ctx.config` (y el JSON legacy
como archivo) y verifican las dos mitades.

**Cuándo aplica:** en la **siguiente** sesión (build del agente). La sesión en
vuelo conserva su superficie de tools — Hermes no reescribe el prompt a mitad
de conversación (invariante de prompt caching).

**Nota de migración (v1.4 → v1.5):** el toolset `dran` ya no existe; quien lo
tuviera deshabilitado en `platform_toolsets`/`agent.disabled_toolsets`
recupera las 46 tools, porque las claves nuevas son desconocidas y Hermes las
enciende por default. Volver a apagarlas es una línea por superficie:

```bash
hermes tools disable dran_pages dran_goals dran_tasks dran_plans dran_services dran_skills dran_brain
```

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

Y el reparto de la configuración: que la tarjeta (`plugin.yaml`) declare los
siete toggles y que el panel de memoria conserve **sólo** lo de memoria, más la
resolución en capas — `defaults ← tarjeta ← config.json` (gana por clave) — que
el proveedor y las tools comparten. Un `config.json` con un solo knob de
memoria no debe arrastrar `base_url` al default de localhost: hay un test para
eso.
