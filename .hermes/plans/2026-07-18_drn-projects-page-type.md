# Dran v6: todos huérfanos con vínculos, Projects, Goals y Plans en Knowledge, Kanban global

> **Para Hermes:** Ejecutar con subagent-driven-development, una tarea por subagente, verificando `mix compile --warnings-as-errors` + tests después de cada fase.

**Goal:** Reescribir el modelo de planificación de Dran. Todos los pages son huérfanos por defecto; los vínculos (`project_slug`, `goal_slug`, `plan_slug`) son **independientes y opcionales**, sin precedencia. Projects y Goals y Plans dejan de ser contenedores jerárquicos y pasan a ser páginas de conocimiento con vínculos opcionales. Un **Kanban global** en el sidebar reemplaza los kanbans embebidos en Goal/Project.

**Stack:** Elixir Phoenix LiveView, Ecto, PostgreSQL, pgvector. Repo: `~/Repos/dran`.

---

## 1. Justificación

### 1.1 Todos son huérfanos con vínculos independientes

El modelo jerárquico actual (`project > goal > plan > todo` con precedencia `plan > goal > project` en `brain.ex:825-839`) tiene tres problemas concretos:

1. **Precedencia opaca.** Un todo con `plan_slug` + `goal_slug` + `project_slug` seteados solo materializa `part_of plan`; los otros dos slugs quedan como metadata inerte. El usuario cree que el todo está vinculado a tres cosas; en realidad solo a una. Esto generó bugs silenciosos en consultas del dashboard de ProjectLive (que filtra por `meta.project_slug`, no por `part_of`).
2. **Múltiples padres imposibles.** Un todo que pertenece operativamente a un proyecto y tácticamente a un plan y mediblemente a un goal — caso normal — debe elegir uno. Es semánticamente incorrecto.
3. **Queries complejas.** `maybe_filter_goal_slug/2` en `brain.ex:244-257` hace un LEFT JOIN contra la tabla `pages` para resolver la precedencia plan→goal. Es frágil, lento y no extiende a `project_slug` sin otro JOIN.

**Nueva regla: los tres slugs son vínculos independientes.** Un todo puede tener `project_slug`, `goal_slug` y `plan_slug` seteados simultáneamente y cada uno materializa su propia relación `part_of`. La función `sync_todo_links/2` (reemplazo de `sync_planning_relations/2`) simplemente sincroniza los tres slugs de forma independiente — si un slug cambia, se borra la relación vieja y se crea la nueva para ese slug, sin tocar los otros dos.

```
TODO (huérfano o con vínculos opcionales)
  ├── meta.project_slug  →  part_of project  (si seteado)
  ├── meta.goal_slug     →  part_of goal     (si seteado)
  └── meta.plan_slug     →  part_of plan     (si seteado)

Sin precedencia. Los tres son independientes. Un todo puede tener 0, 1, 2 o 3 vínculos.
```

Esto vale para **todos los page types**: notes, concepts, entities, references, artifacts, queries, goals, plans, todos, projects. Cualquier página puede tener `project_slug`, `goal_slug`, `plan_slug` y cada uno materializa su `part_of`.

### 1.2 Projects, Goals y Plans son páginas de conocimiento

En el modelo jerárquico, Project/Goal/Plan eran "contenedores" con tabs de sub-páginas. Eso generaba 9 tabs en `goal_live.ex:23-33` (overview, notes, concepts, entities, todos, plans, artifacts, references, graph) — más tabs que cualquier usuario necesita.

**Nuevo modelo:**
- **Project** — dashboard con metadata ejecutable (status, priority, health derivado) + lista de todos vinculados (no kanban). Es página de conocimiento sobre una iniciativa; el kanban vive en su propia ruta global.
- **Goal** — página de conocimiento con métricas (health, target_value, current_value, progress). Muestra todos vinculados pero **sin kanban** (el kanban global lo cubre).
- **Plan** — documento estratégico con horizon + period + status + due_date. Muestra todos vinculados.

Los kanbans embebidos en Goal/Project se eliminan. Un solo **Kanban global** (`/kanban`) filtra por cualquiera de los tres slugs combinables, o por ninguno (inbox GTD).

### 1.3 Kanban global

**Por qué kanban global en vez de por proyecto/goal:**

1. **Cambio de contexto costoso.** Hoy para ver todos de un goal hay que navegar a `/goals/:slug`, click tab "Todos". Para ver todos de un project, `/projects/:slug`, tab "Todos". Para ver inbox (huérfanos), no hay vista — hay que ir a `/todos` y filtrar. Tres UX distintas para la misma acción: "ver mis todos".
2. **Filtros combinables más potentes.** Un kanban global con dropdown `Project ▾`, `Goal ▾`, `Plan ▾` permite ver en una pantalla: "todos del project X + goal Y", "todos del plan Z", "todos huérfanos", "todos del project X sin importar goal/plan". Eso es imposible con kanbans embebidos.
3. **Badges por tipo.** Cada card del kanban muestra badges discretos (máximo 2 visibles) que indican a qué project/goal/plan está vinculada, con color por tipo y tooltip en hover. Click en un badge filtra el kanban por ese vínculo. Esto reemplaza la navegación por jerarquía con navegación por vínculos.
4. **Drag-drop actualiza `kanban_status`** directamente sobre la página — no sobre una relación. Mismo mecanismo que ya existe en `goal_live.ex:560-593`, pero sin scope a un contenedor.

### 1.4 Sidebar reorganizado

El sidebar actual (`layouts.ex:178-332`) agrupa Goals/Plans/Todos bajo "Planning". La nueva organización:

```
Dashboard
Kanban          ← NUEVO, arriba de todo (después de Dashboard)
─────────────
Knowledge
├── Notes
├── Concepts
├── Entities
├── Goals       ← movido aquí (antes en Planning)
├── Plans       ← movido aquí
└── References
─────────────
Graphs
Outputs
...
```

Projects queda como entrada top-level (junto a Dashboard y Kanban) porque es el dashboard ejecutivo principal. Goals y Plans bajan a Knowledge porque ahora son páginas de conocimiento con metadata, no contenedores jerárquicos. Todos desaparece del sidebar — su lugar es el Kanban global.

---

## 2. Estructura de datos

### 2.1 `@page_types` (`lib/dran/brain/page.ex:70`)

```elixir
# antes
@page_types ~w(note comparison plan todo goal entity concept reference artifact query)

# después
@page_types ~w(note comparison plan todo goal entity concept reference artifact query project)
```

### 2.2 Schema embebido — `lib/dran/brain/page_meta.ex`

Schema completo con todos los campos nuevos. Se mantiene la estructura actual (un solo `embedded_schema` con todos los campos de todos los tipos) y se añaden los nuevos.

```elixir
@primary_key false

embedded_schema do
  # ── Common (todos los tipos pueden tener estos vínculos) ──
  field :kind, :string
  field :project_slug, :string          # NUEVO — vínculo a project
  field :goal_slug, :string             # vínculo a goal
  field :plan_slug, :string             # vínculo a plan

  # ── note sub-types ──
  field :date, :date
  field :feasibility, :string
  field :impact, :string
  field :attendees, {:array, :string}
  field :resolved, :boolean
  field :source_ref, :string
  field :author, :string

  # ── comparison ──
  field :entities, {:array, :string}
  field :criteria, {:array, :string}
  field :verdict, :string

  # ── plan ──
  field :horizon, :string               # weekly | monthly | quarterly | yearly
  field :period, :string                # ej. "2026-Q3", "July 2026"
  field :status, :string                # NUEVO significado: draft | active | done | archived
  field :due_date, :date               # NUEVO — fecha límite del plan

  # ── todo ──
  field :kanban_status, :string         # backlog | this_week | today | in_progress | done | cancelled
  field :priority, :string             # low | medium | high | urgent
  field :due_date, :date               # (compartido con plan — un solo campo)
  field :remind_at, :utc_datetime
  field :acknowledged, :boolean
  field :completed_at, :utc_datetime
  field :assignee, :string

  # ── goal ──
  field :start_date, :date
  field :target_date, :date
  field :team, {:array, :string}
  field :health, :string                # green | yellow | red
  field :metric, :string                # NUEVO — ej. "MRR", "users", "uptime"
  field :target_value, :float           # NUEVO — valor objetivo del metric
  field :current_value, :float          # NUEVO — valor actual del metric
  field :unit, :string                  # NUEVO — unidad del metric (%, USD, users)
  field :progress, :float               # NUEVO — 0.0 a 1.0 (auto-calculado o manual)

  # ── project (NUEVO bloque) ──
  field :status, :string                # draft | active | on_hold | done | archived  (compartido con plan)
  field :priority, :string              # low | medium | high | urgent  (compartido con todo)
  field :health, :string                # green | yellow | red  (compartido con goal)
  field :health_source, :string         # NUEVO — manual | derived
  field :start_date, :date              # (compartido con goal)
  field :target_date, :date             # (compartido con goal)

  # ── entity ──
  field :aliases, {:array, :string}
  field :external_url, :string
  field :location, :string

  # ── concept ──
  field :domain, :string
  field :parent_concept, :string

  # ── reference ──
  field :source_url, :string
  field :published_at, :date
  field :content_hash, :string
  field :fetched_at, :utc_datetime

  # ── artifact ──
  field :filename, :string
  field :mime_type, :string
  field :size, :integer
  field :storage_path, :string
  field :sha256, :string
  field :version, :string

  # ── query ──
  field :difficulty, :string
  field :answer_status, :string
  field :answered_by, :string
end
```

> **Nota sobre campos compartidos:** `status`, `priority`, `health`, `start_date`, `target_date`, `due_date` se declaran una sola vez en el schema (no se repiten). Cada tipo los valida con sus propios valores en `validate_meta_for_type/2`. Es el patrón actual; no cambia.

**Campos nuevos totales:**

| Campo | Tipos que lo usan | Module attr |
|-------|-------------------|-------------|
| `project_slug` | todos | — (common) |
| `health_source` | project | `@health_sources` |
| `metric` | goal | — |
| `target_value` | goal | — |
| `current_value` | goal | — |
| `unit` | goal | — |
| `progress` | goal | — |
| `due_date` (plan) | plan, todo | — (ya existe, lo usa plan ahora) |

### 2.3 `all_fields/0` — añadir los nuevos

