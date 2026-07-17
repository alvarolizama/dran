# Dran Platform Improvement Plan v2 (Validated)

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Audit completo de la plataforma Dran — bugs, performance, funcionalidad y SKILL.md — con plan accionable para cada hallazgo.

**Architecture:** Phoenix 1.8 single-app (no umbrella). PostgreSQL con pg_trgm + pgvector + unaccent. Second brain multi-contexto con 10 page-types, FTS + semantic search (embeddings 1024d HNSW), agentes autónomos (research/ingest), MCP server (JSON-RPC), API REST completa. Frontend LiveView + Tailwind v4.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView, Ecto, Req, MDEx, pgvector, Tailwind CSS v4, Firecrawl, custom GenServer inference queue (permit serializer, no job persistence)

---

## Current State (verified 2026-07-16)

- **Compilación:** `mix compile` limpio (97 archivos, 0 errores, 0 warnings)
- **Tests:** 51 tests pasan (16 archivos de test)
- **Migraciones:** 11 migraciones (DB schema estable)
- **Archivos .ex/.heex:** ~60 archivos en `lib/`
- **Línea base:** git main @ 29b27d0, working tree clean
- **Deps:** Phoenix 1.8.8, LiveView 1.2, MDEx 0.13.1, pgvector 0.3, Req 0.5

---

## Validation Corrections vs Original Plan

| Task original | Corrección |
|---|---|
| Task 2 (XSS) | `ts_headline` **no** escapa HTML por defecto. La solución no es quitar `raw()` (eso rompería el `<b>` de headline), sino **sanitizar el HTML permitiendo solo tags seguros** (`<b>`, `<mark>`) |
| Task 3 (crash nil context) | El fallback existe pero **nunca se alcanza** — el match de la línea 116 falla con `CaseClauseError` si `context` es nil. Hay que reestructurar las cláusulas |
| Task 8 (paginación) | `list_pages` es API pública. Añadir `limit`/`offset` opcionales **sin romper** la firma existente |
| Task 9 (ETS cache) | **Eliminado** — cache key no incluye `inline_links`/`embeds`, riesgo de stale data, y `render_markdown` se usa en componentes stateless. Reemplazado por **pre-computación en mount** (asignar `rendered_body` en LiveView) |
| Task 11 (slug utils) | Hay **6 copias**, no 3: `page_edit`, `page_new_live`, `todo_live`, `summaries.ex`, `ingest/utils.ex`, `ingest_live.ex`, `context_live.ex` (7 total) |
| Task 20 (queue persistence) | **Reformulado** — el queue es un **permit serializer**, no una cola de trabajos. No hay jobs que persistir. Se elimina Oban. En su lugar: añadir `Task 20: circuit breaker / timeout handling` para evitar que un inference server caído bloquee indefinidamente |
| Task 14-15 | Se renumeran como 14A (meta accessors) y 14B (format_due/due_date_class) para evitar colisión con Task 14 (búsqueda híbrida) |

---

## PHASE 1: Bug Fixes (Critical) — Subagent Batch 1

### Task 1: Eliminar módulo dead `DranWeb.PageDetailComponent`

**Objective:** Remover código muerto que confunde a futuros desarrolladores.

**Files:**
- Delete: `lib/dran_web/live/page_detail_component.ex`

**Verification:**
```bash
grep -r "PageDetailComponent" lib/ --include="*.ex" --include="*.heex"
# Expected: solo el archivo mismo
```

**Steps:**
1. `rm lib/dran_web/live/page_detail_component.ex`
2. `mix compile --warnings-as-errors` → PASS
3. Commit: `refactor: remove dead PageDetailComponent module`

---

### Task 2: Fix XSS risk en `search_live.ex` — sanitizar excerpt

**Objective:** Eliminar riesgo de XSS manteniendo el highlight de `ts_headline`.

**Files:**
- Modify: `lib/dran_web/live/search_live.ex:93`
- Create: `lib/dran_web/html_sanitizer.ex`

