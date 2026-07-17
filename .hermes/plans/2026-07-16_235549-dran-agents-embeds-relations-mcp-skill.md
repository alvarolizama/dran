# Dran — Plan de Mejora: Agentes, Embeds, Relaciones, MCP y Skill

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Hacer que los agentes de Dran sean más resilientes, observables y capaces (Q&A, curator, gardener, review semanal, ingest con extracción real), los embeds se resuelvan y limpien automáticamente, las relaciones semánticas sean más precisas (bidireccionales, tipadas, con scoring), y el MCP/Skill queden alineados con el comportamiento real. Más: features de second brain profesional (diff de versiones, activity feed, daily note, token tracking, backups) y un Settings LiveView para customización sin redeploy.

**Architecture:** Mejoras incrementales sobre módulos existentes — sin reescrituras. Un solo agente nuevo por módulo implementando `Dran.Agent.Engine.Behaviour`. Scheduler vía Quantum para jobs recurrentes. TDD por task, `mix test` verde en cada commit, `mix precommit` al final de cada fase.

**Nota de verificación (2026-07-16):** `Dran.Inference.Client.request/3` ya usa `retry: :transient` de Req (cubre errores de transporte). El retry del agente (Task 1.3) aplica solo a errores HTTP de API (`{:http_error, status, body}` con 429/5xx). El client ya devuelve `"usage"` en respuestas de chat — el token tracking (Task 1.5) solo lo persiste.

**Tech Stack:** Elixir 1.15+ / Phoenix 1.8 / LiveView 1.2 / Ecto + PostgreSQL (pgvector, pg_trgm) / Req / MCP Streamable HTTP 2025-03-26.

---

## Diagnóstico (lo que encontré leyendo el código)

### Agentes — funcionan, pero con fugas de robustez

| Problema | Archivo | Severidad |
|---|---|---|
| `Engine.run/4` fire-and-forget: si el task crashea antes del primer step, la sesión queda `running` para siempre | `lib/dran/agent/engine.ex` | Alta |
| Sin límite de páginas creadas por sesión (el LLM puede spamear `create_page`) | `lib/dran/agent/research.ex` | Media |
| Steps y sesiones sin índice por `context_id` — listar agentes por contexto es table scan | migrations | Media |
| Tool results truncados a 2000 chars ciegamente — puede cortar JSON a la mitad y confundir al LLM | `lib/dran/agent/engine.ex` | Baja |
| No hay re-intento ante errores transitorios de inferencia (429/500) | `lib/dran/agent/engine.ex` | Media |
| `Session.status` es string libre — no hay validación de valores | `lib/dran/agent/session.ex` | Baja |

### Creación de páginas y embeds — el hoyo más grande

| Problema | Archivo | Severidad |
|---|---|---|
| `resolve_embeds/1` **nunca se llama** en `create_page` ni `update_page` — los `![[slug]]` no crean relaciones `embeds` a menos que algo externo lo invoque | `lib/dran/brain.ex` | **Alta** |
| Al actualizar el body, las relaciones `embeds` viejas **no se borran** — quedan huérfanas apuntando a embeds que ya no existen en el texto | `lib/dran/brain.ex` | **Alta** |
| `rename_slug` (MCP) no reescribe `![[old-slug]]` en otras páginas — existe `replace_slug_in_body/3` pero no se usa | `lib/dran/mcp.ex` | Media |
| `Brain.slugify_title/1` y `Ingest.Utils.slugify/1` duplicados y divergentes (tildes: "meditación" → `meditaci-n` vs consistente) | `lib/dran/brain.ex`, `lib/dran/agent/ingest/utils.ex` | Media |
| `Summaries.augment_page/1` manda solo 50 páginas al prompt de inline_links — en contextos grandes, los links sugeridos son arbitrarios | `lib/dran/summaries.ex` | Media |

### Interrelación de páginas — precisión mejorable

| Problema | Archivo | Severidad |
|---|---|---|
| Umbral semántico fijo `0.22` para todo — páginas cortas generan falsos positivos | `lib/dran/brain/page_augmenter.ex` | Media |
| Relaciones `semantic` son unidireccionales — A→B se crea pero B→A no, el grafo queda sesgado | `lib/dran/brain/page_augmenter.ex` | Media |
| `maybe_create_relation/3` hace `list_relations_for_page` (2 queries con preload) **por cada vecino** — N+1 | `lib/dran/brain/page_augmenter.ex` | Media |
| `auto_relate/2` y `PageAugmenter` duplican lógica de vecinos semánticos con umbrales y k distintos — divergen | `lib/dran/brain.ex` | Media |
| No hay peso/score en `relations` — el grafo 3D no puede ordenar aristas por fuerza | `lib/dran/brain/relation.ex` | Baja |
| `graph_data/1` no incluye `summary` ni `tags` — el graph view no puede mostrar tooltips útiles | `lib/dran/brain.ex` | Baja |

### MCP — desalineado con la realidad

| Problema | Archivo | Severidad |
|---|---|---|
| Doc del módulo dice que embeds se auto-resuelven en create/update — **mentira**, no pasa | `lib/dran/mcp.ex` | Alta (docs) |
| `rename_slug` no actualiza referencias `![[slug]]` en otras páginas ni lo advierte | `lib/dran/mcp.ex` | Media |
| No hay herramienta para re-encolar augmentación (cuando inference estuvo caída) | `lib/dran/mcp.ex` | Baja |
| `list_pages` sin filtro `created_by` ni `owner` — no puedes auditar qué creó cada agente | `lib/dran/mcp.ex` | Baja |
| Enum de `relation_type` en `create_relation`/`delete_relation` omite `semantic` (bien) pero tampoco documenta por qué | `lib/dran/mcp.ex` | Baja |

### Skill (SKILL.md) — desalineado con el código

| Problema | Severidad |
|---|---|
| Dice "embeds are auto-resolved into `embeds` relations" en create_page — no es cierto hoy | Alta |
| Dice `rename_slug`: "Existing `![[old-slug]]` embeds are not updated automatically" — correcto, pero debería decir que **sí** se actualizarán tras el fix | Media |
| Tabla de agentes: falta documentar `max_sources`/`max_search_queries` del research agent | Baja |
| No menciona `Dran.Agent.Engine` como API pública para futuros agentes custom | Baja |

---

## Fases

- **Fase 0 — Fundamentos compartidos** (slug único, validación de status, migraciones)
- **Fase 1 — Agentes resilientes** (lifecycle, límites, retry, observabilidad)
- **Fase 2 — Embeds y creación de páginas** (resolver/limpiar embeds, slug rename propagation, unificar slugify)
- **Fase 3 — Relaciones más precisas** (umbral dinámico, bidireccionalidad, N+1, pesos)
- **Fase 4 — MCP** (herramientas nuevas, fixes de rename, docs reales)
- **Fase 6 — Nuevos agentes** (Q&A, curator, link gardener, weekly review)
- **Fase 7 — Ingest con extracción real** (MarkItDown, vision, ASR)
- **Fase 8 — Second brain profesional** (diff de versiones, activity feed, daily note, backlinks, backups)
- **Fase 9 — Customización** (Dran.Settings + Settings LiveView)
- **Fase 12 — Chat flotante + manejo de contexto** (copiloto del brain, context-aware, persistente)
- **Fase 10 — Limpieza, optimización y validación** (código muerto, edge cases, N+1, E2E)
- **Fase 11 — Métricas en el home** (dashboard con salud del brain, depende de limpieza)
- **Fase 5 — SKILL.md y README** (documentación final, cuando todo jale)

---

## Fase 0 — Fundamentos compartidos

### Task 0.1: Unificar slugify en un solo módulo

**Objective:** Una sola función `Dran.Slug.slugify/1` que usen Brain, Ingest.Utils y cualquier consumidor futuro, manejando tildes correctamente.

**Files:**
- Modify: `lib/dran/slug.ex`
- Test: `test/dran/slug_test.exs`

**Step 1: Escribir test fallido**

```elixir
defmodule Dran.SlugTest do
  use ExUnit.Case, async: true

  alias Dran.Slug

  test "strips accents and normalizes unicode" do
    assert Slug.slugify("Meditación Tántrica") == "meditacion-tantrica"
  end

  test "handles empty and weird input" do
    assert Slug.slugify("") == "untitled"
    assert Slug.slugify("   ") == "untitled"
    assert Slug.slugify("---") == "untitled"
  end

  test "kebab-cases mixed input" do
    assert Slug.slugify("Elixir & Phoenix 1.8!") == "elixir-phoenix-1-8"
  end
end
```

**Step 2: Correr y verificar fallo**
Run: `mix test test/dran/slug_test.exs`
Expected: FAIL (función no existe o no normaliza tildes)

**Step 3: Implementación mínima**

```elixir
def slugify(text) when is_binary(text) do
  text
  |> String.normalize(:nfd)
  |> String.replace(~r/[^a-zA-Z0-9\s-]/u, "")
  |> String.downcase()
  |> String.replace(~r/[^a-z0-9]+/, "-")
  |> String.replace(~r/^-+|-+$/, "")
  |> case do
    "" -> "untitled"
    slug -> slug
  end
end

def slugify(_), do: "untitled"
```

**Step 4: Correr y verificar pass**
Run: `mix test test/dran/slug_test.exs`
Expected: PASS

**Step 5: Commit**
```bash
git add lib/dran/slug.ex test/dran/slug_test.exs
git commit -m "fix: normalize unicode accents in Slug.slugify/1"
```

---

### Task 0.2: Migrar todos los consumidores a Dran.Slug

**Objective:** `Brain.slugify_title/1` e `Ingest.Utils.slugify/1` delegan a `Dran.Slug.slugify/1` — eliminar duplicación.

**Files:**
- Modify: `lib/dran/brain.ex` (slugify_title, ensure_title_and_slug)
- Modify: `lib/dran/agent/ingest/utils.ex` (slugify)
- Modify: `lib/dran/agent/ingest/utils.ex` (usar `Dran.Slug.slugify/1`)

**Step 1: Escribir test de integración**

```elixir
# test/dran/brain_test.exs (agregar)
test "create_page derives slug with accent normalization" do
  {:ok, ctx} = Brain.create_context(%{name: "T", slug: "t"})
  {:ok, page} = Brain.create_page(%{
    context_id: ctx.id, title: "Meditación", page_type: "note", body: "x"
  })
  assert page.slug == "meditacion"
end
```

**Step 2:** `mix test test/dran/brain_test.exs -v` → FAIL (hoy produce "meditaci-n")

**Step 3:** Reemplazar cuerpos de `slugify_title` y `Utils.slugify` con delegación a `Dran.Slug.slugify/1`.

**Step 4:** Test pasa.

**Step 5: Commit**
```bash
git add lib/dran/brain.ex lib/dran/agent/ingest/utils.ex
git commit -m "refactor: delegate all slug generation to Dran.Slug"
```

---

### Task 0.3: Validar Session.status con lista cerrada

**Objective:** `Session.changeset` valida que status sea uno de `pending/running/done/failed/cancelled`.

**Files:**
- Modify: `lib/dran/agent/session.ex:36-51`
- Test: `test/dran/agent/session_test.exs`

**Step 1: Test fallido**

```elixir
test "rejects invalid status" do
  changeset = Session.changeset(%Session{}, %{
    agent_type: "research", input: "x", context_id: Ecto.UUID.generate(),
    status: "bogus"
  })
  refute changeset.valid?
end
```

**Step 2:** FAIL.