```elixir
defp all_fields do
  [
    :kind,
    :project_slug,            # NUEVO
    :goal_slug,
    :plan_slug,
    :date,
    :feasibility,
    :impact,
    :attendees,
    :resolved,
    :source_ref,
    :author,
    :entities,
    :criteria,
    :verdict,
    :horizon,
    :period,
    :status,
    :due_date,
    :kanban_status,
    :priority,
    :remind_at,
    :acknowledged,
    :completed_at,
    :assignee,
    :start_date,
    :target_date,
    :team,
    :health,
    :health_source,           # NUEVO
    :metric,                  # NUEVO
    :target_value,            # NUEVO
    :current_value,           # NUEVO
    :unit,                    # NUEVO
    :progress,                # NUEVO
    :aliases,
    :external_url,
    :location,
    :domain,
    :parent_concept,
    :source_url,
    :published_at,
    :content_hash,
    :fetched_at,
    :filename,
    :mime_type,
    :size,
    :storage_path,
    :sha256,
    :version,
    :difficulty,
    :answer_status,
    :answered_by
  ]
end
```

### 2.4 Atributos de validación

```elixir
@note_kinds ~w(thought journal idea meeting question quote reminder)
#                                                                      ^^^^^^^^ NUEVO
@entity_kinds ~w(person company product tool place event)
@concept_kinds ~w(technique pattern discipline theory)
@reference_kinds ~w(article paper video podcast book)
@artifact_kinds ~w(document code design deliverable file)
@query_kinds ~w(factual conceptual how_to opinion)
@kanban_statuses ~w(backlog this_week today in_progress done cancelled)
@priorities ~w(low medium high urgent)
@healths ~w(green yellow red)
@horizons ~w(weekly monthly quarterly yearly)
@query_difficulties ~w(simple intermediate advanced)
@query_statuses ~w(open answered verified)

# NUEVOS:
@project_statuses ~w(draft active on_hold done archived)
@plan_statuses ~w(draft active done archived)        # sin on_hold — plan no se pausa
@health_sources ~w(manual derived)
```

> **`@note_kinds`:** añadir `reminder` — las notas de tipo reminder pueden tener `due_date` (campo condicional).

### 2.5 `validate_meta_for_type/2`

```elixir
defp validate_meta_for_type(cs, "todo") do
  cs
  |> validate_inclusion(:kanban_status, @kanban_statuses)
  |> validate_inclusion(:priority, @priorities)
end

defp validate_meta_for_type(cs, "project") do
  cs
  |> validate_inclusion(:status, @project_statuses)
  |> validate_inclusion(:priority, @priorities)
  |> validate_inclusion(:health, @healths)
  |> validate_inclusion(:health_source, @health_sources)
end

defp validate_meta_for_type(cs, "goal") do
  cs
  |> validate_inclusion(:health, @healths)
  |> validate_progress_range(cs)
end

defp validate_meta_for_type(cs, "plan") do
  cs
  |> validate_inclusion(:horizon, @horizons)
  |> validate_inclusion(:status, @plan_statuses)
end

defp validate_meta_for_type(cs, "query") do
  cs
  |> validate_inclusion(:difficulty, @query_difficulties)
  |> validate_inclusion(:answer_status, @query_statuses)
end

defp validate_meta_for_type(cs, "note") do
  # Si kind == "reminder", due_date es recomendado (no required — validación suave).
  cs
end

defp validate_meta_for_type(cs, _type), do: cs

defp validate_progress_range(cs) do
  case get_change(cs, :progress) do
    nil -> cs
    val when is_number(val) and val >= 0.0 and val <= 1.0 -> cs
    _ -> add_error(cs, :progress, "must be between 0.0 and 1.0")
  end
end
```

### 2.6 `meta_fields_for/1` — form fields por tipo

```elixir
def meta_fields_for("project") do
  [
    {:select, "status", "Status",
     Enum.map(@project_statuses, &{String.capitalize(&1), &1})},
    {:select, "health", "Health",
     [{"Green", "green"}, {"Yellow", "yellow"}, {"Red", "red"}]},
    {:select, "health_source", "Health source",
     [{"Manual (override)", "manual"}, {"Derived from goals", "derived"}]},
    {:select, "priority", "Priority",
     [{"Low", "low"}, {"Medium", "medium"}, {"High", "high"}, {"Urgent", "urgent"}]},
    {:date, "start_date", "Start date"},
    {:date, "target_date", "Target date"}
  ]
end

def meta_fields_for("goal") do
  [
    {:select, "health", "Health",
     [{"Green", "green"}, {"Yellow", "yellow"}, {"Red", "red"}]},
    {:text, "metric", "Metric", placeholder: "e.g. MRR, users, uptime"},
    {:number, "target_value", "Target value", step: "0.01"},
    {:number, "current_value", "Current value", step: "0.01"},
    {:text, "unit", "Unit", placeholder: "e.g. %, USD, users"},
    {:number, "progress", "Progress (0.0-1.0)", step: "0.01", min: "0", max: "1"},
    {:date, "start_date", "Start date"},
    {:date, "target_date", "Target date"},
    {:text, "project_slug", "Project slug"}
  ]
end

def meta_fields_for("plan") do
  [
    {:select, "horizon", "Horizon", Enum.map(@horizons, &{String.capitalize(&1), &1})},
    {:select, "status", "Status", Enum.map(@plan_statuses, &{String.capitalize(&1), &1})},
    {:text, "period", "Period"},
    {:date, "due_date", "Due date"},
    {:text, "goal_slug", "Goal slug"},
    {:text, "project_slug", "Project slug"}
  ]
end

def meta_fields_for("todo") do
  [
    {:select, "kanban_status", "Status",
     [
       {"Backlog", "backlog"},
       {"This Week", "this_week"},
       {"Today", "today"},
       {"In Progress", "in_progress"},
       {"Done", "done"},
       {"Cancelled", "cancelled"}
     ]},
    {:select, "priority", "Priority",
     [{"Low", "low"}, {"Medium", "medium"}, {"High", "high"}, {"Urgent", "urgent"}]},
    {:date, "due_date", "Due date"},
    {:text, "project_slug", "Project slug"},
    {:text, "goal_slug", "Goal slug"},
    {:text, "plan_slug", "Plan slug"}
  ]
end

def meta_fields_for("note") do
  [
    {:select, "kind", "Kind", Enum.map(@note_kinds, &{String.capitalize(&1), &1})},
    {:date, "date", "Date"},
    {:text, "author", "Author"},
    # Campo condicional: solo se renderiza si kind == "reminder"
    {:date, "due_date", "Due date", condition: {:kind, "reminder"}}
  ]
end
```

> **Campo condicional en `meta_fields_for`:** la opción `condition: {:kind, "reminder"}` indica al renderer del form (en `PageEdit`) que solo muestre `due_date` si `kind == "reminder"`. Es un cambio puntual en el componente `.meta_fields` que ya existe en `lib/dran_web/components/page_components.ex` (o equivalente).

### 2.7 Accesores

```elixir
def note_kinds, do: @note_kinds
def project_statuses, do: @project_statuses
def plan_statuses, do: @plan_statuses
def health_sources, do: @health_sources
# ... los demás ya existen
```

### 2.8 Health derivado de project — funciones puras

El `health` de un project se **deriva** del promedio (floor) del health de sus goals vinculados. Override manual disponible vía `health_source: "manual"`.

```elixir
@health_scores %{"green" => 3, "yellow" => 2, "red" => 1}

@doc """
Deriva el health de un project a partir del health de sus goals.
Regla: promedio de scores (green=3, yellow=2, red=1) con floor.
Devuelve nil si no hay goals (no se recalcula).
"""
def derive_project_health([]), do: nil

def derive_project_health(goal_healths) when is_list(goal_healths) do
  scores =
    goal_healths
    |> Enum.map(&Map.get(@health_scores, &1))
    |> Enum.reject(&is_nil/1)

  case scores do
    [] -> nil
    list ->
      avg = Enum.sum(list) / length(list)
      score_to_health(floor(avg))
  end
end

defp score_to_health(3), do: "green"
defp score_to_health(2), do: "yellow"
defp score_to_health(_), do: "red"
```

### 2.9 Auto-progress de goal

El `progress` de un goal se **auto-calcula** desde sus todos vinculados: `% de todos con kanban_status == "done"`. Si el usuario setea `progress` manualmente, se respeta (override). Si no lo setea, se recalcula al cambiar el kanban_status de cualquier todo vinculado.

```elixir
@doc """
Calcula el progreso de un goal a partir de sus todos vinculados.
Regla: (todos done) / (todos totales no cancelados).
Devuelve nil si no hay todos.
"""
def derive_goal_progress([]), do: nil

def derive_goal_progress(todo_statuses) when is_list(todo_statuses) do
  relevant = Enum.reject(todo_statuses, &(&1 == "cancelled"))
  case relevant do
    [] -> nil
    list ->
      done = Enum.count(list, &(&1 == "done"))
      done / length(list)
  end
end
```

> **Decisión:** el auto-progress se calcula en `brain.ex` al crear/editar un todo con `goal_slug`, no en el changeset de goal. Ver §3.2.

### 2.10 Migración de datos — Opción B (limpieza directa SQL)

No hay producción. Local se resetea. Scripts de limpieza:

```bash
# 1. Limpiar status viejo de plans (tenía 5 valores, ahora 4)
psql -d dran_dev -c "UPDATE pages SET meta = meta - 'status' WHERE page_type = 'plan';"

# 2. Goals existentes: si no tienen metric, no requieren backfill (campos nuevos son nil).
# 3. Projects nuevos: empiezan con health_source: "derived" por defecto.
# 4. Notes con kind reminder: el campo due_date ya existe en el schema (compartido con todo/plan),
#    no requiere migración de schema.
```

**Verificación post-limpieza:**

```bash
cd ~/Repos/dran && mix ecto.migrate   # debe decir "already up"
psql -d dran_dev -c "SELECT count(*) FROM pages WHERE page_type = 'plan' AND meta ? 'status';"
# debe regresar 0
```

---

## 3. `sync_todo_links/2` — reemplaza `sync_planning_relations/2`

Reemplaza la función actual en `lib/dran/brain.ex:809-845`. **Sin precedencia.** Cada slug se sincroniza de forma independiente.

### 3.1 Firma y dispatch

```elixir
@doc """
Sincroniza los vínculos `part_of` de una página con sus slugs en meta.
Sin precedencia: project_slug, goal_slug y plan_slug son independientes.
Cada uno materializa su propia relación part_of si está seteado, y se borra
si se quita. Si la página objetivo no existe, no se crea la relación (el lint
lo reportará).

Invocada desde create_page/1 y update_page/2.
"""
def sync_todo_links(page, prior_page \\ nil)

# Aplica a todos los tipos: cualquier página puede tener vínculos.
def sync_todo_links(%Page{} = page, prior_page) do
  context_id = page.context_id

  sync_one_link(page.slug, "project_slug", page.meta, prior_page && prior_page.meta, context_id)
  sync_one_link(page.slug, "goal_slug",    page.meta, prior_page && prior_page.meta, context_id)
  sync_one_link(page.slug, "plan_slug",    page.meta, prior_page && prior_page.meta, context_id)

  # Recalcular health de project padre si la página es un goal con project_slug
  maybe_recompute_parent_project(page, prior_page, context_id)

  # Recalcular progress de goal padre si la página es un todo con goal_slug
  maybe_recompute_parent_goal_progress(page, prior_page, context_id)

  :ok
end
```

