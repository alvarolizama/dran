// Graph Canvas — interactive mini-canvas for the step's internal graph.
// Lives inside the "Grafo" panel of the step editor modal.
//
// Interactions:
//   - Drag node header → reposition (snapped to 8px grid, persisted)
//   - Drag OUT port → drop on IN port → create edge (24px snap)
//   - Click an edge (the wire) → menu: romper conexión / agregar nodo aquí
//   - Double-click empty canvas → new node + edit modal
//   - "+ Nodo" button (canvas overlay) → new node at the end + edit modal
//   - Click node header (no drag) → edit modal (id / verb / label / delete)
//
// Data flow — the canvas OWNS the graph keys of the contract:
//   IN:  StepModalTabs feeds (nodes, edges) after _buildFromJson() via
//        gc.feed(nodes, edges).
//   OUT: on every change calls the registered onSync callback →
//        contract.graph = {nodes: [{id, verb, label?, x?, y?}], edges: [{from, to}]}
//
// x/y live inside each node's JSON (JSONB embed — no extra schema keys).

const NODE_W = 156
// Alto real del nodo (header h-7 = 28px + 2px de borde). Debe coincidir con lo
// que renderiza _nodeEl (que fija height explícito) para que los puertos
// (top:50%) y las aristas (n.y + NODE_H/2) queden en el MISMO punto. Con 44 las
// aristas salían ~7px por debajo del puerto y al arrastrar se desajustaban.
const NODE_H = 30
const SNAP_R = 24
const GRID = 8
// Separación entre niveles (filas) y entre nodos de un mismo nivel, y margen
// superior/izquierdo del canvas. pitchX = NODE_W + HGAP (184, /8=23 ✓) y
// pitchY = NODE_H + VGAP (88, /8=11 ✓): ambos múltiplos de la grilla de 8px.
const VGAP = 58
const HGAP = 28
const MARGIN = 24
// Umbral de clic (px) para distinguir un clic de un arrastre al soltar.
const CLICK_RADIUS = 5
// Radio (px) dentro del cual un clic sobre el vacío "engancha" una arista y
// abre su menú. La curva se muestrea y se mide la distancia al cursor.
const EDGE_HIT_R = 9

// Punto de una bezier cúbica en t — MISMA matemática que _edgeGeom usa para el
// `d` del path, así el hit-testing coincide píxel a píxel con la línea visible.
function bezier(p0, p1, p2, p3, t) {
  const u = 1 - t
  return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
}

const VERB_STYLES = {
  READ: "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300",
  EDIT: "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300",
  CREATE: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300",
  RUN: "bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-300",
  VERIFY: "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300",
  ASK: "bg-gray-200 text-gray-700 dark:bg-gray-700/40 dark:text-gray-300",
}

