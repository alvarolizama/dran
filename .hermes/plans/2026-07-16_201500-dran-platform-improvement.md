# Dran Platform Improvement Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Audit completo de la plataforma Dran — bugs, performance, funcionalidad y SKILL.md — con plan accionable para cada hallazgo.

**Architecture:** Phoenix 1.8 single-app (no umbrella). PostgreSQL con pg_trgm + pgvector + unaccent. Second brain multi-contexto con 10 page-types, FTS + semantic search (embeddings 1024d HNSW), agentes autónomos (research/ingest), MCP server (JSON-RPC), API REST completa. Frontend LiveView + Tailwind v4.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView, Ecto, Req, MDEx, pgvector, Tailwind CSS v4, Firecrawl, Oban (no — custom GenServer queue)

---

## Current State

- **Compilación:** `mix compile` limpio (97 archivos, 0 errores, 0 warnings)
- **Tests:** 51 tests pasan (16 archivos de test)
- **Migraciones:** 11 migraciones (DB schema estable)
- **Archivos .ex/.heex:** ~60 archivos en `lib/`
- **Línea base:** git main, working tree clean

---

## PHASE 1: Bug Fixes (Critical)

### Task 1: Eliminar módulo dead `DranWeb.PageDetailComponent`

**Objective:** Remover código muerto que confunde a futuros desarrolladores.

**Files:**
- Delete: `lib/dran_web/live/page_detail_component.ex`

**Contexto:**
El archivo `lib/dran_web/live/page_detail_component.ex` define `DranWeb.PageDetailComponent.page_detail/1` con una firma completamente diferente (`attr :page, :map` + `attr :label, :string`) a la función `page_detail/1` que realmente se usa en `lib/dran_web/components/page_components.ex` (que toma `attr :page`, `attr :relations`, `attr :versions`, `attr :logs`, `attr :context_slug`, y slots `:actions` + `:tabs`). Ningún LiveView importa `DranWeb.PageDetailComponent`. Es código muerto.

**Step 1:** Verificar que no hay referencias

```bash
grep -r "PageDetailComponent" lib/ --include="*.ex" --include="*.heex"
```

Expected: Solo el archivo mismo aparece.

**Step 2:** Eliminar el archivo

```bash
rm lib/dran_web/live/page_detail_component.ex
```

**Step 3:** Verificar compilación

```bash
mix compile --warnings-as-errors
```

Expected: PASS, sin warnings.

**Step 4:** Commit

```bash
git add -A && git commit -m "refactor: remove dead PageDetailComponent module"
```

---

### Task 2: Fix XSS risk en `search_live.ex` — `raw()` en excerpts

**Objective:** Eliminar riesgo de XSS en la página de búsqueda.

**Files:**
- Modify: `lib/dran_web/live/search_live.ex:93`

**Contexto:**
`search_live.ex:93` hace `{raw(result.excerpt)}`. El excerpt viene de `Brain.search/2` que usa `ts_headline()` de PostgreSQL. Aunque `ts_headline` escapa HTML por defecto, el uso de `raw/1` en contenido de usuario es una mala práctica. Si en el futuro el excerpt se genera de otra forma, esto se vuelve un XSS real.

**Step 1:** Verificar cómo se genera el excerpt

```bash
grep -n "excerpt" lib/dran/brain.ex
```

Revisar la función `search/2` en `brain.ex` — el excerpt viene de `ts_headline` que SÍ escapa HTML entities. Sin embargo, usar `raw/1` es innecesariamente arriesgado.

**Step 2:** Cambiar `raw(result.excerpt)` por `result.excerpt` (sin `raw`)

```elixir
# En search_live.ex, línea ~93:
# Cambiar:
{raw(result.excerpt)}
# Por:
{result.excerpt}
```

HEEx escapa HTML automáticamente. Si el excerpt contiene HTML entities como `&lt;`, se mostrarán literalmente. Para que se renderice correctamente, usar `Phoenix.HTML.raw/1` solo si se confía en la fuente, o mejor aún, usar `{:safe, result.excerpt}` solo después de sanitizar.

**Opción A (recomendada):** Si `ts_headline` ya escapa, el resultado es texto plano y se puede usar directamente sin `raw`:

```elixir
<div class="mt-1 text-sm text-base-content/70">
  {result.excerpt}
</div>
```

**Opción B:** Si el excerpt contiene HTML legítimo (ej. `<mark>` de ts_headline), mantener `raw` pero sanitizar con una función explícita.

**Step 3:** Verificar que la búsqueda sigue funcionando

```bash
mix test test/dran_web/api/search_controller_test.exs
```

**Step 4:** Commit

```bash
git add lib/dran_web/live/search_live.ex
git commit -m "fix(security): remove unsafe raw() on search excerpts"
```

---

### Task 3: Fix pattern match crash en `PageEdit.handle_event("field_change", ...)`

