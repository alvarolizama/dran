# DESIGN.md — sistema de UI

Estándar de interfaz de la familia de apps que comparten un **mismo lenguaje
visual**.

El documento tiene dos partes:

- **Commons** — la base compartida por todas las apps (tema, tokens, componentes,
  tarjetas, tablas, modales, pickers, gráficas, estados y convenciones). Es
  idéntica en todos los repos: si cambias algo aquí, cámbialo en los tres
  `DESIGN.md`.
- **Custom** — lo específico de **esta** app. Cada repo declara de qué proyecto es
  su `DESIGN.md` al inicio de la sección **Custom**.

---

## Commons — base compartida de la familia

Contrato visual común a todas las apps de la familia. Todo lo de esta sección es
idéntico entre apps; lo específico de cada una vive en **Custom**.

### C1. Principios

1. **daisyUI nativo + Tailwind.** No inventes componentes si daisyUI ya trae
   (`btn`, `card`, `table`, `badge`, `input`, `select`, `alert`, `modal`,
   `dropdown`, `tabs`). CSS propio sólo para convenciones **globales**.
2. **Un solo tema: `dark`.** Las tres apps corren daisyUI `dark --default`.
   Nada de hex/oklch hardcodeado en plantillas: siempre las vars del tema.
3. **Reusar antes de crear.** Mira `*Web.CoreComponents` antes de escribir markup
   a mano (inputs, tablas, headers, iconos ya están).
4. **Verificable.** Todo control interactivo lleva `id` estable para tests
   (`has_element?/2`).

### C2. Tema y tokens

```css
/* assets/css/app.css */
@plugin "../vendor/heroicons";
@plugin "../vendor/daisyui" {
  themes: dark --default;   /* ← tema ÚNICO de la familia */
}
```

```heex
<%!-- lib/<app>_web/components/layouts/root.html.heex --%>
<html data-theme="dark">
```

**Regla del scaffold:** si `app.css` venía con `themes: false` + bloques
`@plugin "../vendor/daisyui-theme"`, hay que **borrar** esos bloques (y el JS del
switcher de tema en `root.html.heex`) al fijar el tema built-in, o el tema viejo
queda pegado.

Colores semánticos (usar SIEMPRE las vars, nunca hex/oklch a mano):

| Rol | Utility daisyUI | Var | Uso |
|---|---|---|---|
| Fondo app | `bg-base-100` | `--color-base-100` | superficie base |
| Superficie 2 | `bg-base-200` | `--color-base-200` | paneles, hover de fila |
| Superficie 3 | `bg-base-300` | `--color-base-300` | bordes, chips |
| Texto | `text-base-content` | `--color-base-content` | + `/50` `/40` para secundario |
| Primario | `btn-primary`, `text-primary` | `--color-primary` | acción principal, links |
| Éxito | `badge-success` | `--color-success` | ok, activo |
| Aviso | `badge-warning` | `--color-warning` | warning / aviso |
| Error | `badge-error`, `text-error` | `--color-error` | destructivo |
| Info | `badge-info` | `--color-info` | entradas / exclusivo-grupo |
| Neutro | `badge-ghost` | `--color-neutral` | global / sin estado |

Radios y bordes salen del tema (`--radius-box`, `--radius-field`, `--border`).
No los hardcodees.

### C3. Layout base

- El contenido principal va en un `<main>`; el **shell** (sidebar/topbar) es de
  cada app → ver **Custom**.
- **Header de página:** `<.header>` — título + `:subtitle` + `:actions`.
- **Filtros y acciones, alineados a la DERECHA** (slot `:actions` o `justify-end`).
  Nunca a la izquierda.
- **Contenedores anchos** (tablas/paneles) envueltos en `overflow-x-auto`.

### C4. Componentes base

| Elemento | Clase estándar |
|---|---|
| Botón primario | `btn btn-primary` (o `<.button variant="primary">`) |
| Botón secundario | `btn btn-primary btn-soft` |
| Botón neutro / cancelar | `btn btn-ghost` |
| Acción de fila | `btn btn-xs btn-ghost` (+ `title=`) |
| Destructivo | `btn ... text-error` + `data-confirm="…"` |
| Badge | `badge badge-sm` + semántico (`badge-primary/success/warning/error/info/ghost/outline/accent`) |
| Chip removible | `badge badge-sm` con `<button>` interno |
| Card | `card bg-base-100 border border-base-300 shadow-sm` (ver C5) |
| Toast (flash) | `toast toast-top toast-end z-50` + `alert alert-info/alert-error` |
| Icono | `<.icon name="hero-…" class="size-4" />` (heroicons, NO SVG suelto) |