**Step 3:** Agregar `|> validate_inclusion(:status, ~w(pending running done failed cancelled))` al changeset.

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: validate agent session status values"
```

---

### Task 0.4: Migración — índices para agent_sessions y agent_steps

**Objective:** Índices para queries por contexto y por sesión.

**Files:**
- Create: `priv/repo/migrations/XXXXXX_add_agent_indexes.exs`

**Step 1:** `mix ecto.gen.migration add_agent_indexes`

**Step 2: Implementación**

```elixir
def change do
  create index(:agent_sessions, [:context_id])
  create index(:agent_sessions, [:status])
  create index(:agent_steps, [:session_id])
end
```

**Step 3:** `mix ecto.migrate`

**Step 4: Commit**
```bash
git commit -m "perf: add indexes on agent_sessions and agent_steps"
```

---

## Fase 1 — Agentes resilientes

### Task 1.1: Garantizar cierre de sesión aunque el task muera

**Objective:** Si el runner del agente muere antes de `finish_session`, la sesión se marca `failed` con razón.

**Files:**
- Modify: `lib/dran/agent/engine.ex:128-190` (execute_loop/loop)
- Test: `test/dran/agent/engine_test.exs`

**Step 1: Test fallido**

```elixir
test "session is marked failed when runner crashes" do
  # start a session whose module raises in build_messages
  # await, then assert session.status == "failed"
end
```

**Step 2:** FAIL — hoy queda en `running`.

**Step 3: Implementación** — envolver `execute_loop` con monitor del caller y un `catch-all` que haga `finish_session(state, %{"summary" => "crashed: ..."})` con status `failed`. Además, `cancel/1` ya cubre el caso manual; agregar un sweeper periódico opcional queda fuera de scope (YAGNI).

Detalle clave: `finish_session/2` hoy pone status `"done"`. Parametrizar:

```elixir
defp finish_session(state, args, status \\ "done") do
  summary = args["summary"] || "Agent completed"
  Repo.get!(Session, state.session.id)
  |> Session.changeset(%{
    status: status,
    summary: summary,
    pages_created: state.pages_created,
    completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
  })
  |> Repo.update!()
  broadcast(state, {:session_done, summary, state.pages_created})
end
```

Y en el `try/catch` de `execute_loop`:

```elixir
try do
  loop(state)
catch
  kind, reason ->
    Logger.error("Agent.Engine crashed: #{Exception.format(kind, reason, __STACKTRACE__)}")
    finish_session(state, %{"summary" => "Agent crashed"}, "failed")
end
```

**Step 4:** Test pasa.

**Step 5: Commit**
```bash
git commit -m "fix: mark agent sessions failed when runner crashes"
```

---

### Task 1.2: Límite de páginas por sesión de research

**Objective:** Research agent no puede crear más de N páginas por sesión (default 10, configurable vía opts).

**Files:**
- Modify: `lib/dran/agent/research.ex:301-328` (execute_tool create_page)
- Test: `test/dran/agent/research_test.exs`

**Step 1: Test fallido**

```elixir
test "create_page returns error when session page limit reached" do
  state = %Research.State{pages_created: 10, session: session}
  {{:error, msg}, _} = Research.execute_tool("create_page", %{"title" => "x", "body" => "y"}, state)
  assert msg =~ "page limit"
end
```

**Step 2:** FAIL.

**Step 3: Implementación**

```elixir
@max_pages_per_session 10

def execute_tool("create_page", args, %State{} = state) do
  limit = Keyword.get(state.opts, :max_pages, @max_pages_per_session)

  if state.pages_created >= limit do
    {{:error, "You have created the maximum of #{limit} pages for this session. Call done."}, state}
  else
    # ... existing logic ...
  end
end
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: cap pages created per research session"
```

---

### Task 1.3: Retry con backoff en errores HTTP de API (no transporte)

**Objective:** `call_llm/1` reintenta hasta 2 veces ante errores HTTP de la API de inferencia (`{:http_error, 429|5xx, _}`) antes de rendirse. Los errores de transporte ya los cubre `retry: :transient` de Req en `Inference.Client.request/3` — **no duplicar**.

**Files:**
- Modify: `lib/dran/agent/engine.ex:257-271` (call_llm)
- Test: `test/dran/agent/engine_test.exs`

**Step 1: Test fallido** — mockear `Inference.chat` (via `req_plug` config o Mox) para que falle una vez con `{:error, {:http_error, 429, _}}` y luego éxito; verificar que el engine continúa sin marcar la sesión como failed.

**Step 2:** FAIL — hoy cualquier error termina el step.

**Step 3: Implementación**

```elixir
@max_llm_retries 2

defp call_llm(state, attempt \\ 0) do
  payload = %{...}

  case Inference.chat(payload) do
    {:ok, message} ->
      extract_tool_call(message)

    {:error, {:http_error, status, _body}} = err
    when status in [429, 500, 502, 503, 504] and attempt < @max_llm_retries ->
      Process.sleep(backoff(attempt))
      call_llm(state, attempt + 1)

    {:error, reason} ->
      {:error, reason}
  end
end

defp backoff(attempt), do: trunc(:math.pow(2, attempt) * 500)
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: retry transient API errors in agent engine"
```

---

### Task 1.4: Truncado inteligente de tool results

**Objective:** Si el resultado excede el límite, truncar en frontera de JSON o línea, con marker `…[truncated]` en vez de cortar a la mitad.

**Files:**
- Modify: `lib/dran/agent/engine.ex:487-509` (format_tool_result)

**Step 1: Test** — resultado de 3000 chars con JSON válido; verificar que el truncado es parseable o termina en línea completa.

**Step 3: Implementación** — cambiar `String.slice(0, @max_tool_result_chars)` por helper `smart_truncate/2` que:
1. Si es JSON, intenta `Jason.decode` en prefijos decrecientes hasta encontrar uno válido.
2. Si no, corta en el último `\n` antes del límite.
3. Sufija `"\n…[truncated]"`.

**Step 5: Commit**
```bash
git commit -m "fix: truncate tool results at safe boundaries"
```

---

### Task 1.5: Token/cost tracking por sesión de agente

**Objective:** Acumular `tokens_used` (prompt + completion) en `Session.meta` por cada llamada al LLM. El client ya devuelve `usage` — solo hay que persistirlo.

**Files:**
- Modify: `lib/dran/agent/engine.ex:257-271` (call_llm), `410-423` (finish_session)
- Test: `test/dran/agent/engine_test.exs`

**Step 1: Test fallido**

```elixir
test "session meta accumulates token usage" do
  # run a session with a mock LLM that returns usage
  # assert session.meta["total_tokens"] > 0
end
```

**Step 3: Implementación** — en `call_llm`, tras `{:ok, message}`, extraer `message["usage"]` y acumular en `state`:

```elixir
defp call_llm(state, attempt \\ 0) do
  ...
  case Inference.chat(payload) do
    {:ok, message} ->
      usage = Map.get(message, "usage", %{})
      state = accumulate_tokens(state, usage)
      # return {state, tool_call} so single_turn can thread it
      ...
  end
end

defp accumulate_tokens(state, usage) do
  tokens = Map.get(usage, "total_tokens", 0)
  Map.update(state, :tokens_used, tokens, &(&1 + tokens))
end
```

En `finish_session`, persistir:

```elixir
meta = Map.merge(state.session.meta || %{}, %{"tokens_used" => Map.get(state, :tokens_used, 0)})
Session.changeset(session, %{..., meta: meta})
```

(Ajustar la firma de `call_llm` para devolver `{state, result}` — `single_turn/1` lo desempaqueta.)

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: track token usage per agent session"
```

---

## Fase 2 — Embeds y creación de páginas

### Task 2.1: Resolver embeds en create_page y update_page

**Objective:** `Brain.create_page/1` y `Brain.update_page/2` llaman a `resolve_embeds/1` tras persistir, para que `![[slug]]` genere relaciones `embeds` automáticamente.

**Files:**
- Modify: `lib/dran/brain.ex:270-297` (create_page), `366-389` (update_page)
- Test: `test/dran/brain_test.exs`

**Step 1: Test fallido**

```elixir
test "create_page resolves ![[embed]] into embeds relation" do
  {:ok, artifact} = Brain.create_page(%{context_id: ctx.id, title: "File", slug: "file-a", page_type: "artifact"})
  {:ok, note} = Brain.create_page(%{context_id: ctx.id, title: "Note", slug: "note-a", page_type: "note", body: "See ![[file-a]]"})

  rels = Brain.list_relations_for_page(note.id).outbound
  assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == artifact.id))
end
```

**Step 2:** FAIL — hoy no crea la relación.

**Step 3: Implementación** — tras el insert/update exitoso, llamar `resolve_embeds(page)` (async no es necesario; es barato). En `update_page`, primero borrar relaciones `embeds` outbound existentes y luego re-resolver (ver Task 2.2).

```elixir
# en create_page, tras broadcast:
_ = resolve_embeds(page)

# en update_page, tras broadcast:
_ = reresolve_embeds(updated_page)
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: auto-resolve ![[embeds]] on page create/update"
```

---

### Task 2.2: Limpiar relaciones embeds obsoletas al actualizar body

**Objective:** Cuando el body cambia, las relaciones `embeds` que ya no aparecen en el texto se eliminan.

**Files:**
- Modify: `lib/dran/brain.ex` (agregar `reresolve_embeds/1`)
- Test: `test/dran/brain_test.exs`

**Step 1: Test fallido**

```elixir
test "update_page removes stale embeds relations" do
  {:ok, a} = Brain.create_page(%{context_id: ctx.id, title: "A", slug: "a", page_type: "artifact"})
  {:ok, b} = Brain.create_page(%{context_id: ctx.id, title: "B", slug: "b", page_type: "artifact"})
  {:ok, note} = Brain.create_page(%{context_id: ctx.id, title: "N", slug: "n", page_type: "note", body: "![[a]] ![[b]]"})

  {:ok, note} = Brain.update_page(note, %{"body" => "only ![[a]] now"})

  targets = Brain.list_relations_for_page(note.id).outbound
            |> Enum.filter(&(&1.relation_type == "embeds"))
            |> Enum.map(& &1.target_id)
  assert a.id in targets
  refute b.id in targets
end
```

**Step 2:** FAIL.

**Step 3: Implementación**

```elixir
@doc "Re-resolve embeds: delete stale ones, create new ones."
def reresolve_embeds(%Page{} = page) do
  current_slugs = extract_embeds(page.body) |> Enum.map(& &1.slug) |> MapSet.new()

  # delete outbound embeds not in current body
  page.id
  |> list_relations_for_page()
  |> Map.get(:outbound, [])
  |> Enum.filter(&(&1.relation_type == "embeds"))
  |> Enum.each(fn rel ->
    target_slug = rel.target.slug
    unless MapSet.member?(current_slugs, target_slug) do
      Repo.delete(rel)
    end
  end)

  resolve_embeds(page)
end
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: clean stale embeds relations on body update"
```

---

### Task 2.3: Propagar rename de slug a páginas que lo embeben

**Objective:** Al renombrar un slug, todas las páginas del contexto que tengan `![[old-slug]]` en el body se actualizan a `![[new-slug]]`, y las relaciones `embeds` se re-resuelven.

**Files:**
- Modify: `lib/dran/brain.ex` (agregar `rename_slug/3` de dominio)
- Modify: `lib/dran/mcp.ex:1233-1268` (rename_slug usa la nueva función)
- Test: `test/dran/brain_test.exs`

**Step 1: Test fallido**

```elixir
test "rename_slug updates embed references in other pages" do
  {:ok, art} = Brain.create_page(%{context_id: ctx.id, title: "Art", slug: "old-art", page_type: "artifact"})
  {:ok, note} = Brain.create_page(%{context_id: ctx.id, title: "N", slug: "n", page_type: "note", body: "![[old-art]]"})

  {:ok, _} = Brain.rename_slug(art, "new-art")

  note = Brain.get_page!(note.id)
  assert note.body =~ "![[new-art]]"
  refute note.body =~ "old-art"
end
```