### 3.2 `sync_one_link/5` — sincroniza un vínculo individual

```elixir
# Sincroniza un único vínculo (project_slug, goal_slug o plan_slug).
# Compara el valor actual con el previo; si cambiaron, borra la relación vieja
# y crea la nueva. Si ambos son nil o iguales, no hace nada.
defp sync_one_link(source_slug, key, current_meta, prior_meta, context_id) do
  current = meta_string(current_meta, key)
  prior = if prior_meta, do: meta_string(prior_meta, key), else: nil

  cond do
    current == prior ->
      :ok

    is_nil(current) or current == "" ->
      # El vínculo se quitó: borrar la relación previa.
      delete_relation_by_slugs(source_slug, prior, "part_of", context_id)
      :ok

    true ->
      # El vínculo cambió o se creó: borrar el previo (si lo había), crear el nuevo.
      delete_relation_by_slugs(source_slug, prior, "part_of", context_id)
      create_relation_by_slugs(source_slug, current, "part_of", context_id)
      :ok
  end
end
```

### 3.3 Helpers existentes (se mantienen)

`meta_string/2`, `create_relation_by_slugs/4`, `delete_relation_by_slugs/4` ya existen en `brain.ex` y se usan tal cual. `maybe_drop_planning_part_of/4` y `ensure_part_of/3` **se eliminan** — ya no son necesarios con `sync_one_link/5`.

### 3.4 Recálculo de health de project

```elixir
defp maybe_recompute_parent_project(page, prior_page, context_id) do
  # Solo recalcular si la página es un goal (su health alimenta el project)
  if page.page_type != "goal" do
    :ok
  else
    project_slug = meta_string(page.meta, "project_slug")

    if blank?(project_slug) do
      :ok
    else
      health_changed? =
        prior_page &&
          meta_string(page.meta, "health") != meta_string(prior_page.meta, "health")

      project_changed? =
        prior_page &&
          meta_string(page.meta, "project_slug") != meta_string(prior_page.meta, "project_slug")

      if is_nil(prior_page) or health_changed? or project_changed? do
        case fetch_page_by_slug(project_slug, context_id) do
          nil -> :ok
          project_page -> recompute_project_health(project_page, context_id)
        end
      end
    end
  end
end

def recompute_project_health(project_page, context_id) do
  if PageMeta.meta_get(project_page.meta, "health_source") == "manual" do
    :ok
  else
    goal_healths =
      project_page.slug
      |> list_goal_healths_for_project(context_id)

    case PageMeta.derive_project_health(goal_healths) do
      nil -> :ok
      derived ->
        update_page_meta_field(project_page, "health", derived)
        update_page_meta_field(project_page, "health_source", "derived")
    end
  end
end

defp list_goal_healths_for_project(project_slug, context_id) do
  context_id
  |> list_pages(type: "goal", include_body: false, limit: 500)
  |> Enum.filter(fn g -> meta_string(g.meta, "project_slug") == project_slug end)
  |> Enum.map(fn g -> meta_string(g.meta, "health") end)
  |> Enum.reject(&is_nil/1)
end

defp update_page_meta_field(page, key, value) do
  new_meta = Map.put(page.meta || %{}, key, value)
  update_page(page, %{"meta" => new_meta})
  :ok
end
```

### 3.5 Recálculo de progress de goal

```elixir
defp maybe_recompute_parent_goal_progress(page, prior_page, context_id) do
  # Solo recalcular si la página es un todo (su kanban_status alimenta el progress del goal)
  if page.page_type != "todo" do
    :ok
  else
    goal_slug = meta_string(page.meta, "goal_slug")

    if blank?(goal_slug) do
      :ok
    else
      status_changed? =
        prior_page &&
          meta_string(page.meta, "kanban_status") != meta_string(prior_page.meta, "kanban_status")

      goal_changed? =
        prior_page &&
          meta_string(page.meta, "goal_slug") != meta_string(prior_page.meta, "goal_slug")

      if is_nil(prior_page) or status_changed? or goal_changed? do
        case fetch_page_by_slug(goal_slug, context_id) do
          nil -> :ok
          goal_page -> recompute_goal_progress(goal_page, context_id)
        end
      end
    end
  end
end

def recompute_goal_progress(goal_page, context_id) do
  # Si el goal tiene progress seteado manualmente, respetarlo (no override).
  # Para distinguir manual vs auto: usamos un campo implícito — si progress es nil
  # o el meta no tiene "progress_manual" flag, se recalcula.
  # Simplificación: si el usuario setea progress, se respeta hasta que lo ponga en nil.
  if PageMeta.meta_get(goal_page.meta, "progress_manual") == true do
    :ok
  else
    todo_statuses =
      goal_page.slug
      |> list_todo_statuses_for_goal(context_id)

    case PageMeta.derive_goal_progress(todo_statuses) do
      nil -> :ok
      derived -> update_page_meta_field(goal_page, "progress", Float.round(derived, 2))
    end
  end
end

defp list_todo_statuses_for_goal(goal_slug, context_id) do
  context_id
  |> list_pages(type: "todo", include_body: false, limit: 1000)
  |> Enum.filter(fn t -> meta_string(t.meta, "goal_slug") == goal_slug end)
  |> Enum.map(fn t -> meta_string(t.meta, "kanban_status") end)
  |> Enum.reject(&is_nil/1)
end
```

> **Flag `progress_manual`:** cuando el usuario setea `progress` en el form, se setea `progress_manual: true` en el meta. Para volver a auto, el usuario borra el campo y `progress_manual` se quita. Es un campo no validado (no está en el schema embebido, pero `meta` es `:map` libre — se acepta cualquier clave extra).

### 3.6 Integración en `create_page/1` y `update_page/2`

Reemplazar las dos llamadas a `sync_planning_relations`:

```elixir
# lib/dran/brain.ex:383 (en create_page)
sync_todo_links(page)

# lib/dran/brain.ex:467 (en update_page)
sync_todo_links(updated_page, page)
```

> **Nombre de la función:** aunque `sync_todo_links` suene a "solo todos", aplica a cualquier página (cualquier tipo puede tener vínculos). El nombre se mantiene por consistencia con el concepto "los vínculos son de tipo todo-like" — pero si se prefiere más exacto, `sync_page_links/2` también es válido. Elegimos `sync_todo_links` porque el caso de uso principal es el kanban de todos.

---

## 4. Kanban global — `KanbanLive`

Nuevo LiveView en `lib/dran_web/live/kanban_live.ex`. Es la entrada principal del sidebar para gestión de todos.

### 4.1 Características

- **6 columnas** (las mismas de `goal_live.ex:14-21`): backlog, this_week, today, in_progress, done, cancelled.
- **3 filtros combinables** arriba: Project, Goal, Plan. Cada uno es un `<select>` con opciones `[All, None, <lista de slugs>]`.
- **Badges discretos** en cada card (máximo 2 visibles): color por tipo (project=azul, goal=verde, plan=púrpura). Hover muestra tooltip con el slug completo. Click en un badge aplica ese filtro.
- **Drag-drop** entre columnas — actualiza `kanban_status` en `meta`.
- **Click en card** navega a `/todos/:slug`.

### 4.2 Código completo