Componentes en `CoreComponents`: `flash`, `button`, `input`, `header`, `table`,
`list`, `icon`, `show/hide`. **Usa `<.input>`**, no armes el `<input>` a mano.

### C5. Tarjetas (cards)

Una sola forma de "caja" en toda la familia.

```heex
<div class="card bg-base-100 border border-base-300 shadow-sm">
  <div class="card-body p-4">
    <h2 class="card-title text-base">
      <.icon name="hero-…" class="size-5 text-base-content/60" />
      Título
    </h2>
    …
  </div>
</div>
```

- **Base:** `card bg-base-100 border border-base-300 shadow-sm` + `card-body`.
- **Densidad del `card-body`** (elegir según el contenido, no al azar):
  `p-4` (denso: listas, KPIs) · `p-5` (medio) · `p-6` (forms) · `p-8` (hero).
- **Título:** `card-title text-base` + icono `size-5 text-base-content/60`.
- **Card interactiva (clicable):** `hover:shadow-md transition-shadow`.
- **Card de sección con header** (badge de icono + título + caption): cada app la
  tiene → ver **Custom**.
- **Card de modal:** `shadow-xl` en vez de `shadow-sm` (ver C7).
- Sombras y radios del tema (`--radius-box`, `shadow-sm/md/xl`); no a mano.

### C6. Tablas

Estructura canónica (una sola forma en toda la familia):

```heex
<div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
  <table class="table table-sm">
    <thead>
      <tr>
        <th>…</th>
        <th class="text-right">Acciones</th>
      </tr>
    </thead>
    <tbody id="things" phx-update="stream">
      <tr :for={{id, t} <- @streams.things} id={id}>
        <td>…</td>
        <td class="text-right">
          <button phx-click="edit" phx-value-id={t.id} class="btn btn-xs btn-ghost" title="Editar">
            <.icon name="hero-pencil" class="size-3.5" />
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</div>
```

Reglas:

- **`table table-sm` siempre.** Envuelta en `overflow-x-auto` + card.
- **Hover de fila, sin zebra** — regla global (una vez por app):
  ```css
  .table tbody tr { transition: background-color 150ms ease; }
  .table tbody tr:hover { background-color: color-mix(in oklab, var(--b2) 60%, transparent); }
  ```
- **Colecciones con `stream` + `phx-update="stream"`** (nunca listas grandes
  asignadas). El `id` de cada fila es el del item.
- **Columna de acciones** al final, `btn-xs btn-ghost` con `title`.
- **Empty state** (fuera de la tabla):
  ```heex
  <div :if={@things_empty?} class="text-center py-12 text-base-content/40">
    <.icon name="hero-…" class="size-10 mx-auto mb-2 opacity-40" />
    <p>No hay … todavía.</p>
  </div>
  ```
- **Datos crudos nunca en pantalla:** formatters propios (fechas, precios), nunca
  `Decimal` crudo.

### C7. Modales

Patrón estándar = overlay `div`, **no `<dialog>`**. Cerrar = volver el assign.

#### C7.1 Modal simple (una columna)

```heex
<div :if={@show_modal?} class="fixed inset-0 z-50 flex items-center justify-center p-4" id="thing-modal">
  <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />

  <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
    <div class="card-body p-6">
      <h2 class="text-lg font-semibold mb-4">Nuevo …</h2>
      <.form for={@form} id="thing-form" phx-submit="save">
        …
        <div class="flex gap-2 mt-6 justify-end">
          <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
          <button type="submit" class="btn btn-primary btn-sm" id="save-thing">Guardar</button>
        </div>
      </.form>
    </div>
  </div>
</div>
```

#### C7.2 Modal de dos columnas (contenido + sidebar de metadata)