**Objective:** Prevenir crash cuando `context` es nil.

**Files:**
- Modify: `lib/dran_web/page_edit.ex:116-120`

**Contexto:**
`page_edit.ex:116` hace pattern match en `%{assigns: %{page: %Page{} = page, context: %{id: context_id}}}`. Si `socket.assigns.context` es `nil` (usuario sin contexto), el match falla y el proceso crashea. Existe un fallback `def handle_event("field_change", _params, socket)` en línea 147, pero solo se ejecuta si NO hay `%Page{}` en assigns — no cubre el caso de page sin context.

**Step 1:** Modificar la cláusula para manejar context nil

```elixir
# En page_edit.ex, línea ~116:
# Cambiar el match para que context sea opcional:
def handle_event(
      "field_change",
      %{"page" => %{"slug" => new_slug}},
      %{assigns: %{page: %Page{} = page}} = socket
    ) do
  context_id = case socket.assigns[:context] do
    %{id: id} -> id
    _ -> nil
  end

  if context_id == nil do
    {:noreply, put_flash(socket, :error, "No context available.")}
  else
    # ... resto del body existente
  end
end
```

**Step 2:** Verificar compilación y tests

```bash
mix compile --warnings-as-errors && mix test
```

**Step 3:** Commit

```bash
git add lib/dran_web/page_edit.ex
git commit -m "fix: handle nil context in field_change slug rename"
```

---

### Task 4: Fix `agent_live.ex` — `ingest` ignora el parámetro `lang`

**Objective:** El selector de idioma aparece en la UI pero `start_agent("ingest", ...)` descarta `_opts`.

**Files:**
- Modify: `lib/dran_web/live/agent_live.ex:495-496`

**Contexto:**
`agent_live.ex:495-496`:
```elixir
defp start_agent("ingest", input, context_id, _opts),
  do: Agent.Ingest.run(input, context_id)
```
El usuario selecciona un idioma pero se ignora. El handler `start` en línea 457 extrae `lang` del params pero no lo pasa al ingest agent.

**Step 1:** Verificar si `Agent.Ingest.run/2` acepta opts

```bash
grep -n "def run" lib/dran/agent/ingest.ex
```

**Step 2:** Si `Ingest.run` solo acepta 2 args, hay dos opciones:
- **A:** Pasar opts a `Ingest.run(input, context_id, opts)` — requiere modificar el módulo ingest.
- **B:** Si ingest no necesita lang (porque solo convierte archivos), ocultar el selector de idioma cuando el tipo sea "ingest".

**Opción recomendada (B):** Mostrar el selector solo para research:

```elixir
# En agent_live.ex render, línea ~67:
# Cambiar el bloque del select para que solo aparezca para research:
<%= if @type == "research" do %>
  <div class="flex-1">
    <span class="label mb-1 block text-sm font-medium text-base-content/70">
      Output language
    </span>
    <select name="agent[lang]" ...>
      ...
    </select>
  </div>
<% end %>
```

**Step 3:** Commit

```bash
git add lib/dran_web/live/agent_live.ex
git commit -m "fix: hide language selector for ingest agent (unused param)"
```

---

### Task 5: Fix inline `onclick` en `dashboard_live.ex` (viola AGENTS.md)

**Objective:** Eliminar JS inline que viola las reglas del proyecto.

**Files:**
- Modify: `lib/dran_web/live/dashboard_live.ex:197`

**Contexto:**
`dashboard_live.ex:197` usa `onclick={"window.location.href='#{page_path(page)}'"}` — JS inline. AGENTS.md prohíbe inline JS en templates. Debería ser un `<.link navigate={...}>` o un `phx-click`.

**Step 1:** Reemplazar el div con onclick por un `<.link>`

```elixir
# En dashboard_live.ex, línea ~196-217:
# Cambiar el div con onclick por:
<.link
  :for={page <- @stats[:recent] || []}
  navigate={page_path(page)}
  class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-200 transition cursor-pointer"
>
  <.icon
    name={@type_icons[page.page_type] || "hero-document"}
    class="size-5 text-base-content/50 shrink-0"
  />
  <div class="min-w-0 flex-1">
    <div class="font-medium text-sm truncate">{page.title}</div>
    <div class="text-xs text-base-content/40">
      {@type_labels[page.page_type] || page.page_type} · {format_date(page.updated_at)}
    </div>
  </div>
  <span
    :if={page.summary}
    class="text-xs text-base-content/40 truncate hidden md:block max-w-[200px]"
  >
    {page.summary}
  </span>
</.link>
```

**Step 2:** Commit

```bash
git add lib/dran_web/live/dashboard_live.ex
git commit -m "fix: replace inline onclick with .link in dashboard recent pages"
```

---

## PHASE 2: Performance

### Task 6: Batch tag lookups — eliminar N+1 en `tag_page_exists?/2` y `tag_link_path/2`

