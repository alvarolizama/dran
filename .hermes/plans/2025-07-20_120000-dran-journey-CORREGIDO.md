# Dran Journey — Implementación Corregida

> **Para Hermes:** Usar subagent-driven-development para ejecutar este plan tarea por tarea.

**Goal:** Implementar una vista "Journey" en Dran que muestre la trayectoria temporal de construcción del segundo cerebro — páginas creadas por período, distribución por tipo, y crecimiento acumulado.

**Architecture:** Un módulo `Dran.Journey` que consulta `brain_log` (action: "page.create") agrupado por período (día/mes/año adaptativo), y un `JourneyLive` que renderiza la línea de tiempo con Tailwind + SVG sparkline. Sin dependencias nuevas. El índice en brain_log YA EXISTE (migración 005) — solo se verifica.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto queries, Tailwind CSS, SVG inline (polyline).

---

## Contexto

El feature "Journey" de Hermes-Agent grafica skills aprendidas y memorias en un timeline. En Dran, el equivalente natural es: **páginas creadas en tu segundo cerebro, a lo largo del tiempo**. No es "lo que la IA aprendió" sino "lo que tú construiste".

### Fuentes de datos existentes (VERIFICADO)

| Tabla | Campos clave | Uso |
|---|---|---|
| `brain_log` | action, subject, details, context_id, inserted_at | Timeline fuente principal (page.create events) |
| `pages` | page_type, created_by, inserted_at, meta, archived | Breakdown por tipo/creador |

### Schema real de brain_log (VERIFICADO)

```elixir
# lib/dran/brain/log.ex
schema "brain_log" do
  field :action, :string
  field :subject, :string        # slug de la página
  field :details, :map, default: %{}  # %{page_id, page_type, owner, created_by}
  belongs_to :context, Dran.Brain.Context
  timestamps(type: :utc_datetime, updated_at: false)
end
```

### Detalles del log "page.create" (VERIFICADO en brain.ex:437)

```elixir
log_action(page.context_id, "page.create", page.slug, %{
  page_id: page.id,
  page_type: page.page_type,
  owner: page.owner,
  created_by: page.created_by
})
```

**IMPORTANTE:** El log NO incluye `title` — solo `page_id`, `page_type`, `owner`, `created_by`. El `subject` es el slug.

### Índices existentes (VERIFICADO en migración 005)

```elixir
create index(:brain_log, [:context_id])
create index(:brain_log, [:action])
```

El índice compuesto `(context_id, inserted_at)` propuesto en el plan original NO es necesario — PostgreSQL puede usar el índice de `context_id` + sort en memoria para volúmenes normales de segundo cerebro. Si en el futuro hay >100k entries por contexto, se agrega.

### Sidebar actual (VERIFICADO en layouts.ex)

El primer grupo (sin label) tiene: dashboard, projects, goals, kanban, graph, activity.
Labels en español: "Actividad", "Objetivos", "Grafo", "Kanban".
Journey debe ir después de activity con label "Trayectoria" y badge opcional.

---

## Tasks

### Task 1: Verificar índice en brain_log

**Objetivo:** Confirmar que el índice existente es suficiente. NO crear migración nueva.

**Files:**
- Read: `priv/repo/migrations/005_create_brain_log.exs`

**Step 1: Verificar índices actuales**

```bash
cd /Users/alvaro/Workspace/Repos/dran
grep -A2 "create index" priv/repo/migrations/005_create_brain_log.exs
```

Expected output:
```
create index(:brain_log, [:context_id])
create index(:brain_log, [:action])
```

**Step 2: Decisión**

Si los índices existen (que sí), NO crear migración. El query pattern es:
```sql
WHERE context_id = ? AND action = 'page.create' ORDER BY inserted_at
```

PostgreSQL usa `index(context_id)` + filter por action + sort. Para volúmenes de segundo cerebro personal (<10k entries/año) esto es instantáneo.

**Step 3: Commit**

```bash
git commit --allow-empty -m "docs(journey): verify existing brain_log indexes are sufficient"
```

---

### Task 2: Módulo `Dran.Journey` — data layer