**Contexto real:**
`ts_headline('spanish', ..., 'MaxWords=35, MinWords=15')` **no** escapa HTML por defecto. Usa `StartSel=<b>` y `StopSel=</b>`. Si el body contiene `<script>alert(1)</script>`, el excerpt incluirá `<b>alert(1)</b>` sin escapar. El `raw()` actual es un XSS real.

**Solución:**
Crear `DranWeb.HTMLSanitizer` con `sanitize_excerpt/1` que:
1. Permita solo tags: `b`, `strong`, `i`, `em`, `mark`
2. Escape todo lo demás
3. Devuelva `{:safe, html}` o `Phoenix.HTML.raw`

**Implementation:**
```elixir
# En search_live.ex, línea 93:
# Cambiar:
{raw(result.excerpt)}
# Por:
{sanitize_excerpt(result.excerpt)}
```

Con import de `DranWeb.HTMLSanitizer` en el LiveView.

**Verification:**
```bash
mix test test/dran_web/api/search_controller_test.exs
mix compile --warnings-as-errors
```

**Commit:** `fix(security): sanitize search excerpts to prevent XSS while preserving ts_headline highlights`

---

### Task 3: Fix pattern match crash en `PageEdit.handle_event("field_change", ...)`

**Objective:** Prevenir `CaseClauseError` cuando `context` es nil.

**Files:**
- Modify: `lib/dran_web/page_edit.ex:116-149`

**Contexto real:**
El match `%{assigns: %{page: %Page{} = page, context: %{id: context_id}}}` falla si `context` es nil. El fallback en línea 147 (`def handle_event("field_change", _params, socket)`) **nunca se alcanza** porque la cláusula de arriba es más específica y falla el match en los assigns, no en los params.

**Solución:**
Reestructurar las cláusulas para que el match de assigns sea menos restrictivo y el fallback sí funcione:

```elixir
# Línea 116-120: cambiar el match para no exigir context
def handle_event(
      "field_change",
      %{"page" => %{"slug" => new_slug}},
      %{assigns: %{page: %Page{} = page}} = socket
    ) do
  context_id = context_id(socket)

  if is_nil(context_id) do
    {:noreply, put_flash(socket, :error, "No context available for slug rename.")}
  else
    # ... resto del body existente (líneas 121-144)
  end
end
```

Nota: `context_id/1` ya existe en `page_edit.ex:304-309` y maneja nil correctamente.

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `fix: handle nil context in field_change slug rename without crashing`

---

### Task 4: Fix `agent_live.ex` — `ingest` ignora el parámetro `lang`

**Objective:** El selector de idioma solo debe aparecer para research.

**Files:**
- Modify: `lib/dran_web/live/agent_live.ex:67-85`

**Solución:**
En el render, envolver el `<select>` de idioma con `<%= if @type == "research" do %>`.

Además, en `handle_event("start", ...)` (línea 457), extraer `lang` solo cuando el tipo sea research:
```elixir
lang = if type == "research", do: params["agent"]["lang"] || "es", else: nil
```

Y pasar `lang: lang` a `start_agent` solo para research (el `start_agent("ingest", ...)` ya ignora `_opts`).

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `fix: hide language selector for ingest agent and only pass lang to research`

---

### Task 5: Fix inline `onclick` en `dashboard_live.ex` (viola AGENTS.md)

**Objective:** Eliminar JS inline.

**Files:**
- Modify: `lib/dran_web/live/dashboard_live.ex:194-217`

**Solución:**
Reemplazar el `<div onclick={...}>` con `<.link navigate={page_path(page)}>` manteniendo las mismas clases y contenido.

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `fix: replace inline onclick with .link in dashboard recent pages`

---

## PHASE 2: Performance — Subagent Batch 2

### Task 6: Batch tag lookups — eliminar N+1 en `tag_page_exists?/2` y `tag_link_path/2`

**Objective:** Eliminar N+1 queries al renderizar tags.

**Files:**
- Modify: `lib/dran_web/components/page_components.ex:357-373`
- Modify: `lib/dran/brain.ex` (añadir `get_pages_by_slugs/2`)