Para forms grandes (crear/editar un recurso): header (pill + título + ✕),
**cuerpo a dos columnas** — contenido principal + `<aside>` de metadata
(`w-80 lg:w-96`, `hidden md:flex`, scroll propio) — y footer. Casi full-screen.

```heex
<div :if={@show_modal?} id="thing-modal-overlay"
     class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 sm:p-6"
     phx-window-keydown="cancel_form" phx-key="Escape">
  <div id="thing-modal" role="dialog" aria-modal="true" phx-click-away="cancel_form"
       class="card bg-base-100 border border-base-300 shadow-2xl w-full flex flex-col overflow-hidden
              h-[calc(100vh-3rem)] sm:h-[calc(100vh-4rem)] max-w-5xl">
    <%!-- Header --%>
    <div class="flex items-center justify-between px-5 py-3.5 border-b border-base-300 shrink-0">
      <div class="flex items-center gap-2.5 min-w-0">
        <span class="text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0 bg-primary/10 text-primary">Nota</span>
        <h3 class="text-base font-semibold truncate">Nueva …</h3>
      </div>
      <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-xs btn-circle" aria-label="Cerrar">
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>

    <%!-- Body: contenido + sidebar --%>
    <div class="flex-1 min-h-0 flex overflow-hidden">
      <div class="flex-1 min-w-0 overflow-y-auto p-6">
        <.form for={@form} id="thing-form" phx-submit="save">…</.form>
      </div>
      <aside class="hidden md:flex md:flex-col w-80 lg:w-96 shrink-0 border-l border-base-300 bg-base-200/40 overflow-y-auto p-5 gap-4">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">Detalles</h4>
        …
      </aside>
    </div>

    <%!-- Footer --%>
    <div class="flex items-center justify-between px-5 py-3 border-t border-base-300 shrink-0">
      <div class="flex items-center gap-2">{render_slot(@left)}</div>
      <div class="flex items-center gap-2">
        <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
        <button type="submit" form="thing-form" class="btn btn-primary btn-sm">Guardar</button>
      </div>
    </div>
  </div>
</div>
```

- El botón **Guardar vive FUERA del `<form>`** (footer) y lo apunta con el
  atributo HTML `form="thing-form"` → el `id` debe coincidir con el del `<.form>`.
- La **sidebar de metadata** va `hidden md:flex` (oculta en móvil) y scrollea
  independiente (`overflow-y-auto`).

Reglas (ambos):

- **Visible sólo cuando el assign existe** (`:if={@form != nil}` / `@show_modal?`).
- **Cierre por backdrop `phx-click` + Escape**
  (`phx-window-keydown` + `phx-key="Escape"`).
- **Anchos:** `max-w-md` (confirmaciones) · `max-w-lg` · `max-w-2xl` (forms) ·
  `max-w-5xl` (modales de dos columnas).
- **Confirmaciones destructivas:** `data-confirm="¿…? Esta acción no se puede deshacer."`
  en el botón.

### C8. Buscadores y selects

Elige el control por la matriz: ¿cuántos valores? × ¿la lista es grande (necesita buscar)?

| | **1 valor** | **N valores** |
|---|---|---|
| **Pocos** (≤ ~10, sin scroll) | **C8.1 select** | **C8.5 badges toggleables** |
| **Muchos** (buscar) | **C8.3 combobox single** | **C8.4 combobox multi** |

Para texto libre con sugerencias (catálogo largo, valor custom): **C8.2 datalist**.

#### C8.1 Select simple (1 valor, sin buscar)

`<.input type="select" options={…} prompt="…" />` — el `<select>` nativo
(`w-full select`). Para un select suelto fuera de un form:
`<select class="select select-bordered select-sm w-full">`.

```heex
<.input field={@form[:owner_id]} type="select" prompt="Elige…" options={@owner_options} />
```

#### C8.2 Datalist (texto libre + sugerencias)

`<.input type="datalist" options={…} />` — input de texto con `<datalist>`: el
usuario elige de la lista **o** escribe cualquier valor.

```heex
<.input field={@form[:model]} type="datalist" label="Modelo" options={@catalog} />
```

#### C8.3 Combobox single (1 valor, con buscar)

Asigns: `<kind>_search` (texto), `<kind>_open` (bool), `current_<kind>_id`
(elegido). El pick **refleja el label y cierra**.

