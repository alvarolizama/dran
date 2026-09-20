# DESIGN.md — sistema de UI

Estándar de interfaz de la familia de apps que comparten un **mismo lenguaje
visual**. El documento tiene dos partes:

- **Commons** — la base compartida por todas las apps: tema y tokens, elementos
  básicos, composición, estados y convenciones. Es idéntica en todos los repos:
  si cambias algo aquí, cámbialo en los tres `DESIGN.md`.
- **Custom** — lo específico de **esta** app (Dran). TokenGate es la referencia
  del Commons: ante la duda de cómo se ve un control, mira un LiveView de
  TokenGate antes de inventar.

**Criterio de reparto:** todo lo que se pueda compartir vive en **Commons**
(tema y marca, layout y responsive, shell/sidebar/menús, elementos y **botones
por contexto**, cards, tablas, modales, buscadores, gráficas, estados). Custom es
la excepción y cada bloque suyo dice **por qué** no es compartible (marca la
diferencia real, no el gusto). Si dudas, va a Commons.

> **Regla de oro de este doc: refleja el código.** Todo lo que se afirma aquí debe
> poder señalarse en `lib/dran_web/…` o `assets/css/app.css`. Si el código
> cambia, este archivo cambia con él.

---

## Commons — base compartida de la familia

### C1. Principios

1. **daisyUI nativo + Tailwind.** No inventes componentes si daisyUI ya trae
   (`btn`, `card`, `table`, `badge`, `input`, `select`, `alert`, `modal`,
   `dropdown`, `tabs`). CSS propio sólo para convenciones **globales**.
2. **Un solo tema por app, elegido en `app.css`.** La familia corre daisyUI
   **`dim --default`** (TokenGate, Skema y Dran), declarado en `app.css` y
   `data-theme` de `root.html.heex`; los valores concretos del tema en uso se
   documentan en **Custom** (§Paleta real). Nada de hex/oklch hardcodeado en
   plantillas: siempre las vars del tema.
3. **Reusar antes de crear.** Mira `*Web.CoreComponents` antes de escribir markup
   a mano: inputs, tablas, headers, iconos ya están.
4. **Verificable.** Todo control interactivo lleva `id` estable para tests
   (`has_element?/2`).

### C2. Tema y tokens

```css
/* assets/css/app.css */
@plugin "../vendor/heroicons";
@plugin "../vendor/daisyui" {
  themes: dim --default;   /* ← tema ÚNICO de la familia (Dran: dim, §Custom) */
}
```

```heex
<%!-- lib/dran_web/components/layouts/root.html.heex — Dran: data-theme="dim" --%>
<html data-theme="dim">
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
| Secundario | `btn-secondary` | `--color-secondary` | acento de marca |
| Acento | `btn-accent` | `--color-accent` | "extra" / activo no primario |
| Neutro | `badge-ghost` | `--color-neutral` | global / sin estado |
| Éxito | `badge-success` | `--color-success` | ok, activo |
| Aviso | `badge-warning` | `--color-warning` | warning / aviso |
| Error | `badge-error`, `text-error` | `--color-error` | destructivo |
| Info | `badge-info` | `--color-info` | informativo |

Radios y bordes salen del tema (`--radius-box`, `--radius-field`, `--border`).
No los hardcodees.

**El tema manda.** Todos los colores de la app —incluidos los del **logo del
tema** (favicon/iconos que sigan el tema) y los de gráficas— salen de los tokens
daisyUI del tema declarado en `app.css`; ninguna vista escribe hex/oklch. Cambiar
de tema = cambiar **una línea** (`themes: <tema> --default`) + `data-theme` en
`root.html.heex`: las vistas no se tocan. Los valores concretos del tema en uso
los documenta cada app en **Custom** (§Paleta real). La única excepción son los
colores de la **marca** (§C2.1), que no siguen el tema.


#### C2.1 Marca (logo y favicon)

El mark de cada app es **de la familia** y no sigue el primary del tema: usa los
colores de marca en un gradiente `#9fe88d → #62efbd` (trazos) con nodos
`#9fe88d` / `#62efbd` / `#6fbb5c` y core `#c9f7be`. Van juntos en el mismo
commit: `priv/static/favicon.svg` (fuente), `logo.png` (512 con alpha) y
`favicon.ico` (16/32/48). Si el tema cambia, el mark **no** se recolorea: el
verde de la familia es lo que hace reconocible la app.

### C3. Layout base

- El contenido principal va en un `<main>`; el **shell** (sidebar, gaveta, rail)
  es familia → **§C12** (cada app declara sólo sus secciones y opciones).
- **Header de página:** `<.header>` — título (`:inner_block`) + `:subtitle` +
  `:actions`.
- **Filtros y acciones, alineados a la DERECHA** (slot `:actions` o
  `justify-end`). Nunca a la izquierda.
- **Contenedores anchos** (tablas/paneles) envueltos en `overflow-x-auto`.

#### C3.1 Responsive (mobile-first)

Toda superficie nueva nace usable en teléfono; el escritorio es la mejora, no
el punto de partida.