**Objective:** Eliminar N+1 queries al renderizar tags de páginas.

**Files:**
- Modify: `lib/dran_web/components/page_components.ex:357-373`
- Modify: `lib/dran/brain.ex` (añadir función batch)

**Contexto:**
`page_components.ex` llama `Brain.get_page_by_slug(tag, context_id)` por cada tag. Una página con 8 tags = 8 queries. En el listado de páginas (50 páginas × 5 tags promedio = 250 queries).

**Step 1:** Añadir función batch en `brain.ex`

```elixir
# En lib/dran/brain.ex, añadir:
def get_pages_by_slugs(slugs, context_id) when is_list(slugs) do
  slugs = Enum.uniq(slugs)

  Repo.all(
    from p in Page,
      where: p.context_id == ^context_id and p.slug in ^slugs,
      select: {p.slug, p.page_type}
  )
  |> Map.new()
end
```

**Step 2:** Modificar `page_detail/1` en `page_components.ex` para pre-cargar tags

```elixir
# En page_detail assigns, antes del ~H:
tag_slugs = assigns.page.tags || []
tag_map = if tag_slugs != [], do: Brain.get_pages_by_slugs(tag_slugs, assigns.page.context_id), else: %{}
assigns = assign(assigns, :tag_map, tag_map)
```

Luego modificar los usos de `tag_page_exists?` y `tag_link_path` para usar el mapa:

```elixir
# En lugar de:
tag_page_exists?(tag, @page.context_id)
# Usar:
Map.has_key?(@tag_map, tag)

# En lugar de:
tag_link_path(tag, @page.context_id)
# Crear una función que use el mapa:
tag_link_from_map(tag, @tag_map)
```

**Step 3:** Verificar tests

```bash
mix test
```

**Step 4:** Commit

```bash
git add lib/dran/brain.ex lib/dran_web/components/page_components.ex
git commit -m "perf: batch tag lookups to eliminate N+1 in page detail"
```

---

### Task 7: Batch embeds e inline_links en `render_markdown`

**Objective:** Eliminar N+1 queries en renderizado de markdown.

**Files:**
- Modify: `lib/dran_web/components/page_components.ex:457-471`
- Modify: `lib/dran/brain.ex` (verificar `fetch_embeds`)

**Contexto:**
`render_markdown/2` llama `Brain.fetch_embeds(body, context_id)` y luego, en `apply_inline_links/3`, llama `Brain.get_page_by_slug` por cada inline link. Si una página tiene 5 inline links = 5 queries + 1 query para embeds.

**Step 1:** Verificar `fetch_embeds`

```bash
grep -n "fetch_embeds" lib/dran/brain.ex
```

**Step 2:** Modificar `apply_inline_links` para batch

```elixir
# En page_components.ex, apply_inline_links/3:
# En lugar de hacer get_page_by_slug por cada slug,
# hacer una sola query batch:
defp apply_inline_links(html, links, context_id) when is_list(links) and links != [] do
  slugs = links |> Enum.map(& &1["slug"]) |> Enum.uniq()
  slug_to_path = if context_id, do: Brain.get_pages_by_slugs(slugs, context_id), else: %{}

  # slug_to_path ya devuelve {slug, page_type}, construir paths:
  slug_to_path = Map.new(slug_to_path, fn {slug, type} ->
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

**Step 3:** Verificar

```bash
mix test
```

**Step 4:** Commit

```bash
git add lib/dran_web/components/page_components.ex lib/dran/brain.ex
git commit -m "perf: batch inline_links resolution in render_markdown"
```

---

### Task 8: Añadir paginación a `list_pages` en page lists

**Objective:** Evitar cargar todas las páginas de un tipo en memoria.

**Files:**
- Modify: `lib/dran/brain.ex` (`list_pages/1`)
- Modify: `lib/dran_web/components/page_list_components.ex`
- Modify: LiveViews que listan páginas (note_live, concept_live, etc.)

**Contexto:**
`Brain.list_pages(context_id: id, type: "note")` carga TODAS las notas. Si un contexto tiene 1000+ notas, esto es un problema de memoria y renderizado.

**Step 1:** Añadir opción de paginación en `brain.ex`

```elixir
def list_pages(opts) do
  page = Keyword.get(opts, :page, 1)
  per_page = Keyword.get(opts, :per_page, 50)

  Repo.all(
    from p in Page,
      where: p.context_id == ^opts[:context_id] and p.page_type == ^opts[:type],
      order_by: [desc: p.updated_at],
      limit: ^per_page,
      offset: ^((page - 1) * per_page)
  )