**Solución:**

En `brain.ex`, añadir después de `get_page_by_slug/2`:
```elixir
def get_pages_by_slugs(slugs, context_id) when is_list(slugs) and is_binary(context_id) do
  slugs = Enum.uniq(slugs)

  Repo.all(
    from p in Page,
      where: p.context_id == ^context_id and p.slug in ^slugs,
      select: {p.slug, p.page_type}
  )
  |> Map.new()
end
```

En `page_components.ex`, modificar `page_detail/1` para pre-cargar tags:
```elixir
# Antes del ~H, en page_detail:
tag_slugs = assigns.page.tags || []
tag_map = if tag_slugs != [], do: Brain.get_pages_by_slugs(tag_slugs, assigns.page.context_id), else: %{}
assigns = assign(assigns, :tag_map, tag_map)
```

Luego modificar las funciones de tag para usar el mapa:
```elixir
# tag_page_exists?(tag, context_id) → Map.has_key?(@tag_map, tag)
# tag_link_path(tag, context_id) → usar tag_map para construir path
```

**Verification:**
```bash
mix test
```

**Commit:** `perf: batch tag lookups to eliminate N+1 in page detail`

---

### Task 7: Batch embeds e inline_links en `render_markdown`

**Objective:** Eliminar N+1 queries en renderizado de markdown.

**Files:**
- Modify: `lib/dran_web/components/page_components.ex:491-520`
- Modify: `lib/dran/brain.ex` (ya tiene `get_pages_by_slugs/2` de Task 6)

**Solución:**
En `apply_inline_links/3`, reemplazar el reduce con `get_page_by_slug` por una sola llamada a `get_pages_by_slugs`:

```elixir
defp apply_inline_links(html, links, context_id) when is_list(links) and links != [] do
  slugs = links |> Enum.map(& &1["slug"]) |> Enum.uniq()
  slug_to_type = if context_id, do: Brain.get_pages_by_slugs(slugs, context_id), else: %{}

  slug_to_path = Map.new(slug_to_type, fn {slug, type} ->
    {slug, "/#{Map.get(@type_routes, type, "notes")}/#{slug}"}
  end)

  Enum.reduce(links, html, fn link, acc ->
    case link do
      %{"text" => text, "slug" => slug} when is_binary(text) and is_binary(slug) ->
        path = Map.get(slug_to_path, slug, "/#{slug}")
        insert_link(acc, text, path)
      _ -> acc
    end
  end)
end
```

**Verification:**
```bash
mix test
```

**Commit:** `perf: batch inline_links resolution in render_markdown`

---

### Task 8: Añadir `limit`/`offset` opcionales a `list_pages` (sin romper API)

**Objective:** Permitir paginación sin romper la firma pública.

**Files:**
- Modify: `lib/dran/brain.ex:85-100`

**Contexto:**
`list_pages(opts)` actualmente hace `Repo.all` sin límite. Se usa en:
- Dashboard stats (top 5 por tipo)
- Page lists (todas las páginas de un tipo)
- API REST

**Solución:**
Añadir opciones `:limit` y `:offset` opcionales, manteniendo backward compatibility:

```elixir
def list_pages(opts) do
  context_id = Keyword.get(opts, :context_id)
  type = Keyword.get(opts, :type)
  limit = Keyword.get(opts, :limit)
  offset = Keyword.get(opts, :offset, 0)

  query =
    from p in Page,
      where: p.context_id == ^context_id and p.page_type == ^type,
      order_by: [desc: p.updated_at]

  query = if limit, do: from(p in query, limit: ^limit, offset: ^offset), else: query

  Repo.all(query)
end
```

**No modificar** los LiveViews en este task — solo añadir la capacidad. La paginación UI es un feature separado.

**Verification:**
```bash
mix test
```

**Commit:** `feat: add optional limit/offset to Brain.list_pages for future pagination`

---

### Task 9: Pre-computar `rendered_body` en LiveViews de página (reemplaza ETS cache)