| Regla | Cómo |
|---|---|
| **Corte del shell** | **`lg` (64rem)**: debajo, la navegación va en **gaveta** (overlay + hamburguesa); arriba, fija y colapsable a **rail** de iconos (§C12) |
| **Padding del contenido** | `p-4 pb-16 sm:p-6` — en móvil más ajustado |
| **Headers de página** | `flex flex-wrap items-center justify-between gap-3`: las acciones bajan de línea en pantallas chicas |
| **Tablas** | siempre `overflow-x-auto` (§C6): scrollean en horizontal, nunca rompen el layout |
| **Grids** | mobile-first: `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3`; **nunca** arrancar en 2+ columnas |
| **Anchos** | `w-full min-w-0`; los `max-w-*` son para modales y textos, no para el contenido |
| **Modales** | overlay `p-4` + card `w-full max-w-*`; las columnas de metadata van `hidden md:flex` (§C7.2) |
| **Texto** | sin truncados duros fuera de tablas/celdas; lo truncado lleva `title` |
| **Acciones** | `btn-xs`+ (target táctil); las de fila conservan `title` (§C6) |

### C4. Elementos básicos

Los controles primitivos. Todo lo demás (cards, tablas, modales, pickers) se
compone de esto.

| Elemento | Clase estándar |
|---|---|
| Botón primario | `btn btn-primary` (o `<.button variant="primary">`) |
| Botón secundario | `btn btn-primary btn-soft` (default de `<.button>`) |
| Botón neutro / cancelar | `btn btn-ghost` |
| Acción de fila | `btn btn-xs btn-ghost` (+ `title=`) |
| Destructivo | `btn ... text-error` + `data-confirm="…"` |
| Badge | `badge badge-sm` + semántico (`badge-primary/success/warning/error/info/ghost/outline/accent`) |
| Chip removible | `badge badge-sm` con `<button>` interno |
| Input de texto | `<.input field={@form[:x]} />` (nunca `<input>` a mano) |
| Icono | `<.icon name="hero-…" class="size-4" />` (heroicons, NO SVG suelto) |
| Toast (flash) | `toast toast-top toast-end z-50` + `alert alert-info/alert-error` |

**Todo pasa por `CoreComponents`** — no armes el `<input>` ni el flash a mano:

- `flash` · `button` (con `variant="primary" | nil`) · `input` · `header` ·
  `table` · `list` · `icon` · `show`/`hide` · `translate_error`/`translate_errors`.

**Primitivas de navegación y superficie** (también en `CoreComponents`, para que
cualquier LiveView las tenga por `use DranWeb, :html`, sin imports):

| Componente | Qué es | Atributos |
|---|---|---|
| `<.nav_link>` | enlace de sidebar/rail: icono + label + badge | `label` · `icon` · `path` · `active` · `badge` |
| `<.nav_group>` | rótulo de grupo + sus enlaces | `label` + slot |
| `<.menu_item>` | entrada de menú (dropdown, menú de usuario) | `href` · `icon` · `label` · `active` |
| `<.section>` | sección: caja con header (badge + título + caption) | `title` · `icon` · `caption` + slot |
| `<.modal>` | modal compacto (C7.1): ✕ / Escape / click-away | `id` · `title` · `on_close` · `max_w` + slot (el caller lo gatea con `:if`) |
| `<.empty_state>` | estado vacío canónico (C6) | `icon` · `title` · `caption` · `class` + slot CTA |

Nacieron en admin/settings y en el shell y se promovieron a `CoreComponents`
para que no exista una segunda copia: si una pantalla necesita un enlace de nav,
una sección, un modal o un estado vacío, **usa el componente compartido** — no
escribas markup nuevo ni un helper local.

#### C4.1 Botones por contexto

El mismo `btn` cambia de forma según dónde viva; no hay un "botón estándar"
único:

| Contexto | Forma |
|---|---|
| **CTA de la página (crear)** | `<.button phx-click="new_x" id="new-x-btn">` + icono `hero-plus` (default = `btn-primary btn-soft`); id kebab `new-*-btn` = ancla de tests |
| **Submit de un form** | `<button type="submit" class="btn btn-primary btn-sm">` (sólido: ahí el sólido ES el CTA del formulario) |
| **Cancelar / cerrar** | `btn btn-ghost btn-sm` |
| **Acción de fila** | `btn btn-xs btn-ghost` + `title` (§C6) |
| **Destructivo** | `btn … text-error` + `data-confirm="¿…? Esta acción no se puede deshacer."` |
| **Toggle de filtro / periodo** | `btn-ghost`; activo `btn-primary` |
| **Otra vía** (login social) | `btn btn-outline` |
| **Navegación** | `<.nav_link>` (§C12.3) |

**`btn-outline` es legítimo para "otra vía"** — misma jerarquía que el
primario, camino alternativo (p. ej. "Continuar con Google"), no una variante
de color.

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
- **Densidad del `card-body`** (elegir según el contenido): `p-4` (denso: listas,
  KPIs) · `p-5` (medio) · `p-6` (forms) · `p-8` (hero).
- **Título:** `card-title text-base` + icono `size-5 text-base-content/60`.
- **Card interactiva (clicable):** `hover:shadow-md transition-shadow`.
- **Card de sección con header** (badge de icono + título + caption): cada app la
  tiene → ver **Custom** (Dran: `.surface-2`, §T1).
- **Card de modal:** `shadow-xl` en vez de `shadow-sm` (ver C7).
- Sombras y radios del tema (`--radius-box`, `shadow-sm/md/xl`); no a mano.

**La misma card según dónde esté:**