**Step 2:** FAIL.

**Step 3: Implementación**

```elixir
def rename_slug(%Page{} = page, new_slug) do
  context_id = page.context_id
  old_slug = page.slug

  Repo.transaction(fn ->
    {:ok, updated} = update_page(page, %{"slug" => new_slug})

    # rewrite bodies referencing old slug
    pages_with_embed =
      Repo.all(
        from p in Page,
          where: p.context_id == ^context_id and p.id != ^page.id,
          where: like(p.body, ^"%![[#{old_slug}%")
      )

    Enum.each(pages_with_embed, fn p ->
      new_body = replace_slug_in_body(p.body, old_slug, new_slug)
      update_page(p, %{"body" => new_body})
    end)

    updated
  end)
end
```

Nota: `replace_slug_in_body/3` ya existe y maneja `![[old|display]]`. La relación `embeds` se re-resuelve porque `update_page` ahora llama a `reresolve_embeds` (Task 2.2).

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: propagate slug renames to embedding pages"
```

---

### Task 2.4: Inline links con candidatos relevantes (no 50 arbitrarios)

**Objective:** `Summaries.augment_prompt/1` selecciona las ~50 páginas más relevantes por similitud con el contenido de la página (o las más recientes si no hay embedding), en vez de las primeras 50 por `updated_at`.

**Files:**
- Modify: `lib/dran/summaries.ex:83-116` (augment_prompt)
- Test: `test/dran/summaries_test.exs`

**Step 1: Test** — con >50 páginas en contexto, verificar que las candidatas incluyen páginas semánticamente cercanas.

**Step 3: Implementación**

```elixir
defp candidate_pages(%Page{} = page) do
  if page.embedding do
    # vecinos por pgvector, limit 50
    vec = Pgvector.new(page.embedding)
    Repo.all(
      from p in Page,
        where: p.context_id == ^page.context_id and p.id != ^page.id,
        where: not is_nil(p.embedding),
        order_by: fragment("? <=> ?", p.embedding, ^vec),
        limit: 50,
        select: %{slug: p.slug, title: p.title, summary: p.summary}
    )
  else
    Brain.list_pages(context_id: page.context_id, limit: 50)
    |> Enum.map(&%{slug: &1.slug, title: &1.title, summary: &1.summary || ""})
  end
end
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: pick inline-link candidates by semantic similarity"
```

---

## Fase 3 — Relaciones más precisas

### Task 3.1: Umbral semántico dinámico por longitud de página

**Objective:** Páginas cortas (<500 chars) usan umbral más estricto (0.15); largas usan 0.22; muy largas (>4000) usan 0.28. Reduce falsos positivos en notas cortas.

**Files:**
- Modify: `lib/dran/brain/page_augmenter.ex:25,62-67`
- Test: `test/dran/brain/page_augmenter_test.exs`

**Step 1: Test fallido** — página corta con vecino a distancia 0.18 no crea relación; página larga con 0.25 sí.

**Step 2:** FAIL (hoy 0.18 < 0.22 → crea relación espuria).

**Step 3: Implementación**

```elixir
defp semantic_threshold(%Page{body: body}) do
  len = String.length(body || "")
  cond do
    len < 500 -> 0.15
    len > 4000 -> 0.28
    true -> 0.22
  end
end
```

Y en `run/1`: `threshold = semantic_threshold(page)` antes de filtrar neighbors.

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: dynamic semantic threshold by page length"
```

---

### Task 3.2: Relaciones semánticas bidireccionales

**Objective:** Al crear relación semántica A→B, crear también B→A si no existe, para que el grafo no quede sesgado.

**Files:**
- Modify: `lib/dran/brain/page_augmenter.ex:180-199` (maybe_create_relation)
- Test: `test/dran/brain/page_augmenter_test.exs`

**Step 1: Test fallido** — tras augment, tanto A→B como B→A existen.

**Step 3: Implementación** — en `maybe_create_relation/3`, además de la relación directa, verificar y crear la inversa con mismo `relation_type` y meta:

```elixir
defp maybe_create_relation(page, target, confidence) do
  create_semantic_edge(page.id, target.id, confidence)
  create_semantic_edge(target.id, page.id, confidence)
end

defp create_semantic_edge(source_id, target_id, confidence) do
  exists =
    Repo.exists?(
      from r in Relation,
        where: r.source_id == ^source_id and r.target_id == ^target_id,
        where: r.relation_type == "semantic"
    )

  unless exists do
    Brain.create_relation(%{
      source_id: source_id,
      target_id: target_id,
      relation_type: "semantic",
      meta: %{"auto" => true, "confidence" => Atom.to_string(confidence)}
    })
  end

  :ok
end
```

(Importar `Relation` y `Repo` — ya están aliased.)

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: bidirectional semantic relations"
```

---

### Task 3.3: Eliminar N+1 en creación de relaciones del augmenter

**Objective:** Cargar los outbound existentes una sola vez por página, no por cada vecino.

**Files:**
- Modify: `lib/dran/brain/page_augmenter.ex:165-199`

**Step 1: Test de benchmark simple** — instrumentar con `ExUnit.CaptureLog` o contar queries con Ecto telemetry; verificar que augment de página con 5 vecinos hace ≤3 queries de relations (1 read + N inserts).

**Step 3: Implementación** — pasar el set de target_ids existentes a `create_relations/2`:

```elixir
defp create_relations(page, neighbor_ids) do
  existing =
    Brain.list_relations_for_page(page.id)
    |> Map.get(:outbound, [])
    |> Enum.filter(&(&1.relation_type == "semantic"))
    |> Enum.map(& &1.target_id)
    |> MapSet.new()

  neighbor_ids
  |> Enum.reject(&MapSet.member?(existing, &1))
  |> Enum.each(fn target_id -> ... end)
end
```

Y quitar la llamada a `list_relations_for_page` dentro de `maybe_create_relation` (Task 3.2 lo reemplaza por `Repo.exists?` puntual, pero mejor: pasar el set completo y consultar membership en memoria).

**Step 4:** PASS + menos queries.

**Step 5: Commit**
```bash
git commit -m "perf: avoid N+1 relation lookups in page augmenter"
```

---

### Task 3.4: Unificar auto_relate con la lógica del augmenter

**Objective:** `Brain.auto_relate/2` usa el mismo umbral dinámico y crea relaciones bidireccionales, o delega a `PageAugmenter.find_semantic_neighbors` para no divergir.

**Files:**
- Modify: `lib/dran/brain.ex:439-513` (auto_relate)

**Step 1: Test** — `auto_relate` con página corta y vecino a 0.18 no crea relación (mismo criterio que augmenter).

**Step 3: Implementación** — extraer `PageAugmenter.find_semantic_neighbors/1` y `semantic_threshold/1` a funciones públicas o a un módulo compartido `Dran.Brain.Semantic`, y hacer que `Brain.auto_relate/2` las use. Mantener la firma pública de `auto_relate` (compatibilidad).

**Step 5: Commit**
```bash
git commit -m "refactor: unify semantic neighbor logic between auto_relate and PageAugmenter"
```

---

### Task 3.5: Peso opcional en relations y en graph_data

**Objective:** Campo `weight` (float, nullable) en `relations` para guardar score del augmenter; `graph_data/1` lo expone en edges.

**Files:**
- Create: `priv/repo/migrations/XXXXXX_add_weight_to_relations.exs`
- Modify: `lib/dran/brain/relation.ex`
- Modify: `lib/dran/brain.ex:621-643` (graph_data)
- Modify: `lib/dran/brain/page_augmenter.ex` (guardar distance como weight)

**Step 1: Migración**

```elixir
alter table(:relations) do
  add :weight, :float
end
```

**Step 2: Schema** — `field :weight, :float` + cast.

**Step 3: graph_data**

```elixir
select: %{source: r.source_id, target: r.target_id, type: r.relation_type, weight: r.weight}
```

**Step 4:** `mix ecto.migrate && mix test`

**Step 5: Commit**
```bash
git commit -m "feat: add weight to relations and expose in graph_data"
```

---

### Task 3.6: graph_data incluye summary y tags en nodos

**Objective:** Nodos del grafo llevan `summary` y `tags` para tooltips/filtros en el 3D view.

**Files:**
- Modify: `lib/dran/brain.ex:621-643`

**Step 1: Test** — `graph_data` devuelve nodos con `summary` y `tags`.

**Step 3:**

```elixir
select: %{id: p.id, title: p.title, slug: p.slug, type: p.page_type, summary: p.summary, tags: p.tags}
```

**Step 5: Commit**
```bash
git commit -m "feat: include summary and tags in graph nodes"
```

---

## Fase 4 — MCP

### Task 4.1: MCP rename_slug usa Brain.rename_slug y documenta propagación

**Objective:** El handler `rename_slug` llama a la nueva función de dominio que reescribe embeds; la descripción del tool lo dice explícitamente.

**Files:**
- Modify: `lib/dran/mcp.ex:593-616` (schema), `1233-1268` (handler)
- Test: `test/dran_web/api/mcp_controller_test.exs` (o test de unidad del handler si existe)

**Step 1: Test** — llamar rename_slug vía MCP; verificar que las páginas con `![[old]]` quedaron actualizadas.

**Step 3: Implementación**

```elixir
# handler
case Brain.rename_slug(page, new_slug) do
  {:ok, _} -> "Renamed '#{old_slug}' → '#{new_slug}'. Updated ![[#{old_slug}]] references in this context."
  {:error, changeset} -> "Error: #{format_changeset_errors(changeset)}"
end
```

Actualizar description: *"…All `![[old-slug]]` embeds in other pages of the same context are rewritten automatically."*

**Step 5: Commit**
```bash
git commit -m "feat(mcp): rename_slug propagates to embeds"
```

---

### Task 4.2: MCP tool reaugment_page

**Objective:** Nueva tool `reaugment_page` que re-encola `PageAugmenter` (summary/tags/embedding/relaciones) para una página — útil cuando inference estuvo caída o el contenido cambió mucho.

**Files:**
- Modify: `lib/dran/mcp.ex` (@tools + execute_tool)
- Test: `test/dran/mcp_test.exs` (si no existe, crear con tests de tools)

**Step 1: Schema**

```elixir
%{
  "name" => "reaugment_page",
  "description" =>
    "Re-run the augmentation pipeline for a page: regenerate summary/tags/embedding and refresh semantic relations. Use when inference was unavailable or the page body changed significantly.",
  "inputSchema" => %{
    "type" => "object",
    "properties" => %{
      "context" => %{"type" => "string"},
      "slug" => %{"type" => "string"}
    },
    "required" => ["context", "slug"]
  }
}
```

**Step 2: Handler**

```elixir
defp execute_tool("reaugment_page", %{"context" => context_slug, "slug" => slug}) do
  context = Brain.get_context_by_slug(context_slug)

  if context do
    case Brain.get_page_by_slug(slug, context.id) do
      nil -> "Error: page '#{slug}' not found"
      page ->
        # force re-embedding by clearing hash so PageAugmenter regenerates
        page
        |> Ecto.Changeset.change(embedding_hash: nil)
        |> Repo.update!()
        |> Dran.Brain.PageAugmenter.schedule()

        "Reaugmentation scheduled for '#{slug}'"
    end
  else
    "Error: context '#{context_slug}' not found"
  end