```heex
<div class="relative" phx-click-away="close_pickers">
  <input type="text" name="thing[owner_id_display]" value={@owner_search}
    phx-focus="open_picker" phx-value-picker="owner"
    phx-change="owner_search" phx-debounce="200"
    autocomplete="off" placeholder="Buscar…" class="input input-sm w-full" />
  <div :if={@owner_open and @owner_results != []}
       class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-60 overflow-y-auto">
    <button :for={o <- @owner_results} type="button"
      phx-click="select_owner_item" phx-value-id={o.id} phx-value-label={o.label}
      class="block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors">
      {o.label}
    </button>
  </div>
</div>
```

#### C8.4 Combobox multi (N valores, con buscar)

Igual que el single, pero el pick **NO cierra** y **acumula** ids
(`current_<kind>_ids`); los elegidos se muestran como **chips** debajo del input
(cada chip con su `<button>`/icono de quitar) y `✓` en la fila activa.

```heex
<div :if={@current_owner_ids != []} class="flex flex-wrap gap-1 mt-2">
  <span :for={id <- @current_owner_ids}
    class="badge badge-sm badge-primary gap-1 cursor-pointer"
    phx-click="toggle_owner" phx-value-id={id}>
    {label_for(id)} <.icon name="hero-x-mark" class="size-3" />
  </span>
</div>
```

#### C8.5 Badges toggleables (N valores, sin buscar)

Para listas cortas (grants): botones `badge` que alternan. Estado: seleccionado =
`badge-primary` (`badge-accent` para "extra"); libre = `badge-outline` + hover.

```heex
<button :for={m <- @models} type="button"
  phx-click="toggle_model" phx-value-id={m.id}
  class={["badge badge-sm transition-all",
          m.id in @granted_ids && "badge-primary",
          m.id not in @granted_ids && "badge-outline cursor-pointer hover:badge-primary/50"]}>
  {m.name}
</button>
```

#### Reglas duras de los combobox (vienen de bugs reales)

1. **El input SIEMPRE va nombrado** (`name="…"`). Sin `name`, dentro de un form,
   LiveView serializa payload vacío en `phx-change` y la búsqueda se borra en
   cada tecla.
2. El handler de búsqueda acepta **ambas formas** del payload (`%{"value" => q}`
   y la anidada `%{ns: %{campo => q}}`) — resolver con cláusulas.
3. **Pick single = reflejar label + cerrar.** **Pick multi = acumular + quedar abierto.**
4. **`phx-click-away` en el wrapper** + `Escape` a nivel form. Nunca dejar el
   dropdown "zombie" abierto.
5. **No** uses `phx-keyup` para filtrar (reabre al soltar Escape). `phx-change` +
   `phx-debounce` (`200` buscar · `300` autocomplete).

### C9. Gráficas (charts)

**No hay librería de gráficas.** En la familia las gráficas son **SVG escritas a
mano en HEEx** (o barras con `style="height: …%"`); los datos se **preprocesan en
Elixir** y las escalas se calculan en el **servidor**.

```heex
<%!-- Bar chart canónico: card + svg --%>
<div id="usage-chart" class="card bg-base-100 border border-base-300 shadow-sm">
  <div class="card-body">
    <h2 class="card-title text-base">
      <.icon name="hero-chart-bar" class="size-5 text-base-content/60" /> Uso
    </h2>
    <div :if={@series == []} class="h-40 flex items-center justify-center text-base-content/40 text-sm">
      Sin datos
    </div>
    <div :else class="flex">
      <div class="flex flex-col justify-between text-[10px] text-base-content/50 pr-1 h-40 text-right w-8">
        <span :for={l <- @y_labels}>{l}</span>
      </div>
      <svg viewBox="0 0 400 150" class="flex-1 h-40" preserveAspectRatio="none">
        <rect :for={{row, i} <- Enum.with_index(@series)} x={10 + i * (@bar_width + 4)}
              y={140 - max(row.value / @max_value * 120, 1)} width={@bar_width}
              height={max(row.value / @max_value * 120, 1)} rx="2" class="fill-primary transition-colors">
          <title>{row.label} — {row.tooltip}</title>
        </rect>
        <line x1="10" y1="140" x2="390" y2="140" class="stroke-base-300" stroke-width="1" />
      </svg>
    </div>
  </div>
</div>
```