| Lugar | Forma |
|---|---|
| Página / sección con header | `.surface-2` (badge de icono + título + caption) — la caja de sección de cada app (§Custom) |
| Contenedora de tabla | `catch` + `overflow-x-auto` (§C6) |
| Lista / filas | `card-body p-4` denso, hover de fila, sin zebra |
| KPI / stat | `card-body p-4`, número `text-2xl font-semibold`, label `text-caption` |
| Modal | `shadow-xl` + `card-body p-6` (§C7) |
| Estado vacío | `card` centrada con `<.empty_state>` (§C10) |

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

- **`table table-sm` siempre.** Envuelta en `overflow-x-auto` + card. Columnas de
  ancho fijo: `table table-sm table-fixed w-full`.
- **Hover de fila, sin zebra** — regla global, una vez por app:
  ```css
  .table tbody tr { transition: background-color 150ms ease; }
  .table tbody tr:hover { background-color: color-mix(in oklab, var(--color-base-200) 60%, transparent); }
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
- **El verbo dice lo que hace el botón, no el color:** un cierre ("Cancelar",
  "← Volver") no viaja en la fila del CTA, y una unión de recurso no se rotula
  "Crear". El par primario/secundario expresa jerarquía; el label, la acción.

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
- **Color de serie:** de una paleta **nombrada** definida en la app (un mapa de
  constantes con nombre, nunca el hex repetido en el call site). Si el color
  identifica un tipo de dato, viaja en el dato del tipo — no en una tabla de
  casos por slug.
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
  Form: `id="thing-form"`; fila: `id={id}` (del stream). **El `id` es la
  convención primaria de toda la familia.**
- **`data-testid` sólo donde no hay id natural:** contenedores y estados sin
  `<form>`/fila/stream detrás. `kebab-case`, la parte variable al final tras un
  guion, y nunca como sustituto de un `id` que ya existe. **Todo testid nuevo
  nace con su consumidor en `test/`**: un testid que ningún test lee es ruido.
- **Assigns por picker:** `<kind>_search` / `<kind>_open` / `current_<kind>_id(s)`.
- **Filtros** alineados a la **derecha** del header, siempre.
- **Modales** = overlay div; cierre por assign.
- **Datos crudos nunca en pantalla:** formatters.
- **Tema:** sólo vars del tema; cero hex/oklch hardcodeado (en HEEx y en los
  hooks JS: usar `cssColor("--color-…", fallback)`, nunca hex fijo).
- **i18n:** `Gettext`.
- Cierra siempre con **`mix precommit`** (alias en `mix.exs`).


### C12. Shell (sidebar, navegación y menús)

El shell de la familia es **sidebar + barra de contenido** (sin topbar de
escritorio). Cada app declara su tema y sus secciones en **Custom**; la mecánica
es esta — Dran es la implementación de referencia.

#### C12.1 Estructura

- Raíz `h-screen` + **daisyUI `drawer lg:drawer-open lg:grid-rows-1 h-full`**. Las
  **dos** clases `lg:` son estructurales: la de la fila tiene su propia regla
  dura en **§C12.5** (sin ella el shell scrollea entero).
- **Barra del contenido (`h-14`), siempre visible: es el ÚNICO sitio del toggle
  de navegación.** En `< lg` es la hamburguesa (`label for="app-drawer"`) que
  abre la gaveta; en `≥ lg`, el mismo botón en la misma posición
  colapsa/expande la sidebar (`label for="sidebar-collapse"`). **Nunca dos
  controles**: el sidebar no lleva chevron propio.
- **Móvil (`< lg`):** la sidebar vive en la gaveta (`drawer-side` +
  `drawer-overlay`); cerrar = overlay o navegar. La gaveta no se persiste.
- **Desktop (`≥ lg`):** sidebar fija, **colapsable a rail de iconos** (4rem) con
  el checkbox `#sidebar-collapse` (hermano del `.drawer`): se angosta, los
  textos con `.shell-hide` desaparecen (marca, selector, buscador, labels de
  enlaces y grupos, badges, nombre/email) y quedan **logo + iconos** centrados
  con `title` (tooltip). **No** se oculta la sidebar ni se usa botón flotante:
  un `fixed` tapa el título de la página. En el rail el menú de usuario abre
  hacia la derecha y el `.drawer-side` pierde el recorte (`overflow: visible`) —
  el scroll lo lleva el `<nav>` interno del aside.
- Sidebar `w-60 shrink-0 border-r border-base-300 bg-base-200/50 flex flex-col`.
  Densidad: header `p-3`, búsqueda `p-3`, nav `flex-1 overflow-y-auto p-2 flex
  flex-col gap-4`, pie `p-3 border-t`.

#### C12.2 Anatomía de la sidebar

| Zona | Contenido |
|---|---|
| header | logo + wordmark · selector de contexto (`select select-xs`) |
| búsqueda | form GET del contexto con hint `⌘K` |
| nav | entradas siempre visibles + grupos (`<.nav_group>`) |
| pie | `<.user_footer>`: avatar + nombre/email + menú |

#### C12.3 Navegación y menús

- **`<.nav_link>`**: `btn btn-sm w-full justify-between font-normal`; inactivo
  `btn-ghost text-base-content/80`; **activo `bg-primary/15 text-primary
  font-medium hover:bg-primary/20` + `aria-current="page"`**. **No** usar
  `btn-primary btn-soft` para el activo: mezcla sólo 8% del color con `base-100`
  y el pill se lee gris. Badge `badge badge-sm` (ghost; primary si activo).
  `title` con el label — es el tooltip del rail.
