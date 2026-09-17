# Dran memory — plugin Hermes

Memoria compartida multi-agente respaldada por un workspace de Dran. El plugin
es transporte delgado: dedupe, trust, search híbrido y extracción de facts
viven server-side en Dran (`/api/memory`).

## Configuración — con UI en el dashboard de Hermes

El plugin declara su config (`config_schema.py`), así que el panel de memoria
del dashboard la renderiza solo: **Hermes → Memory → Dran** (fields: API key,
Base URL, Memory workspace, Auto recall, Auto capture, Max recall results,
Recall char budget, Recall cadence).
También funciona `hermes memory setup` → elegir "dran".

Se persiste en `$HERMES_HOME/dran/config.json` (la API key al `.env` del
perfil — `DRAN_API_KEY`, single source of truth para todas las tools).

## Workspace de memoria — se elige AQUÍ, en Hermes

El workspace donde este agente guarda sus facts se configura en el panel
(arriba) o en `dran/config.json` (`"workspace": "..."`), eligiendo entre los
que la API key del agente puede alcanzar (matriz workspaces×nivel en Dran →
Settings → API Keys). Al arrancar — y cada 5 min — el plugin consulta
`GET /api/agent/config` para **validar** la elección: si la key ya no alcanza
ese workspace (la matriz cambió en Dran), cae al primero permitido y lo
loguea con warning. Si Dran no responde, se usa la config local sin validar.

## Setup (por perfil de Hermes)

1. En Dran → Settings → API Keys: crea el agente y su key eligiendo la matriz
   workspaces×nivel (la key necesita `write` en el workspace de memoria; el
   `created_by` de cada recuerdo se atribuye server-side a la key que lo
   guardó).
2. Guarda la key **una sola vez** en el `.env` del perfil:

   ```bash
   # ~/.hermes/profiles/<perfil>/.env
   DRAN_API_KEY=dran_sk_...
   ```

   Ese mismo valor lo consume el plugin entero (memory provider + tools).
3. Configura el resto desde la UI: **dashboard de Hermes → Memory → Dran**
   (o `hermes memory setup` → elegir "dran"). La API key pégala en el campo
   del panel — va al `.env`, no al JSON.

   Editada a mano, la config vive en `$HERMES_HOME/dran/config.json`:

   ```json
   {
     "base_url": "http://localhost:4000",
     "workspace": "personal",
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
| `dran_list_pages` | Lista páginas, filtrable por tipo |
| `dran_get_page` | Lee el cuerpo completo por slug |
| `dran_create_page` / `dran_update_page` / `dran_delete_page` | Ciclo de vida de páginas |
| `dran_get_links` | Relaciones entrantes/salientes de una página |
| `dran_create_relation` / `dran_delete_relation` | Relaciones tipadas y dirigidas |
| `dran_start_worker` / `dran_get_worker_session` | Dispara y sondea curator / link_gardener / graph_rag |
| `dran_lint_brain` | Auditoría estructural (read-only) |
| `dran_stats` | Números del dashboard |

Cada tool escribe por `_DranClient`, así que **todo write lleva
`X-Hermes-Agent`** con el nombre del perfil. El handler recibe `(args, **kw)`
— Hermes no pasa el nombre de la tool — así que `register()` ata el nombre
por closure (`_make_handler`).

## Identidad y contextos

- `initialize` recibe `agent_identity` (nombre del perfil) → header
  `X-Hermes-Agent` en cada request. Dran lo persiste server-side como
  `agent_name` del contenido escrito, además de atribuir por el actor de la
  API key (`owner_user_id`). El header es atribución, no autorización: nunca
  amplía acceso.
- `agent_context != "primary"` (subagent, cron): prefetch permitido,
  **writes deshabilitados** — los agentes secundarios no contaminan la
  memoria compartida.

## Tests

```bash
python3 -m pytest hermes_plugin/tests/ -q
```

Cubren el registro (provider + tools, schemas válidos, un fallo de tool no
cuesta el provider), el header en cada path de escritura, las rutas REST y
el manejo de errores como JSON.