Reglas:

- **Sin dependencias JS de charts** (nada de apexcharts/echarts/chart.js/d3).
- **Escalas en el servidor:** helpers Elixir (p. ej. escala `sqrt` con mínimo 4%
  para barras; escala lineal para el sparkline). El template sólo pinta.
- **Contenedor:** SVG con `viewBox` + `preserveAspectRatio="none"` y altura fija
  (`h-40`, `h-8`); o barras con `style="height: …%"` dentro de altura fija.
- **Color de serie:** de una paleta definida en la app (nunca hex suelto).
- **Ejes y labels:** `text-[10px]`/`text-xs`, `text-base-content/40-50`,
  `tabular-nums` en los valores.
- **Tooltip:** `<title>` dentro del nodo SVG (o `title=` en la barra).
- **Empty state:** contenedor de la misma altura con texto centrado
  (`text-base-content/40`).
- **Sparkline:** `<svg viewBox="0 0 200 30">` + `<polyline points=… fill="none"
  stroke="currentColor" class="text-primary/40" stroke-width="1.5">`.
- **Hover:** realce sutil (`group-hover:brightness-110`), sin re-render.

### C10. Estados

| Estado | Estándar |
|---|---|
| Loading | `.skeleton` (shimmer) o `loading loading-spinner` |
| Empty | icono + texto centrado (`text-base-content/40`) |
| Error | `text-error` inline, o `alert alert-error` |
| Éxito | flash `alert-info` (toast top-end) |

### C11. Convenciones

- **`id` estable** en todo control clave (forms, botones, filas) → `has_element?/2`.
  Form: `id="thing-form"`; fila: `id={id}` (del stream).
- **Assigns por picker:** `<kind>_search` / `<kind>_open` / `current_<kind>_id(s)`.
- **Filtros** alineados a la **derecha** del header, siempre.
- **Modales** = overlay div; cierre por assign.
- **Datos crudos nunca en pantalla:** formatters.
- **Tema:** sólo vars del tema; cero hex/oklch hardcodeado.
- **i18n:** `Gettext`.
- Cierra siempre con **`mix precommit`** (alias en `mix.exs`).

---

## Custom — Dran

Este `DESIGN.md` es de **Dran**. Tema `night` (único) · `<html lang="es" data-theme="night">`; es la app con el
sistema de tokens propio más completo y el editor de contenido.

> **Tema: `night`, no `dark`.** El Commons dice "tema `dark`" porque es el de gorim;
> TokenGate usa `dim` y Dran usa `night` (commits `0366b01`, `fb2cf8f`). El Commons
> generaliza a *un* tema built-in por app, declarado acá: `app.css` →
> `@plugin "../vendor/daisyui" { themes: night --default; }` y `root.html.heex:2` →
> `data-theme="night"`. Todo lo demás de §C2 (usar las vars del tema, nunca hex suelto)
> aplica igual.

### D1. Sistema propio de tokens (`app.css`, bloque "DRAN DESIGN SYSTEM")

**Escala tipográfica** (usar estas clases, no tamaños sueltos):

| Clase | Tamaño / peso | Uso real |
|---|---|---|
| `text-display` | 2.25rem / 800, `-0.02em` | hero del dashboard |
| `text-title` | 1.5rem / 700, `-0.01em` | título de página |
| `text-heading` | 1.125rem / 600 | título de card/sección |
| `text-body` | 0.875rem / 400 | cuerpo |
| `text-caption` | 0.75rem / 500, `content/55%` | metadata, hints |

Uso observado: `text-caption` (75×), `text-title` (26×), `text-heading` (10×).
Para el resto, utilidades Tailwind directas.

**Superficies y elevación:**

```css
:root {
  --shadow-surface-2: 0 1px 2px oklch(0% 0 0 / 0.08);
  --shadow-surface-3: 0 4px 12px oklch(0% 0 0 / 0.12);
}
```