- **`<.nav_group>`**: rótulo `text-xs font-semibold uppercase tracking-wider
  text-base-content/70`, `px-3 pt-1 pb-1`; grupos con `gap-4`, links con `gap-1`.
- **Menú de usuario** (`#user-menu`, `<.menu_item>`), anclado abajo-izquierda:
  **Workspaces** (→ `/`, siempre: es la vuelta al listado desde cualquier URL) ·
  Profile · API keys · *(divider, sólo con contexto)* entradas del contexto ·
  *(divider)* Log out. El entry activo: `aria-current="page"` + `text-primary`.
- **Sin navegación duplicada:** si el sidebar ya lleva a una sección, la página
  no la repite adentro; las acciones de contexto van en el menú de usuario, no
  en el nav. La identidad de una página la dan su `<h1>` + caption.

#### C12.4 Padding del contenido

Lo pone el layout: `p-4 pb-16 sm:p-6`. El `pb-16` es el aire final del scroll
(la última card nunca queda pegada al borde). Nunca dejar el contenido sin
padding.

#### C12.5 Reglas duras del shell (vienen de bugs reales)

1. **La fila del `.drawer` va acotada: `lg:grid-rows-1`.** El `drawer` de daisyUI
   es un grid y declara **sólo `grid-auto-columns`**: la fila queda **implícita**
   y su alto lo decide `grid-auto-rows` (default `auto`), así que **se infla con
   el contenido de la página**. Con contenido largo scrollea el shell ENTERO — la
   barra del contenido y la sidebar se van con la rueda, y `main` se queda sin
   scroll propio — en lugar de scrollear el contenido por dentro con la sidebar
   fija. Hay **dos palancas equivalentes** y la familia usa las dos: la utilidad
   en el markup (`lg:grid-rows-1`, que funciona porque daisyUI ya trae
   `grid-row-start: 1` en los dos hijos) o la regla en `app.css`
   (`grid-auto-rows: minmax(0, 1fr)` sobre `.drawer`, que es la general — vale
   también si la fila fuera de verdad implícita). **Una de las dos, nunca
   ninguna**; en Dran es la utilidad (`layouts.ex`).
   `repeat(1, minmax(0, 1fr))` acota la fila al viewport: el `minmax(0, …)` es lo
   que permite bajar por debajo del contenido.
   **Scope `lg`**, no negociable: en `< lg` el `.drawer-side` es overlay
   `position: fixed` y no hay columna que acotar (móvil se comporta igual con y
   sin la clase).
2. **No lo tapes con `overflow: hidden` en `.drawer`.** La fila seguiría
   creciendo (recortar no acota el tamaño) y mataría el menú de usuario del rail,
   que abre hacia la derecha y necesita `overflow: visible` en `.drawer-side`
   (§C12.1).
3. **El que scrollea es `main`** (`flex-1 min-h-0 overflow-y-auto`), no el
   documento. La barra del contenido (`h-14 shrink-0`) y la sidebar quedan fijos.

Cómo se verifica (se mide, no se mira) — con el CSS **compilado** y contenido
largo, a 1440×900 y 1280×800, expandido y en rail:

- `documentElement.scrollHeight == innerHeight` (el documento no scrollea);
- `main.scrollHeight > main.clientHeight` (el scroll vive dentro de `main`);
- con la **ventana** scrolleada 400px, el `getBoundingClientRect().top` de la
  sidebar sigue en `0` y el de la barra del contenido también.

Medición en Dran (contenido 2968px, ventana 900px, `assets/css/app.css`
compilado): **sin** la clase, fila del drawer `3024px`, documento `3024`, `main`
`2968/2968` (sin scroll interno) y sidebar `top: -400` con la ventana scrolleada;
**con** la clase, fila `900`, documento `900`, `main` `844/2968` con scroll
interno y sidebar `top: 0` / bottom `900`. Igual en rail (sidebar 240 → 64px) y
sin diferencias en móvil 500×800. El invariante está pinchado en
`test/dran_web/live/instance_shell_test.exs`.

---

## Custom — Dran

Este `DESIGN.md` es de **Dran**. Tema **`dim` (único)**:

```heex
<%!-- lib/dran_web/components/layouts/root.html.heex --%>
<html lang={Gettext.get_locale(DranWeb.Gettext)} data-theme="dim">
```

```css
/* assets/css/app.css */
@plugin "../vendor/daisyui" { themes: dim --default; }
```

> Excepción consciente a la convención familiar (`dark`): Dran corre `dim`.
> El **logo y el favicon** conservan la paleta verde de la familia
> (`#9fe88d` / `#62efbd` / `#6fbb5c` / `#c9f7be`): son la marca, no un color de
> UI — si el primary del tema cambia, la marca **no** se recolorea sola.

### Paleta real de `dim`

Fuente de verdad: los `oklch()` que el plugin emite en
`priv/static/assets/css/app.css`. Los hex son conversión aproximada (sin
gamut-mapping), sólo para leer la tabla. Contraste = WCAG del par con su
`*-content`.

