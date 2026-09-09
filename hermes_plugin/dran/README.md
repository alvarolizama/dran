# Dran memory — plugin Hermes

Memoria compartida multi-agente respaldada por un workspace de Dran. El plugin
es transporte delgado: dedupe, trust, search híbrido y extracción de facts
viven server-side en Dran (`/api/memory`).

## Configuración — con UI en el dashboard de Hermes

El plugin declara su config (`config_schema.py`), así que el panel de memoria
del dashboard la renderiza solo: **Hermes → Memory → Dran** (fields: API key,
Base URL, Memory workspace, Auto recall, Auto capture, Max recall results).
También funciona `hermes memory setup` → elegir "dran".

Se persiste en `$HERMES_HOME/dran/config.json` (la API key al `.env` del
perfil — `DRAN_API_KEY`, single source of truth compartida con el MCP).

## Workspace de memoria — se elige AQUÍ, en Hermes

El workspace donde este agente guarda sus facts se configura en el panel
(arriba) o en `dran/config.json` (`"workspace": "..."`), eligiendo entre los
que la API key del agente puede alcanzar (matriz workspaces×nivel en Dran →
Settings → Agents). Al arrancar — y cada 5 min — el plugin consulta
`GET /api/agent/config` para **validar** la elección: si la key ya no alcanza
ese workspace (la matriz cambió en Dran), cae al primero permitido y lo
loguea con warning. Si Dran no responde, se usa la config local sin validar.

## Setup (por perfil de Hermes)

1. En Dran → Settings → Agents: crea el agente y su key eligiendo la matriz
   workspaces×nivel (la key necesita `write` en el workspace de memoria; el
   `created_by` de cada recuerdo se atribuye server-side a la key que lo
   guardó).
2. Guarda la key **una sola vez** en el `.env` del perfil:

   ```bash
   # ~/.hermes/profiles/<perfil>/.env
   DRAN_API_KEY=dran_sk_...
   ```

   Ese mismo valor lo consume el MCP (`config.yaml` →
   `mcp_servers.dran.headers: "Authorization: Bearer ***"`).
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
     "max_recall_results": 5
   }
   ```

   (`api_key` se resuelve desde `DRAN_API_KEY`; un literal en el JSON gana,
   para overrides por agente.)

4. Instala el plugin en el perfil (symlink — la fuente vive en este repo):

   ```bash
   ln -s ~/Workspace/Repos/alvarolizama/dran/hermes_plugin/dran \
         ~/.hermes/profiles/<perfil>/plugins/dran
   ```

5. Reinicia la sesión de Hermes y verifica: "¿qué recuerdas de ...?"

## Qué hace

| Hook | Comportamiento |
|---|---|
| `queue_prefetch` | Recall en background → `GET /api/memory/search`; `prefetch` inyecta el cache sin bloquear el turno |
| `system_prompt_block` | Instrucción corta: ofrece guardar hechos durables con `dran_memory_add` |
| tools | `dran_memory_search`, `dran_memory_add`, `dran_memory_feedback` |
| `on_session_end` | POST al ingest de Dran (extrae facts server-side; el transcript nunca se persiste) |

## Identidad y contextos

- `initialize` recibe `agent_identity` (nombre del perfil) → header
  `X-Hermes-Agent` (informativo, para logs de transporte; Dran atribuye
  cada recuerdo por el actor de la API key — el header no se persiste).
- `agent_context != "primary"` (subagent, cron): prefetch permitido,
  **writes deshabilitados** — los agentes secundarios no contaminan la
  memoria compartida.