end
```

**Step 5: Commit**
```bash
git commit -m "feat(mcp): add reaugment_page tool"
```

---

### Task 4.3: list_pages con filtros owner y created_by

**Objective:** MCP `list_pages` acepta `owner` y `created_by` para auditar páginas por agente.

**Files:**
- Modify: `lib/dran/mcp.ex` (schema + handler)
- Test

**Step 1: Schema** — agregar propiedades `owner` y `created_by` (string, opcionales).

**Step 2: Handler** — pasar a `Brain.list_pages` (ya soporta ambos filtros — ver `maybe_filter_owner` y `maybe_filter_created_by`).

**Step 5: Commit**
```bash
git commit -m "feat(mcp): filter list_pages by owner and created_by"
```

---

### Task 4.4: Corregir docstrings del módulo MCP

**Objective:** El `@moduledoc` y las descriptions reflejan el comportamiento real post-fixes (embeds auto-resueltos, rename con propagación, 19 tools).

**Files:**
- Modify: `lib/dran/mcp.ex:1-47` (@moduledoc) y descriptions de `create_page`, `update_page`, `rename_slug`.

**Step 1:** Actualizar lista de tools a 19 (agregar `reaugment_page`), corregir nota de embeds: *"Embeds are auto-resolved into `embeds` relations on create and update."*

**Step 5: Commit**
```bash
git commit -m "docs(mcp): sync module docs with real behavior"
```

---

## Fase 6 — Nuevos agentes

Todos implementan `Dran.Agent.Engine.Behaviour` y corren sobre el engine existente. Se registran en `start_agent_by_type/3` del MCP.

### Task 6.1: Agent Q&A (`ask`)

**Objective:** Agente que responde preguntas usando el brain: busca, lee páginas top, sintetiza respuesta con citas, y guarda una página `query` con el veredicto.

**Files:**
- Create: `lib/dran/agent/qa.ex`
- Test: `test/dran/agent/qa_test.exs`
- Modify: `lib/dran/mcp.ex` (start_agent_by_type: agregar `"ask"`)

**Step 1: Test fallido**

```elixir
test "qa agent creates a query page with the answer" do
  # seed 2 pages about "elixir processes"
  # run QA agent with input "what are elixir processes?"
  # assert a query page was created with answer_status: "answered"
end
```

**Step 3: Implementación** — módulo `Dran.Agent.QA` con:

- `agent_type` → `"ask"`
- `tools`:
  - `search` (delega a `Brain.search/2`, mismo handler que research)
  - `get_page` (lee página completa por slug)
  - `create_query_page` (crea página tipo `query` con meta `%{kind, difficulty, answer_status: "answered", answered_by: "qa-agent"}`)
  - `done`
- `system_prompt`:

```
You are a Q&A agent for Dran. Answer the question using ONLY the brain's knowledge.

Workflow:
1. Use `search` with 2-3 varied queries to find relevant pages.
2. Use `get_page` on the top 2-3 results to read full content.
3. Synthesize a concise answer in Spanish. Cite sources as [slug].
4. Use `create_query_page` to save the question + answer.
5. Call `done` with a one-line summary.

Rules:
- If the brain has no relevant pages, say so in the answer (answer_status: "open").
- Never invent facts not present in the pages you read.
- Answer in the same language as the question.
```

- `execute_tool("create_query_page", args, state)`:

```elixir
page_attrs = %{
  context_id: state.session.context_id,
  title: args["title"] || state.session.input,
  slug: args["slug"],
  body: args["answer"],
  page_type: "query",
  tags: args["tags"] || [],
  created_by: "qa-agent",
  owner: "qa-agent",
  meta: %{
    "kind" => args["kind"] || "factual",
    "difficulty" => args["difficulty"] || "intermediate",
    "answer_status" => args["answer_status"] || "answered",
    "answered_by" => "qa-agent",
    "agent_session_id" => state.session.id
  }
}
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: add Q&A agent (ask)"
```

---

### Task 6.2: Agent Curator (conserje del brain)

**Objective:** Agente de mantenimiento que corre periódicamente: encuentra duplicados semánticos, activa `kb_contested`, reporta huérfanos/stale, y genera una nota con el reporte.

**Files:**
- Create: `lib/dran/agent/curator.ex`
- Test: `test/dran/agent/curator_test.exs`
- Modify: `lib/dran/mcp.ex` (start_agent_by_type: agregar `"curator"`)

**Step 1: Test fallido**

```elixir
test "curator flags near-duplicate pages as contested" do
  # seed 2 pages with embeddings at distance < 0.05 but different content
  # run curator
  # assert both pages have kb_contested == true
end
```

**Step 3: Implementación** — `Dran.Agent.Curator`:

- `agent_type` → `"curator"`
- `tools`: `find_duplicates`, `flag_contested`, `lint_report`, `create_note`, `done`
- `find_duplicates` (no LLM — query directa):

```elixir
def execute_tool("find_duplicates", _args, state) do
  pairs =
    Repo.all(
      from p1 in Page,
        join: p2 in Page,
          on: p1.context_id == p2.context_id and p1.id < p2.id,
        where: p1.context_id == ^state.session.context_id,
        where: not is_nil(p1.embedding) and not is_nil(p2.embedding),
        where: fragment("? <=> ?", p1.embedding, p2.embedding) < 0.05,
        select: %{a: p1.slug, b: p2.slug, distance: fragment("? <=> ?", p1.embedding, p2.embedding)},
        limit: 20
    )

  {{:ok, pairs}, Map.put(state, :duplicate_pairs, pairs)}
end
```

- `flag_contested`: recibe lista de slugs, pone `kb_contested = true` via `Ecto.Changeset.change` (no `Brain.update_page` — no queremos re-augmentar).
- `lint_report`: delega a `Brain.lint/1`.
- `create_note`: crea página `note` con el reporte del curator en el body.
- El system prompt le dice al LLM: revisa los pares duplicados, decide cuáles son duplicados reales vs contenido distinto, flaggea los segundos como contested, y genera la nota de reporte.

**Step 5: Commit**
```bash
git commit -m "feat: add curator agent for brain maintenance"
```

---

### Task 6.3: Agent Link Gardener (relaciones tipadas)

**Objective:** Agente que propone relaciones **tipadas** (`part_of`, `supersedes`, `contradicts`) con justificación, más allá de las `semantic` automáticas.

**Files:**
- Create: `lib/dran/agent/link_gardener.ex`
- Test: `test/dran/agent/link_gardener_test.exs`
- Modify: `lib/dran/mcp.ex` (start_agent_by_type)

**Step 1: Test fallido** — seed 3 páginas relacionadas; el gardener crea al menos una relación tipada con justificación en `meta.reason`.

**Step 3: Implementación** — `Dran.Agent.LinkGardener`:

- `agent_type` → `"link_gardener"`
- `tools`: `list_orphans` (delega `Brain.orphan_pages/1`), `get_page`, `search`, `propose_relation`, `done`
- `propose_relation` crea la relación con `meta.justification`:

```elixir
def execute_tool("propose_relation", args, state) do
  context_id = state.session.context_id

  result =
    Brain.create_relation_by_slugs(
      args["source_slug"],
      args["target_slug"],
      args["relation_type"],
      context_id
    )

  case result do
    {:ok, rel} ->
      # attach justification to relation meta
      rel
      |> Ecto.Changeset.change(meta: Map.merge(rel.meta || %{}, %{
        "justification" => args["justification"],
        "proposed_by" => "link-gardener"
      }))
      |> Repo.update()

      {{:ok, %{source: args["source_slug"], target: args["target_slug"]}}, state}

    error ->
      {error, state}
  end
end
```

- System prompt: lee páginas huérfanas o con pocas relaciones, busca candidatas, lee contenido, y propone relaciones tipadas con justificación de 1 línea. Máximo 10 propuestas por sesión. Nunca propone `semantic` (esas son automáticas).

**Step 5: Commit**
```bash
git commit -m "feat: add link gardener agent for typed relations"
```

---

### Task 6.4: Agent Weekly Review

**Objective:** Agente que genera la página de review semanal: goals activos, todos por status, páginas creadas en la semana, sugerencias.

**Files:**
- Create: `lib/dran/agent/weekly_review.ex`
- Test: `test/dran/agent/weekly_review_test.exs`
- Modify: `lib/dran/mcp.ex` (start_agent_by_type)

**Step 1: Test fallido** — seed goals + todos + páginas recientes; el agente crea una página `note` con `meta.kind: "journal"` y `meta.review: "weekly"` conteniendo secciones de goals y todos.

**Step 3: Implementación** — `Dran.Agent.WeeklyReview`:

- `agent_type` → `"weekly_review"`
- `tools`: `gather_stats` (Brain.stats + list_pages de goals/todos + páginas de la semana), `create_review_page`, `done`
- El system prompt recibe los datos agregados y genera el markdown del review: secciones Goals (con health), Todos completados vs pendientes, Páginas nuevas, Sugerencias para la próxima semana.
- `create_review_page` guarda `note` con `meta: %{"kind" => "journal", "review" => "weekly", "week" => "2026-W29"}`.

**Step 5: Commit**
```bash
git commit -m "feat: add weekly review agent"
```

---

### Task 6.5: Scheduler con Quantum para curator y weekly review

**Objective:** Jobs recurrentes: curator diario a las 6am, weekly review los domingos a las 8am.

**Files:**
- Modify: `mix.exs` (agregar `{:quantum, "~> 3.5"}`)
- Create: `lib/dran/scheduler.ex`
- Modify: `lib/dran/application.ex` (agregar scheduler al supervision tree)
- Modify: `config/config.exs` (jobs schedule)

**Step 1: Implementación**

```elixir
# mix.exs deps
{:quantum, "~> 3.5"}

# lib/dran/scheduler.ex
defmodule Dran.Scheduler do
  use Quantum, otp_app: :dran
end

# config/config.exs
config :dran, Dran.Scheduler,
  jobs: [
    curator_daily: [
      schedule: "0 6 * * *",
      task: {Dran.Agent.Curator, :run_scheduled, []}
    ],
    weekly_review: [
      schedule: "0 8 * * 0",
      task: {Dran.Agent.WeeklyReview, :run_scheduled, []}
    ]
  ]
```

Cada agente expone `run_scheduled/0` que obtiene el contexto default y llama a `run/3`:

```elixir
def run_scheduled do
  context = Brain.get_context_by_slug(Auth.default_context_slug())
  if context, do: run("scheduled run", context.id), else: :ok
end
```

**Step 2:** `mix deps.get && mix compile`

**Step 3: Test** — verificar que el scheduler arranca en el supervision tree (`Dran.Scheduler` en `Supervisor.which_children(Dran.Supervisor)`). Los jobs no se ejecutan en test.

**Step 5: Commit**
```bash
git commit -m "feat: schedule curator and weekly review with Quantum"
```

---

## Fase 7 — Ingest con extracción real

### Task 7.1: Ingest de archivos con MarkItDown

**Objective:** `Ingest.Utils.do_ingest/3` convierte archivos descargados (PDF, DOCX, PPTX) a markdown via `Dran.Inference.MarkItDown` y guarda el contenido en el body — no solo un link de descarga.

**Files:**
- Modify: `lib/dran/agent/ingest/utils.ex:169-197` (ingest_file)
- Test: `test/dran/agent/ingest/utils_test.exs`

**Step 1: Test fallido**

```elixir
test "ingest_file converts PDF to markdown body via MarkItDown" do
  # mock MarkItDown.to_markdown to return "# Converted content"
  # ingest a PDF
  # assert page.body =~ "Converted content"