| Token | oklch | ≈hex | Rol · contraste |
|---|---|---|---|
| `--color-base-100` | `oklch(30.857% 0.023 264.149)` | `#2a303c` | fondo de app  |
| `--color-base-200` | `oklch(28.036% 0.019 264.182)` | `#242933` | paneles / hover de fila  |
| `--color-base-300` | `oklch(26.346% 0.018 262.177)` | `#20252e` | chips, bordes  |
| `--color-base-content` | `oklch(82.901% 0.031 222.959)` | `#b2ccd6` | texto principal · texto 7.9:1 vs base-100 |
| `--color-primary` | `oklch(86.133% 0.141 139.549)` | `#9fe88d` | **acción principal** (botón por defecto) · 13.0:1 |
| `--color-secondary` | `oklch(73.375% 0.165 35.353)` | `#ff7d5d` | acento de marca · 7.9:1 |
| `--color-accent` | `oklch(74.229% 0.133 311.379)` | `#c792e9` | acento "extra" · 8.2:1 |
| `--color-neutral` | `oklch(24.731% 0.02 264.094)` | `#1c212b` | panels/chips oscuros · 9.6:1 |
| `--color-success` | `oklch(86.171% 0.142 166.534)` | `#62efbd` | ok, activo · 13.2:1 |
| `--color-warning` | `oklch(86.163% 0.142 94.818)` | `#efd057` | aviso · 12.5:1 |
| `--color-error` | `oklch(82.418% 0.099 33.756)` | `#ffae9b` | destructivo · 10.8:1 |
| `--color-info` | `oklch(86.078% 0.142 206.182)` | `#28ebff` | informativo · 13.0:1 |

Pares `*-content`: `primary-content` `oklch(17.226% 0.028 139.549)` · `secondary-content` `oklch(14.675% 0.033 35.353)` · `accent-content` `oklch(14.845% 0.026 311.379)` · el resto de los semánticos también lleva su par.

Forma del tema: `color-scheme: dark` · radios `box 1rem` /
`field 0.5rem` / `selector 1rem` ·
`--border 1px` · `--depth 0` · `--noise 0`.


> **El primary pinta todos los botones por defecto.** `CoreComponents.button/1`
> sin `variant` emite `btn-primary btn-soft`, así que el color del primary es el
> esperado, no un bug de CSS. Para otro color usá la utilidad explícita
> (`btn-secondary`, `btn-accent`) — **no** redefinas el primary del tema.

### Marca (logo y favicon) — ver §C2.1

Dran usa la marca de la familia (grafo hub-and-spokes) con los **colores de
marca**, no con el primary del tema: gradiente `#9fe88d → #62efbd` en trazos y
halo, nodos `#9fe88d` · `#62efbd` · `#6fbb5c`, core `#c9f7be` (detalle y regla
de los tres archivos en §C2.1). No se recolorea al cambiar el tema.

### T1. `app.css` (561 líneas) — el design system de Dran

Sólo tema + heroicons + typography + `@custom-variant` de LiveView +
`[data-phx-session]`, **la regla global de tablas** (que es exactamente la de
§C6), el bloque TipTap/mermaid (§T7) y el bloque **"DRAN DESIGN SYSTEM"**:

**Escala tipográfica** (usar estas clases, no tamaños sueltos):

| Clase | Tamaño / peso | Uso real |
|---|---|---|
| `text-display` | 2.25rem / 800, `-0.02em` | hero del dashboard |
| `text-title` | 1.5rem / 700, `-0.01em` | título de página (`<.header>`) |
| `text-heading` | 1.125rem / 600 | título de card/sección |
| `text-body` | 0.875rem / 400 | cuerpo |
| `text-caption` | 0.75rem / 500, `content/55%` | metadata, hints |

Uso observado: `text-caption` (86×), `text-title` (33×), `text-heading` (10×),
`text-display` (4×). Un `<h1>` con `text-lg/xl/2xl/3xl` suelto es deuda.

**Superficies y elevación** (la caja canónica de Dran):

| Clase | Fondo | Sombra | Uso |
|---|---|---|---|
| `.surface-1` | `--color-base-200` | — | paneles hundidos |
| `.surface-2` | `--color-base-100` | `--shadow-surface-2` | **caja canónica de Dran** (29×) |
| `.surface-3` | `--color-base-100` | `--shadow-surface-3` | popovers / destacados |

`.surface-2` (`rounded-2xl` cuando la caja es de sección) es *la* caja de Dran;
el `card bg-base-100 …` del Commons §C5 no se usa en Dran para secciones, y
`card` + `shadow-xl/2xl` queda reservado a **modales** (§C7).

**Micro-interacciones propias:** `.lift` (translateY −0.5px + shadow-3),
`.skeleton` (shimmer, respeta `prefers-reduced-motion`), `.focus-ring`, y la
regla global `:focus-visible { outline: 2px solid var(--color-primary) }`.
Transiciones `transition-all duration-150`; desplazamientos `hover:translate-x-0.5`.

#### ¿Qué hay de CSS propio? (inventario)