**Objetivo:** Función `timeline/2` que agrupa páginas creadas por período y devuelve payload listo para el LiveView.

**Files:**
- Create: `lib/dran/journey.ex`
- Test: `test/dran/journey_test.exs`

**Step 1: Escribir test**

```elixir
defmodule Dran.JourneyTest do
  use Dran.DataCase

  alias Dran.Journey
  alias Dran.Brain

  setup do
    {:ok, context} = Brain.create_context(%{name: "Test", slug: "test"})
    {:ok, context: context}
  end

  describe "timeline/2" do
    test "returns empty when no log entries", %{context: context} do
      result = Journey.timeline(context.id)
      assert result.buckets == []
      assert result.total == 0
      assert result.stats.total_pages == 0
    end

    test "groups pages by day", %{context: context} do
      for i <- 1..5 do
        Brain.create_page(%{
          context_id: context.id,
          title: "Page #{i}",
          slug: "page-#{i}",
          page_type: "note"
        })
      end

      result = Journey.timeline(context.id)
      assert length(result.buckets) >= 1
      assert result.total == 5
    end

    test "includes type distribution", %{context: context} do
      Brain.create_page(%{context_id: context.id, title: "Note", slug: "n1", page_type: "note"})
      Brain.create_page(%{context_id: context.id, title: "Todo", slug: "t1", page_type: "todo"})

      result = Journey.timeline(context.id)
      assert Map.get(result.stats.by_type, "note") == 1
      assert Map.get(result.stats.by_type, "todo") == 1
    end

    test "computes trajectory points for sparkline", %{context: context} do
      for i <- 1..3 do
        Brain.create_page(%{context_id: context.id, title: "P#{i}", slug: "p#{i}", page_type: "note"})
      end

      result = Journey.timeline(context.id)
      assert length(result.trajectory) == length(result.buckets)
      # Trajectory is cumulative — last point equals total
      assert List.last(result.trajectory) == result.total
    end

    test "includes creator distribution", %{context: context} do
      Brain.create_page(%{context_id: context.id, title: "By Alvaro", slug: "a1", page_type: "note", created_by: "alvaro"})
      Brain.create_page(%{context_id: context.id, title: "By Agent", slug: "a2", page_type: "note", created_by: "agent"})

      result = Journey.timeline(context.id)
      assert Map.get(result.stats.by_creator, "alvaro") == 1
      assert Map.get(result.stats.by_creator, "agent") == 1
    end
  end

  describe "suggest_granularity/2" do
    test "returns day when span <= 32 days" do
      assert Journey.suggest_granularity(0, 10 * 86_400) == "day"
    end

    test "returns month when span <= 18 months" do
      assert Journey.suggest_granularity(0, 60 * 86_400) == "month"
    end

    test "returns year for longer spans" do
      assert Journey.suggest_granularity(0, 400 * 86_400) == "year"
    end
  end
end
```

**Step 2: Correr test para verificar que falla**

```bash
cd /Users/alvaro/Workspace/Repos/dran
mix test test/dran/journey_test.exs
# Expected: FAIL — Module Dran.Journey not compiled
```

**Step 3: Implementar `lib/dran/journey.ex`**