```elixir
defmodule DranWeb.KanbanLive do
  @moduledoc """
  Global kanban board for all todos. Filters by project_slug, goal_slug,
  plan_slug (combinable). Drag-drop updates kanban_status.
  """
  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.Brain.PageMeta
  alias DranWeb.Plugs.Auth

  @kanban_columns [
    {"backlog", "Backlog", "bg-base-300"},
    {"this_week", "This Week", "bg-blue-500/20 text-blue-700"},
    {"today", "Today", "bg-amber-500/20 text-amber-700"},
    {"in_progress", "In Progress", "bg-purple-500/20 text-purple-700"},
    {"done", "Done", "bg-green-500/20 text-green-700"},
    {"cancelled", "Cancelled", "bg-red-500/20 text-red-700"}
  ]

  # Colores de badges por tipo de vínculo
  @badge_styles %{
    "project" => "bg-blue-100 text-blue-700 hover:bg-blue-200",
    "goal"    => "bg-green-100 text-green-700 hover:bg-green-200",
    "plan"    => "bg-purple-100 text-purple-700 hover:bg-purple-200"
  }

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav="kanban"
    >
      <div class="px-4 py-3">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-xl font-semibold">Kanban</h1>
          <.link navigate={~p"/todos/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> New Todo
          </.link>
        </div>

        <%!-- Filtros combinables ──%>
        <div class="flex flex-wrap gap-3 mb-4 p-3 rounded-lg bg-base-200/50 border border-base-300">
          <.filter_select
            label="Project"
            id="filter-project"
            value={@filter_project}
            options={@filter_project_options}
            phx-change="filter_project"
          />
          <.filter_select
            label="Goal"
            id="filter-goal"
            value={@filter_goal}
            options={@filter_goal_options}
            phx-change="filter_goal"
          />
          <.filter_select
            label="Plan"
            id="filter-plan"
            value={@filter_plan}
            options={@filter_plan_options}
            phx-change="filter_plan"
          />
          <button
            :if={@filter_project != "all" or @filter_goal != "all" or @filter_plan != "all"}
            phx-click="clear_filters"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-x-mark" class="size-4" /> Clear
          </button>
          <div class="ml-auto text-sm text-base-content/60 self-center">
            {@filtered_count} todos
          </div>
        </div>

        <%!-- Board ──%>
        <div
          class="flex gap-4 overflow-x-auto pb-4"
          phx-hook="KanbanDragDrop"
          id="kanban-board"
        >
          <div
            :for={{status, label, badge_class} <- @kanban_columns}
            data-kanban-status={status}
            class="w-72 shrink-0 flex flex-col rounded-lg bg-base-200/40 border border-base-300"
          >
            <div class="flex items-center justify-between px-3 py-2 border-b border-base-300">
              <span class="text-sm font-semibold">{label}</span>
              <span class={"px-2 py-0.5 text-xs rounded-full " <> badge_class}>
                {column_count(@filtered_todos, status)}
              </span>
            </div>
            <div class="p-2 space-y-2 min-h-[200px] flex-1 overflow-y-auto">
              <div
                :for={todo <- column_items(@filtered_todos, status)}
                data-kanban-slug={todo.slug}
                draggable="true"
                phx-click="show_page"
                phx-value-slug={todo.slug}
                class="p-3 rounded-lg bg-base-100 border border-base-300 shadow-sm cursor-grab hover:shadow-md hover:border-primary/40 active:cursor-grabbing transition"
              >
                <div class="font-medium text-sm break-words">{todo.title}</div>

                <%!-- Badges de vínculos (máximo 2 visibles) ──%>
                <div class="flex flex-wrap items-center gap-1.5 mt-2">
                  <%= for {badge, idx} <- visible_badges(todo) do %>
                    <span
                      class={"px-1.5 py-0.5 text-[11px] rounded cursor-pointer " <> Map.get(@badge_styles, badge.type, "bg-base-300")}
                      title={badge.slug}
                      phx-click="filter_by_badge"
                      phx-value-type={badge.type}
                      phx-value-slug={badge.slug}
                      onclick="event.stopPropagation();"
                    >
                      {badge.label}
                    </span>
                  <% end %>
                  <span
                    :if={extra_badge_count(todo) > 0}
                    class="px-1.5 py-0.5 text-[11px] rounded bg-base-300 text-base-content/60"
                    title={extra_badge_titles(todo)}
                  >
                    +{extra_badge_count(todo)}
                  </span>
                </div>

                <div :if={due_date(todo)} class={due_date_class(overdue?(todo))}>
                  <.icon name="hero-calendar-days" class="size-3.5" />
                  {format_due(due_date(todo))}
                </div>
              </div>
              <p
                :if={column_items(@filtered_todos, status) == []}
                class="text-xs text-base-content/30 text-center py-4"
              >
                Empty
              </p>
            </div>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name="KanbanDragDrop">
        export default {
          mounted() {
            this.draggedSlug = null;
            const board = this.el;

            board.addEventListener("dragstart", (e) => {
              const card = e.target.closest("[data-kanban-slug]");
              if (card) {
                this.draggedSlug = card.dataset.kanbanSlug;
                e.dataTransfer.effectAllowed = "move";
              }
            });

            board.addEventListener("dragover", (e) => {
              if (e.target.closest("[data-kanban-status]")) {
                e.preventDefault();
                e.dataTransfer.dropEffect = "move";
              }
            });

            board.addEventListener("drop", (e) => {
              const col = e.target.closest("[data-kanban-status]");
              if (col !== null && this.draggedSlug !== null) {
                e.preventDefault();
                this.pushEvent("move_todo", {
                  slug: this.draggedSlug,
                  target_status: col.dataset.kanbanStatus
                });
              }
              this.draggedSlug = null;
            });

            board.addEventListener("dragend", () => {
              this.draggedSlug = null;
            });
          }
        }
      </script>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      assign(socket,
        context: context,
        kanban_columns: @kanban_columns,
        badge_styles: @badge_styles,
        filter_project: "all",
        filter_goal: "all",
        filter_plan: "all",
        filter_project_options: [],
        filter_goal_options: [],
        filter_plan_options: [],
        filtered_todos: [],
        filtered_count: 0
      )

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    context = socket.assigns.context

    if context do
      all_todos =
        Brain.list_pages(
          context_id: context.id,
          type: "todo",
          include_body: false,
          limit: 1000
        )

      project_slugs = Brain.list_pages(context_id: context.id, type: "project", limit: 200)
      goal_slugs = Brain.list_pages(context_id: context.id, type: "goal", limit: 200)
      plan_slugs = Brain.list_pages(context_id: context.id, type: "plan", limit: 200)

      socket =
        socket
        |> assign(all_todos: all_todos)
        |> assign(
          filter_project_options: build_filter_options(project_slugs),
          filter_goal_options: build_filter_options(goal_slugs),
          filter_plan_options: build_filter_options(plan_slugs)
        )
        |> recompute_filtered_todos()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Filtros ──

  def handle_event("filter_project", %{"value" => value}, socket) do
    {:noreply, socket |> assign(filter_project: value) |> recompute_filtered_todos()}
  end

  def handle_event("filter_goal", %{"value" => value}, socket) do
    {:noreply, socket |> assign(filter_goal: value) |> recompute_filtered_todos()}
  end

  def handle_event("filter_plan", %{"value" => value}, socket) do
    {:noreply, socket |> assign(filter_plan: value) |> recompute_filtered_todos()}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(filter_project: "all", filter_goal: "all", filter_plan: "all")
      |> recompute_filtered_todos()

    {:noreply, socket}
  end

  def handle_event("filter_by_badge", %{"type" => type, "slug" => slug}, socket) do
    socket =
      case type do
        "project" -> assign(socket, filter_project: slug)
        "goal"    -> assign(socket, filter_goal: slug)
        "plan"    -> assign(socket, filter_plan: slug)
        _ -> socket
      end
      |> recompute_filtered_todos()

    {:noreply, socket}
  end

  # ── Drag-drop ──

  def handle_event("move_todo", %{"slug" => slug, "target_status" => status}, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Todo not found.")}

        todo ->
          new_meta = Map.put(todo.meta || %{}, "kanban_status", status)

          case Brain.update_page(todo, %{"meta" => new_meta}) do
            {:ok, _updated} ->
              {:noreply, recompute_filtered_todos(socket)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Could not update todo status.")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/todos/#{slug}")}
  end

  # ── Helpers de filtrado ──

  defp recompute_filtered_todos(socket) do
    todos =
      socket.assigns.all_todos
      |> filter_by_slug(:project, socket.assigns.filter_project)
      |> filter_by_slug(:goal, socket.assigns.filter_goal)
      |> filter_by_slug(:plan, socket.assigns.filter_plan)

    socket
    |> assign(filtered_todos: todos, filtered_count: length(todos))
  end

  defp filter_by_slug(todos, _type, "all"), do: todos

  defp filter_by_slug(todos, type, "none") do
    key = "#{type}_slug"
    Enum.reject(todos, fn t ->
      v = meta_get(t.meta, key)
      v != nil and v != ""
    end)
  end

  defp filter_by_slug(todos, type, slug) do
    key = "#{type}_slug"
    Enum.filter(todos, fn t -> meta_get(t.meta, key) == slug end)
  end

  defp build_filter_options(pages) do
    [{"All", "all"}, {"None (orphan)", "none"}] ++
      Enum.map(pages, fn p -> {p.title, p.slug} end)
  end

  # ── Helpers de card ──

  defp meta_get(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp meta_get(nil, _key), do: nil

  defp kanban_status(page) do
    case meta_get(page.meta, "kanban_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  defp column_items(todos, status) do
    Enum.filter(todos, fn t -> kanban_status(t) == status end)
  end

  defp column_count(todos, status) do
    Enum.count(todos, fn t -> kanban_status(t) == status end)
  end

  # Construye la lista de badges de un todo. Máximo 2 visibles, resto en +N.
  defp visible_badges(todo) do
    todo
    |> all_badges()
    |> Enum.take(2)
    |> Enum.with_index(fn badge, idx -> {badge, idx} end)
  end

  defp all_badges(todo) do
    []
    |> maybe_add_badge("project", meta_get(todo.meta, "project_slug"))
    |> maybe_add_badge("goal",    meta_get(todo.meta, "goal_slug"))
    |> maybe_add_badge("plan",    meta_get(todo.meta, "plan_slug"))
  end

  defp maybe_add_badge(list, _type, nil), do: list
  defp maybe_add_badge(list, _type, ""), do: list
  defp maybe_add_badge(list, type, slug) do
    label = String.slice(slug, 0, 12)
    [%{type: type, slug: slug, label: label} | list]
  end

  defp extra_badge_count(todo) do
    max(0, length(all_badges(todo)) - 2)
  end

  defp extra_badge_titles(todo) do
    todo
    |> all_badges()
    |> Enum.drop(2)
    |> Enum.map(fn b -> "#{b.type}: #{b.slug}" end)
    |> Enum.join(", ")
  end

  defp due_date(page), do: meta_get(page.meta, "due_date")

  defp overdue?(page) do
    case due_date(page) do
      s when is_binary(s) and s != "" ->
        case Date.from_iso8601(s) do
          {:ok, d} -> Date.compare(d, Date.utc_today()) == :lt
          _ -> false
        end
      _ -> false
    end
  end

  defp format_due(nil), do: ""
  defp format_due(""), do: ""
  defp format_due(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> Calendar.strftime(d, "%b %d")
      _ -> s
    end
  end

  defp due_date_class(true),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-red-600 font-medium"
  defp due_date_class(false),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-base-content/60"

  # ── Componente de filtro ──

  attr :label, :string, required: true
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :phx_change, :string, required: true

  defp filter_select(assigns) do
    ~H"""
    <div class="flex flex-col">
      <label for={@id} class="text-xs font-medium text-base-content/60 mb-1">{@label}</label>
      <select
        id={@id}
        class="px-2 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100"
        phx-change={@phx_change}
      >
        <%!-- El value se setea via JS o con selected en option ──%>
        <%= for {label, value} <- @options do %>
          <option value={value} selected={value == @value}>{label}</option>
        <% end %>
      </select>
    </div>
    """
  end
end
```

### 4.3 Ruta en `router.ex`

```elixir
# Antes del bloque de Knowledge
live "/kanban", KanbanLive, :index
```

---

## 5. `ProjectLive` — dashboard con tabs

Nuevo LiveView en `lib/dran_web/live/project_live.ex`. **No kanban** — el kanban vive en `/kanban`. ProjectLive es un dashboard ejecutivo con 6 tabs.

### 5.1 Tabs

```
ProjectLive
├── Overview   ← body markdown + meta (status, health derivado, priority, target_date)
├── Todos      ← lista de todos con meta.project_slug == page.slug (link a /kanban?project=slug)
├── Goals      ← lista de goals con meta.project_slug == page.slug + health
├── Plans      ← lista de plans con meta.project_slug == page.slug
├── Graph      ← subgrafo del project
└── Related    ← notes/concepts/entities/references con meta.project_slug (vista combinada)
```

### 5.2 Código (estructura clave — omite HEEx repetido del form)