**Objective:** Evitar re-parsing markdown en cada render de LiveView sin cache global.

**Files:**
- Modify: `lib/dran_web/live/note_live.ex` (y los otros 9 page-type LiveViews)
- Modify: `lib/dran_web/components/page_components.ex` (opcional: `render_markdown` sigue disponible para casos dinámicos)

**Contexto:**
`render_markdown/2` se ejecuta en cada render del componente `page_detail`. El body solo cambia cuando el usuario edita. En vez de un cache ETS global (con riesgo de stale data), pre-computar el HTML en el mount/handle_params del LiveView y asignarlo como `rendered_body`.

**Solución (patrón para cada page LiveView):**
```elixir
# En mount o handle_params, después de cargar la página:
rendered = render_markdown(page.body, context_id: page.context_id, inline_links: page.inline_links)
assign(socket, page: page, rendered_body: rendered)
```

Y en el template, usar `{@rendered_body}` en lugar de llamar a `render_markdown` dentro del componente.

**Nota:** `page_detail` recibe `page` como attr, así que el LiveView padre debe pasar `rendered_body` como attr adicional o el componente debe aceptar un slot/attr para HTML pre-renderizado.

**Verification:**
```bash
mix test
```

**Commit:** `perf: pre-compute rendered markdown in page LiveViews to avoid re-parsing on every render`

---

### Task 10: Debounce `refresh_steps` en `agent_live.ex`

**Objective:** Evitar queries de DB en cada mensaje PubSub de step.

**Files:**
- Modify: `lib/dran_web/live/agent_live.ex`

**Solución:**
En `handle_agent_message/2`, para `{:step_completed, ...}`, programar un refresh en 200ms si no hay uno ya programado:

```elixir
defp handle_agent_message(socket, {:step_completed, _step, _result}) do
  if socket.assigns[:steps_refresh_timer] do
    Process.cancel_timer(socket.assigns.steps_refresh_timer)
  end

  timer = Process.send_after(self(), :refresh_steps, 200)
  assign(socket, steps_refresh_timer: timer)
end

def handle_info(:refresh_steps, socket) do
  {:noreply, refresh_steps(socket) |> assign(steps_refresh_timer: nil)}
end
```

También limpiar el timer en `terminate/2` si existe.

**Verification:**
```bash
mix test
```

**Commit:** `perf: debounce agent step refresh to avoid DB query spam`

---

## PHASE 3: Code Quality / DRY — Subagent Batch 3

### Task 11: Extraer `slugify`/`unique_slug`/`ensure_unique_slug` a `Dran.Slug`

**Objective:** Eliminar 6+ copias duplicadas.

**Files:**
- Create: `lib/dran/slug.ex`
- Modify: `lib/dran_web/page_edit.ex`, `lib/dran_web/live/page_new_live.ex`, `lib/dran_web/live/todo_live.ex`
- **También:** `lib/dran/summaries.ex`, `lib/dran/agent/ingest/utils.ex`, `lib/dran_web/live/ingest_live.ex`, `lib/dran_web/live/context_live.ex` (estas tienen `slugify` duplicado, no necesitan `unique_slug`)

**Implementation:**
```elixir
defmodule Dran.Slug do
  @moduledoc "Shared slug generation and uniqueness checking."

  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
  end

  def slugify(_), do: ""

  def generate(title, context_id, fallback_type) do
    base = slugify(title)
    base = if base == "", do: fallback_type, else: base
    ensure_unique(base, context_id, 0)
  end

  def ensure_unique(base, context_id, attempt) do
    slug = candidate_slug(base, attempt)

    if Dran.Brain.get_page_by_slug(slug, context_id) do
      ensure_unique(base, context_id, attempt + 1)
    else
      slug
    end
  end

  def ensure_unique(base, context_id, original_slug, attempt) do
    slug = candidate_slug(base, attempt)

    if slug == original_slug or is_nil(Dran.Brain.get_page_by_slug(slug, context_id)) do
      slug
    else
      ensure_unique(base, context_id, original_slug, attempt + 1)
    end
  end

  defp candidate_slug(base, 0), do: base
  defp candidate_slug(base, _attempt) do
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{base}-#{suffix}"
  end
end
```

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `refactor: extract slug utilities to shared Dran.Slug module`