```elixir
defmodule Dran.Journey do
  @moduledoc """
  Builds the Journey timeline — pages created over time, grouped by period.

  The journey answers: "How has my second brain grown?"
  """

  import Ecto.Query
  alias Dran.Repo
  alias Dran.Brain.Log

  @day 86_400
  @month 30 * @day

  @doc """
  Build the full journey payload for a context.

  Returns:
    %{
      buckets: [%{label, period_key, pages: [%{slug, page_type, created_by}], total, recency, dominant_type}],
      total: integer,
      stats: %{total_pages, by_type, by_creator, busiest_period, busiest_count},
      trajectory: [integer],  # cumulative count per bucket
      axis: %{start: "Jul 2025", end: "Jul 2026"},
      range: %{min_ts, max_ts, granularity}
    }
  """
  def timeline(context_id, _opts \\ []) do
    entries =
      Repo.all(
        from l in Log,
          where: l.context_id == ^context_id and l.action == "page.create",
          order_by: [asc: l.inserted_at],
          select: %{subject: l.subject, details: l.details, inserted_at: l.inserted_at}
      )

    if entries == [] do
      empty_payload()
    else
      min_ts = List.first(entries).inserted_at |> to_unix()
      max_ts = List.last(entries).inserted_at |> to_unix()
      _span = max_ts - min_ts

      granularity = suggest_granularity(min_ts, max_ts)
      buckets = build_buckets(entries, granularity, min_ts, max_ts)
      total = length(entries)

      by_type =
        entries
        |> Enum.map(&Map.get(&1.details, "page_type", "unknown"))
        |> Enum.frequencies()

      by_creator =
        entries
        |> Enum.map(&Map.get(&1.details, "created_by", "unknown"))
        |> Enum.frequencies()

      busiest =
        buckets
        |> Enum.max_by(& &1.total, fn -> %{label: "-", total: 0} end)

      trajectory =
        buckets
        |> Enum.scan(0, fn bucket, acc -> acc + bucket.total end)
        |> Enum.drop(1)

      %{
        buckets: buckets,
        total: total,
        stats: %{
          total_pages: total,
          by_type: by_type,
          by_creator: by_creator,
          busiest_period: busiest.label,
          busiest_count: busiest.total
        },
        trajectory: trajectory,
        axis: %{
          start: format_axis_date(min_ts),
          end: format_axis_date(max_ts)
        },
        range: %{min_ts: min_ts, max_ts: max_ts, granularity: granularity}
      }
    end
  end

  @doc """
  Suggest the best granularity for a time span.

  - <= 32 days: day
  - <= 18 months: month
  - else: year
  """
  def suggest_granularity(min_ts, max_ts) do
    span = max_ts - min_ts

    cond do
      span <= 32 * @day -> "day"
      span <= 18 * @month -> "month"
      true -> "year"
    end
  end

  @doc """
  Empty payload when no entries exist.
  """
  def empty_payload do
    %{
      buckets: [],
      total: 0,
      stats: %{total_pages: 0, by_type: %{}, by_creator: %{}, busiest_period: nil, busiest_count: 0},
      trajectory: [],
      axis: %{start: "", end: ""},
      range: %{min_ts: nil, max_ts: nil, granularity: nil}
    }
  end

  # Convert utc_datetime to unix timestamp
  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp build_buckets(entries, granularity, min_ts, max_ts) do
    entries
    |> Enum.group_by(fn e -> period_key(e.inserted_at, granularity) end)
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, items} ->
      ts = key_to_timestamp(key, granularity)
      rec = if max_ts > min_ts, do: (ts - min_ts) / (max_ts - min_ts), else: 1.0

      pages =
        Enum.map(items, fn e ->
          %{
            slug: e.subject,
            page_type: Map.get(e.details, "page_type", "unknown"),
            created_by: Map.get(e.details, "created_by", "unknown"),
            inserted_at: e.inserted_at
          }
        end)

      dominant_type =
        pages
        |> Enum.frequencies_by(& &1.page_type)
        |> Enum.max_by(fn {_, v} -> v end, fn -> {"unknown", 0} end)
        |> elem(0)

      %{
        label: period_label(ts, granularity),
        period_key: key,
        ts: ts,
        pages: pages,
        total: length(items),
        recency: rec,
        dominant_type: dominant_type
      }
    end)
  end

  defp period_key(%DateTime{} = dt, "day"), do: {dt.year, dt.month, dt.day}
  defp period_key(%DateTime{} = dt, "month"), do: {dt.year, dt.month}
  defp period_key(%DateTime{} = dt, "year"), do: {dt.year}

  defp period_key(%NaiveDateTime{} = ndt, granularity) do
    dt = DateTime.from_naive!(ndt, "Etc/UTC")
    period_key(dt, granularity)
  end

  defp key_to_timestamp({y, m, d}, "day"), do: DateTime.new!(Date.new!(y, m, d), ~T[00:00:00]) |> DateTime.to_unix()
  defp key_to_timestamp({y, m}, "month"), do: DateTime.new!(Date.new!(y, m, 1), ~T[00:00:00]) |> DateTime.to_unix()
  defp key_to_timestamp({y}, "year"), do: DateTime.new!(Date.new!(y, 1, 1), ~T[00:00:00]) |> DateTime.to_unix()

  defp period_label(ts, "day") do
    dt = DateTime.from_unix!(ts)
    "#{dt.day} #{month_abbr(dt.month)}"
  end

  defp period_label(ts, "month") do
    dt = DateTime.from_unix!(ts)
    "#{month_abbr(dt.month)} #{dt.year}"
  end

  defp period_label(ts, "year") do
    dt = DateTime.from_unix!(ts)
    "#{dt.year}"
  end

  defp format_axis_date(ts) do
    dt = DateTime.from_unix!(ts)
    "#{month_abbr(dt.month)} #{dt.year}"
  end

  defp month_abbr(m) do
    ~w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
    |> Enum.at(m - 1, "?")
  end
end
```