| Clase | Fondo | Sombra | Uso |
|---|---|---|---|
| `.surface-1` | `--color-base-200` | — | paneles hundidos |
| `.surface-2` | `--color-base-100` | `--shadow-surface-2` | **card estándar** (29×) |
| `.surface-3` | `--color-base-100` | `--shadow-surface-3` | popovers / destacados |

**Micro-interacciones propias:** `.lift` (translateY −0.5px + shadow-3),
`.skeleton` (shimmer, respeta `prefers-reduced-motion`), `.focus-ring`, y la
regla global `:focus-visible { outline: 2px solid var(--color-primary) }`.
Transiciones `transition-all duration-150`; desplazamientos `hover:translate-x-0.5`.

### D2. Shell

`Layouts.app` — `flex h-screen` con **sidebar a la izquierda**
(`w-64 border-r border-base-300 bg-base-200/50`) y contenido `flex-1 overflow-y-auto`.

- **Sidebar:** logo + `<.workspace_selector>` (`id="context-selector"`,
  `select select-sm`), buscador del workspace (`GET /:slug/search`, icono +
  `kbd ⌘K`), nav en `<details open>` colapsables (chevron `group-open:rotate-90`),
  `sidebar_footer_icons` y `user_footer`.
- **Nav link activo:** `bg-primary/10 text-primary font-medium border-l-2 border-primary`.
- **Opciones del shell:** `sidebar={false}` (oculta el `aside`), `topbar` +
  `topbar_active={:dashboard | :account | :admin}` (barra `<.app_topbar>` con el
  logo a la izquierda y el menú de opciones —Workspaces, Account, Admin y
  Salir— arriba a la derecha, con la opción activa resaltada), `fluid` (contenido
  sin padding interno), `active_nav`.
- **Shell sin sidebar:** lo comparten las tres opciones de instancia y sus
  subpáginas — `/`, `/settings/account`, `/settings/api-keys` y todo `/admin/*` —
  vía `sidebar={false}` + `topbar`. El contenido lo paddea el layout
  (`px-6 pt-6 pb-16`) y la opción Admin solo aparece para owners.
- **Command palette:** `DranWeb.CommandPalette` (`#command-palette`, `phx-hook`, ⌘K) —
  overlay `fixed inset-0 z-50 bg-black/50 backdrop-blur-sm`, panel
  `mx-auto max-w-lg rounded-xl border border-base-300 bg-base-100 shadow-2xl`
  (margen superior 15vh), selección `bg-primary/10`.

### D3. Componentes extra

| Componente | Qué es |
|---|---|
| `DranWeb.Admin.section/1` | sección: `.surface-2 rounded-2xl` con header (icono en `bg-primary/10` + `text-heading` + `text-caption`) |
| `DranWeb.Admin.modal/1` | modal compacto: overlay `bg-black/50`, `card`, `phx-click-away`, `max_w` (`max-w-lg` por defecto) |
| `DranWeb.ResourceComponents.resource_modal/1` | modal **casi full-screen** (`h-[calc(100vh-3rem)]`, `max-w-5xl`) |
| `DranWeb.ResourceComponents.resource_header/1` · `form_actions/1` · `markdown_body_field/1` | header con back-link, fila cancelar/guardar, campo body con editor |
| `DranWeb.MarkdownEditorComponents.markdown_editor/1` | editor TipTap |
| `DranWeb.PageComponents` · `PageListComponents` · `VersionDiffComponent` | piezas de páginas y diff de versiones |

### D4. Modal de recurso (crear/editar) — `<.resource_modal>`

Implementación Dran del patrón **Commons C7.2** (modal de dos columnas): casi
full-screen, header (pill + título + ✕), cuerpo a dos columnas (contenido + slot
`:sidebar` metadata) y footer.

```heex
<.resource_modal id="page-modal" title="Nueva página" pill="Nota"
  on_close="close_modal" form_id="page-form" submit_label="Guardar">
  <.form for={@form} id="page-form" phx-submit="save">…</.form>
  <:sidebar>…</:sidebar>
</.resource_modal>
```

- Cierra con ✕, **ESC** (`phx-window-keydown` + `phx-key="Escape"` en el overlay)
  y **click-away**, todos → `on_close`.
- El botón **Guardar vive FUERA del `<form>`** (footer) y lo apunta con
  `form={@form_id}` → `form_id` debe coincidir con el `id` del `<.form>`.