---

### Task 12: Extraer type mappings a `DranWeb.PageTypes`

**Objective:** Eliminar 4 copias de mapas de type→path/label/icon.

**Files:**
- Create: `lib/dran_web/page_types.ex`
- Modify: `lib/dran_web/components/page_components.ex`, `lib/dran_web/live/dashboard_live.ex`, `lib/dran_web/live/page_new_live.ex`, `lib/dran_web/live/graph_live.ex`

**Implementation:**
```elixir
defmodule DranWeb.PageTypes do
  @moduledoc "Single source of truth for page type metadata."

  @types %{
    "note" => %{path: "notes", label: "Note", icon: "hero-document-text", plural: "Notes"},
    "concept" => %{path: "concepts", label: "Concept", icon: "hero-light-bulb", plural: "Concepts"},
    "entity" => %{path: "entities", label: "Entity", icon: "hero-user", plural: "Entities"},
    "reference" => %{path: "references", label: "Reference", icon: "hero-bookmark", plural: "References"},
    "goal" => %{path: "goals", label: "Goal", icon: "hero-flag", plural: "Goals"},
    "plan" => %{path: "plans", label: "Plan", icon: "hero-clipboard-document-list", plural: "Plans"},
    "todo" => %{path: "todos", label: "Todo", icon: "hero-check-circle", plural: "Todos"},
    "artifact" => %{path: "artifacts", label: "Artifact", icon: "hero-paper-clip", plural: "Artifacts"},
    "comparison" => %{path: "comparisons", label: "Comparison", icon: "hero-scale", plural: "Comparisons"},
    "query" => %{path: "queries", label: "Query", icon: "hero-question-mark-circle", plural: "Queries"}
  }

  def all, do: @types
  def path(type), do: @types[type][:path] || "#{type}s"
  def label(type), do: @types[type][:label] || type |> to_string() |> String.capitalize()
  def icon(type), do: @types[type][:icon] || "hero-document"
  def plural(type), do: @types[type][:plural] || "#{label(type)}s"
  def page_show_path(%{page_type: type, slug: slug}), do: "/#{path(type)}/#{slug}"
end
```

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `refactor: centralize page type mappings in DranWeb.PageTypes`

---

### Task 13: Extraer graph constants y `circular_layout` a `GraphHelpers`

**Objective:** Eliminar duplicación entre `GraphLive` y `GraphHelpers`.

**Files:**
- Modify: `lib/dran_web/graph_helpers.ex` (hacer `circular_layout` público)
- Modify: `lib/dran_web/live/graph_live.ex`

**Solución:**
1. En `graph_helpers.ex`, cambiar `defp circular_layout` a `def circular_layout`
2. En `graph_live.ex`, eliminar `@type_colors`, `@edge_colors`, y la copia local de `circular_layout`
3. Usar `GraphHelpers.type_colors()`, `GraphHelpers.edge_colors()`, y `GraphHelpers.circular_layout()` en su lugar

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `refactor: remove duplicate graph code between GraphLive and GraphHelpers`

---

### Task 14A: Extraer meta accessors de Todo a `DranWeb.TodoHelpers`

**Objective:** Sacar lógica de kanban/prioridad/fechas del LiveView.

**Files:**
- Create: `lib/dran_web/todo_helpers.ex`
- Modify: `lib/dran_web/live/todo_live.ex:574-627`

**Implementation:**
Ver plan original Task 14 — el código propuesto es correcto. Mover las funciones privadas a un módulo público.

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `refactor: extract todo meta accessors to DranWeb.TodoHelpers`

---

### Task 14B: Mover `format_due` y `due_date_class` a `TodoHelpers`

**Objective:** Consolidar todas las funciones de kanban/todo.