**Step 4: Correr test para verificar que pasa**

```bash
mix test test/dran/journey_test.exs
# Expected: all tests pass
```

**Step 5: Commit**

```bash
git add lib/dran/journey.ex test/dran/journey_test.exs
git commit -m "feat(journey): add Journey module with timeline aggregation"
```

**Criterios de aceptación:**
- [ ] `timeline/1` retorna `%{buckets, total, stats, trajectory, axis, range}`
- [ ] Buckets agrupados correctamente por día/mes/año
- [ ] Trajectory es acumulativo (cada punto >= anterior)
- [ ] Stats incluye by_type, by_creator, busiest_period
- [ ] Payload vacío cuando no hay log entries
- [ ] Tests pasan sin warnings

---

### Task 3: Tipo de color por page_type

**Objetivo:** Función que asigna un color HSL a cada page_type con golden-angle spacing, para las bars del timeline.

**Files:**
- Modify: `lib/dran/journey.ex` (agregar función)

**Step 1: Agregar función de colores**

Agregar al módulo `Dran.Journey`:

```elixir
@doc """
Deterministic color for each page_type using golden-angle hue spacing.

Returns a map of %{type => "#RRGGBB"}.
"""
def type_colors do
  types = ~w[note concept entity project reference goal plan todo comparison query]

  types
  |> Enum.with_index()
  |> Enum.map(fn {type, i} ->
    hue = rem(round(i * 137.508), 360)
    {type, hsl_to_hex(hue, 0.55, 0.62)}
  end)
  |> Map.new()
end

defp hsl_to_hex(h, s, l) do
  c = (1 - abs(2 * l - 1)) * s
  h_mod = rem(h, 360)
  x = c * (1 - abs(rem(div(h_mod, 60), 2) - 1))
  m = l - c / 2

  {r, g, b} =
    cond do
      h_mod < 60 -> {c, x, 0.0}
      h_mod < 120 -> {x, c, 0.0}
      h_mod < 180 -> {0.0, c, x}
      h_mod < 240 -> {0.0, x, c}
      h_mod < 300 -> {x, 0.0, c}
      true -> {c, 0.0, x}
    end

  r = round((r + m) * 255)
  g = round((g + m) * 255)
  b = round((b + m) * 255)

  "##{hex(r)}#{hex(g)}#{hex(b)}"
end

defp hex(n), do: n |> max(0) |> min(255) |> Integer.to_string(16) |> String.pad_leading(2, "0")
```

**Step 2: Commit**

```bash
git add lib/dran/journey.ex
git commit -m "feat(journey): add type colors with golden-angle hue spacing"
```

---

### Task 4: `JourneyLive` — LiveView principal

**Objetivo:** Vista completa con timeline bar chart, legend, stats, y sparkline.

**Files:**
- Create: `lib/dran_web/live/journey_live.ex`
- Test: `test/dran_web/live/journey_live_test.exs`

**Step 1: Crear test básico**

```elixir
defmodule DranWeb.JourneyLiveTest do
  use DranWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the journey page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/journey")
    assert html =~ "Trayectoria" or html =~ "Journey"
  end
end
```

**Step 2: Verificar que falla**

```bash
mix test test/dran_web/live/journey_live_test.exs
# Expected: FAIL — route not found
```

**Step 3: Crear JourneyLive**