end
```

**Step 3: Implementación** — en `ingest_file/6`, tras `Uploads.store`:

```elixir
body =
  case Dran.Inference.MarkItDown.to_markdown(filename, content_type, binary) do
    {:ok, markdown} ->
      "Source: #{url}\n\n#{markdown}"

    {:error, reason} ->
      Logger.info("MarkItDown failed for #{filename}: #{inspect(reason)}, storing as attachment only")
      "Source: #{url}\n\n[Download](#{stored.storage_path})"
  end
```

La página resultante tiene el contenido real → embedding útil → relaciones semánticas reales. Si MarkItDown falla o no está configurado, degradación graceful al comportamiento actual.

**Step 5: Commit**
```bash
git commit -m "feat: extract file content to markdown on ingest"
```

---

### Task 7.2: Ingest de imágenes con Vision

**Objective:** Archivos de imagen (PNG, JPG, WEBP) se describen con el modelo Vision y el body queda con la descripción.

**Files:**
- Modify: `lib/dran/agent/ingest/utils.ex` (ingest_file)
- Modify: `lib/dran/inference/vision.ex` (si hace falta un helper `describe_image/2` de alto nivel — revisar primero)
- Test

**Step 3: Implementación** — mismo patrón que 7.1: si `content_type` empieza con `"image/"`, llamar a Vision con la imagen base64 + prompt *"Describe this image in detail, in Spanish. Include visible text, objects, and context."* El body queda: `Source: url\n\n**Description:** ...\n\n[View image](storage_path)`.

**Step 5: Commit**
```bash
git commit -m "feat: describe ingested images with vision model"
```

---

### Task 7.3: Ingest de audio con ASR

**Objective:** Archivos de audio (MP3, WAV, M4A) se transcriben con el modelo ASR y el body queda con la transcripción.

**Files:**
- Modify: `lib/dran/agent/ingest/utils.ex` (ingest_file)
- Modify: `lib/dran/inference/asr.ex` (helper `transcribe/2` si no existe)
- Test

**Step 3:** Mismo patrón: `content_type` con `"audio/"` → ASR → body con transcripción + link al archivo.

**Step 5: Commit**
```bash
git commit -m "feat: transcribe ingested audio with ASR model"
```

---

## Fase 8 — Second brain profesional

### Task 8.1: Diff de versiones

**Objective:** Ver qué cambió entre dos versiones de una página — dominio + UI.

**Files:**
- Modify: `lib/dran/brain.ex` (agregar `version_diff/2`)
- Modify: `lib/dran_web/live/page_live.ex` o donde viva el historial (verificar con `search_files` qué LiveView muestra versiones)
- Test: `test/dran/brain_test.exs`

**Step 1: Test fallido**

```elixir
test "version_diff returns line-level changes between versions" do
  # create page, update body twice
  # diff v1 vs v2 → shows added/removed lines
end
```

**Step 3: Implementación** — diff línea por línea sin dependencias nuevas:

```elixir
def version_diff(%Page{} = page, version) do
  with %PageVersion{} = old <- get_page_version(page.id, version) do
    old_lines = String.split(old.body || "", "\n")
    new_lines = String.split(page.body || "", "\n")

    {:ok, %{from: version, to: page.version, changes: line_diff(old_lines, new_lines)}}
  else
    nil -> {:error, :version_not_found}
  end
end

defp line_diff(old_lines, new_lines) do
  old_set = MapSet.new(old_lines)
  new_set = MapSet.new(new_lines)

  added = Enum.reject(new_lines, &MapSet.member?(old_set, &1))
  removed = Enum.reject(old_lines, &MapSet.member?(new_set, &1))

  %{added: added, removed: removed, unchanged: length(new_lines) - length(added)}
end
```

(Diff aproximado estilo "qué líneas entraron/salieron" — no un Myers diff completo. Suficiente para revisar cambios; YAGNI.)

**Step 5: Commit**
```bash
git commit -m "feat: version diff for pages"
```

---

### Task 8.2: Activity feed

**Objective:** Vista de actividad reciente del brain (usa `Dran.Brain.Log` — append-only ya existe).

**Files:**
- Modify: `lib/dran/brain.ex` (list_log ya existe — quizá agregar filtro por fecha)
- Create: `lib/dran_web/live/activity_live.ex`
- Modify: `lib/dran_web/router.ex`
- Modify: `lib/dran_web/components/layouts.ex` (nav link)
- Test: `test/dran_web/live/activity_live_test.exs`

**Step 1: Test** — el LiveView renderiza entradas del log con acción, subject y timestamp.

**Step 3: Implementación** — LiveView simple que suscribe a `brain:<context_id>` para updates en vivo y lista `Brain.list_log/1` con formato: ícono por acción (create/update/delete), subject como link a la página, tiempo relativo ("hace 2h"). Reutilizar componentes de `page_components.ex`.

**Step 5: Commit**
```bash
git commit -m "feat: activity feed LiveView from brain log"
```

---

### Task 8.3: Daily note automática

**Objective:** Al abrir el dashboard, si no existe nota del día, se crea automáticamente una `note` con `meta.kind: "journal"` y `meta.date` de hoy.

**Files:**
- Modify: `lib/dran/brain.ex` (agregar `ensure_daily_note/1`)
- Modify: `lib/dran_web/live/dashboard_live.ex` (llamarlo en mount)
- Test: `test/dran/brain_test.exs`

**Step 1: Test fallido**

```elixir
test "ensure_daily_note creates today's journal note once" do
  assert {:ok, note} = Brain.ensure_daily_note(ctx.id)
  assert {:ok, same} = Brain.ensure_daily_note(ctx.id)
  assert same.id == note.id
end
```

**Step 3: Implementación**

```elixir
def ensure_daily_note(context_id, date \\ Date.utc_today()) do
  slug = "daily-" <> Date.to_iso8601(date)

  case get_page_by_slug(slug, context_id) do
    nil ->
      create_page(%{
        context_id: context_id,
        title: Date.to_iso8601(date),
        slug: slug,
        page_type: "note",
        body: "",
        meta: %{"kind" => "journal", "date" => Date.to_iso8601(date)},
        created_by: "system"
      })

    page ->
      {:ok, page}
  end
end
```

**Step 5: Commit**
```bash
git commit -m "feat: auto-create daily journal note"
```

---

### Task 8.4: Backlinks en la vista de página

**Objective:** La página muestra "Pages linking here" usando las relaciones inbound — UI sobre `list_relations_for_page` (ya existe).

**Files:**
- Modify: el LiveView de detalle de página (verificar cuál es: `note_live.ex` / `concept_live.ex` / etc. — probablemente hay un componente compartido de detalle)
- Test

**Step 3:** Sección colapsable "Linked from (N)" que lista las páginas inbound con tipo de relación, igual que `get_links` del MCP pero en la UI. Reutilizar `Brain.list_relations_for_page/1` — ya trae inbound con source preloaded.

**Step 5: Commit**
```bash
git commit -m "feat: show backlinks on page detail"
```

---

### Task 8.5: Backup/export completo del contexto

**Objective:** Export del contexto completo (páginas + relaciones + versiones) a JSON descargable — la base de backups.

**Files:**
- Modify: `lib/dran/exporter.ex` (ya existe — verificar qué exporta hoy)
- Modify: `lib/dran_web/controllers/api/export_controller.ex` (verificar endpoint actual)
- Test: `test/dran_web/api/export_controller_test.exs` (ya existe)

**Step 1:** Leer `exporter.ex` primero — quizá ya exporta páginas. Extender a: relaciones, page_versions, meta completa. Formato: un JSON con `%{context: ..., pages: [...], relations: [...], versions: [...], exported_at: ...}`.

**Step 3: Implementación**

```elixir
def full_export(context_id) do
  %{
    context: Repo.get!(Context, context_id),
    pages: Repo.all(from p in Page, where: p.context_id == ^context_id),
    relations: relations_for_context(context_id),
    versions: versions_for_context(context_id),
    exported_at: DateTime.utc_now()
  }
end
```

Endpoint autenticado `GET /api/export/:context/full` que devuelve el JSON con `content-disposition: attachment`.

**Step 5: Commit**
```bash
git commit -m "feat: full context export for backups"
```

---

## Fase 9 — Customización

### Task 9.1: Dran.Settings — settings runtime en DB

**Objective:** Settings clave-valor por contexto (o global) en DB, editables sin redeploy: umbral semántico, límites de agentes, idioma default de research.

**Files:**
- Create: `priv/repo/migrations/XXXXXX_create_settings.exs`
- Create: `lib/dran/settings.ex`
- Test: `test/dran/settings_test.exs`

**Step 1: Migración**

```elixir
create table(:settings, primary_key: false) do
  add :key, :string, primary_key: true
  add :value, :map, null: false, default: %{}
  timestamps(type: :utc_datetime)