const GraphCanvas = {
  mounted() {
    this.nodes = []
    this.edges = []
    this.nodeMap = {}
    this.nextId = 1
    this.connecting = null
    this.dragging = null
    this.dragMoved = false
    this.editModal = null
    this.edgeMenu = null

    this._down = this._down.bind(this)
    this._move = this._move.bind(this)
    this._up = this._up.bind(this)
    this._dbl = this._dbl.bind(this)
    this._click = this._click.bind(this)
    this._onFeed = (e) => this.feed(e.detail.nodes, e.detail.edges)
    this._refit = () => {
      this._fit()
      // Si el panel estaba oculto al alimentarse, el layout se calculó sin
      // ancho; al revelarse (ancho real) se recalcula y re-renderiza.
      if (this._revealPending()) this._render()
      else this._redrawEdges()
    }

    this.el.addEventListener("mousedown", this._down)
    this.el.addEventListener("mousemove", this._move)
    window.addEventListener("mouseup", this._up)
    this.el.addEventListener("dblclick", this._dbl)
    this.el.addEventListener("click", this._click)
    this.el.addEventListener("step-tabs:feed-graph", this._onFeed)

    // El viewBox del SVG se fija al tamaño del contenedor (user-units == px),
    // así las aristas no se escalan y siempre coinciden con los nodos HTML.
    // ResizeObserver: al cambiar el alto del modal/ventana o al revelarse el
    // panel Grafo (pasa de hidden a visible → rect real), recalcula y redraw.
    if (typeof ResizeObserver !== "undefined") {
      this._ro = new ResizeObserver(this._refit)
      this._ro.observe(this.el)
    }

    // Parent hook (StepModalTabs) mounts first; by the time we mount, ask it
    // for the contract's current graph so a pre-filled JSON renders immediately.
    this.el.dispatchEvent(new CustomEvent("graph-canvas:request-feed", {bubbles: true}))
  },

  destroyed() {
    this.el.removeEventListener("mousedown", this._down)
    this.el.removeEventListener("mousemove", this._move)
    window.removeEventListener("mouseup", this._up)
    this.el.removeEventListener("dblclick", this._dbl)
    this.el.removeEventListener("click", this._click)
    this.el.removeEventListener("step-tabs:feed-graph", this._onFeed)
    if (this._ro) this._ro.disconnect()
    if (this.editModal) this.editModal.remove()
    if (this.edgeMenu) this.edgeMenu.remove()
  },

  // ── Integration surface (called by StepModalTabs) ──────────────────────

  // Replace canvas content from parsed contract data.
  feed(nodes, edges) {
    this.nodes = (nodes || []).map((n) => ({
      id: String(n.id),
      verb: n.verb || "ASK",
      label: n.label || "",
      x: Number.isFinite(n.x) ? n.x : null,
      y: Number.isFinite(n.y) ? n.y : null,
    }))
    this.edges = (edges || [])
      .filter((e) => e.from && e.to)
      .map((e) => ({from: String(e.from), to: String(e.to)}))
    this._index()
    this._layoutMissing()
    this._render()
  },

  // Current graph state, ready for contract.graph.
  collect() {
    return {
      nodes: this.nodes.map((n) => {
        const out = {id: n.id, verb: n.verb}
        if (n.label) out.label = n.label
        if (n.x !== null && n.y !== null) {
          out.x = n.x
          out.y = n.y
        }
        return out
      }),
      edges: this.edges.map((e) => ({from: e.from, to: e.to})),
    }
  },

  // ── Internal state ──────────────────────────────────────────────────────

  _index() {
    this.nodeMap = {}
    for (const n of this.nodes) this.nodeMap[n.id] = n
    // Drop edges whose endpoints vanished; dedupe.
    const seen = new Set()
    this.edges = this.edges.filter((e) => {
      if (!this.nodeMap[e.from] || !this.nodeMap[e.to]) return false
      const k = `${e.from}\u2192${e.to}`
      if (seen.has(k) || e.from === e.to) return false
      seen.add(k)
      return true
    })
    // nextId: continue after the largest numeric node id (default ids are numeric).
    let max = 0
    for (const n of this.nodes) {
      const v = parseInt(n.id, 10)
      if (Number.isFinite(v) && v > max) max = v
    }
    this.nextId = max + 1
  },

  // Auto-layout por NIVELES (Sugiyama-lite) de los nodos SIN posición. Los que
  // ya tienen x/y (movidos a mano o guardados) se respetan. Regla del usuario:
  //   - dos nodos que dependen de uno → fila horizontal bajo ese padre
  //   - los dependientes de esos → siguen en vertical (nivel siguiente)
  //   - hijo de UN solo padre → alineado bajo ese padre
  //   - hijo de VARIOS padres → centrado entre ellos (baricentro)
  //
  // Si el panel está oculto al alimentarse (tab default = intent), clientWidth
  // es 0 y no se puede centrar: se deja la estructura y se recalcula al
  // revelarse (_revealPending vía ResizeObserver).
  _layoutMissing() {
    this._autoIds = this.nodes
      .filter((n) => n.x === null || n.y === null)
      .map((n) => n.id)
    if (this._autoIds.length === 0) return
    this._needsLayoutOnReveal = !(this.el.clientWidth > 0)
    this._computePositions(new Set(this._autoIds))
  },

  // Botón "Reordenar": re-layoutea TODO el grafo por niveles, ignorando las
  // posiciones guardadas/manuals. Es opt-in (el usuario pulsa el botón), así que
  // reordenar un layout manual a propósito es el comportamiento esperado.
  _tidy() {
    if (this.nodes.length === 0) return
    const all = new Set(this.nodes.map((n) => n.id))
    this._autoIds = [...all]
    this._computePositions(all)
    this._closeEdgeMenu()
    this._render()
    this._sync()
  },

  // Motor de layout: asigna nivel (profundidad) y centro-x a cada nodo, y
  // ESCRIBE x/y solo en los ids de `idsToPos`. Los padres de cada nodo son los
  // de nivel menor, así al procesar de arriba hacia abajo el baricentro ya está
  // resuelto. Ciclo-seguro: un DFS marca las back-edges (las que cierran un
  // ciclo) y se excluyen del nivelado/baricentro — se siguen dibujando, solo no
  // empujan nodos a niveles infinitos.
  _computePositions(idsToPos) {
    if (this.nodes.length === 0) return
    const pitchX = NODE_W + HGAP
    const pitchY = NODE_H + VGAP
    const cw = this.el.clientWidth || 0
    const canvasCenter = cw > 0 ? cw / 2 : MARGIN + NODE_W / 2

    // 0. Back-edges por DFS iterativo (Sugiyama). Estado: 0=sin ver, 1=en pila
    //    (GRAY), 2=terminado (BLACK). Una arista from→to con `to` GRAY cierra
    //    ciclo → back-edge. Se recorren TODAS las componentes (raíces primero,
    //    luego nodos sueltos) para no dejar nodos sin estado.
    const adj = {}
    for (const n of this.nodes) adj[n.id] = []
    for (const e of this.edges) {
      if (adj[e.from]) adj[e.from].push(e.to)
    }
    const state = {}
    for (const n of this.nodes) state[n.id] = 0
    const backEdges = new Set()
    const roots = this.nodes.filter((n) => !this.edges.some((e) => e.to === n.id)).map((n) => n.id)
    const starts = [...roots, ...this.nodes.map((n) => n.id)]
    for (const start of starts) {
      if (state[start] !== 0) continue
      // Pila de frames: [id, índice del próximo hijo a visitar].
      const stack = [[start, 0]]
      state[start] = 1
      while (stack.length) {
        const frame = stack[stack.length - 1]
        const id = frame[0]
        const children = adj[id] || []
        if (frame[1] < children.length) {
          const child = children[frame[1]++]
          if (state[child] === 0) {
            state[child] = 1
            stack.push([child, 0])
          } else if (state[child] === 1) {
            // child en la pila actual → id→child cierra ciclo.
            backEdges.add(`${id}\u2192${child}`)
          }
        } else {
          state[id] = 2
          stack.pop()
        }
      }
    }
    const layoutEdges = this.edges.filter((e) => !backEdges.has(`${e.from}\u2192${e.to}`))

    // 1. Nivel = longest-path desde las raíces (ciclo-seguro por tope de iters).
    const level = {}
    for (const n of this.nodes) level[n.id] = 0
    const maxIter = this.nodes.length + layoutEdges.length + 4
    let changed = true
    let iter = 0
    while (changed && iter < maxIter) {
      changed = false
      iter++
      for (const e of layoutEdges) {
        const nl = level[e.from] + 1
        if (nl > level[e.to]) {
          level[e.to] = nl
          changed = true
        }
      }
    }

    // 2. Agrupar por nivel + padres de nivel estrictamente menor (baricentro).
    const byLevel = new Map()
    for (const n of this.nodes) {
      const L = level[n.id]
      if (!byLevel.has(L)) byLevel.set(L, [])
      byLevel.get(L).push(n.id)
    }
    const maxLevel = Math.max(...byLevel.keys())
    const parentsOf = {}
    for (const n of this.nodes) parentsOf[n.id] = []
    for (const e of layoutEdges) {
      if (level[e.from] < level[e.to]) parentsOf[e.to].push(e.from)
    }

    // Centro-x de cada nodo. Pre-llenado con los x ya conocidos (manuales) para
    // que un nodo auto se alinee bajo su padre manual.
    const center = {}
    for (const n of this.nodes) {
      if (n.x !== null) center[n.id] = n.x + NODE_W / 2
    }

    // 3. Nivel por nivel (arriba → abajo): desired = baricentro de los padres
    //    posicionados; ordenar por desired; separar a pitchX centrando la fila
    //    en el promedio de los desired (→ simétrico bajo el padre común).
    for (let L = 0; L <= maxLevel; L++) {
      const ids = byLevel.get(L) || []
      if (ids.length === 0) continue
      const desired = {}
      for (const id of ids) {
        const ps = parentsOf[id].filter((p) => center[p] !== undefined)
        desired[id] = ps.length
          ? ps.reduce((s, p) => s + center[p], 0) / ps.length
          : canvasCenter
      }
      const sorted = [...ids].sort((a, b) => desired[a] - desired[b] || String(a).localeCompare(String(b)))
      const n = sorted.length
      const mean = sorted.reduce((s, id) => s + desired[id], 0) / n
      sorted.forEach((id, i) => {
        center[id] = mean + (i - (n - 1) / 2) * pitchX
      })
      for (const id of ids) {
        if (!idsToPos.has(id)) continue
        const node = this.nodeMap[id]
        if (!node) continue
        node.x = Math.max(0, Math.round((center[id] - NODE_W / 2) / GRID) * GRID)
        node.y = MARGIN + L * pitchY
      }
    }
  },

  // Centro horizontal del canvas alineado a la grilla, o 0 si aún no hay ancho.
  _centerX() {
    const w = this.el.clientWidth || 0
    if (w <= 0) return 0
    return Math.max(0, Math.round((w - NODE_W) / 2 / GRID) * GRID)
  },

  // Al revelarse el panel Grafo (ancho real), recalcula el layout de los nodos
  // auto-posicionados que se calcularon sin ancho. Corre desde _refit.
  _revealPending() {
    if (!this._needsLayoutOnReveal) return false
    if (!(this.el.clientWidth > 0)) return false
    this._needsLayoutOnReveal = false
    this._computePositions(new Set(this._autoIds || []))
    return true
  },

  _sync() {
    this.el.dispatchEvent(
      new CustomEvent("graph-canvas:sync", {bubbles: true, detail: this.collect()})
    )
  },

  _svg() {
    return this.el.querySelector("svg")
  },

  _layer() {
    return this.el.querySelector("[data-nodes]")
  },

  // viewBox 1:1 con el contenedor (1 user-unit == 1 px). Las aristas viven en
  // el MISMO sistema de coordenadas que los nodos HTML (left/top en px), así no
  // se escalan ni se desfasan al redimensionar o al revelar el panel.
  // ANTES: el viewBox crecía con maxX/maxY de los nodos → el SVG escalaba las
  // aristas para caber, mientras los nodos HTML no escalaban → desalineación
  // progresiva al arrastrar.
  _fit() {
    const svg = this._svg()
    if (!svg) return
    const w = this.el.clientWidth || this.el.offsetWidth || 600
    const h = this.el.clientHeight || this.el.offsetHeight || 320
    svg.setAttribute("viewBox", `0 0 ${w} ${h}`)
  },

  // ── Rendering ───────────────────────────────────────────────────────────

  _render() {
    const svg = this._svg()
    const layer = this._layer()
    svg.replaceChildren()
    layer.replaceChildren()

    const defs = document.createElementNS("http://www.w3.org/2000/svg", "defs")
    defs.innerHTML =
      '<marker id="gc-arrow" viewBox="0 0 10 7" refX="9" refY="3.5" markerWidth="8" markerHeight="6" orient="auto">' +
      '<path d="M 0 0 L 10 3.5 L 0 7 Z" fill="currentColor" opacity="0.35"/></marker>'
    svg.appendChild(defs)
    svg.style.color = "var(--color-base-content)"

    for (const e of this.edges) this._drawEdge(svg, e)
    for (const n of this.nodes) layer.appendChild(this._nodeEl(n))

    this._fit()
    this.el.querySelector("[data-gc-empty]").hidden = this.nodes.length > 0
  },

  // Geometría de la arista: devuelve los 4 puntos de control de la bezier
  // (flujo vertical) + su punto medio visible. Lo usan tanto _drawEdge (pinta)
  // como _edgeAt (hit-testing), así la línea clicable == la línea dibujada.
  _edgeGeom(e) {
    const a = this.nodeMap[e.from]
    const b = this.nodeMap[e.to]
    if (!a || !b) return null
    // Sale por el centro-bottom del origen, entra por el centro-top del destino
    // (mismos puntos que los puertos de _nodeEl).
    const x1 = a.x + NODE_W / 2
    const y1 = a.y + NODE_H
    const x2 = b.x + NODE_W / 2
    const y2 = b.y
    const dy = Math.max(40, Math.abs(y2 - y1) * 0.4)
    return {
      // P0, P1 (control), P2 (control), P3
      p0: {x: x1, y: y1},
      p1: {x: x1, y: y1 + dy},
      p2: {x: x2, y: y2 - dy},
      p3: {x: x2, y: y2},
      // Punto medio de la curva (t=0.5) — ancla del menú y del hit-test.
      mid: {
        x: bezier(x1, x1, x2, x2, 0.5),
        y: bezier(y1, y1 + dy, y2 - dy, y2, 0.5),
      },
    }
  },

  _drawEdge(svg, e) {
    const g = this._edgeGeom(e)
    if (!g) return
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path")
    p.setAttribute(
      "d",
      `M ${g.p0.x} ${g.p0.y} C ${g.p1.x} ${g.p1.y}, ${g.p2.x} ${g.p2.y}, ${g.p3.x} ${g.p3.y}`
    )
    // Mismo estilo que el workflow canvas: clase base + estado. Sin estado de
    // ejecución en el grafo interno → siempre pending (dash + flujo animado).
    p.classList.add("gc-edge", "gc-edge-pending")
    p.setAttribute("marker-end", "url(#gc-arrow)")
    svg.appendChild(p)
  },

  _nodeEl(n) {
    const div = document.createElement("div")
    div.className =
      "gc-node absolute rounded-lg bg-base-100 border border-base-300 shadow-sm select-none"
    div.style.width = `${NODE_W}px`
    // Altura explícita == NODE_H: sin ella el header (h-7=28px) + borde daba
    // ~30px y el cálculo de puertos/aristas asumía otro valor → desfase.
    div.style.height = `${NODE_H}px`
    div.style.left = `${n.x}px`
    div.style.top = `${n.y}px`
    div.dataset.nodeId = n.id

    const header = document.createElement("div")
    header.className =
      "flex items-center gap-1.5 px-2 h-full cursor-grab active:cursor-grabbing rounded-lg"

    const badge = document.createElement("span")
    badge.className = `gc-verb text-[9px] font-mono uppercase tracking-wider px-1.5 rounded-full shrink-0 leading-4 ${VERB_STYLES[n.verb] || VERB_STYLES.ASK}`
    badge.textContent = n.verb

    const title = document.createElement("span")
    title.className = "text-xs font-medium truncate flex-1 text-base-content/70 pointer-events-none"
    title.textContent = n.label || n.id

    header.appendChild(badge)
    header.appendChild(title)
    div.appendChild(header)

    // Puertos del flujo vertical: OUT abajo (centro-bottom), IN arriba
    // (centro-top). Coinciden con los extremos que dibuja _drawEdge.
    // El hover (escala + glow) vive en CSS (.gc-port:hover) — no en Tailwind:
    // el transform inline translateX(-50%) de centrado pisaría al scale.
    const port = (type) => {
      const s = document.createElement("span")
      s.dataset.nodeId = n.id
      s.dataset.port = type
      s.className = "gc-port absolute w-3 h-3 rounded-full border-2 border-base-100 cursor-crosshair"
      s.style.left = "50%"
      s.style.transform = "translateX(-50%)"
      if (type === "out") {
        s.style.bottom = "-6px"
        s.style.background = "var(--color-primary)"
      } else {
        s.style.top = "-6px"
        s.style.background = "var(--color-info)"
      }
      return s
    }
    div.appendChild(port("out"))
    div.appendChild(port("in"))
    return div
  },

  // ── Pointer interactions ────────────────────────────────────────────────

  _point(e) {
    const rect = this.el.getBoundingClientRect()
    return {x: e.clientX - rect.left, y: e.clientY - rect.top}
  },

  _portCenter(nodeId, type) {
    const n = this.nodeMap[nodeId]
    if (!n) return {x: 0, y: 0}
    // Flujo vertical: OUT = centro-bottom, IN = centro-top (igual que _drawEdge
    // y que los puertos de _nodeEl).
    return {
      x: n.x + NODE_W / 2,
      y: type === "out" ? n.y + NODE_H : n.y,
    }
  },

  // ── Creación de nodos ─────────────────────────────────────────────────────

  // Id numérico único (no colisiona con ids existentes, sean "1" o "S1").
  _genId() {
    let id
    do {
      id = String(this.nextId++)
    } while (this.nodeMap[id])
    return id
  },

  // Botón "+ Nodo": agrega un nodo al final del flujo (debajo del más bajo,
  // centrado) y abre su modal de edición.
  _addNode() {
    if (this.editModal) return
    const id = this._genId()
    const cx = this._centerX() || 24
    let maxY = 24
    for (const n of this.nodes) {
      if (n.y !== null) maxY = Math.max(maxY, n.y + NODE_H + 48)
    }
    const n = {id, verb: "READ", label: "", x: cx, y: maxY}
    this.nodes.push(n)
    this.nodeMap[id] = n
    this._closeEdgeMenu()
    this._render()
    this._sync()
    this._openEdit(id)
  },

  // ── Menú de arista (clic sobre la conexión) ───────────────────────────────

  // Arista más cercana al punto p (muestrea la bezier visible). Devuelve null
  // si ninguna cae dentro de EDGE_HIT_R.
  _edgeAt(p) {
    let best = null
    let bestD = EDGE_HIT_R
    for (const e of this.edges) {
      const g = this._edgeGeom(e)
      if (!g) continue
      for (let i = 0; i <= 16; i++) {
        const t = i / 16
        const x = bezier(g.p0.x, g.p1.x, g.p2.x, g.p3.x, t)
        const y = bezier(g.p0.y, g.p1.y, g.p2.y, g.p3.y, t)
        const d = Math.hypot(p.x - x, p.y - y)
        if (d < bestD) {
          bestD = d
          best = e
        }
      }
    }
    return best
  },

  _closeEdgeMenu() {
    if (this.edgeMenu) {
      this.edgeMenu.remove()
      this.edgeMenu = null
    }
  },

  // Menú contextual anclado al punto de CLIC (no al centro de la arista):
  // romper la conexión o insertar un nodo en el medio (A→B pasa a A→N→B).
  // 100% client-side, igual que _openEdit; los cambios salen por _sync()
  // hacia el contrato. Mismas secciones que el canvas grande del workflow
  // para que la UX sea idéntica en ambos.
  _openEdgeMenu(edge, clickPoint) {
    this._closeEdgeMenu()
    const g = this._edgeGeom(edge)
    if (!g) return

    const nameOf = (id) => {
      const n = this.nodeMap[id]
      return (n && (n.label || n.id)) || id
    }

    const menu = document.createElement("div")
    menu.dataset.gcEdgeMenu = ""
    menu.className =
      "gc-edge-menu absolute z-40 w-44 rounded-lg border border-base-300 bg-base-100 shadow-lg overflow-hidden"

    const head = document.createElement("p")
    head.className =
      "px-3 py-1.5 text-[10px] font-mono uppercase tracking-wider text-base-content/45 border-b border-base-200 truncate"
    head.textContent = `${nameOf(edge.from)} → ${nameOf(edge.to)}`
    menu.appendChild(head)

    const mk = (act, text, danger, icon) => {
      const b = document.createElement("button")
      b.type = "button"
      b.dataset.act = act
      b.className =
        "w-full text-left px-3 py-1.5 text-xs transition-colors duration-150 hover:bg-base-200 flex items-center gap-1.5 " +
        (danger ? "text-error" : "text-base-content/75")
      // Icono inline (mismo que el workflow canvas)
      if (icon) {
        const s = document.createElement("span")
        s.className = "size-3.5 shrink-0"
        s.innerHTML = icon
        b.appendChild(s)
      }
      b.textContent = text
      menu.appendChild(b)
      return b
    }
    // Mismas secciones que el workflow canvas: agregar step, linkear existente, romper.
    const insertBtn = mk("insert", "Agregar step", false, '<svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>')
    const linkBtn = mk("link", "Linkear step…", false, '<svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101"/><path d="M10.172 13.828a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.102 1.101"/></svg>')
    const breakBtn = mk("break", "Romper conexión", true, '<svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path d="M6 18L18 6M6 6l12 12"/></svg>')

    insertBtn.addEventListener("click", (ev) => {
      ev.stopPropagation()
      this._insertNodeOnEdge(edge)
    })
    linkBtn.addEventListener("click", (ev) => {
      ev.stopPropagation()
      this._linkStep(edge)
    })
    breakBtn.addEventListener("click", (ev) => {
      ev.stopPropagation()
      this._deleteEdge(edge)
    })

    this.el.appendChild(menu)
    // Posicionar en el punto exacto donde se hizo clic, con clamp para que
    // el menú no se salga del canvas (overflow-hidden lo clippearía).
    const mw = menu.offsetWidth
    const mh = menu.offsetHeight
    const w = this.el.clientWidth
    const h = this.el.clientHeight
    const left = Math.min(Math.max(clickPoint.x, mw / 2 + 4), Math.max(mw / 2 + 4, w - mw / 2 - 4))
    const top = Math.min(Math.max(clickPoint.y, mh / 2 + 4), Math.max(mh / 2 + 4, h - mh / 2 - 4))
    menu.style.left = `${left}px`
    menu.style.top = `${top}px`
    menu.style.transform = "translate(-50%, -50%)"
    this.edgeMenu = menu
  },

  // Romper la conexión: elimina SOLO la arista (los nodos quedan intactos).
  _deleteEdge(edge) {
    this.edges = this.edges.filter(
      (e2) => !(e2.from === edge.from && e2.to === edge.to)
    )
    this._closeEdgeMenu()
    this._render()
    this._sync()
  },

  // Insertar un nodo en el medio de la arista: A→B pasa a A→N→B, con N en el
  // punto medio. Abre el modal de edición de N.
  _insertNodeOnEdge(edge) {
    const g = this._edgeGeom(edge)
    const id = this._genId()
    const x = g ? Math.max(0, Math.round((g.mid.x - NODE_W / 2) / GRID) * GRID) : this._centerX()
    const y = g ? Math.max(0, Math.round((g.mid.y - NODE_H / 2) / GRID) * GRID) : 24
    const n = {id, verb: "EDIT", label: "", x, y}
    this.nodes.push(n)
    this.nodeMap[id] = n

    const from = edge.from
    const to = edge.to
    this.edges = this.edges.filter((e2) => !(e2.from === from && e2.to === to))
    this.edges.push({from, to: id}, {from: id, to})

    this._closeEdgeMenu()
    this._render()
    this._sync()
    this._openEdit(id)
  },

  // Linkear step: conecta directamente los dos nodos extremos de la arista si
  // aún no están conectados. Útil cuando el usuario quiere crear una conexión
  // entre nodos existentes sin arrastrar puertos. Misma UX que el workflow
  // canvas donde "Linkear step…" crea la relación desde el menú.
  _linkStep(edge) {
    // Si ya existe la conexión directa, no hacer nada (evitar duplicados).
    if (this.edges.some((e2) => e2.from === edge.from && e2.to === edge.to)) return
    this.edges.push({from: edge.from, to: edge.to})
    this._closeEdgeMenu()
    this._render()
    this._sync()
  },

  // Clic delegado: botón "+Nodo", menú de arista abierto, o detección de clic
  // sobre una arista del canvas. Los clics en nodos/puertos los maneja _up.
  _click(e) {
    if (e.button !== 0 || this.editModal) return
    if (e.target.closest("[data-gc-tidy]")) {
      this._tidy()
      return
    }
    if (e.target.closest("[data-gc-add]")) {
      this._addNode()
      return
    }
    // Dentro del menú: sus botones ya tienen listeners propios.
    if (e.target.closest("[data-gc-edge-menu]")) return
    // Un drag/conexión recién soltado no debe abrir un menú de arista.
    if (this._justDragged) {
      this._justDragged = false
      this._closeEdgeMenu()
      return
    }
    // Clic sobre un nodo: lo maneja _up (modal de edición). Solo cierra el menú.
    if (e.target.closest(".gc-node")) {
      this._closeEdgeMenu()
      return
    }
    // Clic en el vacío: ¿enganchó una arista? Pasar el punto de clic para que
    // el menú aparezca donde se hizo clic (no centrado en la arista).
    const pt = this._point(e)
    const edge = this._edgeAt(pt)
    if (edge) this._openEdgeMenu(edge, pt)
    else this._closeEdgeMenu()
  },

  _down(e) {
    if (e.button !== 0 || this.editModal) return
    // Cada nueva interacción limpia el flag de drag previo (defensa: si un drag
    // soltó el mouse fuera del canvas, el click no llega y _justDragged quedaría
    // en true, tragándose el próximo clic-en-arista legítimo).
    this._justDragged = false
    const port = e.target.closest(".gc-port")
    if (port) {
      e.preventDefault()
      this.connecting = {from: port.dataset.nodeId, x: 0, y: 0}
      const g = document.createElementNS("http://www.w3.org/2000/svg", "path")
      g.setAttribute("stroke", "var(--color-primary)")
      g.setAttribute("stroke-width", "2")
      g.setAttribute("fill", "none")
      g.setAttribute("stroke-dasharray", "6 3")
      this.ghost = g
      this._svg().appendChild(g)
      this._move(e)
      return
    }
    const header = e.target.closest(".gc-node > div:first-child")
    if (header) {
      const nodeEl = header.closest(".gc-node")
      const id = nodeEl.dataset.nodeId
      const n = this.nodeMap[id]
      if (!n) return
      e.preventDefault()
      const p = this._point(e)
      this.dragging = {id, el: nodeEl, dx: p.x - n.x, dy: p.y - n.y}
      this.dragMoved = false
      nodeEl.style.zIndex = "10"
    }
  },

  _move(e) {
    if (this.connecting) {
      const p = this._point(e)
      this.connecting.x = p.x
      this.connecting.y = p.y
      const c = this._portCenter(this.connecting.from, "out")
      const dy = Math.max(40, Math.abs(p.y - c.y) * 0.4)
      this.ghost.setAttribute(
        "d",
        `M ${c.x} ${c.y} C ${c.x} ${c.y + dy}, ${p.x} ${p.y - dy}, ${p.x} ${p.y}`
      )
      // Highlight nearest IN port within snap radius.
      let best = null
      let bestD = SNAP_R
      for (const n of this.nodes) {
        if (n.id === this.connecting.from) continue
        const c2 = this._portCenter(n.id, "in")
        const d = Math.hypot(p.x - c2.x, p.y - c2.y)
        if (d < bestD) {
          bestD = d
          best = n.id
        }
      }
      this.el.querySelectorAll(".gc-port[data-drop]").forEach((el) => el.removeAttribute("data-drop"))
      if (best) {
        const el = this.el.querySelector(`.gc-port[data-port="in"][data-node-id="${best}"]`)
        if (el) el.setAttribute("data-drop", "")
      }
      return
    }
    if (this.dragging) {
      const p = this._point(e)
      const x = Math.max(0, Math.round((p.x - this.dragging.dx) / GRID) * GRID)
      const y = Math.max(0, Math.round((p.y - this.dragging.dy) / GRID) * GRID)
      const n = this.nodeMap[this.dragging.id]
      if (!n) return
      this.dragMoved = true
      n.x = x
      n.y = y
      this.dragging.el.style.left = `${x}px`
      this.dragging.el.style.top = `${y}px`
      this._redrawEdges()
      this._fit()
    }
  },

  _up(_e) {
    if (this.connecting) {
      // Find highlighted target at release.
      const dropped = this.el.querySelector('.gc-port[data-port="in"][data-drop]')
      if (dropped) {
        const to = dropped.dataset.nodeId
        const from = this.connecting.from
        if (from !== to && !this.edges.some((e2) => e2.from === from && e2.to === to)) {
          this.edges.push({from, to})
          this._render()
          this._sync()
        }
      }
      this.el.querySelectorAll(".gc-port[data-drop]").forEach((el) => el.removeAttribute("data-drop"))
      if (this.ghost) {
        this.ghost.remove()
        this.ghost = null
      }
      this.connecting = null
      // El mouseup de una conexión va seguido de un click: que _click no lo
      // interprete como clic-en-vacío y abra un menú de arista.
      this._justDragged = true
      return
    }
    if (this.dragging) {
      const {id, el} = this.dragging
      el.style.zIndex = ""
      this.dragging = null
      if (this.dragMoved) {
        this._sync()
        this._justDragged = true
      } else {
        this._openEdit(id)
      }
    }
  },

  _dbl(e) {
    if (this.editModal) return
    if (e.target.closest(".gc-node")) return
    const p = this._point(e)
    const id = this._genId()
    const n = {
      id,
      verb: "READ",
      label: "",
      x: Math.max(0, Math.round(p.x / GRID) * GRID - NODE_W / 2),
      y: Math.max(0, Math.round(p.y / GRID) * GRID - NODE_H / 2),
    }
    this.nodes.push(n)
    this.nodeMap[id] = n
    this._closeEdgeMenu()
    this._render()
    this._sync()
    this._openEdit(id)
  },

  _redrawEdges() {
    const svg = this._svg()
    const defs = svg.querySelector("defs")
    svg.replaceChildren(defs)
    for (const e of this.edges) this._drawEdge(svg, e)
  },

  // ── Edit modal ──────────────────────────────────────────────────────────

  _openEdit(nodeId) {
    const n = this.nodeMap[nodeId]
    if (!n) return
    this._closeEdit()

    const modal = document.createElement("div")
    modal.className = "gc-modal absolute inset-0 z-30 flex items-center justify-center rounded-xl bg-base-content/20 backdrop-blur-[2px]"
    const verbs = ["READ", "EDIT", "CREATE", "RUN", "VERIFY", "ASK"]
    modal.innerHTML = `
      <div class="bg-base-100 rounded-xl border border-base-300 shadow-xl p-4 w-72 space-y-3" data-panel>
        <h3 class="text-sm font-semibold">Editar nodo</h3>
        <label class="block">
          <span class="block text-[10px] uppercase tracking-wider text-base-content/50 mb-1">ID</span>
          <input data-f="id" type="text" value="${n.id}" class="input input-bordered input-xs w-full font-mono" />
        </label>
        <label class="block">
          <span class="block text-[10px] uppercase tracking-wider text-base-content/50 mb-1">Verbo</span>
          <select data-f="verb" class="select select-bordered select-xs w-full font-mono">
            ${verbs.map((v) => `<option value="${v}" ${v === n.verb ? "selected" : ""}>${v}</option>`).join("")}
          </select>
        </label>
        <label class="block">
          <span class="block text-[10px] uppercase tracking-wider text-base-content/50 mb-1">Etiqueta</span>
          <input data-f="label" type="text" value="${n.label || ""}" placeholder="etiqueta…" class="input input-bordered input-xs w-full" />
        </label>
        <div class="flex justify-between gap-2 pt-1">
          <button type="button" data-act="delete" class="btn btn-ghost btn-xs text-error">Eliminar</button>
          <span class="flex gap-2">
            <button type="button" data-act="cancel" class="btn btn-ghost btn-xs">Cancelar</button>
            <button type="button" data-act="save" class="btn btn-primary btn-xs">Guardar</button>
          </span>
        </div>
      </div>`

    modal.addEventListener("mousedown", (ev) => {
      if (ev.target === modal) this._closeEdit()
    })
    modal.querySelector('[data-act="cancel"]').addEventListener("click", () => this._closeEdit())
    modal.querySelector('[data-act="save"]').addEventListener("click", () => this._saveEdit(nodeId, modal))
    modal.querySelector('[data-act="delete"]').addEventListener("click", () => this._deleteNode(nodeId))
    modal.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault()
        this._saveEdit(nodeId, modal)
      } else if (ev.key === "Escape") {
        this._closeEdit()
      }
    })

    this.el.appendChild(modal)
    this.editModal = modal
    const label = modal.querySelector('[data-f="label"]')
    if (label) label.focus()
  },

  _closeEdit() {
    if (this.editModal) {
      this.editModal.remove()
      this.editModal = null
    }
  },

  _saveEdit(nodeId, modal) {
    const n = this.nodeMap[nodeId]
    if (!n) return this._closeEdit()
    const newId = modal.querySelector('[data-f="id"]').value.trim()
    const verb = modal.querySelector('[data-f="verb"]').value
    const label = modal.querySelector('[data-f="label"]').value.trim()
    if (!newId) return
    if (newId !== nodeId && this.nodeMap[newId]) {
      // ID collision: flag the input, keep modal open.
      const input = modal.querySelector('[data-f="id"]')
      input.setCustomValidity("ID ya existe")
      input.reportValidity()
      return
    }
    if (newId !== nodeId) {
      delete this.nodeMap[nodeId]
      for (const e of this.edges) {
        if (e.from === nodeId) e.from = newId
        if (e.to === nodeId) e.to = newId
      }
      n.id = newId
      this.nodeMap[newId] = n
    }
    n.verb = verb
    n.label = label
    this._render()
    this._sync()
    this._closeEdit()
  },

  _deleteNode(nodeId) {
    this.nodes = this.nodes.filter((x) => x.id !== nodeId)
    this.edges = this.edges.filter((e) => e.from !== nodeId && e.to !== nodeId)
    delete this.nodeMap[nodeId]
    this._render()
    this._sync()
    this._closeEdit()
  },
}

export default GraphCanvas