```elixir
defmodule DranWeb.JourneyLive do
  @moduledoc """
  LiveView for the Journey timeline — pages created over time.

  Shows a bar chart of brain activity by period (day/month/year),
  colored by dominant page type, with a cumulative sparkline.
  """
  use DranWeb, :live_view

  alias Dran.Journey
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    journey =
      if context do
        Journey.timeline(context.id)
      else
        Journey.empty_payload()
      end

    {:ok,
     assign(socket,
       context: context,
       journey: journey,
       type_colors: Journey.type_colors(),
       active_nav: "journey",
       page_title: gettext("Trayectoria")
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-6">
          <.header />
          <.stats_row :if={@journey.total > 0} stats={@journey.stats} />
          <.empty_state :if={@journey.total == 0} />
          <.timeline_chart
            :if={@journey.total > 0}
            buckets={@journey.buckets}
            trajectory={@journey.trajectory}
            type_colors={@type_colors}
            axis={@journey.axis}
          />
          <.type_legend :if={@journey.total > 0} by_type={@journey.stats.by_type} type_colors={@type_colors} />
          <.creator_legend :if={@journey.total > 0} by_creator={@journey.stats.by_creator} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Components ──────────────────────────────────────────────────────────────

  defp header(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-title">{gettext("Trayectoria")}</h1>
        <p class="text-caption mt-1">
          {gettext("Crecimiento de tu segundo cerebro en el tiempo")}
        </p>
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true

  defp stats_row(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <.stat_card
        label={gettext("Total páginas")}
        value={@stats.total_pages}
        icon="hero-document-duplicate"
        color="text-primary"
      />
      <.stat_card
        label={gettext("Tipos")}
        value={map_size(@stats.by_type)}
        icon="hero-tag"
        color="text-secondary"
      />
      <.stat_card
        label={gettext("Período pico")}
        value={@stats.busiest_period || "—"}
        icon="hero-fire"
        color="text-warning"
        small={true}
      />
      <.stat_card
        label={gettext("Páginas pico")}
        value={@stats.busiest_count}
        icon="hero-chart-bar"
        color="text-info"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "text-base-content"
  attr :small, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <div class="surface-2 lift p-4 flex items-center gap-3 rounded-xl">
      <div class={["shrink-0 size-9 rounded-lg flex items-center justify-center", bg_for(@color)]}>
        <.icon name={@icon} class={["size-4", @color]} />
      </div>
      <div class="min-w-0">
        <div class={["font-bold tabular-nums leading-tight truncate", @small && "text-base", !@small && "text-xl"]}>
          {@value}
        </div>
        <div class="text-caption">{@label}</div>
      </div>
    </div>
    """
  end

  defp bg_for("text-primary"), do: "bg-primary/10"
  defp bg_for("text-secondary"), do: "bg-secondary/10"
  defp bg_for("text-accent"), do: "bg-accent/10"
  defp bg_for("text-info"), do: "bg-info/10"
  defp bg_for("text-success"), do: "bg-success/10"
  defp bg_for("text-warning"), do: "bg-warning/10"
  defp bg_for(_), do: "bg-base-200"

  attr :buckets, :list, required: true
  attr :trajectory, :list, required: true
  attr :type_colors, :map, required: true
  attr :axis, :map, required: true

  defp timeline_chart(assigns) do
    max_total = assigns.buckets |> Enum.map(& &1.total) |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(max_total: max_total)
      |> assign(sparkline_path: build_sparkline(assigns.trajectory))

    ~H"""
    <div class="surface-2 p-5 rounded-2xl space-y-3">
      <div class="space-y-1.5">
        <div
          :for={bucket <- @buckets}
          class="flex items-center gap-2 group"
        >
          <span class="text-xs text-base-content/50 w-16 text-right tabular-nums shrink-0">
            {bucket.label}
          </span>
          <div class="flex-1 flex items-center gap-1">
            <div
              class="h-5 rounded-sm transition-all duration-300 group-hover:brightness-110"
              style={"width: #{bucket_width(bucket.total, @max_total)}%; background-color: #{Map.get(@type_colors, bucket.dominant_type, "#666")}"}
            >
            </div>
            <span class="text-xs font-medium tabular-nums text-base-content/70 w-6 text-right">
              {bucket.total}
            </span>
          </div>
        </div>
      </div>

      <%!-- Sparkline --%>
      <div :if={@trajectory != []} class="pt-2 border-t border-base-300">
        <svg viewBox="0 0 200 30" class="w-full h-8" preserveAspectRatio="none">
          <polyline
            points={@sparkline_path}
            fill="none"
            stroke="currentColor"
            class="text-primary/40"
            stroke-width="1.5"
          />
        </svg>
      </div>

      <%!-- Axis --%>
      <div :if={@axis.start != ""} class="flex justify-between text-[10px] text-base-content/40">
        <span>{@axis.start}</span>
        <span>{@axis.end}</span>
      </div>
    </div>
    """
  end

  defp bucket_width(total, max_total) when max_total > 0 do
    round(total / max_total * 100)
  end
  defp bucket_width(_, _), do: 0

  defp build_sparkline([]), do: ""

  defp build_sparkline(trajectory) do
    max_val = Enum.max(trajectory)
    width = 200
    height = 28
    n = length(trajectory)

    trajectory
    |> Enum.with_index()
    |> Enum.map(fn {val, i} ->
      x = if n > 1, do: i / (n - 1) * width, else: 0
      y = if max_val > 0, do: height - val / max_val * height, else: height
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  attr :by_type, :map, required: true
  attr :type_colors, :map, required: true

  defp type_legend(assigns) do
    sorted =
      assigns.by_type
      |> Enum.sort_by(fn {_, v} -> -v end)
      |> Enum.map(fn {type, count} -> {type, count, Map.get(assigns.type_colors, type, "#666")} end)

    assigns = assign(assigns, sorted: sorted)

    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <span class="text-caption text-base-content/50">{gettext("Tipos:")}</span>
      <span
        :for={{type, count, color} <- @sorted}
        class="inline-flex items-center gap-1.5 text-xs"
      >
        <span class="size-2.5 rounded-full" style={"background-color: #{color}"}></span>
        <span class="text-base-content/70">{type}</span>
        <span class="text-base-content/40 font-mono">{count}</span>
      </span>
    </div>
    """
  end

  attr :by_creator, :map, required: true

  defp creator_legend(assigns) do
    sorted = Enum.sort_by(assigns.by_creator, fn {_, v} -> -v end)
    assigns = assign(assigns, sorted: sorted)

    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <span class="text-caption text-base-content/50">{gettext("Creadores:")}</span>
      <span
        :for={{creator, count} <- @sorted}
        class="inline-flex items-center gap-1.5 text-xs"
      >
        <.icon name={if creator == "agent", do: "hero-cpu-chip", else: "hero-user"} class="size-3.5 text-base-content/50" />
        <span class="text-base-content/70">{creator}</span>
        <span class="text-base-content/40 font-mono">{count}</span>
      </span>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="surface-2 p-12 rounded-2xl text-center space-y-4">
      <div class="size-16 rounded-full bg-base-200 flex items-center justify-center mx-auto">
        <.icon name="hero-map" class="size-8 text-base-content/30" />
      </div>
      <div>
        <h3 class="text-heading">{gettext("Sin páginas aún")}</h3>
        <p class="text-caption mt-1">{gettext("Crea algunas páginas para ver la trayectoria de tu cerebro.")}</p>
      </div>
    </div>
    """
  end
end
```