| Bloque | Para qué |
|---|---|
| `@import "tailwindcss" source(none)` + `@source` ×4 | escaneo explícito de clases (v4 no autodescubre) |
| `@import "phoenix-colocated/…"` + `@source` de `_build/dev/phoenix-colocated` | CSS de hooks colocados en LiveView (dev) |
| `@plugin "../vendor/heroicons"` | `<.icon name="hero-…">` |
| `@plugin "../vendor/daisyui" { themes: dim --default }` | el tema |
| `@plugin "@tailwindcss/typography"` | `prose` para el markdown de lectura |
| `@custom-variant phx-click-loading` / `phx-submit-loading` / `phx-change-loading` | estados de carga de LiveView |
| `[data-phx-session], [data-phx-teleported-src] { display: contents }` | que los wrappers de LiveView no rompan el layout |
| `.md-editor` · `.editor-toolbar` · `.tb-btn` · `.tiptap …` | editor TipTap (§T7) |
| `.mermaid-rendered` · `.mermaid-codeblock …` | mermaid en lectura y preview (§T7) |
| `.inline-link` · `.wikilink*` · `.embed*` · `.tag-link*` | markdown renderizado y tags (§T7) |
| `.agent-step` (+ `slide-in`) | animación de pasos del worker |
| "DRAN DESIGN SYSTEM": `text-*` · `.surface-*` · `.skeleton` · `.lift` · `.focus-ring` · `:root` vars | escala tipográfica, superficies, estados |
| `.table tbody tr:hover`, `transition` (§C6) | hover de fila unificado |
| reglas de `#sidebar-collapse` sobre `.shell-sidebar` / `.shell-hide` / `.nav-link` / `.shell-sidebar-header` / `.shell-user-footer` (dentro de `@media (min-width: 64rem)`) | colapso a rail de iconos en desktop (§C12.1): el checkbox es el estado, el CSS lo aplica |

**Regla: ningún bloque propio declara color hardcodeado.** Todo color del CSS
custom sale de `var(--color-…)` o `oklch(from var(--color-…) …)` — el tema
provee, el bloque deriva. Si hace falta un color, se usa el token/utility del
tema — nunca hex, oklch crudo ni la paleta cruda de Tailwind.

**Excepciones documentadas** (las únicas):

- **Paleta nombrada del grafo.** Los colores que no son del tema viven en un
  mapa con nombre: `DranWeb.GraphHelpers` (`@neutral_color` `#94A3B8`,
  `@edge_colors`, `@fallback_color`, `@hidden_type_color`) y su espejo en el
  hook (`assets/js/hooks/graph_3d.js` → `NEUTRAL_COLOR`). Es intencional: el
  canvas WebGL no lee vars CSS; el hook las resuelve con `cssColor()`/`oklchAlpha()`
  y los fallbacks son sólo eso, fallbacks. El hex de un **tipo** de página vive
  en el registry o en la config del workspace, nunca aquí.
- **Logo/favicon** (`priv/static/favicon.svg`, `logo.png`, `favicon.ico`): la
  paleta de marca `#9fe88d`/`#62efbd`/`#6fbb5c`/`#c9f7be` (§Custom). Al cambiar
  el primary del tema, actualizarlos en el mismo commit.

### T2. Shell — lo exclusivo de Dran

La mecánica del shell (drawer, barra con el toggle único, rail, anatomía de la
sidebar, menús, padding) es **Commons: §C12**. Dran aporta lo suyo:

- **Opciones del shell:** `nav={:workspace}` (default) | `nav={:instance}` |
  `sidebar={false}` (sólo login/setup) y `active_nav`.
- **Nav de workspace:** bloque de vistas — Home · Graph · Journey — y **Memory en
  su propio bloque** (el nav separa bloques con su `gap`, así que entre Journey y
  Memory queda un hueco: Memory son hechos de los workers, no una vista de
  páginas) + grupo *Knowledge base* (tipos de página + Clusters). **Ninguna acción
  de workspace en el nav**: Activity y Workspace settings viven en el menú de
  usuario.
- **Nav de instancia (`nav={:instance}`):** Workspaces arriba; grupo *Account*
  (Profile, API keys); grupo *Admin* (Users, All workspaces, Models, System,
  Jobs) — visible para owners. **Sin item Overview**: `/admin` sigue existiendo
  como ruta (impersonation redirige ahí) pero el index de cards no es destino.
- **Banner de impersonación** (`root.html.heex`, `id="impersonation-banner"`):
  `bg-warning text-warning-content`, centrado, icono `hero-eye` y botón
  `btn-xs btn-neutral` (`id="stop-impersonating"`) — mismo tratamiento que
  TokenGate.
- **Command palette:** `DranWeb.CommandPalette` (`#command-palette`, `phx-hook`,
  ⌘K) — overlay `fixed inset-0 z-50 bg-black/50 backdrop-blur-sm`, panel
  `mx-auto max-w-lg rounded-xl border border-base-300 bg-base-100 shadow-2xl`
  (margen superior 15vh), selección `bg-primary/10`.
- **Un solo shell para toda la app:** las páginas de instancia (`/`,
  `/settings/*`, `/admin/*`) usan el mismo sidebar con `nav={:instance}`; el
  flujo topbar (`<.app_topbar>`) fue eliminado y `topbar`/`topbar_active` quedan
  como attrs deprecados no-op.
- **CSS del shell en `app.css`:** el bloque de `#sidebar-collapse` /
  `.shell-hide` / `.shell-collapse-icon` que implementa el rail (§T1).

### T3. Componentes extra