```elixir
defmodule DranWeb.ProjectLive do
  @moduledoc """
  Dashboard LiveView for project pages. Tabs: Overview, Todos, Goals,
  Plans, Graph, Related. No kanban — the global /kanban view handles that.
  """
  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.Brain.PageMeta
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @page_type "project"

  @project_tabs [
    {"overview", "Overview"},
    {"todos", "Todos"},
    {"goals", "Goals"},
    {"plans", "Plans"},
    {"graph", "Graph"},
    {"related", "Related"}
  ]

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav="projects"
    >
      <div :if={@live_action == :show}>
        <.page_detail
          page={@page}
          relations={@relations}
          versions={@versions}
          compare_version={@compare_version}
          logs={@logs}
          context_slug={@context_slug}
          rendered_body={@rendered_body}
        >
          <:actions>
            <.link navigate={~p"/projects"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
            <.link navigate={~p"/kanban?project=#{@page.slug}"} class="btn btn-ghost btn-sm">
              <.icon name="hero-view-columns" class="size-4" /> View in Kanban
            </.link>
            <button :if={not @editing} phx-click="toggle_edit" class="btn btn-primary btn-sm">
              <.icon name="hero-pencil" class="size-4" /> Edit
            </button>
            <button :if={@editing} phx-click="save_page" class="btn btn-success btn-sm">
              <.icon name="hero-check" class="size-4" /> Save
            </button>
            <button :if={@editing} phx-click="cancel_edit" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="size-4" /> Cancel
            </button>
          </:actions>

          <:tabs>
            <div class="border-b border-base-300 mb-4">
              <div class="flex gap-1">
                <button
                  :for={{tab, label} <- @project_tabs}
                  phx-click="switch_tab"
                  phx-value-tab={tab}
                  class={
                    "px-3 py-2 text-sm font-medium border-b-2 " <>
                      if @active_tab == tab,
                        do: "border-primary text-primary",
                        else: "border-transparent text-base-content/60 hover:text-base-content"
                  }
                >
                  {label}
                </button>
              </div>
            </div>

            <%!-- Overview: body + meta + health derivado badge ──%>
            <div :if={@active_tab == "overview"}>
              <%!-- Health badge destacado ──%>
              <div class="flex items-center gap-3 mb-4">
                <span class={"px-3 py-1 rounded-full text-sm font-medium " <> health_badge_class(@page)}>
                  Health: {String.capitalize(meta_get(@page.meta, "health") || "—")}
                </span>
                <span class="text-xs text-base-content/60">
                  Source: {meta_get(@page.meta, "health_source") || "derived"}
                </span>
              </div>

              <%= if @editing do %>
                <.form for={@form} id="page-edit-form" phx-change="validate_page" phx-submit="save_page">
                  <div class="space-y-5">
                    <.input field={@form[:title]} type="text" label="Title" class="text-lg font-medium" />
                    <div class="grid grid-cols-2 gap-4">
                      <.input field={@form[:slug]} type="text" label="Slug" class="font-mono text-sm" />
                      <.input field={@form[:summary]} type="text" label="Summary" />
                    </div>
                    <.input field={@form[:tags]} type="text" label="Tags" />
                    <.meta_fields page_type={@page_type} meta={@page.meta || %{}} />
                    <.markdown_editor id="project-editor" body={@page.body}
                      context_id={@context_id} save_status={@save_status} />
                    <div class="flex justify-end gap-2 pt-2 border-t border-base-300">
                      <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
                      <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    </div>
                  </div>
                </.form>
              <% else %>
                <div class="prose prose-base dark:prose-invert max-w-none">
                  {@rendered_body}
                </div>
              <% end %>
            </div>

            <%!-- Todos: lista (no kanban) ──%>
            <div :if={@active_tab == "todos"}>
              <div class="flex items-center justify-between mb-3">
                <span class="text-sm text-base-content/60">{length(@project_todos)} todos linked</span>
                <.link navigate={~p"/kanban?project=#{@page.slug}"} class="btn btn-ghost btn-xs">
                  Open in Kanban →
                </.link>
              </div>
              <div :for={todo <- @project_todos} class="p-3 rounded-lg border border-base-300 mb-2 hover:border-primary/40 transition">
                <div class="flex items-center justify-between">
                  <.link navigate={PageTypes.page_show_path(todo)} class="font-medium text-primary hover:underline">
                    {todo.title}
                  </.link>
                  <span class={"px-2 py-0.5 text-xs rounded " <> kanban_status_class(todo)}>
                    {String.capitalize(kanban_status(todo))}
                  </span>
                </div>
                <div :if={todo.summary} class="text-xs text-base-content/60 mt-1">{todo.summary}</div>
              </div>
              <p :if={@project_todos == []} class="text-sm text-base-content/40">
                No todos linked to this project.
              </p>
            </div>

            <%!-- Goals: lista con health ──%>
            <div :if={@active_tab == "goals"}>
              <div :for={goal <- @project_goals} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link navigate={PageTypes.page_show_path(goal)} class="font-medium text-primary hover:underline">
                    {goal.title}
                  </.link>
                  <span class={"px-2 py-0.5 text-xs rounded " <> health_class(goal)}>
                    {String.capitalize(meta_get(goal.meta, "health") || "—")}
                  </span>
                </div>
                <div :if={goal.summary} class="text-xs text-base-content/60 mt-1">{goal.summary}</div>
              </div>
              <p :if={@project_goals == []} class="text-sm text-base-content/40">
                No goals linked to this project.
              </p>
            </div>

            <%!-- Plans: lista con status + due_date ──%>
            <div :if={@active_tab == "plans"}>
              <div :for={plan <- @project_plans} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link navigate={PageTypes.page_show_path(plan)} class="font-medium text-primary hover:underline">
                    {plan.title}
                  </.link>
                  <span class="px-2 py-0.5 text-xs rounded bg-base-300 text-base-content/70">
                    {String.capitalize(meta_get(plan.meta, "status") || "draft")}
                  </span>
                </div>
                <div class="text-xs text-base-content/60 mt-1 flex gap-3">
                  <span>{String.capitalize(meta_get(plan.meta, "horizon") || "")}</span>
                  <span :if={meta_get(plan.meta, "period")}>{meta_get(plan.meta, "period")}</span>
                  <span :if={meta_get(plan.meta, "due_date")}>
                    Due: {meta_get(plan.meta, "due_date")}
                  </span>
                </div>
              </div>
              <p :if={@project_plans == []} class="text-sm text-base-content/40">
                No plans linked to this project.
              </p>
            </div>

            <%!-- Graph: subgrafo ──%>
            <div :if={@active_tab == "graph"}>
              <.page_graph id="project-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
            </div>

            <%!-- Related: combinado notes/concepts/entities/references ──%>
            <div :if={@active_tab == "related"}>
              <div class="grid grid-cols-2 gap-4">
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">NOTES ({length(@project_notes)})</h4>
                  <div :for={n <- @project_notes} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(n)} class="text-primary hover:underline">{n.title}</.link>
                  </div>
                </div>
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">CONCEPTS ({length(@project_concepts)})</h4>
                  <div :for={c <- @project_concepts} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(c)} class="text-primary hover:underline">{c.title}</.link>
                  </div>
                </div>
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">ENTITIES ({length(@project_entities)})</h4>
                  <div :for={e <- @project_entities} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(e)} class="text-primary hover:underline">{e.title}</.link>
                  </div>
                </div>
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">REFERENCES ({length(@project_references)})</h4>
                  <div :for={r <- @project_references} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(r)} class="text-primary hover:underline">{r.title}</.link>
                  </div>
                </div>
              </div>
            </div>
          </:tabs>
        </.page_detail>
      </div>

      <div :if={@live_action != :show}>
        <.page_list pages={@pages} page_type={@page_type} context_slug={@context_slug} />
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      if context do
        allow_upload(socket, :file,
          accept: ~w(image/* video/* audio/* application/pdf text/plain text/markdown text/csv text/html application/json application/zip),
          max_file_size: Dran.Uploads.max_size(),
          auto_upload: true,
          progress: &handle_progress/3
        )
      else
        socket
      end

    {:ok,
     assign(socket,
       context: context,
       page_type: @page_type,
       project_tabs: @project_tabs,
       active_tab: "overview",
       editing: false,
       save_status: "idle"
     )}
  end

  def handle_params(%{"slug" => slug} = _params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/projects")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)

          # Cargar todas las sub-páginas filtrando por project_slug
          project_todos    = filter_by_slug(context.id, "todo", "project_slug", page.slug)
          project_goals    = filter_by_slug(context.id, "goal", "project_slug", page.slug)
          project_plans    = filter_by_slug(context.id, "plan", "project_slug", page.slug)
          project_notes    = filter_by_slug(context.id, "note", "project_slug", page.slug)
          project_concepts = filter_by_slug(context.id, "concept", "project_slug", page.slug)
          project_entities = filter_by_slug(context.id, "entity", "project_slug", page.slug)
          project_references = filter_by_slug(context.id, "reference", "project_slug", page.slug)

          rendered_body =
            render_markdown(page.body,
              context_id: page.context_id,
              inline_links: Map.get(page.meta || %{}, "inline_links", [])
            )

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             compare_version: nil,
             logs: logs,
             page_title: page.title,
             active_tab: "overview",
             context_id: context.id,
             project_todos: project_todos,
             project_goals: project_goals,
             project_plans: project_plans,
             project_notes: project_notes,
             project_concepts: project_concepts,
             project_entities: project_entities,
             project_references: project_references,
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/projects")}
    end
  end

  def handle_params(_params, _url, socket) do
    pages =
      if socket.assigns.context do
        Brain.list_pages(context_id: socket.assigns.context.id, type: @page_type)
      else
        []
      end

    {:noreply, assign(socket, pages: pages, page_title: "Projects")}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("node_click", %{"slug" => slug}, socket),
    do: {:noreply, node_click(socket, slug)}

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket),
    do: {:noreply, node_drag(socket, id, x, y)}

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/projects/new")}

  def handle_event("toggle_edit", p, s), do: PageEdit.handle_event("toggle_edit", p, s)
  def handle_event("cancel_edit", p, s), do: PageEdit.handle_event("cancel_edit", p, s)
  def handle_event("validate_page", p, s), do: PageEdit.handle_event("validate_page", p, s)
  def handle_event("save_page", p, s), do: PageEdit.handle_event("save_page", p, s)
  def handle_event("body_change", p, s), do: PageEdit.handle_event("body_change", p, s)
  def handle_event("field_change", p, s), do: PageEdit.handle_event("field_change", p, s)
  def handle_event("request_upload", p, s), do: PageEdit.handle_event("request_upload", p, s)
  def handle_event("upload_complete", p, s), do: PageEdit.handle_event("upload_complete", p, s)

  def handle_event("compare_version", params, socket),
    do: DranWeb.VersionCompare.handle_event("compare_version", params, socket)

  def handle_event("clear_compare", params, socket),
    do: DranWeb.VersionCompare.handle_event("clear_compare", params, socket)

  defp handle_progress(:file, _entry, socket), do: {:noreply, socket}

  # ── Helpers ──

  defp meta_get(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp meta_get(nil, _key), do: nil

  defp filter_by_slug(context_id, type, slug_key, slug_value) do
    context_id
    |> Brain.list_pages(type: type, include_body: false, limit: 500)
    |> Enum.filter(fn p -> meta_get(p.meta, slug_key) == slug_value end)
  end

  defp kanban_status(page) do
    case meta_get(page.meta, "kanban_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  defp kanban_status_class(page) do
    case kanban_status(page) do
      "done"        -> "bg-green-100 text-green-700"
      "in_progress" -> "bg-purple-100 text-purple-700"
      "today"       -> "bg-amber-100 text-amber-700"
      "this_week"   -> "bg-blue-100 text-blue-700"
      "cancelled"   -> "bg-red-100 text-red-700"
      _             -> "bg-base-300 text-base-content/60"
    end
  end

  defp health_class(page) do
    case meta_get(page.meta, "health") do
      "green"  -> "bg-green-100 text-green-700"
      "yellow" -> "bg-yellow-100 text-yellow-700"
      "red"    -> "bg-red-100 text-red-700"
      _        -> "bg-base-300 text-base-content/60"
    end
  end

  defp health_badge_class(page) do
    case meta_get(page.meta, "health") do
      "green"  -> "bg-green-500/20 text-green-700"
      "yellow" -> "bg-yellow-500/20 text-yellow-700"
      "red"    -> "bg-red-500/20 text-red-700"
      _        -> "bg-base-300 text-base-content/60"
    end
  end
end
```