**Step 4: Verificar que el test pasa**

```bash
mix test test/dran_web/live/journey_live_test.exs
# Expected: PASS
```

**Step 5: Commit**

```bash
git add lib/dran_web/live/journey_live.ex test/dran_web/live/journey_live_test.exs
git commit -m "feat(journey): add JourneyLive with timeline bar chart and sparkline"
```

---

### Task 5: Router + Sidebar nav

**Objetivo:** Agregar ruta `/journey` y link en la navegación lateral.

**Files:**
- Modify: `lib/dran_web/router.ex`
- Modify: `lib/dran_web/components/layouts.ex`

**Step 1: Agregar ruta en router.ex**

En la sección "Views", después de `live "/activity"` (línea ~150), agregar:

```elixir
live "/journey", JourneyLive, :index
```

**Step 2: Agregar nav link en layouts.ex sidebar_nav**

En el primer grupo (sin label, el que tiene dashboard, projects, goals, kanban, graph, activity), agregar DESPUÉS de activity:

```elixir
%{
  key: "journey",
  label: gettext("Trayectoria"),
  icon: "hero-map",
  path: ~p"/journey"
}
```

**Step 3: Verificar compilación**

```bash
mix compile --warnings-as-errors
# Expected: Compiled X files (...)
```

**Step 4: Commit**