| Componente | Qué es |
|---|---|
| `DranWeb.ResourceComponents.resource_modal/1` | modal **casi full-screen** (`h-[calc(100vh-3rem)]`, `max-w-5xl`) — implementación Dran del patrón **C7.2** (§T3.1) |
| `DranWeb.ResourceComponents.resource_header/1` · `form_actions/1` · `markdown_body_field/1` | header con back-link, fila cancelar/guardar, campo body con editor |
| `DranWeb.MarkdownEditorComponents.markdown_editor/1` | editor TipTap |
| `DranWeb.PageListComponents.page_list/1` · `page_card/1` · `type_badge_label/1` | lista de páginas (agrupada o plana), card de página y badge de tipo |
| `DranWeb.PageComponents.backlinks_section/1` | backlinks de una página |
| `DranWeb.PageComponents.tabs_bar/1` | tabs del detalle (`tab-<tab>`) |
| `DranWeb.PageComponents.graph_3d/1` | hook `Graph3D` (payload JSON + `type_paths`, ver §T6) |
| `DranWeb.PageComponents.page_attributes/1` | panel de atributos/metadata de la página |
| `DranWeb.PageComponents.page_edit_form/1` · `page_new_form/1` | forms de edición y creación de página |
| `DranWeb.VersionDiffComponent` | diff de versiones |

> Las primitivas de navegación/superficie (`nav_link`, `nav_group`, `menu_item`,
> `section`, `modal`, `empty_state`) viven en `CoreComponents` (§C4), no acá:
> las comparten shell, admin y settings.

#### T3.1 `<.resource_modal>` — modal de recurso (C7.2)

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

### T4. Pickers y buscadores: implementación de referencia

Implementación real del patrón **Commons C8** en Dran:

- **Command palette (⌘K):** `command_palette.ex` — input `phx-debounce="200"`,
  `phx-click-away="close"`, resultados agrupados por tipo con el color del tipo,
  selección `bg-primary/10`. Cumple las reglas duras 1–5 de §C8.
- **Autocomplete de memoria:** `memory_live.ex` — `phx-debounce="300"`.
- **Select de workspace:** `<.workspace_selector>` (`layouts.ex`) — select nativo
  `select select-xs` (C8.1), submit on-change.
- Los colores de chip/icono/badge de un resultado **salen del dato del tipo**
  (`Workspace.page_type_color/2`), nunca de una tabla de casos por slug (§T8).

### T5. Tabla canónica

`<.table>` de `core_components.ex` rendea `table table-sm` (sin zebra; se corrigió
en el commit `6ac1e56`) con soporte `:col`/`:action` e ids de fila por item. La
regla global de hover (§C6) vive una vez en `app.css` con
`var(--color-base-200)` — en daisyUI 5 los alias `--b1/--b2/--b3` ya no existen.
Envolver en `overflow-x-auto` + caja (§T1: `.surface-2` o `card`) según contexto.

### T6. Gráficas (implementación Dran)

Sin librería (ver **Commons C9**). Tres formas reales:

- **Barras horizontales:** `journey_live.ex` — `style="width: …%; background-color:
  <type color>"` dentro de altura fija; el color viene de `@type_colors` del
  registry (paleta nombrada). Contenedor `.surface-2 p-5 rounded-2xl`.
- **Sparkline:** `journey_live.ex` — `<svg viewBox="0 0 200 30">` + `<polyline
  class="text-primary/40">`; las escalas (`bucket_width/2`, `build_sparkline/1`)
  se calculan en el servidor.
- **Grafo 3D:** `PageComponents.graph_3d/1` + hook `graph_3d.js` (force-graph).
  El payload (nodos con `color` por tipo, links con color de relación) se arma
  server-side en `GraphHelpers.build_page_subgraph/2`; el hook nunca inventa
  colores — sólo `cssColor()` para vars del tema (fondo del canvas, tooltip,
  links atenuados) y la paleta nombrada espejo (§T1 excepciones).

### T7. Contenido enriquecido

- **Editor TipTap:** estilos `.md-editor`, `.editor-toolbar` (sticky + blur),
  `.tb-btn` (`.is-active` = `bg-primary`), `.tiptap` (tipografía tipo Notion,
  blockquote, code, tablas, selección con tinte primary).
- **Mermaid:** `.mermaid-rendered` (lectura) y `.mermaid-codeblock` (preview inline).
  Hooks: `assets/js/hooks/{mermaid,mermaid_codeblock,graph_3d,markdown_editor}.js`.
- **Solo lectura:** `prose` (plugin `@tailwindcss/typography` cargado) + clases
  propias `.inline-link`, `.wikilink`, `.wikilink-broken`, `.embed` / `.embed-broken`.
- **Tags:** `.tag-link`, `.tag-link-exists` (primary), `.tag-link-missing` (warning).

### T8. Modelo de página (4 tipos + custom por workspace)

- **Cuatro tipos built-in**: `note`, `reference`, `entity`, `concept`. Son los
  únicos valores de `Dran.PageRegistry.types/0`.
- **`meta.kind` NO existe.** Se fueron el select de kind, el filtro `?kind=`, la
  validación por kind y `kind_labels/0`. `meta.props` **se queda** (bolsa libre,
  con `PropsMaterializer`).
- **Tipos custom por workspace**: `workspaces.workspace_page_types` (jsonb, lista
  ordenada de `{slug, label, plural, path, icon, color, meta_fields}`). Los tipos
  efectivos = 4 built-in ∪ custom. El `path` es explícito y único.

**Reglas de UI que se derivan:**

- **El sidebar, la leyenda y los filtros iteran los tipos efectivos del
  workspace**, nunca `PageRegistry.types()` a secas: un tipo custom aparece con
  la misma dignidad que un built-in.
