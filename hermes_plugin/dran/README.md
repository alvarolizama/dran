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
| **Tarjeta**: instancia, destino de escritura, el switch de memoria, los 7 toggles, token | **Capabilities → Plugins → Dran → engranaje** (o el TUI) | `plugins.entries.dran.settings` del perfil (`config.yaml`); el token al `.env` |
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
  del proveedor de memoria. Escribe **su** `config.json`, y declara **sólo**
  los cinco knobs de recall: la credencial y la instancia son de la tarjeta,
  así que no hay ninguna clave repetida entre las dos superficies.

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
destino de escritura, la credencial, los **siete toggles** de tools y los
**dos presupuestos** de la superficie de servicios
([el ladder](#presupuestos-de-servicios-el-ladder)). Se guarda
por campo, en `plugins.entries.dran.settings` del perfil (`config.yaml`); el
token va al `.env` por la ruta de credenciales, nunca al YAML.

**El panel de memoria** (`config_schema.py`): **Settings → Memory & Context** →
elegí **Memory provider: `dran`** y el panel de Dran aparece **justo debajo**,
con **sólo** lo de memoria — Auto recall, Auto capture, Max recall
results, Recall char budget, Recall cadence. Los cinco campos son `inline`, así
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

## El switch de memoria (la mitad de memoria del plugin)

La tarjeta tiene el campo **Memory (recall & capture)**. Apagado, Hermes **no
carga el proveedor**: `is_available()` devuelve `false`, así que el manager no
lo agrega (`agent_init`: `if _mp and _mp.is_available()`) y quedan sin efecto el
recall del inicio del turno y la captura del transcript al cerrar la sesión.
Además:

- las **cuatro tools de memoria** (`dran_memory_search`, `dran_memory_add`,
  `dran_memory_update`, `dran_memory_feedback`) salen de `get_tool_schemas()`:
  desaparecen del prompt **y del catálogo de `tool_search`**, igual que un grupo
  apagado;
- y las guardas vivas rechazan igual (prefetch, captura y dispatch), porque una
  sesión en vuelo ya tiene su proveedor registrado y su lista de tools
  congelada: recibe un error estructurado y ningún efecto.

Encendido es el default, y **ausente es encendido** (fail-open, como los siete
grupos). La clave vive en la tarjeta (plana: `memory`); el `config.json` legacy
también la acepta y gana por clave.

Lo que este switch **no** hace: el panel de `Memory & Context` sigue existiendo y
sigue mostrando sus cinco knobs — sin proveedor cargado, sus valores no afectan
nada. Y no puede hacerlo desaparecer: el panel se monta porque
`memory.provider: dran`, y **eso no se puede mover a la tarjeta** (elegir
proveedor es config del core; el writer de plugins sólo acepta claves
plugin-relativas).

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
     destino de escritura (`scope` + `scope_group`), el switch **Memory (recall
     & capture)** y los **siete toggles** de tools. El token, si lo cargás acá,
     va al **mismo** `.env` que el paso 2.
   - **Settings → Memory & Context** → elegí Memory provider **`dran`**: el
     panel que aparece justo debajo tiene **sólo** los knobs de recall (Auto
     recall, Auto capture, Max recall results, Recall char budget, Recall
     cadence) — ni la instancia ni el token: todo eso vive en la tarjeta.

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
  (salvo 429) no se reintentan — el servidor ya respondió. Un **timeout tampoco
  se reintenta nunca**: reintentarlo duplica el peor caso (2× el cap + backoff)
  para volver a concluir lo mismo, y contra un mutador es peor que fallar.
- **Circuit breaker**: tras 3 fallos consecutivos, todas las llamadas
  fallan rápido durante 60 s — un Dran caído no agrega un timeout a cada
  turno. Cualquier éxito rearma el contador. La línea de inventario de servicios
  del turno se paga con un cliente **efímero** (su breaker muere con él): una
  ventana lenta de Composio no puede abrir el breaker que apaga el recall.

#### Presupuestos de servicios: el ladder

Un timeout no es «un número que se sube»: es un contrato entre DOS capas, y el
invariante no se negocia — **el cap del cliente va SIEMPRE por encima del
presupuesto del servidor**. Con el cliente cortando primero, el socket gana la
carrera y el agente sólo puede decir «dran unavailable»: sin capa, sin endpoint
y sin saber si vale reintentar. Con el servidor por debajo, el error llega
**tipado** desde dran y el mensaje dice qué pasó de verdad.

| Capa | Presupuesto | Dónde se ajusta |
|---|---|---|
| Camino caliente (memoria, pages, goals, tasks, skills) | **5 s** | `REQUEST_TIMEOUT` (constante) |
| Línea de inventario de servicios del turno | **3 s** | `PREFETCH_SERVICES_TIMEOUT` (constante) |
| Leer servicios (`dran_services`, `dran_services_tools`) | **15 s** | tarjeta → **Services read timeout (s)** |
| Emitir el link de conexión (`dran_services_connect`) | **20 s** | `SERVICES_CONNECT_TIMEOUT` (constante) |
| Ejecutar una tool (`dran_services_run`) | **45 s** | tarjeta → **Services run timeout (s)** |
| dran → Composio, lecturas | **12 s** | instancia → `DRAN_COMPOSIO_TIMEOUT` |
| dran → Composio, ejecución | **25 s** | instancia → `DRAN_COMPOSIO_EXECUTE_TIMEOUT` |

El cap es por **consecuencia**, no por endpoint: lo que espera un turno no lleva
el mismo presupuesto que una acción real contra el proveedor. Y todo lo que no
sea del camino caliente sale con su presupuesto **explícito**: ninguna llamada
de services hereda el `REQUEST_TIMEOUT` de 5 s.

Un detalle del transporte que conviene tener claro: `urlopen(timeout=…)` —y el
`receive_timeout` de Req del otro lado— acotan el **silencio del socket**, no el
tiempo total. Una respuesta lenta pero que sigue goteando puede pasarse del cap
(medido: 16 s con un cap de 15 s en `GET /api/services`, contra 0.6–0.8 s de
mediana). El cap corta la llamada muerta; no es una fecha límite de reloj.

Un timeout del lado del cliente sale **tipado**, nunca como «dran unavailable»:

```json
{"error": "timeout", "layer": "plugin", "cap_s": 15.0, "retryable": true,
 "hint": "the call did not fit in the 15s plugin budget (plugin → dran → Composio → provider). Retry once: this says slow, not down."}
```

`dran_services_run` es la excepción y por eso `retryable` es `false`: un mutador
que se pasó del presupuesto puede haber aterrizado igual (el envío corrió y sólo
se perdió la respuesta), así que se verifica con una lectura — o con el registro
de `service_calls` — antes de reintentar. Dran caído es OTRA cosa: sale
`layer: "transport"` con `retryable: true`.

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

Del lado del servidor esa lectura son DOS hops al vendor que no se suman: las
conexiones del lector (la autoridad del estado, que se lee siempre) y la
metadata del toolkit que sólo ADORNA la lista. Van en paralelo (`Task.async_stream`,
la lectura cuesta el máximo) y la metadata vive cacheada por instancia
(`Dran.Services.ToolkitMetaCache`, 6 h: el catálogo es el mismo para todos los
lectores), con un presupuesto propio y corto — si el catálogo tarda, la lista
sale igual con el slug humanizado. Medido contra el vendor real: 897 ms en serie
→ 637 ms en frío (paralelo) → 227 ms tibio (metadata cacheada).

### Skills (las instrucciones que el agente carga por tool)

Un **skill** es instrucciones para un agente — no conocimiento que se lee. Vive
sólo en Dran (tabla `skills`, con dueño y visibilidad por ítem) y viaja por tool:
el cuerpo se sirve por tool y muere con la sesión, no se registra como skill
local (nada de `external_dirs`) y no hay índice anónimo (sin lector no hay
scope). La única fila local es el PUNTERO — ver abajo —, y no es un cuerpo del
catálogo: es el texto que enseña la ruta. La única copia en disco de un cuerpo es
el **espejo del plugin** (ver «El espejo en disco»), que no entra a `skills_list`.
Cuatro tools FIJAS y el catálogo como DATO — una tool por skill sería una lista
que el servidor no puede cambiar sin reiniciar el perfil — más la que reconcilia
el espejo:

| Tool | Ruta que golpea |
|---|---|
| `dran_skills` | `GET /api/skills` — el catálogo VIVO del lector (slug, descripción, versión, hash, destino), **sin cuerpos**; `q` filtra por texto en el servidor (slug, name, description) |
| `dran_skill` | `GET /api/skills/:slug` — el cuerpo enmarcado con slug, versión y `content_hash`; `unchanged` cuando el hash no cambió desde la última carga de la SESIÓN; y el espejo se actualiza con lo que volvió |
| `dran_skill_save` | `POST`/`PUT /api/skills[/:slug]` — slug nuevo crea, existente edita versionado (misma puerta y misma validación server-side que la web) |
| `dran_skill_delete` | `DELETE /api/skills/:slug` |
| `dran_skill_sync` | `GET /api/skills` + `GET /api/skills/:slug` (+ `PUT` con `push=true`) — reconcilia el espejo por checksum y sube las ediciones locales |

El descubrimiento no depende de la red en el camino crítico: `initialize()` (que
corre ANTES del build del prompt) calienta el caché del índice, y la sección de
prompt `dran-skills` —posición `after_memory`, `max_chars` 3000 bajo el tope de
4000— renderiza una línea por skill desde ESE caché y manda a `dran_skills` para el
listado vivo, porque el bloque se congela por sesión. La sección se registra
SIEMPRE y **nunca queda muda**: sin índice ni puntero devuelve un PISO de texto fijo
(`SKILLS_SECTION_FLOOR`) que nombra el catálogo y la suite. Un perfil con el plugin
pero **sin** `memory.provider: dran` no corre `initialize()` —y con Dran caído la
primera vez tampoco hay puntero—, así que sin ese piso el aviso desaparecía por una
elección de MEMORIA que no tiene nada que ver con el catálogo.

### El espejo en disco (el cache del catálogo)

El cuerpo sigue viniendo por tool y **el remoto sigue mandando**: `dran_skill`
pide `/api/skills/:slug` SIEMPRE y sirve lo que el servidor contestó. Lo que
agrega el espejo es lo que la red no puede dar, y vive en un solo lugar:
`$HERMES_HOME/dran/skills/` — tarjeta → **Skills mirror on disk** (default ON).

| Necesidad | Cómo la resuelve |
|---|---|
| Contestar con Dran caído | si el detalle no llega (sin conexión, timeout, breaker abierto, 5xx) el cuerpo sale del archivo, con `source: cache`, `stale: true` y el frame marcado `OFFLINE COPY`. Un **404 no** cae acá: ahí el servidor contestó y la copia vieja NO se sirve |
| No re-verificar a mano | el índice ya trae el `content_hash` de todo lo legible: al abrir sesión (en un hilo, sin bloquear el arranque) se compara con `manifest.json` y se bajan SÓLO los cuerpos que cambiaron o faltan |
| Poder editar y subir | el hash del cuerpo EN DISCO contra la BASE del manifiesto dice si hay una edición local; `dran_skill_sync` (con `push`) la manda |
| No arrastrar copias muertas | un slug que SALIÓ del catálogo se quedaba en disco para siempre — el pull itera el catálogo y `forget()` sólo corre en un delete o en un 404. `dran_skill_sync` lo PODA: lo mueve a `dran/backups/orphans-<ts>/` y lo saca del manifiesto |

Layout: `manifest.json` (por slug: `content_hash` = el remoto la última vez,
`body_hash` = lo que hay en disco, versión, `file_mtime_ns`/`file_size`) y
`<slug>/SKILL.md` — el archivo montado (frontmatter + cuerpo), el MISMO formato
que el servidor sirve en `skill_md` y que se escribe verbatim cuando su cuerpo
hashea igual.

**En el conflicto gana el remoto.** Si el cuerpo cambió en los dos lados, la
edición local se descarta, el espejo se reescribe con el del servidor y el
reporte lo dice (`conflicts: [{resolution: "remote"}]`); `force=true` es la única
puerta por la que el local se impone. La SUITE no entra acá: sus nueve slugs no
están en el catálogo (viajan con el plugin), así que el espejo sólo reconcilia los
skills del workspace.

Las tres invariantes que lo sostienen (y que los tests miden):

1. **`body_hash == content_hash` recién bajado** — si no, cada archivo se leería
   como editado y el push subiría versiones que nadie escribió;
2. **la verdad sobre «editado» es el ARCHIVO** (con `mtime` + tamaño para no
   releer lo intacto): el `body_hash` del manifiesto lo dejó el último write y una
   edición a mano no lo actualiza; un archivo borrado o ilegible cuenta como
   ausente y el próximo pull lo repara;
3. **el slug es un nombre de directorio** — se valida contra el formato del wire
   antes de armar cualquier ruta: un `../../` no escribe nada.

**La PODA, y por qué el arranque no la hace.** El pull itera el CATÁLOGO, así que
un slug que salió del catálogo nunca se volvía a mirar: se quedaba en disco para
siempre y con Dran caído se servía como `OFFLINE COPY` (un `loader` de la era
pre-plugin no es la fila local que el plugin registra con ese nombre). Lo poda
`dran_skill_sync`, con dos guardas — porque borrar es lo único irreversible de la
reconciliación: con `index_truncated` (el índice vino lleno, así que «no existe» y
«no cupo» son indistinguibles) NO se poda nada, y los bytes se MUEVEN a
`dran/backups/orphans-<ts>/` antes de salir del manifiesto, así que la poda es
reversible — y es la única red para una edición local de un huérfano, que no se
puede pushear porque el slug no está en el remoto. El sync de ARRANQUE sólo lo
reporta (`orphans`, con nota): reconcilia en un hilo, sin nadie mirando, y borrar
es una decisión que se pide, no un efecto de abrir sesión.

**El cuerpo que no cabe inline viaja como PUNTERO.** El resultado de un tool es
JSON, y el escape de los saltos de línea le suma ~7% al cuerpo: 96,971 chars de
cuerpo ⇒ 104,258 de resultado. Hermes **persiste** todo resultado arriba de su
tope (default 100,000 chars) y lo cambia por un preview de 1,500 más una ruta —
o sea que un skill pesado llegaba CORTADO y el agente se creía que había leído
los pasos. Con `SKILLS_INLINE_MAX_CHARS` (90 K, con margen bajo el tope de
Hermes) el corte no puede pasar por tamaño: lo que no cabe sale como el frame, la
versión, el hash y **la ruta del archivo que se acaba de escribir**
(`body_omitted.path` + `read_it`), el mismo byte y verificado por hash, para que
lo lea con `read_file` — que está pinneado a infinito (nunca se persiste) y
pagina con offset/limit, así que además se lee sólo lo que se necesita. Sin
archivo a dónde apuntar (espejo apagado, o el write falló) se manda el sobre
completo: ahí el spill de Hermes sigue siendo la red, y su mensaje ya manda a
`read_file`.

Nada de esto entra a `skills_list`: el espejo es del plugin, no se copia a
`~/.hermes/skills/` y no se registra como skill local. Los presupuestos del
arranque (`SKILLS_CACHE_MAX_BODIES` / `_CHARS`) existen para que una sesión no se
lleve el catálogo entero: lo que no entra queda `deferred` y lo baja
`dran_skill_sync` cuando alguien lo pide.

**El discovery es un DISPARO, no una nota al pie.** La descripción de la tool y
el pie del bloque dicen *«antes de arrancar una tarea que pueda matchear un
skill, listá con `dran_skills` y elegí el que aplique»*: el bloque del prompt es
una foto del arranque de la sesión, así que su existencia no alcanza — si el
texto sólo dijera «llamá si está viejo», el listado quedaría librado a que el
bloque le parezca sospechoso al modelo. Con `q` la búsqueda es del servidor
(substring, sin mayúsculas, comodines de LIKE literales) y el cliente la
repite como red de seguridad contra un Dran que todavía no conozca el param:
nunca ensancha el resultado.

**La suite no está en el catálogo.** El router y los ocho flows viven en el PLUGIN
(`hermes_plugin/dran/skills/<slug>/SKILL.md`). El plugin los registra como filas
locales y su bloque del prompt apunta a ellas; el agente las lee con
`skill_view("dran:<slug>")`, sin red. `dran_skills`/`dran_skill` no las devuelven
nunca. Dran reserva los nueve slugs —crear uno ajeno da `422`— y su espejo sólo
reconcilia los skills del WORKSPACE. Para cambiarlas: editar el archivo y
redeployar el plugin (`hermes plugins update dran`).

**Las cinco tools están DIFERIDAS.** Hermes reemplaza toda tool de plugin por el
puente (`tool_search` / `tool_describe` / `tool_call`): un toolset de plugin no
está entre los core ni entre las superficies GUI, así que `is_deferrable_tool_name`
lo difiere SIEMPRE y el manifest del catálogo corta cada descripción (~60 chars) —
el disparo «listá antes de arrancar» no entra ahí. El bloque del prompt y el
cuerpo del puntero nombran el puente y la query en INGLÉS (`"dran skills"`): una
query en español no matchea ningún tool y devuelve vacío, que no es lo mismo que
una capacidad ausente.

### La suite del sistema: las nueve filas LOCALES (el plugin es su única puerta)

El pedido «listar los skills» corre `skills_list` — el registro LOCAL — y ahí no
había ni una fila de Dran (el catálogo se sirve, no se instala), así que la
respuesta honesta del listado era «no hay skills». El plugin registra entonces la
suite entera con `ctx.register_skill`: **nueve filas** —
`hermes_plugin/dran/skills/<slug>/SKILL.md`, con el router (`loader`) primero y
los ocho flows (`knowledge-flow`, `relations-flow`, `workers-flow`, `memory-flow`,
`goal-flow`, `plan-flow`, `services-flow`, `skills-flow`) —, que Hermes lista como
`dran:<slug>` y sirve con `skill_view`. La descripción de cada una sale del
**frontmatter del archivo**, así que el listado no puede decir algo que el cuerpo
no diga. El router contesta además «¿qué se puede hacer con Dran?»: es la entrada
de la suite y el índice del catálogo.

Y son el **único** lugar donde viven esos bytes: el plugin registra estas filas
locales y el bloque del prompt apunta a ellas, así que hay UNA sola fuente para el
listado, el bloque y el `skill_view` del agente — nada que pueda driftear (Dran ya
no los sirve: sólo reserva sus slugs).

- **viven dentro del plugin y no se copian a `~/.hermes/skills/`**; Hermes las
  retracta al descargar el plugin. Los slugs no llevan prefijo `dran-`: el
  namespace es del host (`dran:loader`), y `dran:dran-knowledge-flow` leería dos
  veces lo mismo;
- **no entran en `<available_skills>`** (el índice del prompt): no cuestan tokens
  por sesión — se ven cuando alguien pide la lista, que es exactamente el caso (la
  línea del prompt la pone el bloque `dran-skills`, que lee el catálogo remoto);
- **fail-open por archivo**: el que falte (un install que no copió `skills/`) se
  pierde con un warning y el plugin carga igual;
- la descripción del router es el disparo de las DOS preguntas y mide ≤60 chars,
  porque Hermes corta ahí: `Use when asked to list skills or operate Dran.` (el
  frontmatter del SKILL.md y lo que registra `__init__.py` se verifican iguales en
  los tests: archivo y registro no pueden derivar, y el parser del servidor valida
  el mismo frontmatter al compilar).

Cada tool escribe por `_DranClient`, así que **todo write lleva
`X-Hermes-Agent`** con el nombre del perfil. El handler recibe `(args, **kw)`
— Hermes no pasa el nombre de la tool — así que `register()` ata el nombre
por closure (`_make_handler`).

### Apagar superficies (el switch por grupo)

Las 47 tools son **siete superficies**, y cada una tiene **dos interruptores
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

**El tercer switch, aparte de los siete grupos:** el de **memoria** (tarjeta →
Memory). Apaga la mitad de memoria completa — recall, captura y las cuatro tools
`dran_memory_*` — y su semántica está en
[El switch de memoria](#el-switch-de-memoria-la-mitad-de-memoria-del-plugin).

**Nota de migración (v1.5 → v1.6):** tres cosas en un cambio.

1. La suite pasa a vivir **dentro del plugin** (`hermes_plugin/dran/skills/`) y el
   plugin la registra entera: nueve filas locales `dran:<slug>` en `skills_list`,
   que se cargan con `skill_view` sin red. El router se llama **`loader`** y los
   flows pierden el prefijo `dran-` (`knowledge-flow`, …): el namespace lo pone el
   host. Dran **deja de servirla** — su catálogo es sólo el del workspace y los
   nueve slugs quedan reservados (`422` al crear uno) —, así que quien tuviera un
   slug viejo anotado (`dran-knowledge-flow` en un `related_skills`, en una nota)
   tiene que actualizarlo.
2. Se suman `dran_skill_sync` (el toolset `dran_skills` pasa de 4 a 5 tools) y la
   clave de tarjeta **Skills mirror on disk** (`skills_cache`, default ON). Nada que
   hacer: un perfil existente arranca con el espejo encendido y sin bodies en disco
   — se llena al cargar skills y en el primer arranque de sesión. Apagado, el plugin
   no escribe nada y todo lo demás se comporta como en la v1.5.
3. El plugin se instala en vez de linkearse (el symlink de desarrollo nunca fue una
   instalación: no hay provenance ni `plugins update`):

   ```bash
   hermes plugins install "git@github.com:alvarolizama/dran.git#hermes_plugin/dran"
   ```

**Nota de migración (v1.4 → v1.5):** el toolset `dran` ya no existe; quien lo
tuviera deshabilitado en `platform_toolsets`/`agent.disabled_toolsets`
recupera las 47 tools, porque las claves nuevas son desconocidas y Hermes las
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
siete toggles y el switch de memoria, que el panel de memoria conserve **sólo**
lo de memoria (sin la credencial), más la resolución en capas —
`defaults ← tarjeta ← config.json` (gana por clave) — que el proveedor y las
tools comparten. Un `config.json` con un solo knob de memoria no debe arrastrar
`base_url` al default de localhost: hay un test para eso. Y otro que fija qué
hace el switch apagado: `is_available()` false, `get_tool_schemas()` vacío y la
llamada rechazada.

**El espejo de skills** tiene su propio bloque (33 tests). Los que fijan el
contrato, en orden de importancia:

1. `mount → parse` devuelve el MISMO cuerpo (cuerpos con `---`, comillas, barras y
   saltos finales incluidos) y su hash es el `content_hash` del servidor: si esto
   no cerrara, todo archivo se leería editado;
2. el remoto manda: cargar un skill escribe el espejo con `body_hash == content_hash`,
   un cuerpo nuevo del servidor reescribe el archivo, un **404 no** cae al espejo y
   con Dran caído la respuesta llega con `source: cache` + `stale: true`;
3. la reconciliación baja SÓLO lo que cambió (se mide que no haya GET de detalle),
   respeta su presupuesto (`deferred`), repara un archivo borrado o ilegible y no
   aborta por un slug que falla;
4. push: una edición local se reporta (`pending_push`) y se sube fast-forward; en
   conflicto gana el remoto y `force` impone la local;
5. la poda: la tool mueve el huérfano al respaldo y lo saca del manifiesto (el slug
   vivo no se toca), el arranque sólo lo reporta, un índice recortado **no** poda
   nada, y la edición local de un huérfano se conserva en el respaldo;
6. el techo inline: lo que cabe sigue llegando con su cuerpo, lo que no cabe llega
   como PUNTERO al archivo del espejo (y el archivo tiene el cuerpo completo), la
   copia OFFLINE de un cuerpo grande también apunta, y sin archivo se cae al sobre
   completo (nunca se inventa un path);
7. y las guardas: slug inválido (`../../`) no arma ninguna ruta ni escribe,
   manifiesto corrupto se lee vacío, `"false"` en el `config.json` apaga el espejo
   (sin escribir nada a disco) y el arranque usa el índice que ya bajó el prompt
   (UN GET, en un hilo). El smoke end-to-end contra los payloads reales del
   servidor vive fuera de la suite (ver abajo).

Y el smoke de contrato (`mix run` + un cliente que sirve esos payloads), que
verifica lo mismo contra los bytes que emite `Dran.Skills` — incluida la versión
que el `PUT` real devuelve.