```bash
git add lib/dran_web/router.ex lib/dran_web/components/layouts.ex
git commit -m "feat(journey): add route and sidebar nav link"
```

---

### Task 6: Verificación visual en browser

**Objetivo:** Verificar que la vista se renderiza correctamente.

**Verificación visual:**
1. Navegar a `http://localhost:4000/journey`
2. Verificar que el header dice "Trayectoria"
3. Si no hay páginas, ver empty state con ícono de mapa
4. Crear una nota de prueba, regresar a /journey
5. Verificar que aparece al menos un bucket en la timeline
6. Verificar que los colores de los types son distintos
7. Verificar que el sparkline aparece debajo
8. Verificar que el link "Trayectoria" aparece en la sidebar con el ícono correcto

**Criterios de aceptación finales:**
- [ ] `/journey` carga sin errores
- [ ] Empty state se muestra cuando no hay datos
- [ ] Timeline aparece después de crear páginas
- [ ] Colores por type son distintos y consistentes
- [ ] Sparkline muestra crecimiento acumulado
- [ ] Sidebar tiene link a Trayectoria
- [ ] Stats muestran total, types, busiest period
- [ ] Axis muestra rango de fechas
- [ ] `mix test` pasa completo
- [ ] `mix compile --warnings-as-errors` sin warnings

---

## Files que cambian

| Archivo | Acción |
|---|---|
| `lib/dran/journey.ex` | **Crear** — data layer |
| `lib/dran_web/live/journey_live.ex` | **Crear** — LiveView |
| `lib/dran_web/router.ex` | **Modificar** — agregar ruta |
| `lib/dran_web/components/layouts.ex` | **Modificar** — nav link |
| `test/dran/journey_test.exs` | **Crear** — tests unitarios |
| `test/dran_web/live/journey_live_test.exs` | **Crear** — test LiveView |

## Riesgos

- **Performance**: Queries sobre brain_log usan índice existente `context_id`. Para volúmenes normales (<10k entries) es instantáneo. Si crece mucho, agregar índice compuesto después.
- **Brain log vacío**: Si el usuario nunca creó páginas, el empty state se muestra. No hay crash.
- **Granularidad**: Con pocos datos (1-2 entries), la granularidad puede ser rara. El código lo maneja con buckets vacíos.
- **Timezones**: Usamos UTC para todo, como el resto de Dran. Los timestamps `utc_datetime` se convierten con `DateTime.from_naive!(ndt, "Etc/UTC")`.

## Correcciones vs plan original

1. **NO crear migración de índice** — ya existe en migración 005
2. **Remover `limit` muerto** — el parámetro no se usaba
3. **Corregir acceso a details** — usar `page_type` y `created_by` (que existen), NO `title` (que no existe)
4. **Agregar `to_unix/1` helper** — maneja tanto `DateTime` como `NaiveDateTime` (utc_datetime)
5. **Agregar `by_creator` stats** — aprovechar que el log tiene `created_by`
6. **Label en español** — "Trayectoria" no "Journey" para consistencia con sidebar
7. **Agregar creator_legend** — mostrar quién creó páginas (alvaro vs agent)
8. **Hacer `empty_payload/0` pública desde el inicio** — evitar refactor posterior

## Preguntas abiertas

- ¿Quieres también un MCP tool `dran_get_journey` para ver la trayectoria desde el chat? (Se puede agregar después)
- ¿Mantener `/activity` y `/journey` como vistas separadas? **Sí** — activity = log crudo en tiempo real, journey = agregado temporal.