end
```

**Step 2: Implementación**

```elixir
defmodule Dran.Settings do
  @moduledoc "Runtime settings stored in DB, overriding config defaults."

  alias Dran.Repo
  import Ecto.Query

  @defaults %{
    "semantic_threshold_short" => 0.15,
    "semantic_threshold_mid" => 0.22,
    "semantic_threshold_long" => 0.28,
    "agent_max_pages" => 10,
    "agent_max_sources" => 10,
    "research_lang" => "es",
    "daily_note_enabled" => true
  }

  def get(key) do
    case Repo.one(from s in "settings", where: s.key == ^key, select: s.value) do
      nil -> Map.get(@defaults, key)
      value -> value
    end
  end

  def put(key, value) do
    Repo.insert_all("settings", [%{key: key, value: %{"value" => value}, inserted_at: now(), updated_at: now()}],
      on_conflict: [set: [value: %{"value" => value}, updated_at: now()]],
      conflict_target: :key
    )
  end

  def all, do: Map.merge(@defaults, db_settings())

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
```

**Step 3:** `PageAugmenter.semantic_threshold/1` y `Research.@max_sources` leen de `Dran.Settings.get/1` con fallback a defaults de módulo.

**Step 5: Commit**
```bash
git commit -m "feat: runtime settings in DB with defaults"
```

---

### Task 9.2: Settings LiveView

**Objective:** UI para editar los settings de 9.1 — sliders para umbrales, inputs para límites, toggle para daily note, select de idioma.

**Files:**
- Modify: `lib/dran_web/live/settings_live.ex` (ya existe — extender)
- Test: `test/dran_web/live/settings_live_test.exs`

**Step 1: Test** — el form renderiza los settings actuales y al guardar persiste en DB.

**Step 3:** Sección "Brain tuning" en el settings LiveView existente: form con `to_form/1`, campos para cada setting de `@defaults`, botón guardar → `Dran.Settings.put/2` + flash de confirmación. Estilo consistente con el resto de la app (Tailwind, componentes existentes).

**Step 5: Commit**
```bash
git commit -m "feat: settings UI for brain tuning"
```

---

## Fase 12 — Chat flotante + manejo de contexto

El copiloto del brain: un chat siempre disponible que responde usando el conocimiento del contexto activo, sin salir de la página donde estás.

### Task 12.1: ChatSession GenServer + persistencia

**Objective:** Proceso por usuario+contexto que mantiene el historial del chat en memoria y lo persiste en DB para sobrevivir navegación entre LiveViews.

**Files:**
- Create: `lib/dran/chat/session.ex` (schema)
- Create: `lib/dran/chat/server.ex` (GenServer)
- Create: `lib/dran/chat/supervisor.ex` (DynamicSupervisor)
- Create: `priv/repo/migrations/XXXXXX_create_chat_sessions.exs`
- Modify: `lib/dran/application.ex` (agregar supervisor + registry)
- Test: `test/dran/chat/server_test.exs`

**Step 1: Migración**

```elixir
create table(:chat_sessions, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :context_id, references(:contexts, type: :binary_id, on_delete: :delete_all), null: false
  add :user, :string, null: false
  add :messages, :map, null: false, default: %{"items" => []}  # JSONB array
  add :page_slug, :string  # página donde se inició el chat (opcional)
  timestamps(type: :utc_datetime)
end

create index(:chat_sessions, [:context_id, :user])
```

**Step 2: Test fallido**

```elixir
test "chat server maintains message history across calls" do
  {:ok, pid} = ChatServer.start_link(context_id: ctx.id, user: "alvaro")
  {:ok, reply} = ChatServer.send_message(pid, "¿qué sé de elixir?")
  history = ChatServer.history(pid)
  assert length(history) == 2  # user + assistant
end
```

**Step 3: Implementación**

```elixir
defmodule Dran.Chat.Server do
  use GenServer, restart: :temporary

  @max_history 20  # mensajes en memoria; se persisten todos

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def send_message(pid, text), do: GenServer.call(pid, {:send, text}, 120_000)
  def history(pid), do: GenServer.call(pid, :history)
  def clear(pid), do: GenServer.call(pid, :clear)

  @impl true
  def init(opts) do
    context_id = Keyword.fetch!(opts, :context_id)
    user = Keyword.fetch!(opts, :user)

    # load or create DB session
    session = load_or_create_session(context_id, user, opts[:page_slug])
    messages = session.messages["items"] || []

    {:ok, %{session: session, messages: messages, context_id: context_id, user: user}}
  end

  @impl true
  def handle_call({:send, text}, _from, state) do
    user_msg = %{"role" => "user", "content" => text, "at" => now()}

    # build context-aware LLM call
    {:ok, reply_text, sources} = Dran.Chat.Brain.answer(state.context_id, text, state.messages)

    assistant_msg = %{
      "role" => "assistant",
      "content" => reply_text,
      "sources" => sources,
      "at" => now()
    }

    new_messages = (state.messages ++ [user_msg, assistant_msg]) |> Enum.take(-@max_history)
    persist_messages(state.session, new_messages)

    {:reply, {:ok, reply_text, sources}, %{state | messages: new_messages}}
  end

  def handle_call(:history, _from, state), do: {:reply, state.messages, state}

  def handle_call(:clear, _from, state) do
    persist_messages(state.session, [])
    {:reply, :ok, %{state | messages: []}}
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  # ... load_or_create_session, persist_messages ...
end
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: chat session GenServer with DB persistence"
```

---

### Task 12.2: Dran.Chat.Brain — respuestas con contexto

**Objective:** El módulo que responde usando hybrid search + get_page del contexto actual, con las fuentes citadas.

**Files:**
- Create: `lib/dran/chat/brain.ex`
- Test: `test/dran/chat/brain_test.exs`

**Step 1: Test fallido**

```elixir
test "answer cites pages from the context" do
  # seed 2 pages about "meditación"
  {:ok, answer, sources} = ChatBrain.answer(ctx.id, "¿qué es la meditación?", [])
  assert answer =~ "meditación"
  assert [%{"slug" => _} | _] = sources
end
```

**Step 3: Implementación**

```elixir
defmodule Dran.Chat.Brain do
  alias Dran.{Brain, Inference}

  @max_sources 3

  def answer(context_id, question, history) do
    with {:ok, results} <- Brain.search(question, context_id: context_id, limit: @max_sources),
         pages <- fetch_top_pages(results, context_id),
         {:ok, reply} <- chat_with_pages(question, pages, history) do
      sources = Enum.map(pages, &%{"slug" => &1.slug, "title" => &1.title})
      {:ok, reply, sources}
    else
      {:error, :not_configured} ->
        {:ok, "El cerebro no está disponible (inference no configurado). Intenta de nuevo más tarde.", []}

      _ ->
        {:ok, "No encontré nada relevante en tu cerebro para esa pregunta.", []}
    end
  end

  defp fetch_top_pages(results, context_id) do
    results
    |> Enum.take(@max_sources)
    |> Enum.map(&Brain.get_page_by_slug(&1.slug, context_id))
    |> Enum.reject(&is_nil/1)
  end

  defp chat_with_pages(question, pages, history) do
    pages_text =
      pages
      |> Enum.map_join("\n\n---\n\n", fn p ->
        "## #{p.title} (#{p.slug})\n#{String.slice(p.body || "", 0, 2000)}"
      end)

    messages = [
      %{"role" => "system", "content" => system_prompt(pages_text)}
      | Enum.take(history, -10)
    ] ++ [%{"role" => "user", "content" => question}]

    payload = %{
      "model" => Inference.chat_model(),
      "messages" => messages,
      "temperature" => 0.3,
      "max_tokens" => 1024
    }

    case Inference.chat(payload) do
      {:ok, message} -> {:ok, Map.get(message, "content", "")}
      error -> error
    end
  end

  defp system_prompt(pages_text) do
    """
    Eres el copiloto del segundo cerebro de Álvaro. Responde SOLO con información
    de las páginas provistas. Si la respuesta no está en las páginas, dilo claramente.

    Reglas:
    - Responde en español, tono directo y útil.
    - Cita las fuentes como [slug] al final de cada oración relevante.
    - Si el usuario pide crear/editar algo, di que use las herramientas de la UI.
    - Máximo 3 párrafos por respuesta.

    Páginas disponibles:

    #{pages_text}
    """
  end
end
```

**Step 4:** PASS.

**Step 5: Commit**
```bash
git commit -m "feat: context-aware chat brain with source citation"
```

---

### Task 12.3: ChatWidget LiveComponent (flotante)

**Objective:** Componente flotante estilo copiloto, montado en el layout como `CommandPalette`, disponible en todas las páginas autenticadas.

**Files:**
- Create: `lib/dran_web/components/chat_widget.ex`
- Modify: `lib/dran_web/components/layouts.ex` (montar junto a CommandPalette)
- Modify: `assets/css/app.css` (estilos del widget si hace falta)
- Test: `test/dran_web/components/chat_widget_test.exs`

**Step 1: Test** — el componente renderiza el botón flotante, abre el panel, envía mensaje y muestra respuesta.

**Step 3: Implementación** — patrón idéntico a `CommandPalette`:

```elixir
defmodule DranWeb.ChatWidget do
  use DranWeb, :live_component

  alias Dran.Chat.{Server, Supervisor}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:input, "")
     |> assign(:messages, [])
     |> assign(:loading, false)
     |> assign(:chat_pid, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # start or fetch chat server for this user+context
    socket =
      if connected?(socket) and is_nil(socket.assigns.chat_pid) do
        pid = Supervisor.find_or_start(assigns.context_slug, assigns.current_user)
        messages = Server.history(pid)
        assign(socket, chat_pid: pid, messages: messages)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="fixed bottom-4 right-4 z-50 flex flex-col items-end gap-2">
      <%!-- Chat panel --%>
      <div
        :if={@open}
        class="w-96 h-[32rem] bg-base-100 border border-base-300 rounded-2xl shadow-2xl flex flex-col overflow-hidden"
      >
        <%!-- Header --%>
        <div class="flex items-center justify-between px-4 py-3 border-b border-base-300 bg-base-200/50">
          <div class="flex items-center gap-2">
            <.icon name="hero-sparkles" class="size-4 text-primary" />
            <span class="font-semibold text-sm">{gettext("Brain Copilot")}</span>
            <span class="badge badge-xs badge-ghost">{@context_slug}</span>
          </div>
          <div class="flex gap-1">
            <button phx-click="clear" phx-target={@myself} class="btn btn-ghost btn-xs" title={gettext("Clear")}>
              <.icon name="hero-trash" class="size-3" />
            </button>
            <button phx-click="toggle" phx-target={@myself} class="btn btn-ghost btn-xs">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <%!-- Messages --%>
        <div class="flex-1 overflow-y-auto p-3 space-y-3" id={"#{@id}-messages"} phx-hook="ScrollBottom">
          <div :if={@messages == []} class="text-center text-base-content/40 text-sm mt-8">
            {gettext("Ask me anything about your brain...")}
          </div>
          <div :for={msg <- @messages} class={[
            "max-w-[85%] rounded-xl px-3 py-2 text-sm",
            msg["role"] == "user" && "ml-auto bg-primary text-primary-content",
            msg["role"] == "assistant" && "mr-auto bg-base-200"
          ]}>
            <div class="whitespace-pre-wrap">{msg["content"]}</div>
            <div :if={msg["sources"] && msg["sources"] != []} class="flex flex-wrap gap-1 mt-1.5">
              <.link
                :for={src <- msg["sources"]}
                navigate={"/pages/#{src["slug"]}"}
                class="badge badge-xs badge-outline hover:badge-primary transition-colors"
              >
                {src["title"]}
              </.link>
            </div>
          </div>
          <div :if={@loading} class="mr-auto bg-base-200 rounded-xl px-3 py-2">
            <span class="loading loading-dots loading-sm"></span>
          </div>
        </div>

        <%!-- Input --%>
        <form phx-submit="send" phx-target={@myself} class="p-3 border-t border-base-300">
          <div class="flex gap-2">
            <input
              type="text"
              name="message"
              value={@input}
              placeholder={gettext("Ask about %{context}...", context: @context_slug)}
              class="flex-1 input input-sm input-bordered focus:outline-none focus:ring-1 focus:ring-primary"
              autocomplete="off"
            />
            <button type="submit" class="btn btn-primary btn-sm" disabled={@loading}>
              <.icon name="hero-paper-airplane" class="size-4" />
            </button>
          </div>
        </form>
      </div>

      <%!-- FAB --%>
      <button
        phx-click="toggle"
        phx-target={@myself}
        class="btn btn-primary btn-circle shadow-lg hover:scale-105 active:scale-95 transition-transform"
        aria-label={gettext("Open brain copilot")}
      >
        <.icon name={if @open, do: "hero-chevron-down", else: "hero-chat-bubble-left-right"} class="size-5" />
      </button>
    </div>
    """
  end

  @impl true
  def handle_event("toggle", _, socket), do: {:noreply, assign(socket, :open, !socket.assigns.open)}

  def handle_event("clear", _, socket) do
    Server.clear(socket.assigns.chat_pid)
    {:noreply, assign(socket, :messages, [])}
  end

  def handle_event("send", %{"message" => text}, socket) when text != "" do
    socket = assign(socket, loading: true, input: "")
    pid = socket.assigns.chat_pid

    # optimistic user message
    user_msg = %{"role" => "user", "content" => text}
    socket = assign(socket, :messages, socket.assigns.messages ++ [user_msg])

    # async LLM call
    widget = self()
    Task.start(fn ->
      {:ok, reply, sources} = Server.send_message(pid, text)
      send_update(widget, __MODULE__, id: socket.assigns.id, reply: reply, sources: sources)
    end)

    {:noreply, socket}
  end

  @impl true
  def update(%{reply: reply, sources: sources}, socket) do
    assistant_msg = %{"role" => "assistant", "content" => reply, "sources" => sources}
    {:ok, assign(socket, loading: false, messages: socket.assigns.messages ++ [assistant_msg])}
  end
end
```

Y en `layouts.ex`, junto a CommandPalette:

```elixir
<.live_component
  module={DranWeb.ChatWidget}
  id="chat-widget"
  context_slug={@context_slug}
  current_user={@current_user}
/>
```

Nota: el `ScrollBottom` hook es un hook JS mínimo que scrollea al último mensaje — va en `app.js` (5 líneas). Alternativa sin hook: `phx-mounted` + `JS.dispatch` — pero el hook es más limpio.

**Step 5: Commit**
```bash
git commit -m "feat: floating brain copilot chat widget"
```

---

### Task 12.4: Contexto de página activa en el chat

**Objective:** El chat sabe en qué página estás y puede referenciarla: "esta página", "resúmela", "relaciónala con X".

**Files:**
- Modify: `lib/dran_web/components/chat_widget.ex`
- Modify: `lib/dran/chat/brain.ex`
- Test

**Step 1: Test** — en `/notes/mi-nota`, preguntar "resume esta página" usa el contenido de `mi-nota` sin buscar.

**Step 3: Implementación**

- El widget recibe `page_slug` opcional del layout/LiveView: `<.live_component ... page_slug={assigns[:page_slug]} />`. Los LiveViews de detalle (`NoteLive :show`, etc.) lo pasan via `assign(socket, :page_slug, slug)` en mount.
- `ChatBrain.answer/4` acepta `opts[:current_page]`:

```elixir
def answer(context_id, question, history, opts \\ []) do
  current_page = if slug = opts[:current_page], do: Brain.get_page_by_slug(slug, context_id)

  # if question references "esta página" / "this page" and we have current_page, skip search
  if references_current_page?(question) and current_page do
    chat_with_pages(question, [current_page], history)
  else
    # normal search flow
  end
end

defp references_current_page?(question) do
  q = String.downcase(question)
  String.contains?(q, ["esta página", "esta nota", "este concepto", "this page", "aquí", "esto"])
end
```

- El header del widget muestra la página activa: `Chatting about: mi-nota` cuando `page_slug` está presente.

**Step 5: Commit**
```bash
git commit -m "feat: chat aware of current page context"
```

---

### Task 12.5: Mejora del context selector

**Objective:** El selector de contexto en el sidebar es más usable: muestra conteo de páginas por contexto, último contexto usado persiste entre sesiones, y atajo de teclado para cambiar.

**Files:**
- Modify: `lib/dran_web/components/layouts.ex` (context_selector)
- Modify: `lib/dran_web/controllers/session_controller.ex` (persistir contexto en cookie además de sesión)
- Modify: `assets/js/app.js` (atajo `⌘⇧C` para ciclar contextos)
- Test

**Step 1: Test** — al cambiar de contexto, la cookie `dran_last_context` se guarda; al hacer login, se restaura.

**Step 3: Implementación**

- `context_selector` muestra `Personal (142)` con el conteo por contexto (query ligera: `select context_id, count(*) from pages group by context_id`).
- `SessionController.put_context/2` guarda además una cookie firmada `dran_last_context` con `max_age: 30 días`.
- `Auth.assign_to_socket/2` lee la cookie si la sesión no tiene `context_slug`.
- En `app.js`, keybinding `Cmd/Ctrl+Shift+C` emite `phx-click` al selector (o abre un mini-dropdown de contextos). Alternativa más simple: los items del dropdown ya son links — el atajo solo abre el dropdown (focus + click via JS).

**Step 5: Commit**
```bash
git commit -m "feat: improved context selector with counts and persistence"
```

---

### Task 12.6: Sugerencias de chat según la vista actual

**Objective:** El chat sugiere preguntas relevantes según dónde estás: en el dashboard sugiere "¿qué hice esta semana?", en un goal "¿qué todos faltan?", en una nota "¿a qué se relaciona esto?".

**Files:**
- Modify: `lib/dran_web/components/chat_widget.ex`
- Test

**Step 1: Test** — en dashboard, las sugerencias incluyen "weekly summary"; en una página goal, incluyen "todos pendientes".

**Step 3: Implementación** — el widget recibe `view_type` y `page_type` assigns; con mensajes vacíos, muestra chips clickeables:

```elixir
defp suggestions_for(assigns) do
  cond do
    assigns[:page_type] == "goal" ->
      ["¿Qué todos faltan de este goal?", "Resume el estado de este goal", "¿Qué bloquea este goal?"]

    assigns[:page_type] == "note" ->
      ["Resume esta nota", "¿A qué otras páginas se relaciona?", "Convierte esta nota en concepto"]

    assigns[:view_type] == "dashboard" ->
      ["¿Qué capturé esta semana?", "¿Qué goals están en rojo?", "¿Qué páginas están huérfanas?"]

    true ->
      ["¿Qué sé de...?", "¿Qué hice esta semana?", "Busca páginas sobre..."]
  end
end
```

Click en un chip = enviar el mensaje directamente.

**Step 5: Commit**
```bash
git commit -m "feat: contextual chat suggestions"
```

---

## Fase 10 — Limpieza, optimización y validación

Fase de endurecimiento antes de cerrar: quitar deuda, encontrar bugs silenciosos, validar que todo el sistema queda consistente.

### Task 10.1: Limpieza de código muerto y duplicados

**Objective:** Eliminar código sin uso tras los refactors de fases anteriores.

**Files:**
- Todo `lib/dran/`

**Checklist:**

- [ ] `Brain.slugify_title/1` e `Ingest.Utils.slugify/1` — si tras Task 0.2 solo delegan a `Dran.Slug`, eliminar las funciones privadas viejas y dejar la llamada directa.
- [ ] `Brain.auto_relate/2` — tras Task 3.4 (unificación), verificar que no queden dos implementaciones divergentes. Si `auto_relate` solo es llamada por `PageAugmenter`, considerar hacerla privada o deprecarla.
- [ ] `Summaries.summarize_page/1` y `suggest_tags/1` — wrappers que llaman a `augment_page/1` completo (3x costo de inferencia si solo necesitas uno). Verificar si algo los usa (`search_files`); si no, eliminar o marcar `@deprecated`.
- [ ] `Engine.parse_response/1` + `extract_json/1` (fallback de JSON en content) — si el modelo siempre devuelve tool_calls nativos, este camino es código muerto. Verificar con logs de sesiones reales; si nunca se usa, eliminar.
- [ ] `Dran.Rerank` — verificar que `use_rerank?()` default `false` significa que nunca corre. Decidir: o se activa por default, o se documenta que es opt-in en Settings (Fase 9). No dejar código zombie.
- [ ] Warnings de compilación: `mix compile --warnings-as-errors` limpio.
- [ ] Deps sin uso: `mix deps.unlock --check-unused` (ya corre en precommit).

**Step 5: Commit**
```bash
git commit -m "chore: remove dead code and consolidate duplicates"
```

---

### Task 10.2: Auditoría de bugs — edge cases de dominio

**Objective:** Revisar y cubrir con tests los edge cases que las fases anteriores pudieron abrir.

**Files:**
- Test: `test/dran/brain_test.exs`, `test/dran/agent/engine_test.exs`

**Casos a verificar y testear:**

- [ ] `create_page` con body que solo tiene `![[embed]]` y nada más — ¿el título derivado queda como `![[embed]]`? Debería ignorar líneas de embed al derivar título.
- [ ] `reresolve_embeds` cuando el body queda vacío — todas las relaciones embeds se borran, sin error.
- [ ] `rename_slug` a slug que difiere solo en mayúsculas (`My-Page` → `my-page`) — debe funcionar y no chocar con el unique constraint.
- [ ] `rename_slug` de página que es target de relaciones `semantic` — las relaciones sobreviven (usan IDs, no slugs — verificar).
- [ ] Agente cancelado a la mitad de un step con `create_page` en vuelo — la página puede quedar creada pero la sesión `cancelled`. Verificar que `pages_created` queda consistente con las páginas reales (query por `meta.agent_session_id`).
- [ ] `Engine.cancel/1` con session_id inexistente — devuelve `{:error, :not_found}` (ya cubierto, verificar test).
- [ ] `PageAugmenter` con página que cambió mientras augmentaba — `Repo.get` al inicio mitiga, pero si el body cambia entre `ensure_embedding` y `find_semantic_neighbors`, el texto embebido puede quedar desfasado. Aceptable, documentar.
- [ ] `Brain.stats/1` en contexto con 0 páginas — no truena (división por cero, nil group_by).
- [ ] Embeds con slug que no existe — `resolve_embeds` devuelve en `not_found`, no crea relación rota.

Cada caso que falle → fix + test. Cada caso que pase → test que lo congela.

**Step 5: Commit**
```bash
git commit -m "test: cover domain edge cases from embeds/rename/agents"
```

---

### Task 10.3: Optimización — queries y N+1 restantes

**Objective:** Perfilado de las queries más calientes y fix de N+1 restantes.

**Checklist:**

- [ ] `Brain.list_relations_for_page/1` — 2 queries con preload completo de pages (aunque `trim_preloaded_pages` vacía el body después, ya se trajo de la DB). Cambiar a query con `select` ligero desde el origen: id, title, slug, page_type — sin body.
- [ ] `Brain.stats/1` — carga 10k páginas en memoria para contar por tipo. Reescribir con `group_by` en SQL:
  ```elixir
  by_type = Repo.all(from p in Page, where: p.context_id == ^context_id, group_by: p.page_type, select: {p.page_type, count(p.id)})
  ```
  Igual para `todos_by_status` con `fragment("?->>'kanban_status'")`.
- [ ] `graph_data/1` — ya es ligero, verificar índices en `relations(source_id)` y `relations(target_id)` existen (revisar migración 003).
- [ ] `orphan_pages/1` — el subquery `not in` puede ser lento en tablas grandes; reescribir con `left_join` + `where is_nil`.
- [ ] Verificar índice en `pages(context_id, updated_at)` para `list_pages` ordenado.
- [ ] `Summaries.augment_prompt` — tras Task 2.4 usa pgvector, verificar que el índice HNSW/IVFFlat de embeddings existe (revisar migración `add_embedding_to_pages`).

**Criterio:** medir antes y después con `:timer.tc` en `iex` sobre la DB dev (o con datos seed generados masivamente). Solo optimizar lo que muestre mejora real >30%.

**Step 5: Commit**
```bash
git commit -m "perf: eliminate remaining N+1 queries and add missing indexes"
```

---

### Task 10.4: Validación end-to-end del flujo completo

**Objective:** Prueba de humo integral que ejercita el pipeline entero: crear → embed → relacionar → renombrar → buscar → exportar.

**Files:**
- Create: `test/dran/integration_test.exs`

**Test de integración (happy path):**

```elixir
test "full pipeline: create → embed → relate → rename → search → export" do
  ctx = create_context()

  # create pages with embeds
  {:ok, artifact} = Brain.create_page(%{context_id: ctx.id, title: "Doc", slug: "doc", page_type: "artifact", body: "contenido"})
  {:ok, note} = Brain.create_page(%{context_id: ctx.id, title: "Nota", slug: "nota", page_type: "note", body: "Ver ![[doc]]"})

  # embeds relation exists
  assert_embeds_relation(note, artifact)

  # rename propagates
  {:ok, _} = Brain.rename_slug(artifact, "doc-renombrado")
  assert Brain.get_page!(note.id).body =~ "![[doc-renombrado]]"

  # search finds renamed page
  {:ok, results} = Brain.search("contenido", context_id: ctx.id)
  assert Enum.any?(results, &(&1.slug == "doc-renombrado"))

  # export includes everything
  export = Dran.Exporter.full_export(ctx.id)
  assert length(export.pages) == 2
  assert length(export.relations) >= 1
end
```

Más chequeos manuales (documentados en el test como comentarios para QA manual):

- [ ] `mix precommit` verde completo.
- [ ] Levantar dev server y recorrer: dashboard → crear nota con embed → ver grafo → renombrar → ver activity feed → exportar.
- [ ] Correr cada agente una vez desde la UI de `/agents`.
- [ ] Verificar logs: ningún `PageAugmenter failed` ni `Engine: step crashed` sin causa raíz.

**Step 5: Commit**
```bash
git commit -m "test: end-to-end integration smoke test"
```

---

## Fase 11 — Métricas en el home

### Task 11.1: Métricas extendidas en dominio (Brain.metrics)

**Objective:** Función de dominio que agrega las métricas del dashboard en una sola pasada — crecimiento semanal, salud del brain, actividad de agentes.

**Files:**
- Modify: `lib/dran/brain.ex` (agregar `metrics/1`)
- Test: `test/dran/brain_test.exs`

**Step 1: Test fallido**

```elixir
test "metrics returns growth, health and agent stats" do
  m = Brain.metrics(ctx.id)
  assert m.pages_this_week >= 0
  assert m.pages_last_week >= 0
  assert m.embedding_coverage <= 1.0
  assert is_map(m.relations_by_type)
  assert is_map(m.agents)
end
```

**Step 3: Implementación**

```elixir
def metrics(context_id) do
  now = DateTime.utc_now()
  week_ago = DateTime.add(now, -7 * 86400, :second)
  two_weeks_ago = DateTime.add(now, -14 * 86400, :second)

  %{
    pages_this_week: count_pages_since(context_id, week_ago),
    pages_last_week: count_pages_since(context_id, two_weeks_ago) - count_pages_since(context_id, week_ago),
    embedding_coverage: embedding_coverage(context_id),
    relations_by_type: relations_by_type(context_id),
    contested_count: length(contested_pages(context_id)),
    agents: agent_metrics(context_id)
  }
end

defp embedding_coverage(context_id) do
  total = Repo.aggregate(from(p in Page, where: p.context_id == ^context_id), :count)
  embedded = Repo.aggregate(from(p in Page, where: p.context_id == ^context_id and not is_nil(p.embedding)), :count)
  if total == 0, do: 0.0, else: embedded / total
end

defp relations_by_type(context_id) do
  Repo.all(
    from r in Relation,
      join: p in assoc(r, :source),
      where: p.context_id == ^context_id,
      group_by: r.relation_type,
      select: {r.relation_type, count(r.id)}
  ) |> Map.new()
end

defp agent_metrics(context_id) do
  week_ago = DateTime.add(DateTime.utc_now(), -7 * 86400, :second)

  %{
    sessions_this_week:
      Repo.aggregate(
        from(s in Dran.Agent.Session, where: s.context_id == ^context_id and s.inserted_at > ^week_ago),
        :count
      ),
    tokens_this_week:
      Repo.one(
        from s in Dran.Agent.Session,
          where: s.context_id == ^context_id and s.inserted_at > ^week_ago,
          select: coalesce(sum(fragment("coalesce((?->>'tokens_used')::int, 0)", s.meta)), 0)
      ),
    pages_created_by_agents:
      Repo.aggregate(
        from(s in Dran.Agent.Session, where: s.context_id == ^context_id),
        :count
      )
  }
end
```

**Step 5: Commit**
```bash
git commit -m "feat: extended brain metrics in domain"
```

---

### Task 11.2: Dashboard con métricas nuevas

**Objective:** El home muestra las métricas de 11.1: crecimiento semanal con delta, cobertura de embeddings, relaciones por tipo, actividad de agentes.

**Files:**
- Modify: `lib/dran_web/live/dashboard_live.ex` (ya tiene `metric_card` — agregar sección nueva)
- Test: `test/dran_web/live/dashboard_live_test.exs` (crear si no existe)

**Step 1: Test** — el dashboard renderiza los nuevos bloques con valores del contexto.

**Step 3: Implementación** — debajo de las metric cards actuales, una sección "Brain health":

- **Card "This week"** — páginas creadas esta semana con delta vs semana pasada (`+5` verde / `-2` gris).
- **Card "Embedding coverage"** — porcentaje con progress bar; warning si < 90%.
- **Card "Relations"** — breakdown mini por tipo: `semantic: N · related: N · embeds: N`.
- **Card "Agents"** — sesiones esta semana + tokens consumidos.
- **Daily note CTA** — si la daily note de hoy no existe o está vacía, botón "Open today's note" (usa `ensure_daily_note` de Task 8.3).

Reutilizar el componente `metric_card` existente; el delta y el progress bar son variantes nuevas en el mismo archivo. i18n con `gettext` para todos los labels (el proyecto ya tiene es/en).

**Step 5: Commit**
```bash
git commit -m "feat: brain health metrics on dashboard"
```

---

## Fase 5 — SKILL.md y README (al final, cuando todo jale)

### Task 5.1: Sincronizar SKILL.md con comportamiento real

**Objective:** Corregir afirmaciones falsas y agregar todo lo implementado en las fases 0-9.

**Files:**
- Modify: `SKILL.md`

**Cambios concretos:**

1. Sección MCP API → Tools: agregar filas `reaugment_page`, `cancel_agent` (si se implementa en 4.x), y los nuevos agent types en `start_agent`: `ask`, `curator`, `link_gardener`, `weekly_review`.
2. Sección "Creating Pages": el punto sobre auto-augmentation incluye *"resolves `![[slug]]` embeds into `embeds` relations (and cleans stale ones on update)"*.
3. Tabla "Editing, Renaming & Deleting": fila `rename_slug` → *"Existing `![[old-slug]]` embeds in other pages are rewritten automatically."*
4. Sección "Autonomous Agents": reescribir completa —
   - Tabla de los 6 agentes: `research`, `ingest`, `ask`, `curator`, `link_gardener`, `weekly_review` con qué hace cada uno.
   - Límites: research (`max_sources=10`, `max_search_queries=10`, `max_pages=10` — configurables vía Settings).
   - Sesiones fallidas se marcan `failed` (no se quedan colgadas).
   - `meta.tokens_used` para tracking de costo.
5. Sección "Common Mistakes": quitar la nota de rename_slug (ya no aplica).
6. Nueva sección "Ingest with extraction": MarkItDown (PDF/DOCX/PPTX), Vision (imágenes), ASR (audio) — `ingest_url` ahora extrae contenido cuando inference está configurado.
7. Nueva sección "Scheduled agents": curator diario 6am, weekly review domingos 8am (Quantum).
8. Bump `version: 2.3.0` → `3.0.0`.

**Step 5: Commit**
```bash
git commit -m "docs: sync SKILL.md with all platform improvements"
```

---

### Task 5.2: Actualizar README.md

**Objective:** El README refleja el estado real del proyecto: 6 agentes, extracción en ingest, scheduler, settings, features nuevas.

**Files:**
- Modify: `README.md`

**Cambios concretos:**

1. **Features** — agregar:
   - Autonomous agents (6): research, ingest, ask (Q&A), curator, link gardener, weekly review
   - Content extraction on ingest: PDF/DOCX → markdown (MarkItDown), image description (Vision), audio transcription (ASR)
   - Auto-resolved embeds (`![[slug]]`) with stale cleanup
   - Bidirectional semantic relations with dynamic thresholds
   - Version history with diff
   - Activity feed
   - Daily notes
   - Full context export (backups)
   - Runtime settings (no redeploy to tune brain)
2. **Stack** — agregar Quantum (scheduler).
3. **Environment variables** — verificar que estén todas las actuales (las del SKILL.md §4 sirven de checklist).
4. **MCP section** — link a SKILL.md, lista de tools actualizada (19+).
5. Screenshots/sección de UI si el README los tiene — actualizar menciones a graph 3D y activity feed.

**Step 5: Commit**
```bash
git commit -m "docs: update README with agents, extraction, settings features"
```

---

## Tests / Validation global

- Cada task corre su test objetivo: `mix test <file>` verde antes de commit.
- Al final de cada fase: `mix precommit` completo (compile warnings-as-errors + format + test).
- Fase 2 y 3 tocan el pipeline de augmentación: correr manualmente en dev con inference configurada:
  ```bash
  PORT=4001 mix phx.server
  # crear página con ![[embed]] desde la UI, verificar en psql:
  # select * from relations where relation_type = 'embeds';
  ```
- Verificación del grafo: abrir `/graph` en dev y confirmar que las aristas semánticas aparecen bidireccionales y con weight.
- Fase 6 (agentes nuevos): correr cada agente desde MCP manualmente y revisar la sesión en `/agents/<type>/<session_id>`.
- Fase 7: ingestar un PDF real en dev y verificar que el body tiene el markdown extraído.
- Fase 6.5 (scheduler): verificar en `mix phx.server` logs que Quantum arranca; no esperar al cron — probar `Dran.Agent.Curator.run_scheduled()` en `iex -S mix`.

## Riesgos y tradeoffs

- **Bidireccionalidad semántica (3.2):** duplica el número de aristas `semantic`. En contextos grandes el grafo se densifica — mitigación: el graph view puede filtrar por tipo; además el weight permite podar visualmente.
- **Propagación de rename (2.3):** reescribe bodies dentro de una transacción — si hay cientos de páginas con el embed puede tardar. Aceptable para un second brain personal; se loguea al log de brain cada update.
- **Umbral dinámico (3.1):** los valores 0.15/0.22/0.28 son heurísticos. Quedan editables en runtime vía Settings (Fase 9) — el riesgo desaparece.
- **Re-augment (4.2):** limpiar `embedding_hash` fuerza re-embedding — costo de una llamada a inferencia por página. Documentado en la description del tool.
- **Curator flagging contested (6.2):** el LLM decide qué es duplicado real vs contenido distinto — puede equivocarse. Mitigación: el flag `kb_contested` es reversible y el curator crea una nota explicando cada decisión.
- **Quantum en single-node:** el scheduler corre en el nodo único de producción — si el servidor reinicia a las 6am, el job del curator se pierde ese día. Aceptable; Quantum con `:global` es overkill para single-node.
- **MarkItDown en archivos grandes:** el límite de descarga es 100MB — un PDF de 50MB en base64 al modelo puede exceder límites del payload. Mitigación: skip conversión si el archivo supera ~10MB (verificar límite real del endpoint de inference antes de implementar).
- **Settings sin cache:** cada `Dran.Settings.get/1` es un query. A mitigar solo si se vuelve hot path (el augmenter corre async, no es crítico); si hace falta, un ETS con invalidación en `put/2` — YAGNI por ahora.
- **Pregunta abierta:** ¿queremos que `update_page` también re-resuelva inline_links (wiki-style `[[...]]`) si algún día se soportan? Hoy no existen; YAGNI.

## Orden sugerido de ejecución

1. **Fase 0** (fundamentos) — sin ella los demás tests de slugs fallan.
2. **Fase 2** (embeds) — el hoyo funcional más visible.
3. **Fase 3** (relaciones) — depende de 0, convive con 2.
4. **Fase 1** (agentes resilientes) — independiente; paralelizable con 2/3 en archivos disjuntos. **Debe ir antes de Fase 6** (los nuevos agentes heredan crash recovery, límites y tracking).
5. **Fase 4** (MCP) — depende de 2.3 y 3.
6. **Fase 6** (nuevos agentes) — depende de 1 (engine robusto). Tasks 6.1-6.4 paralelizables (archivos nuevos disjuntos); 6.5 al final.
7. **Fase 7** (ingest real) — depende solo de 0; paralelizable con 4/6.
8. **Fase 8** (profesional) — independiente; paralelizable.
9. **Fase 9** (customización) — depende de 3.1 (umbrales) y 8.3 (daily note).
10. **Fase 12** (chat flotante + contexto) — depende de 6.1 (ChatBrain reutiliza el patrón Q&A). Tasks 12.1-12.3 secuenciales; 12.4-12.6 paralelizables.
11. **Fase 10** (limpieza, optimización, validación) — **al final de todo el código**, cuando todas las features están implementadas.
12. **Fase 11** (métricas en el home) — depende de 10.3 (queries optimizadas) para no perfilar dos veces.
13. **Fase 5** (SKILL.md + README) — **última**, documenta todo lo implementado.