**Files:**
- Modify: `lib/dran_web/todo_helpers.ex` (añadir funciones)
- Modify: `lib/dran_web/live/todo_live.ex:628-645`

**Implementation:**
Ver plan original Task 15 — el código propuesto es correcto.

**Verification:**
```bash
mix compile --warnings-as-errors && mix test
```

**Commit:** `refactor: move format_due and due_date_class to TodoHelpers`

---

## PHASE 4: Functionality — Subagent Batch 4

### Task 15: Añadir búsqueda híbrida (FTS + semantic) en la UI

**Objective:** Exponer las estrategias de búsqueda del backend en la UI.

**Files:**
- Modify: `lib/dran_web/live/search_live.ex`
- Modify: `lib/dran/brain.ex` (verificar `search/2` ya soporta `:strategy`)

**Contexto:**
`Brain.search/2` ya soporta `:strategy` (`:fts`, `:semantic`, `:hybrid`, `:auto`). La UI solo usa `:auto` (que por defecto es FTS cuando no hay embeddings configurados).

**Solución:**
1. En `mount`, añadir assign `search_mode: "auto"`
2. En el template, añadir segmented control:
```elixir
<div class="flex gap-1 mb-4 p-1 bg-base-200 rounded-lg">
  <button
    :for={mode <- ["auto", "fts", "semantic", "hybrid"]}
    phx-click="set_mode"
    phx-value-mode={mode}
    class={[
      "px-3 py-1 text-sm rounded-md transition",
      @search_mode == mode && "bg-primary text-primary-content",
      @search_mode != mode && "text-base-content/70 hover:bg-base-300"
    ]}
  >
    {String.capitalize(mode)}
  </button>
</div>
```
3. Añadir handler:
```elixir
def handle_event("set_mode", %{"mode" => mode}, socket) do
  {:noreply, assign(socket, search_mode: mode)}
end
```
4. En `handle_params`, pasar `strategy: String.to_atom(socket.assigns.search_mode)` a `Brain.search`

**Verification:**
```bash
mix test
```

**Commit:** `feat: add search strategy toggle (auto/fts/semantic/hybrid) to search UI`

---

### Task 16: Añadir eliminación de páginas

**Objective:** Permitir borrar páginas desde la UI.

**Files:**
- Modify: `lib/dran_web/components/page_components.ex` (añadir botón delete en sidebar)
- Modify: `lib/dran_web/page_edit.ex` (añadir handler `delete_page`)

**Contexto:**
`Brain.delete_page/1` ya existe en `brain.ex:374`. Solo falta la UI.

**Solución:**
1. En `page_detail`, añadir en el sidebar (slot `:actions`):
```elixir
<button
  phx-click="delete_page"
  data-confirm="Are you sure you want to delete this page? This cannot be undone."
  class="btn btn-ghost btn-sm text-error"
>
  <.icon name="hero-trash" class="size-4" /> Delete
</button>
```
2. En `page_edit.ex`, añadir:
```elixir
def handle_event("delete_page", _params, socket) do
  page = socket.assigns.page

  case Brain.delete_page(page) do
    {:ok, _} ->
      {:noreply,
       socket
       |> put_flash(:info, "Page deleted")
       |> push_navigate(to: ~p"/")}

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Failed to delete page")}
  end
end
```

**Verification:**
```bash
mix test
```

**Commit:** `feat: add page deletion from edit sidebar`

---

### Task 17: Añadir export de contexto (JSON)

**Objective:** Permitir exportar un contexto completo.

**Files:**
- Create: `lib/dran/exporter.ex`
- Create: `lib/dran_web/controllers/api/export_controller.ex`
- Modify: `lib/dran_web/router.ex`