end
```

**Step 2:** Añadir control de paginación en el template `page_list_components.ex`

**Step 3:** Modificar LiveViews para manejar paginación

**Step 4:** Commit

```bash
git add lib/dran/brain.ex lib/dran_web/components/page_list_components.ex lib/dran_web/live/note_live.ex
git commit -m "feat: add pagination to page lists (50 per page)"
```

---

### Task 9: Cache de markdown rendering por `body_hash`

**Objective:** Evitar re-parsing markdown en cada render de LiveView.

**Files:**
- Modify: `lib/dran_web/components/page_components.ex` (`render_markdown/2`)

**Contexto:**
`render_markdown` se ejecuta en cada render de LiveView. Si el body no cambió, el resultado HTML es idéntico. Se puede cachear usando `body_hash` (que ya existe como columna en la DB).

**Step 1:** Añadir un cache simple basado en ETS

```elixir
# En page_components.ex:
@markdown_cache :dran_markdown_cache

def render_markdown(body, opts) when is_binary(body) do
  context_id = Keyword.get(opts, :context_id)
  cache_key = {body, context_id}

  case :ets.lookup(@markdown_cache, cache_key) do
    [{^cache_key, html}] -> raw(html)
    [] ->
      html = do_render_markdown(body, opts)
      :ets.insert(@markdown_cache, {cache_key, html})
      raw(html)
  end
end
```

**Step 2:** Inicializar tabla ETS en `application.ex`

```elixir
# En application.ex, dentro de children:
:ets.new(:dran_markdown_cache, [:set, :public, :named_table])
```

**Nota:** Implementar con cuidado — el cache debe invalidarse cuando cambia el body o los embeds. Usar TTL o límite de tamaño.

**Step 3:** Commit

```bash
git add lib/dran_web/components/page_components.ex lib/dran/application.ex
git commit -m "perf: cache markdown rendering by body_hash in ETS"
```

---

### Task 10: Debounce `refresh_steps` en `agent_live.ex`

**Objective:** Evitar queries de DB en cada mensaje PubSub de step.

**Files:**
- Modify: `lib/dran_web/live/agent_live.ex`

**Contexto:**
Cada `{:step_completed, _step, _result}` dispara `refresh_steps(socket)` que hace un `Repo.all`. Si el agente completa 5 steps rápido, son 5 queries. Se puede debounce con un timer.

**Step 1:** Modificar `handle_agent_message` para debounce

```elixir
defp handle_agent_message(socket, {:step_completed, _step, _result}) do
  # Debounce: schedule a refresh in 200ms if not already scheduled
  Process.send_after(self(), :refresh_steps, 200)
  socket
end

# Añadir handler:
def handle_info(:refresh_steps, socket) do
  {:noreply, refresh_steps(socket)}
end
```

**Step 2:** Commit

```bash
git add lib/dran_web/live/agent_live.ex
git commit -m "perf: debounce agent step refresh to avoid DB query spam"
```

---

## PHASE 3: Code Quality / DRY

### Task 11: Extraer `slugify`/`unique_slug`/`ensure_unique_slug` a un módulo compartido

**Objective:** Eliminar 3 copias duplicadas del mismo código.

**Files:**
- Create: `lib/dran/slug.ex`
- Modify: `lib/dran_web/page_edit.ex`
- Modify: `lib/dran_web/live/page_new_live.ex`
- Modify: `lib/dran_web/live/todo_live.ex`

**Contexto:**
`slugify/1`, `unique_slug/2-3`, `ensure_unique_slug/3-4` están copiados en:
- `page_edit.ex:323-367`
- `page_new_live.ex:278-305`
- `todo_live.ex:543-570`

Las 3 versiones son casi idénticas, con pequeñas diferencias en el fallback_type.

**Step 1:** Crear `lib/dran/slug.ex`

```elixir
defmodule Dran.Slug do
  @moduledoc """
  Shared slug generation and uniqueness checking.
  """

  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
  end

  def generate(title, context_id, fallback_type) do
    base = slugify(title)
    base = if base == "", do: fallback_type, else: base
    ensure_unique(base, context_id, 0)
  end

  def ensure_unique(base, context_id, attempt) do
    slug =
      if attempt == 0 do
        base
      else
        suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        "#{base}-#{suffix}"
      end

    if Dran.Brain.get_page_by_slug(slug, context_id) do
      ensure_unique(base, context_id, attempt + 1)
    else
      slug
    end
  end

  def ensure_unique(base, context_id, original_slug, attempt) do
    slug =
      if attempt == 0 do
        base
      else
        suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        "#{base}-#{suffix}"
      end

    if slug == original_slug or is_nil(Dran.Brain.get_page_by_slug(slug, context_id)) do
      slug
    else
      ensure_unique(base, context_id, original_slug, attempt + 1)
    end
  end