### 5.3 Ruta en `router.ex`

```elixir
live "/projects", ProjectLive, :index
live "/projects/new", PageNewLive, :new
live "/projects/:slug", ProjectLive, :show
```

### 5.4 Soporte de query params en `/kanban`

Para que el link "Open in Kanban" de ProjectLive filtre automáticamente, `KanbanLive.handle_params/3` debe leer query params `project`, `goal`, `plan`:

```elixir
def handle_params(params, _url, socket) do
  context = socket.assigns.context

  if context do
    socket =
      socket
      |> assign(
        filter_project: Map.get(params, "project", "all"),
        filter_goal: Map.get(params, "goal", "all"),
        filter_plan: Map.get(params, "plan", "all")
      )

    # ... cargar all_todos y options como arriba ...
    {:noreply, recompute_filtered_todos(socket)}
  else
    {:noreply, socket}
  end
end
```

---

## 6. `GoalLive` — modificar

Cambios sobre el `goal_live.ex` actual.

### 6.1 Quitar el kanban

- Eliminar `@kanban_columns` (líneas 14-21).
- Eliminar el hook JS `.GoalKanban` y su `<script>` block.
- Eliminar `handle_event("move_todo", ...)` (líneas 560-593).
- Eliminar todos los helpers `goal_kanban_status/1`, `goal_column_items/2`, `goal_column_count/2` y el código HEEx del tab "todos" que renderiza el kanban.
- Eliminar la carga de `goal_todos` filtrados (se reemplaza por una lista simple).

### 6.2 Tab "Todos" como lista (no kanban)

```elixir
<%!-- Todos: lista simple con link a kanban global ──%>
<div :if={@active_tab == "todos"}>
  <div class="flex items-center justify-between mb-3">
    <span class="text-sm text-base-content/60">{length(@goal_todos)} todos linked</span>
    <.link navigate={~p"/kanban?goal=#{@page.slug}"} class="btn btn-ghost btn-xs">
      Open in Kanban →
    </.link>
  </div>
  <div :for={todo <- @goal_todos} class="p-3 rounded-lg border border-base-300 mb-2">
    <div class="flex items-center justify-between">
      <.link navigate={PageTypes.page_show_path(todo)} class="font-medium text-primary hover:underline">
        {todo.title}
      </.link>
      <span class={"px-2 py-0.5 text-xs rounded " <> kanban_status_class(todo)}>
        {String.capitalize(kanban_status(todo))}
      </span>
    </div>
    <div :if={todo.summary} class="text-xs text-base-content/60 mt-1">{todo.summary}</div>
  </div>
  <p :if={@goal_todos == []} class="text-sm text-base-content/40">
    No todos linked to this goal.
  </p>
</div>
```

### 6.3 Mostrar progress + metric en Overview

En el tab Overview, añadir un panel de métricas antes del body:

```elixir
<%!-- Panel de métricas del goal ──%>
<div class="grid grid-cols-3 gap-4 mb-4 p-4 rounded-lg bg-base-200/50 border border-base-300">
  <div>
    <div class="text-xs text-base-content/60 uppercase">Metric</div>
    <div class="font-medium">{meta_get(@page.meta, "metric") || "—"}</div>
  </div>
  <div>
    <div class="text-xs text-base-content/60 uppercase">Current / Target</div>
    <div class="font-medium">
      {format_value(meta_get(@page.meta, "current_value"))}
      / {format_value(meta_get(@page.meta, "target_value"))}
      <span class="text-xs text-base-content/60">{meta_get(@page.meta, "unit")}</span>
    </div>
  </div>
  <div>
    <div class="text-xs text-base-content/60 uppercase">Progress</div>
    <div class="flex items-center gap-2">
      <div class="flex-1 bg-base-300 rounded-full h-2 overflow-hidden">
        <div class="bg-primary h-full" style={"width: #{progress_percent(@page)}%"}></div>
      </div>
      <span class="text-sm font-medium">{progress_percent(@page)}%</span>
    </div>
  </div>
</div>
```

Helpers nuevos en `goal_live.ex`:

```elixir
defp progress_percent(page) do
  case meta_get(page.meta, "progress") do
    nil -> 0
    v when is_number(v) -> round(v * 100)
    v when is_binary(v) ->
      case Float.parse(v) do
        {f, _} -> round(f * 100)
        :error -> 0
      end
    _ -> 0
  end
end

defp format_value(nil), do: "—"
defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
defp format_value(v), do: to_string(v)
```

### 6.4 Actualizar `meta_fields_for("goal")`

Ya cubierto en §2.6 — se añaden metric, target_value, current_value, unit, progress.

---

## 7. `PlanLive` — modificar

Cambios sobre el `plan_live.ex` actual (2 tabs: content, graph).

### 7.1 Añadir tab "Todos"

```elixir
@tabs [
  {"content", "Content"},
  {"todos", "Todos"},
  {"graph", "Graph"}
]
```

### 7.2 Cargar todos vinculados en `handle_params`

```elixir
plan_todos =
  filter_by_slug(context.id, "todo", "plan_slug", page.slug)

# añadir a assigns:
plan_todos: plan_todos
```

### 7.3 Render del tab Todos

Mismo patrón que en GoalLive — lista simple con link a `/kanban?plan=#{@page.slug}`.

### 7.4 Mostrar status + due_date en Overview

En el tab content, antes del body markdown:

```elixir
<div class="flex items-center gap-3 mb-4 text-sm">
  <span class={"px-2 py-0.5 rounded " <> plan_status_class(@page)}>
    {String.capitalize(meta_get(@page.meta, "status") || "draft")}
  </span>
  <span class="text-base-content/60">
    {String.capitalize(meta_get(@page.meta, "horizon") || "")}
    <span :if={meta_get(@page.meta, "period")}>· {meta_get(@page.meta, "period")}</span>
  </span>
  <span :if={meta_get(@page.meta, "due_date")} class="text-base-content/60">
    Due: {meta_get(@page.meta, "due_date")}
  </span>
</div>
```

Helper:

```elixir
defp plan_status_class(page) do
  case meta_get(page.meta, "status") do
    "active" -> "bg-green-100 text-green-700"
    "done"   -> "bg-blue-100 text-blue-700"
    "archived" -> "bg-base-300 text-base-content/60"
    _        -> "bg-amber-100 text-amber-700"  # draft
  end
end
```

---

## 8. Sidebar — `layouts.ex`

### 8.1 Nuevo orden

Reescribir el `groups` en `sidebar_nav/1` (`layouts.ex:178-332`):

```elixir
groups = [
  %{
    label: nil,
    items: [
      %{key: "dashboard", label: gettext("Dashboard"), icon: "hero-home", path: ~p"/", badge: counts[:dashboard]},
      %{key: "kanban", label: gettext("Kanban"), icon: "hero-view-columns", path: ~p"/kanban", badge: counts[:todos]},
      %{key: "projects", label: gettext("Projects"), icon: "hero-rocket-launch", path: ~p"/projects", badge: counts[:projects]},
      %{key: "graph", label: gettext("Graph"), icon: "hero-share", path: ~p"/graph", badge: counts[:graph]},
      %{key: "activity", label: gettext("Activity"), icon: "hero-clock", path: ~p"/activity", badge: counts[:activity]}
    ]
  },
  %{
    label: gettext("Knowledge"),
    items: [
      %{key: "notes", label: gettext("Notes"), icon: "hero-document-text", path: ~p"/notes", badge: counts[:notes]},
      %{key: "concepts", label: gettext("Concepts"), icon: "hero-light-bulb", path: ~p"/concepts", badge: counts[:concepts]},
      %{key: "entities", label: gettext("Entities"), icon: "hero-user-group", path: ~p"/entities", badge: counts[:entities]},
      %{key: "goals", label: gettext("Goals"), icon: "hero-flag", path: ~p"/goals", badge: counts[:goals]},
      %{key: "plans", label: gettext("Plans"), icon: "hero-clipboard-document-list", path: ~p"/plans", badge: counts[:plans]},
      %{key: "references", label: gettext("References"), icon: "hero-bookmark", path: ~p"/references", badge: counts[:references]}
    ]
  },
  %{
    label: gettext("Outputs"),
    items: [
      %{key: "artifacts", label: gettext("Artifacts"), icon: "hero-cube", path: ~p"/artifacts", badge: counts[:artifacts]},
      %{key: "comparisons", label: gettext("Comparisons"), icon: "hero-scale", path: ~p"/comparisons", badge: counts[:comparisons]}
    ]
  },
  %{
    label: gettext("Agents"),
    items: [
      %{key: "research", label: gettext("Research"), icon: "hero-beaker", path: ~p"/agents/research"},
      %{key: "ingest", label: gettext("Files Ingest"), icon: "hero-arrow-down-tray", path: ~p"/agents/ingest"}
    ]
  },
  %{
    label: gettext("Configs"),
    items: [
      %{key: "contexts", label: gettext("Contexts"), icon: "hero-rectangle-stack", path: ~p"/contexts", badge: counts[:contexts]},
      %{key: "settings", label: gettext("Settings"), icon: "hero-cog-6-tooth", path: ~p"/settings", badge: counts[:settings]}
    ]
  },
  %{
    label: gettext("Docs"),
    items: [
      %{key: "docs", label: gettext("Documentation"), icon: "hero-book-open", path: ~p"/docs"}
    ]
  }
]
```

