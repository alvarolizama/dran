# Dran memory — plugin Hermes

Memoria compartida multi-agente respaldada por un workspace de Dran. El plugin
es transporte delgado: dedupe, trust, search híbrido y extracción de facts
viven server-side en Dran (`/api/memory`).

## Setup (por perfil de Hermes)

1. En Dran → Settings → API keys: crea una key **por agente** con
   `write_access` sobre el workspace compartido (el `created_by` de cada
   recuerdo se atribuye server-side a la key que lo guardó).
2. Guarda la key **una sola vez** en el `.env` del perfil:

   ```bash
   # ~/.hermes/profiles/<perfil>/.env
   DRAN_API_KEY=dran_sk_...
   ```

   Ese mismo valor lo consume el MCP (`config.yaml` →
   `mcp_servers.dran.headers: "Authorization: Bearer ${DRAN_API_KEY}"`).
3. Configura el provider — **sin escribir la key de nuevo**. `api_key` se
   resuelve solo desde `DRAN_API_KEY` (se omite, o se deja el placeholder
   `${DRAN_API_KEY}`). Un literal en el JSON gana, para overrides por agente:

   ```bash
   hermes memory setup    # elegir "dran"
   ```

   o edita `$HERMES_HOME/dran_memory.json`:

   ```json
   {
     "base_url": "http://localhost:4000",
     "workspace": "personal",
     "auto_recall": true,
     "auto_capture": true,
     "max_recall_results": 5
   }
   ```

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
  `X-Hermes-Agent` para el audit de Dran.
- `agent_context != "primary"` (subagent, cron): prefetch permitido,
  **writes deshabilitados** — los agentes secundarios no contaminan la
  memoria compartida.