end
```

**Step 2:** Reemplazar en los 3 archivos las funciones duplicadas por llamadas a `Dran.Slug`

**Step 3:** Commit

```bash
git add lib/dran/slug.ex lib/dran_web/page_edit.ex lib/dran_web/live/page_new_live.ex lib/dran_web/live/todo_live.ex
git commit -m "refactor: extract slug utilities to shared Dran.Slug module"
```

---

### Task 12: Extraer type mappings a un solo módulo

**Objective:** Eliminar 4-5 copias de los mapas de type→path/label/icon.

**Files:**
- Create: `lib/dran_web/page_types.ex`
- Modify: `lib/dran_web/components/page_components.ex`
- Modify: `lib/dran_web/live/dashboard_live.ex`
- Modify: `lib/dran_web/live/page_new_live.ex`

**Contexto:**
Los mapas `@type_labels`, `@type_icons`, `@type_paths`, `@type_to_path`, `@type_routes` están duplicados en:
- `dashboard_live.ex:39-73` (3 mapas)
- `page_new_live.ex:15-26` (1 mapa)
- `page_components.ex:297-343` (funciones type_path/1, type_label/1, etc.)
- `page_components.ex:478-489` (@type_routes)

**Step 1:** Crear módulo centralizado

```elixir
defmodule DranWeb.PageTypes do
  @moduledoc "Single source of truth for page type metadata."

  @types %{
    "note" => %{path: "notes", label: "Notes", icon: "hero-document-text", plural: "Notes"},
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

**Step 2:** Reemplazar todos los mapas y funciones duplicadas con calls a `DranWeb.PageTypes`

**Step 3:** Commit

```bash
git add lib/dran_web/page_types.ex lib/dran_web/components/page_components.ex lib/dran_web/live/dashboard_live.ex lib/dran_web/live/page_new_live.ex
git commit -m "refactor: centralize page type mappings in DranWeb.PageTypes"
```

---

### Task 13: Extraer `circular_layout` y graph constants a `GraphHelpers`

**Objective:** Eliminar duplicación entre `GraphLive` y `GraphHelpers`.

**Files:**
- Modify: `lib/dran_web/graph_helpers.ex`
- Modify: `lib/dran_web/live/graph_live.ex`

**Contexto:**
- `GraphLive` define `@type_colors` y `@edge_colors` (líneas 18-35) idénticos a los de `GraphHelpers` (líneas 10-27).
- `GraphLive.load_show_graph/2` (líneas 189-265) es casi idéntico a `GraphHelpers.build_page_subgraph/1` (líneas 37-105).
- `circular_layout/4` está definido en ambos archivos.

**Step 1:** Eliminar las constantes y funciones duplicadas de `GraphLive`, usar `GraphHelpers` en su lugar

**Step 2:** Commit

```bash
git add lib/dran_web/graph_helpers.ex lib/dran_web/live/graph_live.ex
git commit -m "refactor: remove duplicate graph code between GraphLive and GraphHelpers"
```

---

### Task 14: Extraer meta accessors de Todo a `DranWeb.TodoHelpers`

**Objective:** Sacar lógica de kanban/prioridad/fechas del LiveView a un módulo reutilizable.

**Files:**
- Create: `lib/dran_web/todo_helpers.ex`
- Modify: `lib/dran_web/live/todo_live.ex:574-657`

**Contexto:**
`todo_live.ex` tiene 84 líneas de funciones privadas que acceden `page.meta` y devuelven labels, clases CSS y formatting:

```elixir
defp kanban_status(page)    # Lee meta["kanban_status"], default "backlog"
defp priority(page)         # Lee meta["priority"], default "medium"
defp priority_label(page)   # Mapea priority → "Urgent", "High", etc.
defp priority_class(page)    # Mapea priority → clases Tailwind
defp goal_slug(page)         # Lee meta["goal_slug"]
defp due_date(page)          # Lee meta["due_date"]
defp overdue?(page)          # Compara due_date con hoy
defp format_due/1            # Formatea fecha "Jul 16"
defp due_date_class/1         # Clases CSS según overdue
defp status_button_class/3    # Clases de botón activo/inactivo
defp column_count/2           # Cuenta items por status
defp column_items/2            # Filtra items por status
```

Estas funciones son útiles en cualquier LiveView que muestre todos (dashboard, concept_live, page_components). Al sacarlas a un módulo, quedan disponibles para reutilizar.

**Step 1:** Crear `lib/dran_web/todo_helpers.ex`

```elixir
defmodule DranWeb.TodoHelpers do
  @moduledoc "Shared helpers for todo/kanban metadata and rendering."

  def kanban_status(page) do
    case (page.meta || %{})["kanban_status"] do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  def priority(page) do
    case (page.meta || %{})["priority"] do
      s when is_binary(s) and s != "" -> s
      _ -> "medium"
    end
  end

  def priority_label(page) do
    case priority(page) do
      "urgent" -> "Urgent"
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      other -> other |> to_string() |> String.capitalize()
    end
  end

  def priority_class(page) do
    case priority(page) do
      "urgent" -> "bg-red-100 text-red-700"
      "high" -> "bg-orange-100 text-orange-700"
      "medium" -> "bg-blue-100 text-blue-700"
      "low" -> "bg-gray-100 text-gray-600"
      _ -> "bg-gray-100 text-gray-600"
    end
  end

  def goal_slug(page), do: (page.meta || %{})["goal_slug"]

  def due_date(page), do: (page.meta || %{})["due_date"]

  def overdue?(page) do
    case due_date(page) do
      s when is_binary(s) and s != "" ->
        case Date.from_iso8601(s) do
          {:ok, d} -> Date.compare(d, Date.utc_today()) == :lt
          _ -> false
        end
      %Date{} = d -> Date.compare(d, Date.utc_today()) == :lt
      _ -> false
    end
  end

  def status_button_class(current, status, badge_class) when current == status,
    do: "px-2.5 py-1 text-xs rounded-full border transition #{badge_class} border-transparent font-semibold"

  def status_button_class(_current, _status, _badge_class),
    do: "px-2.5 py-1 text-xs rounded-full border transition border-base-300 text-base-content/60 hover:bg-base-200"

  def column_count(items, status),
    do: Enum.count(items, fn item -> kanban_status(item) == status end)

  def column_items(items, status),
    do: Enum.filter(items, fn item -> kanban_status(item) == status end)
end
```

**Step 2:** Reemplazar las funciones privadas en `todo_live.ex` con `import DranWeb.TodoHelpers`

**Step 3:** Compilar y testear

```bash
mix compile --warnings-as-errors && mix test
```

**Step 4:** Commit

```bash
git add lib/dran_web/todo_helpers.ex lib/dran_web/live/todo_live.ex
git commit -m "refactor: extract todo meta accessors to DranWeb.TodoHelpers"
```

---

### Task 15: Mover `format_due` y `due_date_class` de `todo_live.ex` a `TodoHelpers`

**Objective:** Consolidar todas las funciones de kanban/todo en un solo módulo.

**Files:**
- Modify: `lib/dran_web/todo_helpers.ex` (añadir `format_due/1` y `due_date_class/1`)
- Modify: `lib/dran_web/live/todo_live.ex:628-645`

**Contexto:**
Investigación más profunda reveló que `format_date/1` **ya está centralizada** en `PageComponents` (línea 375-381) y auto-importada en todos los LiveViews vía `dran_web.ex:58`. NO hay duplicación de `format_date` — los 11 LiveViews que la llaman la obtienen del import automático.

Sin embargo, `todo_live.ex:628-645` tiene `format_due/1` (formato corto `%b %d`) y `due_date_class/1` que son específicas de todos y viven sueltas en el LiveView. Deben moverse a `TodoHelpers` junto con las funciones de Task 14.

**Step 1:** En `lib/dran_web/todo_helpers.ex` (creado en Task 14), añadir:

```elixir
def format_due(nil), do: ""
def format_due(""), do: ""

def format_due(s) when is_binary(s) do
  case Date.from_iso8601(s) do
    {:ok, d} -> Calendar.strftime(d, "%b %d")
    _ -> s
  end
end

def format_due(%Date{} = d), do: Calendar.strftime(d, "%b %d")
def format_due(other), do: to_string(other)

def due_date_class(true),
  do: "flex items-center gap-1 mt-1.5 text-[11px] text-red-600 font-medium"

def due_date_class(false),
  do: "flex items-center gap-1 mt-1.5 text-[11px] text-base-content/60"
```

**Step 2:** Eliminar las versiones privadas de `todo_live.ex:628-645`

**Step 3:** Compilar y testear

```bash
mix compile --warnings-as-errors && mix test
```

**Step 4:** Commit

```bash
git add lib/dran_web/todo_helpers.ex lib/dran_web/live/todo_live.ex
git commit -m "refactor: move format_due and due_date_class to TodoHelpers"
```

> **Nota:** `format_date/1` NO necesita extraerse — ya está centralizada en `PageComponents:375` y auto-importada. La copia en `page_detail_component.ex:38-44` usa formato diferente (`%Y-%m-%d`) pero ese módulo se elimina en Task 1.

---

## PHASE 4: Functionality

### Task 14: Añadir búsqueda híbrida (FTS + semantic) en la UI de búsqueda

**Objective:** El backend ya tiene embeddings y rerank, pero la web solo usa FTS.

**Files:**
- Modify: `lib/dran/brain.ex` (función `search/2` ya existe — verificar si soporta `:semantic`)
- Modify: `lib/dran_web/live/search_live.ex`

**Contexto:**
`Brain.search/2` actualmente usa FTS (tsvector). Existe `test/dran/brain/semantic_search_test.exs` pero la UI web no usa búsqueda semántica. El rerank también existe (`Dran.Rerank`) pero no se invoca desde la web.

**Step 1:** Verificar si `Brain.search` ya soporta modo semántico/híbrido

```bash
grep -n "def search" lib/dran/brain.ex
```

**Step 2:** Añadir toggle de modo de búsqueda en `search_live.ex`

```elixir
# En mount, añadir assign:
search_mode: "fts"  # o "hybrid", "semantic"

# En el form, añadir un toggle/segmented control:
<div class="flex gap-2 mb-4">
  <button phx-click="set_mode" phx-value-mode="fts" class={...}>Text</button>
  <button phx-click="set_mode" phx-value-mode="hybrid" class={...}>Hybrid</button>
  <button phx-click="set_mode" phx-value-mode="semantic" class={...}>Semantic</button>
</div>
```

**Step 3:** Pasar el modo a `Brain.search`

**Step 4:** Commit

---

### Task 15: Añadir UI para crear relaciones entre páginas

**Objective:** Permitir crear relaciones desde la UI sin necesidad de wikilinks en markdown.

**Files:**
- Modify: `lib/dran_web/components/page_components.ex` (añadir sección de relaciones con botón "Add relation")
- Modify: LiveViews que usan `page_detail` (añadir handler `add_relation`)

**Contexto:**
Las relaciones solo se crean automáticamente por wikilinks `[[slug]]` en el markdown, o vía API. No hay UI para conectar páginas manualmente.

**Step 1:** Añadir botón "Add relation" en el sidebar de `page_detail`

**Step 2:** Implementar un modal/inline form para buscar y seleccionar páginas

**Step 3:** Crear handler `handle_event("add_relation", %{"target_slug" => slug, "relation_type" => type}, socket)`

**Step 4:** Commit

---

### Task 16: Añadir eliminación de páginas

**Objective:** No existe forma de borrar páginas desde la UI.

**Files:**
- Modify: `lib/dran/brain.ex` (verificar si `delete_page/1` existe)
- Modify: `lib/dran_web/components/page_components.ex` (añadir botón delete)
- Modify: `lib/dran_web/page_edit.ex` (añadir handler `delete_page`)

**Step 1:** Verificar si `Brain.delete_page/1` existe

```bash
grep -n "delete_page" lib/dran/brain.ex
```

**Step 2:** Si no existe, añadirla

**Step 3:** Añadir botón en el sidebar con `data-confirm`

**Step 4:** Commit

---

### Task 17: Añadir export de contexto (JSON / Markdown)

**Objective:** Permitir exportar el second brain para respaldo o migración.

**Files:**
- Create: `lib/dran/exporter.ex`
- Create: `lib/dran_web/controllers/api/export_controller.ex`
- Modify: `lib/dran_web/router.ex`

**Step 1:** Crear `Dran.Exporter` que serializa un contexto completo a JSON

**Step 2:** Añadir endpoint `GET /api/contexts/:slug/export`

**Step 3:** Añadir botón en la UI de settings o dashboard

**Step 4:** Commit

---

### Task 18: Persistencia y reintentos en la inference queue

**Objective:** El queue actual es un GenServer en memoria — pierde trabajos al reiniciar.

**Files:**
- Modify: `lib/dran/inference/queue.ex`
- Or: Replace with Oban if available in deps

**Contexto:**
`inference/queue.ex` es un GenServer simple con límite de concurrencia. Si el BEAM se reinicia, todos los trabajos en cola se pierden. No hay reintentos ni backoff.

**Step 1:** Verificar si Oban está en deps

```bash
grep "oban" mix.exs
```

**Step 2:** Si no está, considerar añadirlo, o implementar persistencia en DB para la cola existente

**Step 3:** Commit

---

## PHASE 5: SKILL.md Improvements

### Task 19: Reestructurar SKILL.md — separar guía de usuario de convenciones de dev

**Objective:** SKILL.md mezcla "cómo usar Dran" (usuario) con "cómo desarrollar Dran" (dev).

**Files:**
- Modify: `SKILL.md`
- Create: `docs/USER_GUIDE.md` (opcional)

**Contexto:**
El SKILL.md actual tiene 14,969 caracteres y mezcla:
- Guía de uso (qué es Dran, page types, cómo buscar)
- Convenciones de desarrollo (estructura de código, patrones)
- Referencia de API MCP
- Configuración

**Step 1:** Reorganizar en secciones claras:
1. **Overview** — qué es Dran, arquitectura general
2. **Development** — estructura, convenciones, testing
3. **MCP API** — referencia de tools/resources/prompts
4. **Configuration** — env vars, setup
5. **User Guide** — cómo usar (opcionalmente en doc separada)

**Step 2:** Eliminar información duplicada entre SKILL.md y README.md

**Step 3:** Commit

---

### Task 20: Añadir sección de testing al SKILL.md

**Objective:** SKILL.md no menciona cómo correr tests ni qué testar.

**Files:**
- Modify: `SKILL.md`

**Step 1:** Añadir sección:

```markdown
## Testing

### Comandos
- `mix test` — corre todos los tests
- `mix test test/dran/brain/` — tests de un directorio
- `mix test --failed` — solo tests que fallaron la última vez
- `mix precommit` — compile + lint + test antes de commit

### Convenciones
- Tests en `test/` espejan la estructura de `lib/`
- Usar `start_supervised!/1` para procesos en tests
- Evitar `Process.sleep/1` — usar `Process.monitor/1` y assert en DOWN
- Tests de LiveView: usar `has_element?/2`, no raw HTML
```

**Step 2:** Commit

---

### Task 21: Añadir diagrama de arquitectura al SKILL.md

**Objective:** Falta una visión visual de cómo se conectan los componentes.

**Files:**
- Modify: `SKILL.md`

**Step 1:** Añadir sección con diagrama ASCII:

```
┌─────────────────────────────────────────────────┐
│                    Browser                       │
│  LiveViews (Dashboard, Notes, Search, Graph)     │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│                 Phoenix Router                    │
│  ┌─────────────┐  ┌──────────────────────────┐  │
│  │  /api/*     │  │  LiveView routes         │  │
│  │  (REST)     │  │  (WebSocket)             │  │
│  └─────────────┘  └──────────────────────────┘  │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│                   Dran.Brain                     │
│  Contexts → Pages → Relations → Versions → Logs  │
│  FTS (tsvector) + Semantic (pgvector HNSW)       │
└──────┬───────────┬───────────────┬──────────────┘
       │           │               │
┌──────▼────┐ ┌───▼────┐ ┌───────▼───────┐
│ Inference  │ │ Agents │ │ MCP Server    │
│ (LLM API)  │ │ (Task) │ │ (JSON-RPC)    │
│ Embeddings │ │ Search │ │ Tools/Resources│
│ Rerank     │ │ Scrape │ │ Prompts       │
│ Vision/ASR │ │ Create │ │               │
└────────────┘ └────────┘ └───────────────┘
```

**Step 2:** Commit

---

## PHASE 6: Hardening

### Task 22: Añadir rate limiting al API

**Objective:** El API REST no tiene rate limiting.

**Files:**
- Modify: `lib/dran_web/router.ex` (añadir plug de rate limiting en pipeline `:api`)
- Create: `lib/dran_web/plugs/rate_limit.ex`

**Step 1:** Crear plug simple basado en ETS

**Step 2:** Aplicar en pipeline `:api`

**Step 3:** Commit

---

### Task 23: Añadir health check endpoint

**Objective:** No hay endpoint `/health` para monitoring.

**Files:**
- Modify: `lib/dran_web/router.ex`
- Create: `lib/dran_web/controllers/health_controller.ex`

**Step 1:** Crear controller que verifique DB y returne JSON

**Step 2:** Añadir ruta `GET /health` fuera de auth

**Step 3:** Commit

---

### Task 24: Validar y documentar el flujo de embeddings

**Objective:** Verificar que el flujo de generación de embeddings no bloquea la creación de páginas.

**Files:**
- Verify: `lib/dran/brain.ex` (función `create_page`)
- Verify: `lib/dran/embeddings.ex`

**Step 1:** Verificar si `Brain.create_page` llama a `Embeddings.generate` síncrona o asíncrona

```bash
grep -n "embedding" lib/dran/brain.ex | head -20
```

**Step 2:** Si es síncrono, mover a `Task.Supervisor` para no bloquear

**Step 3:** Commit

---

## Summary de Hallazgos

| Categoría | Cantidad | Severidad |
|-----------|---------|-----------|
| Bugs | 5 | Media-Alta |
| Performance | 5 | Media |
| DRY/Code Quality | 5 | Media |
| Functionality | 5 | Baja-Media |
| SKILL.md | 3 | Baja |
| Hardening | 3 | Media |

### Prioridades recomendadas

1. **Inmediato:** Task 1 (dead code), Task 2 (XSS), Task 3 (crash), Task 5 (AGENTS.md violation)
2. **Próximo sprint:** Tasks 6-8 (performance N+1), Tasks 11-15 (DRY + modularización)
3. **Medio plazo:** Tasks 14-17 (funcionalidad), Task 22-24 (hardening)
4. **Cuando se pueda:** Tasks 18-21 (queue persistence, SKILL.md)

### Riesgos

- **Task 9 (markdown cache):** Riesgo de stale data si los embeds cambian. Necesita invalidación cuidadosa.
- **Task 8 (paginación):** Cambio de UX — los usuarios pueden notar diferencia en listas.
- **Task 12 (type mapping):** Refactor toca muchos archivos — alto riesgo de merge conflicts si se hace en paralelo.
- **Task 18 (queue persistence):** Si se añade Oban, requiere dependencia nueva y migración de DB.