- **Sin cláusulas por tipo.** Un helper con una cláusula por slug está prohibido:
  un tipo custom nace sin cláusula y cae al fallback. El color viaja en el dato
  del tipo (`Workspace.page_type_color/2`), no en una tabla de casos.
- **La excepción son las relaciones, no los tipos.** Los tipos de relación son un
  conjunto cerrado del dominio, así que una tabla de casos por relación sí es
  legítima — hoy `PageComponents.relation_type_badge_class/1` (clases
  semánticas) y `GraphHelpers.edge_colors/0` (hex para el canvas). Deuda menor
  declarada: dos mapas para el mismo hecho, unificables en la paleta nombrada.
- **Iconos de tipo custom**: los `.hero-*` solo compilan si `app.css` los
  escanea. El `@source` debe cubrir el directorio del registry y cualquier
  icono elegible en el formulario de tipos custom.

### T9. Referencias (código real)

- `lib/dran_web/components/core_components.ex` — `flash`, `button`
  (`variant` primary/nil), `input`, `header` (título `text-title`, §T1),
  `table` (`table-sm`, stream), `list`, `icon`, `show`/`hide`,
  `translate_error(s)` y las primitivas compartidas `nav_link`, `nav_group`,
  `menu_item`, `section`, `modal`, `empty_state` (§C4).
- `lib/dran_web/components/layouts.ex` — shell `app/1`, `sidebar_nav`,
  `nav_link`, `instance_nav`, `workspace_selector`,
  `user_footer`, `flash_group`.
- `lib/dran_web/components/resource_components.ex` — `resource_modal` (§T3.1),
  `resource_header`, `form_actions`, `markdown_body_field`.
- `lib/dran_web/components/command_palette.ex` — `DranWeb.CommandPalette` (⌘K).
- `lib/dran/page_registry.ex` — 4 tipos built-in: `types/0`, `ui/1` (path,
  label, icon, color, plural) y `type_colors/0` (paleta nombrada).
- `lib/dran/workspace.ex` — tipos custom: `custom_page_types/1`, `page_type_ui/2`
  y los accesos `page_type_{path,label,plural,icon,color}`. Toda superficie que
  pinta un tipo pasa por acá (built-in ∪ custom).
- `lib/dran_web/graph_helpers.ex` — paleta nombrada (relaciones, neutro,
  ocultos) y `build_page_subgraph/2`.
- `lib/dran_web/live/journey_live.ex` — barras + sparkline (§T6).
- `lib/dran_web/live/search_live.ex` — resultados de búsqueda; chip/icono/badge
  del resultado toman el color del tipo.
- `lib/dran_web/components/layouts/root.html.heex` — `data-theme="dim"`.
- `assets/css/app.css` — tema `dim --default`, escala tipográfica, superficies,
  skeleton, lift, foco, regla global de tablas, TipTap, mermaid,
  wikilinks/tags/embeds. Inventario de CSS propio en §T1.
- `assets/js/hooks/graph_3d.js` — `cssColor()`/`oklchAlpha()` (vars del tema al
  canvas), paleta nombrada espejo, tooltip HTML con `textContent` (no
  `innerHTML`).
- Skills: `liveview-ui-wiring` (pickers), `phoenix-daisyui-theming` (tema).

### Verificar

```bash
grep -n 'data-theme' lib/dran_web/components/layouts/root.html.heex   # dim
grep -n 'themes:' assets/css/app.css                                   # dim --default
grep -rn '@apply' assets/css/                                          # 0 (sólo el comentario del título)
grep -rnE 'type_chip_bg|type_icon_color|defp type_badge\b' lib/        # 0 (type_badge_label es legítimo: delega a ui_label)
grep -rn 'table-zebra' lib/                                            # 0
grep -rn 'app_topbar\|sidebar_footer_icons' lib/                      # 0 (shell topbar eliminado)
grep -n 'do: "p-6 pb-16"' lib/dran_web/components/layouts.ex           # padding de instancia
grep -c 'btn-soft' lib/dran_web/components/layouts.ex                  # 0 (el activo usa bg-primary/15)
mix tailwind dran && grep -c 'data-theme=dim' priv/static/assets/css/app.css  # 1
grep -n 'drawer lg:drawer-open' lib/dran_web/components/layouts.ex      # shell responsive
grep -c 'class="drawer lg:drawer-open[^"]*lg:grid-rows-1' lib/dran_web/components/layouts.ex  # 1 (fila acotada, §C12.5)
grep -n 'shell-hide' assets/css/app.css                                # colapso a rail (desktop)
grep -c '<.button' lib/dran_web/live/*.ex                               # CTAs de crear como componente
grep -rn 'flex-wrap items-center justify-between' lib/dran_web/live/   # headers que envuelven
grep -rn 'p-4 sm:p-6' lib/dran_web/                                    # padding mobile-first
grep -c 'for="sidebar-collapse"' lib/dran_web/components/layouts.ex     # 1 (toggle único, en la barra)
grep -c 'aside[^>]*label for="sidebar' lib/dran_web/components/layouts.ex  # 0 (el sidebar no lleva toggle propio)
grep -n 'user-menu' assets/css/app.css                                  # el menú del rail abre a la derecha
grep -n '^### C12' DESIGN.md                                            # shell en Commons
grep -n '^## Custom' DESIGN.md                                          # sólo lo exclusivo de Dran
```