**Implementation:**
```elixir
# lib/dran/exporter.ex
defmodule Dran.Exporter do
  alias Dran.Brain
  alias Dran.Brain.{Page, Relation}

  def export_context(context_slug) do
    context = Brain.get_context_by_slug(context_slug)
    pages = Brain.list_pages(context_id: context.id)
    relations = Enum.flat_map(pages, &Brain.list_relations_for_page(&1.id).outbound)

    %{
      exported_at: DateTime.utc_now(),
      context: %{name: context.name, slug: context.slug, description: context.description},
      pages: Enum.map(pages, &page_json/1),
      relations: Enum.map(relations, &relation_json/1)
    }
  end

  defp page_json(page) do
    %{
      slug: page.slug, title: page.title, page_type: page.page_type,
      body: page.body, summary: page.summary, tags: page.tags,
      meta: page.meta, inserted_at: page.inserted_at, updated_at: page.updated_at
    }
  end

  defp relation_json(rel) do
    %{
      source_slug: rel.source.slug, target_slug: rel.target.slug,
      relation_type: rel.relation_type
    }
  end
end
```

Controller:
```elixir
defmodule DranWeb.API.ExportController do
  use DranWeb, :controller
  alias Dran.Exporter

  def show(conn, %{"slug" => slug}) do
    data = Exporter.export_context(slug)
    json(conn, data)
  end
end
```

Router:
```elixir
scope "/api", DranWeb.API do
  pipe_through :api
  get "/contexts/:slug/export", ExportController, :show
end
```

**Verification:**
```bash
mix test
```

**Commit:** `feat: add context export endpoint (JSON)`

---

## PHASE 5: SKILL.md Improvements — Subagent Batch 5

### Task 18: Reestructurar SKILL.md

**Objective:** Separar guía de usuario de convenciones de dev.

**Files:**
- Modify: `SKILL.md`

**Solución:**
Reorganizar en secciones claras:
1. **Overview** — qué es Dran, arquitectura general
2. **Development** — estructura, convenciones, testing
3. **MCP API** — referencia de tools/resources/prompts
4. **Configuration** — env vars, setup
5. **User Guide** — cómo usar

**Commit:** `docs: restructure SKILL.md into clear sections`

---

### Task 19: Añadir sección de testing al SKILL.md

**Objective:** Documentar cómo correr tests.

**Files:**
- Modify: `SKILL.md`

**Commit:** `docs: add testing section to SKILL.md`

---

### Task 20: Añadir diagrama de arquitectura al SKILL.md

**Objective:** Visión visual de componentes.

**Files:**
- Modify: `SKILL.md`

**Commit:** `docs: add architecture diagram to SKILL.md`

---

## PHASE 6: Hardening — Subagent Batch 6

### Task 21: Añadir health check endpoint

**Objective:** Endpoint `/health` para monitoring.

**Files:**
- Create: `lib/dran_web/controllers/health_controller.ex`
- Modify: `lib/dran_web/router.ex`

**Implementation:**
```elixir
defmodule DranWeb.HealthController do
  use DranWeb, :controller

  def show(conn, _params) do
    # Check DB
    db_status = case Ecto.Adapters.SQL.query(Dran.Repo, "SELECT 1") do
      {:ok, _} -> "ok"
      {:error, _} -> "error"
    end

    status = if db_status == "ok", do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{status: db_status, timestamp: DateTime.utc_now()})
  end
end
```

Router (fuera de auth):
```elixir
scope "/", DranWeb do
  get "/health", HealthController, :show
end
```

**Commit:** `feat: add /health endpoint for monitoring`

---

### Task 22: Añadir rate limiting básico al API

**Objective:** Proteger API REST de abuse.

**Files:**
- Create: `lib/dran_web/plugs/rate_limit.ex`
- Modify: `lib/dran_web/router.ex`

**Implementation (simple ETS-based):**
```elixir
defmodule DranWeb.Plugs.RateLimit do
  @moduledoc "Simple ETS-based rate limiter"
  import Plug.Conn

  @table :dran_rate_limit
  @limit 100
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table()
    key = {conn.remote_ip, DateTime.utc_now() |> DateTime.to_unix() |> div(60)}

    case :ets.update_counter(@table, key, {2, 1}, {key, 0}) do
      count when count > @limit ->
        conn
        |> put_status(429)
        |> Phoenix.Controller.json(%{error: "rate limit exceeded"})
        |> halt()
      _ ->
        conn
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table])
      _ -> :ok
    end
  end
end
```