### D5. Contenido enriquecido

- **Editor TipTap:** estilos `.md-editor`, `.editor-toolbar` (sticky + blur),
  `.tb-btn` (`.is-active` = `bg-primary`), `.tiptap` (tipografía tipo Notion,
  blockquote, code, tablas, selección con tinte primary).
- **Mermaid:** `.mermaid-rendered` (lectura) y `.mermaid-codeblock` (preview inline).
  Hooks: `assets/js/hooks/{mermaid,mermaid_codeblock,graph_3d,markdown_editor}.js`.
- **Solo lectura:** `prose` (plugin `@tailwindcss/typography` cargado) + clases
  propias `.inline-link`, `.wikilink`, `.wikilink-broken`, `.embed` / `.embed-broken`.
- **Tags:** `.tag-link`, `.tag-link-exists` (primary), `.tag-link-missing` (warning).
- **Gráficas:** `journey_live.ex` — barras horizontales
  (`style="width: …%; background-color: <type color>"`) + sparkline SVG
  (`viewBox="0 0 200 30"`, `<polyline class="text-primary/40">`); escalas en
  helpers (`bucket_width/2`, `build_sparkline/1`). Contenedor `.surface-2 p-5 rounded-2xl`.

### D6. ✅ Discordancia resuelta

El `<.table>` de `core_components.ex` rendía `table table-zebra` y `app.css` no tenía
la regla global de hover de §C6. **Ambas cosas están corregidas** (commit `6ac1e56`):

- `lib/dran_web/components/core_components.ex:380` → `table table-sm` (sin zebra).
- `assets/css/app.css:556-562` → `.table tbody tr` + `.table tbody tr:hover`
  (`color-mix(in oklab, var(--color-base-200) 60%, transparent)`).

Verificar con:
```bash
grep -n 'table table-sm' lib/dran_web/components/core_components.ex
grep -n 'tbody tr:hover' assets/css/app.css
```

### D7. Modelo de página (4 tipos + tipos custom por workspace)

El vocabulario de páginas quedó reducido y movido:

- **Cuatro tipos built-in**: `note`, `reference`, `entity`, `concept`. Son los únicos
  valores de `Dran.PageRegistry.types/0`.
- **`meta.kind` NO existe.** Se fueron el select de kind del editor, el filtro `?kind=`
  de las listas, la validación por kind, `kind_labels/0` y `kind_options/*`.
  `meta.props` **se queda** (bolsa libre de propiedades, ortogonal, con
  `PropsMaterializer`).
- **Tipos custom por workspace**: `workspaces.workspace_page_types` (jsonb, lista
  ordenada de `{slug, label, plural, path, icon, color, meta_fields}`). Los tipos
  efectivos de un workspace = 4 built-in ∪ custom. El `path` es explícito y único dentro
  del workspace (el sidebar y la leyenda del grafo iteran la lista, y el orden importa).

**Reglas de UI que se derivan:**

- **El sidebar y la leyenda de tipo iteran los tipos efectivos del workspace**, nunca
  `PageRegistry.types()` a secas: un tipo custom debe aparecer con la misma dignidad que
  un built-in. El color del nodo y del chip salen de `ui.color` del tipo (built-in del
  registry, custom de la config del workspace).
- **Sin cláusulas por tipo.** Un helper con una cláusula por slug (el patrón
  `type_chip_bg/1`, `type_icon_color/1`, `type_badge/1` de `search_live.ex:509-538`)
  está prohibido: un tipo custom nace sin cláusula y cae al fallback. El color viaja en
  el dato del tipo, no en una tabla de casos.
- **Iconos de tipo custom**: los `.hero-*` solo compilan si `app.css` los escanea. El
  `@source` debe cubrir el directorio donde vive el registry **y** cualquier icono
  elegible en el formulario de tipos custom, o el icono rinde vacío sin diagnóstico.

### D8. Deuda de estandarización (medida)

Cifras reales medidas con grep (no estimadas):