### 8.2 `compute_counts/1` — añadir projects

```elixir
%{
  dashboard: stats[:total_pages] || 0,
  notes: by_type["note"] || 0,
  concepts: by_type["concept"] || 0,
  entities: by_type["entity"] || 0,
  references: by_type["reference"] || 0,
  queries: by_type["query"] || 0,
  projects: by_type["project"] || 0,   # NUEVO
  goals: by_type["goal"] || 0,
  plans: by_type["plan"] || 0,
  todos: by_type["todo"] || 0,
  artifacts: by_type["artifact"] || 0,
  comparisons: by_type["comparison"] || 0,
  contexts: contexts_count,
  graph: stats[:total_relations] || 0,
  activity: Dran.Brain.count_log(context.id)
}
```

### 8.3 Notas sobre el cambio

- **"Planning" desaparece** como categoría. Goals y Plans bajan a Knowledge. Projects sube al top (con Dashboard, Kanban, Graph, Activity).
- **Todos desaparece del sidebar** — su lugar es el Kanban. La ruta `/todos` sigue existiendo para el index/listado, pero no se linkea desde el sidebar.
- **Kanban aparece segundo** en el top-level, después de Dashboard. Es la entrada más usada después del dashboard.

---

## 9. Queries — Ecto JSONB para filtros

Todas las queries de filtrado por vínculos usan el patrón `fragment("meta->>'key' = ?", value)` sobre la columna JSONB `meta`.

### 9.1 Todos de un project

```elixir
from p in Page,
  where: p.page_type == "todo" and fragment("meta->>'project_slug' = ?", ^slug),
  order_by: [desc: p.updated_at]
```

### 9.2 Combinado project + goal

```elixir
from p in Page,
  where:
    p.page_type == "todo" and
    fragment("meta->>'project_slug' = ?", ^proj) and
    fragment("meta->>'goal_slug' = ?", ^goal),
  order_by: [desc: p.updated_at]
```

### 9.3 Sin vínculo (huérfano / inbox GTD)

```elixir
from p in Page,
  where:
    p.page_type == "todo" and
    fragment("meta->>'project_slug' IS NULL") and
    fragment("meta->>'goal_slug' IS NULL") and
    fragment("meta->>'plan_slug' IS NULL"),
  order_by: [desc: p.updated_at]
```

> **Nota:** `IS NULL` cubre tanto la ausencia de la clave como el valor NULL. Para cubrir también strings vacíos, usar `coalesce`:
> ```elixir
> fragment("coalesce(meta->>'project_slug', '') = ''")
> ```

### 9.4 Helper `filter_by_slug` en `Brain`

Extender `list_pages/1` para aceptar `:project_slug`:

```elixir
def list_pages(opts \\ []) do
  # ... ya existe goal_slug, plan_slug, añadir:
  project_slug = Keyword.get(opts, :project_slug)
  # ...
  |> maybe_filter_project_slug(project_slug)
end

defp maybe_filter_project_slug(query, nil), do: query

defp maybe_filter_project_slug(query, "none") do
  where(query, [p],
    is_nil(fragment("?->>'project_slug'", p.meta)) or
      fragment("?->>'project_slug'", p.meta) == ""
  )
end

defp maybe_filter_project_slug(query, project_slug) do
  where(query, [p], fragment("?->>'project_slug'", p.meta) == ^project_slug)
end
```

### 9.5 Query con índice GIN (recomendado)

Para que los filtros JSONB sean eficientes con volúmenes grandes:

```sql
CREATE INDEX IF NOT EXISTS pages_meta_gin_idx ON pages USING GIN (meta);
```

Esto acelera cualquier query `meta->>'key' = ?` y `meta @> '{"key": "value"}'`. Aplicable a la migración de Dran si no existe ya.

### 9.6 Query de health derivado de project (SQL)

```elixir
defp list_goal_healths_for_project(project_slug, context_id) do
  from(p in Page,
    where:
      p.context_id == ^context_id and
      p.page_type == "goal" and
      fragment("?->>'project_slug'", p.meta) == ^project_slug,
    select: fragment("?->>'health'", p.meta)
  )
  |> Repo.all()
  |> Enum.reject(&is_nil/1)
end
```

Más eficiente que cargar las páginas completas y filtrar en memoria (versión actual en §3.4). Usar esta versión en producción.

---

## 10. Plan de tareas

4 fases secuenciales. Cada fase termina con `mix compile --warnings-as-errors` + tests. Una task por subagente.

### Fase 1: Schema, validación y funciones puras (`page_meta.ex`)

**Task 1.1** — Añadir `:project_slug` al bloque Common del `embedded_schema` y a `all_fields/0` en `lib/dran/brain/page_meta.ex:20-86`.

**Task 1.2** — Añadir campos nuevos al schema:
- `:health_source` (project)
- `:metric`, `:target_value`, `:current_value`, `:unit`, `:progress` (goal)
- Añadir a `all_fields/0`

**Task 1.3** — Definir `@project_statuses`, `@plan_statuses` (actualizar de 5 a 4 valores), `@health_sources`. Exponer vía `project_statuses/0`, `plan_statuses/0`, `health_sources/0`.

**Task 1.4** — Añadir `reminder` a `@note_kinds`.

**Task 1.5** — Implementar `validate_meta_for_type(cs, "project")` con `validate_inclusion` de status/priority/health/health_source.

**Task 1.6** — Actualizar `validate_meta_for_type(cs, "plan")`: cambiar `@plan_statuses` a los 4 valores nuevos (draft/active/done/archived).

**Task 1.7** — Añadir `validate_progress_range/1` helper y llamarlo en `validate_meta_for_type(cs, "goal")`.

**Task 1.8** — Implementar `derive_project_health/1` (función pura, §2.8) y `derive_goal_progress/1` (§2.9).

**Task 1.9** — Actualizar `meta_fields_for("project")`, `meta_fields_for("goal")`, `meta_fields_for("plan")`, `meta_fields_for("todo")`, `meta_fields_for("note")` con los nuevos campos (§2.6).

**Task 1.10** — Añadir soporte de campo condicional `condition: {:kind, "reminder"}` en el componente `.meta_fields` (inspeccionar `lib/dran_web/components/page_components.ex` para encontrar el renderer).

**Task 1.11** — Tests en `test/dran/brain/page_meta_test.exs`:
- `derive_project_health([green, green, yellow])` → `yellow` (floor 2.67 = 2)
- `derive_project_health([green, red])` → `yellow`
- `derive_project_health([])` → `nil`
- `derive_goal_progress(["done", "done", "in_progress"])` → `0.67`
- `derive_goal_progress(["done", "cancelled"])` → `1.0` (cancelled no cuenta)
- `derive_goal_progress([])` → `nil`
- Changeset de `project` con status inválido → inválido
- Changeset de `goal` con progress = 1.5 → inválido
- Changeset de `plan` con status = "on_hold" → inválido (ya no permitido)
- Changeset de `note` con kind = "reminder" → válido

**Verificación de fase:**
```bash
cd ~/Repos/dran && mix compile --warnings-as-errors && PORT=4099 mix test test/dran/brain/page_meta_test.exs
```

---

### Fase 2: `sync_todo_links/2` + recálculos (`brain.ex`)

**Task 2.1** — Implementar `sync_one_link/5` (helper privado, §3.2).

**Task 2.2** — Reemplazar `sync_planning_relations/2` (líneas 809-845) por `sync_todo_links/2` (§3.1). Actualizar las llamadas en `create_page/1:383` y `update_page/2:467`.

**Task 2.3** — Eliminar `maybe_drop_planning_part_of/4` y `ensure_part_of/3` (ya no se usan). Mantener `meta_string/2`, `blank?/1`, `create_relation_by_slugs/4`, `delete_relation_by_slugs/4`.

**Task 2.4** — Implementar `maybe_recompute_parent_project/3`, `recompute_project_health/2`, `list_goal_healths_for_project/2` (§3.4). Usar la versión SQL de §9.6 para `list_goal_healths_for_project/2`.

**Task 2.5** — Implementar `maybe_recompute_parent_goal_progress/3`, `recompute_goal_progress/2`, `list_todo_statuses_for_goal/2` (§3.5).

**Task 2.6** — Extender `list_pages/1` con `:project_slug` filter y `maybe_filter_project_slug/2` (§9.4).

**Task 2.7** — Tests en `test/dran/brain_test.exs` (o `test/dran/sync_links_test.exs` nuevo):
- Todo con solo `project_slug` → `part_of project` solo
- Todo con `project_slug` + `goal_slug` → ambos `part_of` creados (sin precedencia)
- Todo con los tres slugs → tres `part_of` creados
- Todo que pasa de `plan_slug` a `goal_slug` (quita plan, añade goal) → se borra `part_of plan`, se crea `part_of goal`, `part_of project` (si existía) se mantiene
- Todo que quita todos los slugs → se borran todas las relaciones `part_of`
- Goal con `project_slug` → al editar health, `recompute_project_health` recalcula health del project
- Project con `health_source: "manual"` → editar un goal NO pisa el health
- Todo con `goal_slug` + `kanban_status: "done"` → `recompute_goal_progress` actualiza progress del goal
- Goal con `progress_manual: true` → `recompute_goal_progress` no pisa el valor
- Page inexistente como target → no se crea relación (no crash)

**Verificación de fase:**
```bash
cd ~/Repos/dran && mix compile --warnings-as-errors && PORT=4099 mix test test/dran/brain_test.exs
```

---

### Fase 3: UI — KanbanLive, ProjectLive, modificaciones Goal/PlanLive

**Task 3.1** — Crear `lib/dran_web/live/kanban_live.ex` completo (§4.2). Incluye filtros combinables, badges, drag-drop.

**Task 3.2** — Añadir rutas en `router.ex`:
```elixir
live "/kanban", KanbanLive, :index
live "/projects", ProjectLive, :index
live "/projects/new", PageNewLive, :new
live "/projects/:slug", ProjectLive, :show
```

**Task 3.3** — Soporte de query params `project`, `goal`, `plan` en `KanbanLive.handle_params/3` (§5.4).

**Task 3.4** — Crear `lib/dran_web/live/project_live.ex` completo (§5.2). 6 tabs, sin kanban.

**Task 3.5** — Modificar `goal_live.ex`:
- Quitar `@kanban_columns`, hook JS `.GoalKanban`, `handle_event("move_todo")`, helpers `goal_column_*`
- Reemplazar tab "todos" por lista simple con link a `/kanban?goal=#{slug}` (§6.2)
- Añadir panel de métricas (progress bar) en Overview (§6.3)
- Añadir helpers `progress_percent/1`, `format_value/1`