Router:
```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug DranWeb.Plugs.RateLimit
end
```

**Commit:** `feat: add basic ETS-based rate limiting to API pipeline`

---

### Task 23: Circuit breaker para inference queue

**Objective:** Evitar que un inference server caído bloquee requests indefinidamente.

**Files:**
- Modify: `lib/dran/inference/queue.ex`

**Contexto:**
El queue es un permit serializer. Si el inference server está caído, los requests HTTP fallan con timeout (de `Config.timeout()`), pero el permit se mantiene hasta que el caller process muere. Esto es correcto, pero se puede mejorar con un circuit breaker que falle rápido después de N errores consecutivos.

**Solución:**
Añadir un `CircuitBreaker` GenServer que trackee fallos por capability:

```elixir
# En Queue, añadir:
def run(capability, fun) do
  case CircuitBreaker.allow?(capability) do
    true ->
      acquire(capability)
      try do
        result = fun.()
        CircuitBreaker.record_success(capability)
        result
      rescue
        e ->
          CircuitBreaker.record_failure(capability)
          reraise e, __STACKTRACE__
      after
        release(capability)
      end
    false ->
      {:error, :circuit_open}
  end
end
```

**Nota:** Esto es opcional/mejora futura. El timeout actual ya previene bloqueo indefinido.

**Commit:** `feat: add circuit breaker to inference queue`

---

## Execution Plan

| Batch | Tasks | Parallelizable | Est. Time |
|-------|-------|---------------|-----------|
| 1 | 1-5 (bugs) | Sí (independientes) | ~15 min |
| 2 | 6-10 (performance) | Parcial (6 y 7 dependen de brain.ex) | ~20 min |
| 3 | 11-14B (DRY) | Parcial (11 y 12 independientes, 13-14 dependen) | ~20 min |
| 4 | 15-17 (functionality) | Sí | ~25 min |
| 5 | 18-20 (SKILL.md) | Sí | ~10 min |
| 6 | 21-23 (hardening) | Sí | ~15 min |

**Reglas de ejecución:**
- Cada subagente debe correr `mix compile --warnings-as-errors && mix test` antes de commit
- Si un subagente falla, reintentar con contexto adicional
- Después de cada batch, verificar que main sigue compilando
- Batch 2 (Tasks 6-7) debe ir secuencial porque ambos tocan `brain.ex`

---

## Summary de Hallazgos (Validated)

| Categoría | Cantidad | Severidad | Estado |
|-----------|---------|-----------|--------|
| Bugs | 5 | Media-Alta | Confirmados |
| Performance | 5 | Media | 4 confirmados, 1 reformulado |
| DRY/Code Quality | 5 | Media | Confirmados (slug: 7 copias no 3) |
| Functionality | 3 | Baja-Media | 2 confirmados, 1 simplificado |
| SKILL.md | 3 | Baja | Confirmados |
| Hardening | 3 | Media | 2 confirmados, 1 reformulado |

### Prioridades

1. **Inmediato:** Tasks 1-5 (bugs críticos)
2. **Próximo sprint:** Tasks 6-10 (performance), Tasks 11-14B (DRY)
3. **Medio plazo:** Tasks 15-17 (funcionalidad)
4. **Cuando se pueda:** Tasks 18-23 (SKILL.md, hardening)

### Riesgos

- **Task 2 (XSS):** La sanitización debe permitir `<b>`/`</b>` de ts_headline pero escapar todo lo demás. Usar `HtmlSanitizeEx` o implementación manual cuidadosa.
- **Task 9 (pre-compute):** Cambia el patrón de renderizado. Hay que actualizar 10 LiveViews. Riesgo de inconsistencia si alguno se olvida.
- **Task 12 (type mapping):** Toca 4 archivos. Alto riesgo de merge conflicts si se hace en paralelo con otros tasks.
- **Task 22 (rate limit):** ETS table crece sin bound. En producción debería tener TTL o usar un sliding window más sofisticado.