| Regla | Hoy (medido) | Trabajo |
|---|---|---|
| C1/C2 — "Un solo tema: `dark`" | **Dran corre `night`**, no `dark`: `root.html.heex:2` → `<html lang="es" data-theme="night">`; `app.css:24` → `themes: night --default;` (commits `0366b01`, `fb2cf8f`). Los otros dos repos sí usan `dark`/`dim` | Corregir el texto: el Commons generaliza a "un tema built-in por app, declarado en Custom"; Dran declara `night`. **No se cambia el tema** |
| C3 — header de página | **`<.header>` tiene 0 usos** (`grep -rn "<\.header[^_a-zA-Z]" lib test assets` → vacío). El que se usa en `activity_live.ex:71` es `<.header_section>`, un `defp` local (`:94`). Hay **34 `h1`**, 24 con `text-title` y 9 con `text-2xl/3xl font-bold`. El `<.header>` del Commons (`core_components.ex:332-346`) usa `text-lg font-semibold`, no la escala de D1 | Decidir: header de página con la escala propia (`text-title`). Ojo: tocar `<.header>` afecta a los 3 repos si sube al Commons — la escala propia es un override de Dran (§Dudas) |
| C5 — una sola forma de caja | La forma canónica `card bg-base-100 border border-base-300 shadow-sm` tiene **0 usos**. Conviven: `card bg-base-100 border border-base-300` sin sombra ×7, `shadow-xl`/`shadow-2xl` (modales) ×3, y **`surface-2` ×29 en 12 archivos** — a la que D1 llama literalmente "**card estándar**" | Elegir: `surface-2` como caja canónica de Dran (gana 29–11 en uso y ya es la que D1 declara), y dejar `card` + sombras para modales |
| C4 — botón secundario | `btn-outline` ×3 (`login_live.ex:71`, `settings_live.ex:732,947`), `btn-soft` ×1 | Decidir y escribir la regla (`btn-outline` para "otra vía" es legítimo si se documenta) |
| C9/C11 — color de serie | `graph_helpers.ex:15-24`: 6 hex de relación (`#94A3B8`, `#EF4444`, `#F59E0B`, `#10B981`, `#A78BFA`, `#64748B`); `graph_3d.js` repite `#94A3B8` ×6 como fallback; 0 `@apply` | Mover a una paleta nombrada; los tipos ya declaran su color en el registry |
| C11 — ids estables | `data-testid` ×24 convivendo con 91 `id="` sin regla escrita; el borrado de kind se lleva 5 testids (`kind-filters`, `kind-option-*`, `kind-clear`, `kind-filter-toggle`, `kind-filter-menu`) que **2 asserts usan** (`pages_live_test.exs:84,238`) | Fijar la convención y decidir el reemplazo de los testids de kind **antes** de tocar la UI |
| D3 — componentes extra | El `@doc` de `admin.ex:71` documenta `<.admin_section …>` pero la función es `section/1` (`:82`); 11 usos de `<.section>` y 1 de `<.admin_section>` (dentro de su propio doc). La lista de D3 omite 7 componentes de `page_components.ex` (`backlinks_section/1:361`, `tabs_bar/1:453`, `empty_state/1:502`, `graph_3d/1:547`, `page_attributes/1:815`, `page_edit_form/1:883`, `page_new_form/1:938`) | Corregir el `@doc` y completar la lista |

### D9. Referencias (código real)

- `lib/dran_web/components/core_components.ex` — `flash`, `button`, `input`,
  `header`, `table`, `list`, `icon`, `show/hide`.
- `lib/dran_web/components/admin.ex` — `DranWeb.Admin.modal/1`, `section/1`.
- `lib/dran_web/components/resource_components.ex` — `resource_modal`,
  `resource_header`, `form_actions`, `markdown_body_field`.
- `lib/dran_web/components/command_palette.ex` — `DranWeb.CommandPalette` (⌘K).
- `lib/dran_web/components/layouts.ex` — shell `app/1`, `sidebar_nav`, `nav_link`,
  `sidebar_footer_icons`, `workspace_selector`, `user_footer`.
- `lib/dran_web/components/layouts/root.html.heex` — `data-theme="night"`, `lang="es"`.
- `assets/css/app.css` — escala tipográfica, superficies, skeleton, lift, foco,
  TipTap, mermaid, wikilinks/tags/embeds.
- Skills: `liveview-ui-wiring` (pickers), `phoenix-daisyui-theming` (tema).