**Task 3.6** — Modificar `plan_live.ex`:
- Añadir tab "todos" a `@tabs` (§7.1)
- Cargar `plan_todos` en `handle_params` (§7.2)
- Render del tab Todos (§7.3)
- Mostrar status + due_date + horizon + period en Overview (§7.4)

**Task 3.7** — Actualizar `sidebar_nav/1` en `layouts.ex` (§8.1) y `compute_counts/1` (§8.2).

**Task 3.8** — Añadir `"project"` al map `@types` en `lib/dran_web/page_types.ex`:
```elixir
"project" => %{path: "projects", label: "Project", icon: "hero-rocket-launch", plural: "Projects"},
```

**Task 3.9** — Añadir `empty_state("project")` en `lib/dran_web/components/page_list_components.ex`.

**Task 3.10** — Añadir shortcut a Projects y Kanban en `dashboard_live.ex` (`@nav_groups`).

**Task 3.11** — Añadir entradas en `command_palette.ex`:
- "Go to Kanban" → `/kanban`
- "New Project" → `/projects/new`

**Verificación de fase:**
```bash
cd ~/Repos/dran && mix compile --warnings-as-errors && PORT=4099 mix test
# Verificación visual:
cd ~/Repos/dran && PORT=4099 mix phx.server
# 1. /kanban → verificar filtros combinables, drag-drop, badges
# 2. /projects/new → crear project → /projects/:slug → verificar tabs
# 3. /goals/:slug → verificar que no hay kanban, hay lista de todos + progress bar
# 4. /plans/:slug → verificar tab todos + status + due_date
# 5. Sidebar → verificar orden: Dashboard, Kanban, Projects arriba; Goals/Plans en Knowledge
```

---

### Fase 4: Docs, MCP, cleanup, suite completa

**Task 4.1** — Actualizar `lib/dran_web/docs_content.ex`:
- Nuevo modelo: todos huérfanos con vínculos independientes
- Project como dashboard (no contenedor)
- Goal con metric/progress
- Plan con status + due_date
- Kanban global
- Convención `project_slug`, `goal_slug`, `plan_slug` en meta

**Task 4.2** — Inspeccionar y actualizar `lib/dran/mcp.ex`:
- Si expone `page_types`, añadir `"project"`
- Si expone filtros por slug, añadir `project_slug`

**Task 4.3** — Script de migración SQL (Opción B):
```bash
psql -d dran_dev -c "UPDATE pages SET meta = meta - 'status' WHERE page_type = 'plan';"
psql -d dran_dev -c "UPDATE pages SET meta = meta - 'status' WHERE page_type = 'plan' AND meta->>'status' = 'on_hold';"
```
Verificar que no quede ningún plan con `on_hold`.

**Task 4.4** — Cleanup: `grep -rn "sync_planning_relations\|maybe_drop_planning_part_of\|ensure_part_of" lib/` confirma que no quedan referencias.

**Task 4.5** — Actualizar skill second-brain (`~/.hermes/skills/second-brain/SKILL.md`) y copiar del repo.

**Task 4.6** — Suite completa:
```bash
cd ~/Repos/dran && mix compile --warnings-as-errors && PORT=4099 mix test
```

**Task 4.7** — Crear índice GIN si no existe:
```bash
psql -d dran_dev -c "CREATE INDEX IF NOT EXISTS pages_meta_gin_idx ON pages USING GIN (meta);"
```

**Verificación final:**
- [ ] `mix compile --warnings-as-errors` sin warnings
- [ ] `PORT=4099 mix test` sin failures
- [ ] `mix ecto.migrate` no requiere migración (debe decir already up)
- [ ] Script de limpieza corrido
- [ ] Browser: `/kanban` con filtros + drag-drop funcional
- [ ] Browser: `/projects/:slug` con 6 tabs funcionales
- [ ] Browser: `/goals/:slug` sin kanban, con progress bar
- [ ] Browser: `/plans/:slug` con tab Todos + status + due_date
- [ ] Sidebar con nuevo orden
- [ ] `grep -rn "sync_planning_relations" lib/` regresa vacío

---

## 11. Riesgos y tradeoffs

### 11.1 Complejidad UI del Kanban global

- **Riesgo:** el kanban global con 3 filtros combinables + badges clickeables + drag-drop es la vista más compleja de Dran. Es fácil que se vuelva lenta con muchos todos (>200) porque carga todos y filtra en memoria.
- **Mitigación (performance):**
  - Mover el filtrado a SQL con `WHERE meta->>'project_slug' = ?` (§9.4) en vez de cargar todos y filtrar en Elixir.
  - Paginar el kanban por columnas si una columna tiene >50 items (mostrar "Ver más").
  - Índice GIN en `meta` (§9.5).
- **Mitigación (UX):**
  - Los badges son discretos (máximo 2 visibles) para no saturar la card.
  - El tooltip en hover evita truncamiento ambiguo.
  - El click en un badge filtra — es el equivalente a "navegar por jerarquía" pero sin salir del kanban.
- **Tradeoff:** la complejidad de UI es aceptable porque reemplaza 3 vistas distintas (kanban de project, kanban de goal, index de todos) con una sola más potente.

### 11.2 Queries JSONB — performance y consistencia

- **Riesgo:** los filtros `fragment("meta->>'key' = ?", value)` no usan índices por defecto. Con volúmenes grandes (>1000 páginas) se vuelve lento.
- **Mitigación:** índice GIN en `meta` (§9.5). Las queries `meta->>'key' = ?` lo aprovechan parcialmente; para uso total, queries con `meta @> '{"key": "value"}'`.
- **Riesgo (consistencia):** si un slug en `meta` no corresponde a una página existente (ej. `project_slug: "foo"` pero no hay project con slug `foo`), la query filtra pero el link lleva a 404.
- **Mitigación:** el lint report existente (`LintController`) ya caza esto para `goal_slug`/`plan_slug`. Extenderlo para `project_slug` en Task 4.1.

### 11.3 Sin precedencia — semántica de "pertenencia"

- **Riesgo:** al eliminar la precedencia, un todo con `plan_slug` + `goal_slug` aparece en el kanban filtrado por ambos. Eso puede confundir al usuario: "¿este todo es del plan o del goal?" — respuesta: de ambos, son vínculos independientes.
- **Mitigación (documentación):** `docs_content.ex` debe dejar claro que los vínculos son independientes. Un todo puede estar vinculado a un plan (táctico) y a un goal (medible) simultáneamente sin conflicto.
- **Mitigación (UX):** los badges en la card del kanban muestran todos los vínculos visiblemente. El usuario ve "este todo está en project X, goal Y, plan Z" de un vistazo.
- **Tradeoff:** perdemos la jerarquía rígida (un todo cuelga de un solo padre) pero ganamos flexibilidad. El caso de uso real de Dran (un solo usuario, ~500 páginas) no necesita jerarquía estricta; necesita vínculos expresivos.

### 11.4 Duplicación entre `ProjectLive` y `KanbanLive`

- **Riesgo:** ambos muestran todos, pero de forma distinta (lista vs kanban). Si se cambia el modelo de todo, hay que tocar ambos.
- **Mitigación:** la lista de `ProjectLive` es deliberadamente simple (solo título + status badge + summary). Toda la complejidad de interacción vive en `KanbanLive`. Si `ProjectLive` necesita más features (ej. editar inline), se extrae un componente compartido.
- **Tradeoff:** aceptar duplicación menor por claridad. ProjectLive es dashboard; KanbanLive es ejecución.

### 11.5 Auto-progress de goal — consistencia eventual

- **Riesgo:** el `progress` de un goal se recalcula en cada update de un todo vinculado. Si dos todos se editan concurrentemente, el progress puede pisarse con valores desactualizados.
- **Mitigación:** aceptable para el caso de uso (un solo usuario). Si se mueve a multi-usuario, envolver el recálculo en una transacción.
- **Riesgo (override frágil):** el flag `progress_manual: true` es un campo no validado. Si se pierde (ej. edit directo del JSONB), el auto-progress pisa el valor manual.
- **Mitigación:** documentar el flag en `docs_content.ex`. Considerar migrarlo a un campo del schema embebido si se vuelve problemático.

### 11.6 Health derivado de project — misma problemática que v5

- **Riesgo:** el `health` del project se recalcula en cada edit de un goal vinculado. Mismos problemas que el auto-progress: performance, race condition, override.
- **Mitigación:** misma que §11.5. `health_source: "manual"` es el override explícito; se respeta.

### 11.7 Migración de planes viejos con `on_hold`

- **Riesgo:** el `@plan_statuses` pasa de 5 valores (`draft/active/on_hold/completed/archived`) a 4 (`draft/active/done/archived`). Planes viejos con `status: "on_hold"` o `status: "completed"` quedan con valor inválido tras el cambio.
- **Mitigación:** script SQL en Task 4.3 mapea los valores viejos:
  ```sql
  UPDATE pages SET meta = jsonb_set(meta, '{status}', '"done"', true)
  WHERE page_type = 'plan' AND meta->>'status' = 'completed';
  UPDATE pages SET meta = jsonb_set(meta, '{status}', '"active"', true)
  WHERE page_type = 'plan' AND meta->>'status' = 'on_hold';
  UPDATE pages SET meta = meta - 'status'
  WHERE page_type = 'plan' AND meta->>'status' NOT IN ('draft', 'active', 'done', 'archived');
  ```
- **Riesgo residual:** ninguno — no hay producción, el script se corre una vez.

### 11.8 Convención `*_slug` vs FK real

- Seguimos el patrón existente: slugs en `meta` JSONB + materialización en tabla `relations` con tipo `part_of`. Sin FKs.
- **Riesgo conocido:** si se borra un project, los `part_of` quedan dangling (igual que con goals/plans hoy). El lint report lo caza.
- **Tradeoff:** sin FK = sin integridad referencial a nivel DB, pero flexibilidad total (un todo puede referenciar un project que se creará después). Es el tradeoff que Dran ya asumió.

---

## 12. Alternativa considerada: mantener precedencia jerárquica

Si se quiere mantener el modelo jerárquico actual (plan > goal > project con precedencia):

- No cambiar `sync_planning_relations` — dejar el `cond` con 3 ramas.
- ProjectLive y GoalLive mantienen kanban embebido (no crear KanbanLive global).
- Sidebar mantiene "Planning" como categoría.
- **Costo:** 3 LiveViews con kanban duplicado (~600 líneas cada uno), queries JSONB con JOIN para resolver precedencia, UX inconsistente para "ver todos de X".

**Recomendación:** eliminar la precedencia. El modelo de vínculos independientes es más simple de implementar, más expresivo para el usuario, y permite el kanban global que reemplaza 3 vistas duplicadas por una.
