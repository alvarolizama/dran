// Workflow DAG canvas editor — WfPanZoom + editing interactions:
//   - drag cards to reposition (grid-snapped, persisted via "move_step")
//   - drag from an OUT port to an IN port to connect ("connect_steps")
//   - double-click empty canvas to create a step there ("new_step_at")
// Edge menus (⋯ → agregar / linkear / romper) are plain phx-click/JS-toggle
// (no JS state beyond the toggle); each card has a ✎ pencil button
// (data-wf-no-drag) that opens the edit modal — the card body is drag-only.
//
// Edges animate client-side: the server re-renders them only on reload
// (move_step/connect_steps), but the edges' `d` derives from live port
// centers, so during a drag they are redrawn every pointermove via
// redrawEdges() and on every server patch via updated().
import WfPanZoom from "./wf_pan_zoom.js"

const GRID = 16
// Edge-link mode ("Linkear step…"): the target edge's PREREQ port chases the
// cursor up to this many stage units; beyond it the edge rests at its
// geometric midpoint.
const LINK_SNAP_RADIUS = 140
const MENU_HIT_HALF = 10
const CLICK_RADIUS = 4
const PORT_RADIUS = 22
// Tolerancia (en px de PANTALLA) para que un clic "enganche" el alambre de una
// arista y abra su menú. Se convierte a unidades de stage dividiendo por scale,
// así la tolerancia visual es constante a cualquier zoom.
const EDGE_HIT_SCREEN = 9
const SVG_NS = "http://www.w3.org/2000/svg"

// Cubic bezier point at t — mirrors the edge path math of graph_edges/3.
function bezier(p0, p1, p2, p3, t) {
  const u = 1 - t
  return (
    u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
  )
}

const WfCanvas = {
  ...WfPanZoom,

  // Pan/zoom transform changed: edge menus ride the wire midpoints (the
  // overlay does not inherit the stage transform, so it must be re-placed
  // in overlay coordinates on every transform update).
  _apply() {
    WfPanZoom._apply.call(this)
    this._placeEdgeMenus()
  },

  mounted() {
    WfPanZoom.mounted.call(this)
    if (!this.stage) return

    this._edit = {drag: null, link: null}

    // Ghost layer for in-progress connections — lives INSIDE the stage so
    // it inherits the pan/zoom transform and stays aligned with ports.
    this._ghostSvg = document.createElementNS(SVG_NS, "svg")
    this._ghostSvg.setAttribute("data-wf-ghost", "")
    this._ghostSvg.classList.add("wfe-ghost-layer")
    this._ghostPath = document.createElementNS(SVG_NS, "path")
    this._ghostPath.classList.add("wfe-ghost")
    this._ghostSvg.appendChild(this._ghostPath)
    this.stage.appendChild(this._ghostSvg)

    this._onPointerDown = (e) => this._editDown(e)
    this._onPointerMove = (e) => this._editMove(e)
    this._onPointerUp = (e) => this._editUp(e)
    this._onDblClick = (e) => this._editDblClick(e)
    this._onDocClick = (e) => this._closeEdgeMenus(e)
    this._onEdgeMenuClick = (e) => this._edgeMenuClick(e)
    this._linkMode = null

    this.el.addEventListener("pointerdown", this._onPointerDown)
    window.addEventListener("pointermove", this._onPointerMove)
    window.addEventListener("pointerup", this._onPointerUp)
    this.el.addEventListener("dblclick", this._onDblClick)
    this.el.addEventListener("click", this._onEdgeMenuClick)
    document.addEventListener("click", this._onDocClick)

    // morphdom discards the client-only ghost <svg> while patching the
    // stage's children (it has no server counterpart — verified in the LV
    // bundle: trailing unkeyed extra children are removed). The observer
    // re-appends it the instant any child list change lands, so an active
    // link (or the just-dropped edge) survives the reload round-trip.
    this._ghostObserver = new MutationObserver(() => {
      if (!this._ghostSvg.isConnected) this.stage.appendChild(this._ghostSvg)
    })
    this._ghostObserver.observe(this.stage, {childList: true, subtree: false})
  },

  destroyed() {
    WfPanZoom.destroyed.call(this)
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    window.removeEventListener("pointermove", this._onPointerMove)
    window.removeEventListener("pointerup", this._onPointerUp)
    this.el.removeEventListener("dblclick", this._onDblClick)
    this.el.removeEventListener("click", this._onEdgeMenuClick)
    document.removeEventListener("click", this._onDocClick)
    this._ghostObserver.disconnect()
  },

  // Pan must never start on ports (they begin connections) nor on cards
  // (their pointer gesture is the card drag). Buttons/controls are covered
  // by WfPanZoom's [phx-click] guard.
  _onDown(e) {
    if (e.target.closest("[data-wf-port]")) return
    if (e.target.closest(".wfe-node")) return
    if (e.target.closest("[data-wf-edge-menu]")) return
    WfPanZoom._onDown.call(this, e)
  },

  _stagePoint(e) {
    const rect = this.el.getBoundingClientRect()
    return {
      x: (e.clientX - rect.left - this.tx) / this.scale,
      y: (e.clientY - rect.top - this.ty) / this.scale,
    }
  },

  _editDown(e) {
    if (e.button !== 0) return

    // Punto de inicio del gesto: en el click siguiente distingue un clic real
    // (abrir menú de arista) de un pan/drag/conexión que terminó sobre un
    // alambre (no debe abrir nada). Se captura antes de los early-returns.
    this._downClient = {x: e.clientX, y: e.clientY}

    // The ✎ edit button owns its own phx-click — never start a card drag
    // (or a pan) from it.
    if (e.target.closest("[data-wf-no-drag]")) return

    // 1) Connection start: drag out of an OUT port.
    const port = e.target.closest('[data-wf-port="out"]')
    if (port) {
      e.preventDefault()
      this._edit.link = {from: port.dataset.stepId}
      return
    }

    // 2) Card drag: remember the start; movement decides drag vs click.
    const node = e.target.closest(".wfe-node")
    if (node) {
      const p = this._stagePoint(e)
      this._edit.drag = {
        id: node.dataset.stepId,
        el: node,
        startX: e.clientX,
        startY: e.clientY,
        origX: p.x - (p.x - parseFloat(node.style.left)),
        origY: parseFloat(node.style.top),
        moved: false,
        ports: this.el.querySelectorAll(
          `[data-wf-port][data-step-id='${node.dataset.stepId}']`
        ),
      }
    }
  },

  _editMove(e) {
    const edit = this._edit

    // Edge-link mode: the target edge's PREREQ side chases the cursor
    // (clamped to LINK_SNAP_RADIUS) and the menu rides along; normal
    // gestures are suspended while it is active.
    if (this._linkMode) {
      const p = this._stagePoint(e)
      const snap = this._linkSnapPoint(p)
      this._linkMode.snap = snap.snapped ? snap : null
      this.redrawEdges()
      this._placeEdgeMenus()
      return
    }

    // Connection in progress: ghost path + highlight the nearest IN port.
    if (edit.link) {
      const p = this._stagePoint(e)
      const from = this.el.querySelector(
        `[data-wf-port='out'][data-step-id='${edit.link.from}']`
      )
      if (from) {
        const r = this._stageRect(from)
        this._ghostPath.setAttribute(
          "d",
          `M ${r.cx} ${r.cy} C ${r.cx + 60} ${r.cy}, ${p.x - 60} ${p.y}, ${p.x} ${p.y}`
        )
      }

      const target = this._portNear(p, edit.link.from)
      this.el
        .querySelectorAll(".wfe-port-target")
        .forEach((el) => el.classList.remove("wfe-port-target"))
      if (target) target.classList.add("wfe-port-target")
      return
    }

    // Card drag (after the click-radius threshold).
    const drag = edit.drag
    if (!drag) return
    const dx = e.clientX - drag.startX
    const dy = e.clientY - drag.startY

    if (!drag.moved) {
      if (Math.hypot(dx, dy) < CLICK_RADIUS) return
      drag.moved = true
      drag.el.classList.add("wfe-dragging")
    }

    const x = Math.max(0, Math.round((drag.origX + dx) / GRID) * GRID)
    const y = Math.max(0, Math.round((drag.origY + dy) / GRID) * GRID)
    drag.el.style.left = `${x}px`
    drag.el.style.top = `${y}px`
    // Keep the port dots glued to the card while the edges wait for the
    // server round-trip.
    drag.ports.forEach((port) => {
      const isIn = port.dataset.wfPort === "in"
      port.style.left = `${isIn ? x - 6 : x + drag.el.offsetWidth - 6}px`
      port.style.top = `${y + drag.el.offsetHeight / 2 - 6}px`
    })

    // Edges follow the card in the same frame — no round-trip lag.
    this.redrawEdges()
  },

  _editUp(e) {
    const edit = this._edit

    // End of an edge-link gesture: release the snap (menu returns to its
    // resting midpoint); the ghost dies on the next server patch.
    if (this._linkMode) {
      this._linkMode.snap = null
      this._ghostPath.removeAttribute("d")
      this.redrawEdges()
      this._placeEdgeMenus()
      return
    }

    // Finish a connection: nearest IN port wins → connect_steps.
    if (edit.link) {
      const target = this._portNear(this._stagePoint(e), edit.link.from)
      this.el
        .querySelectorAll(".wfe-port-target")
        .forEach((el) => el.classList.remove("wfe-port-target"))

      if (target) {
        // Optimistic edge: freeze the ghost at the drop point until the
        // server round-trip renders the real path (updated() keeps it
        // alive through the patch; the new server path replaces it).
        const p = this._stagePoint(e)
        const from = this.el.querySelector(
          `[data-wf-port='out'][data-step-id='${edit.link.from}']`
        )
        if (from) {
          const r = this._stageRect(from)
          this._ghostPath.setAttribute(
            "d",
            `M ${r.cx} ${r.cy} C ${r.cx + 60} ${r.cy}, ${p.x - 60} ${p.y}, ${p.x} ${p.y}`
          )
          this._edit.pendingEdge = true
        }
        this.pushEvent("connect_steps", {
          "prereq-id": edit.link.from,
          "dependent-id": target.dataset.stepId,
        })
      } else {
        this._ghostPath.removeAttribute("d")
      }
      edit.link = null
      return
    }

    // Finish a card drag: only when it really moved → persist move_step.
    const drag = edit.drag
    if (!drag) return
    edit.drag = null
    if (!drag.moved) return

    drag.el.classList.remove("wfe-dragging")
    this.pushEvent("move_step", {
      "step-id": drag.id,
      x: parseInt(drag.el.style.left, 10),
      y: parseInt(drag.el.style.top, 10),
    })
  },

  // After any server patch: morphdom syncs attributes to the server render,
  // and the stage's pan/zoom transform exists ONLY client-side — a full
  // re-render (⌗ repack, reload_current) wipes stage.style.transform while
  // this.tx/ty/scale stay authoritative. Re-assert it BEFORE any rect math,
  // or redrawEdges() computes wires against a phantom transform (the ⌗
  // "lines vanish" bug). Then redraw from the live port positions, drop the
  // just-connected edge's optimistic ghost, and re-place the menus.
  // Post-patch the open menus may carry stale ids (an edge may be gone) —
  // the toggle-click path below re-closes them defensively.
  updated() {
    if (this._edit && this._edit.pendingEdge) {
      this._edit.pendingEdge = null
      this._ghostPath.removeAttribute("d")
    }
    this._apply()
    this.redrawEdges()
    this._placeEdgeMenus()
    this._trackEdgeSettle()
  },

  // Cards (and ports) GLIDE to their patch target via the CSS transition on
  // .wfe-node / [data-wf-port] — but redrawEdges() derives paths from live
  // port rects, which mid-transition still report the OLD positions. A
  // single redraw at patch time would freeze the wires behind the moving
  // cards (the ⌗ repack disconnect). While a position transition is in
  // flight, redraw every frame; the loop self-terminates when the
  // transitions end (bounded, in case a hover keeps one alive).
  _trackEdgeSettle() {
    if (this._settleRaf) {
      cancelAnimationFrame(this._settleRaf)
      this._settleRaf = null
    }
    if (!this._settling()) return

    const deadline = performance.now() + 500
    const tick = () => {
      this.redrawEdges()
      this._placeEdgeMenus()
      if (performance.now() < deadline && this._settling()) {
        this._settleRaf = requestAnimationFrame(tick)
      } else {
        this._settleRaf = null
        this.redrawEdges()
        this._placeEdgeMenus()
      }
    }
    this._settleRaf = requestAnimationFrame(tick)
  },

  // True while any card/port has a CSS *transition* running (the infinite
  // wfe-flow/wfe-pulse keyframe animations are CSSTransition-excluded).
  // redrawEdges() already forced a style/layout flush before this runs, so
  // transitions triggered by the patch are visible here.
  _settling() {
    if (typeof CSSTransition === "undefined") return false
    for (const el of this.el.querySelectorAll(".wfe-node, [data-wf-port]")) {
      for (const a of el.getAnimations()) {
        if (a instanceof CSSTransition) return true
      }
    }
    return false
  },

  _editDblClick(e) {
    if (e.target.closest(".wfe-node") || e.target.closest("[data-wf-port]")) return
    if (e.target.closest("[data-wf-controls]")) return
    const p = this._stagePoint(e)
    this.pushEvent("new_step_at", {x: Math.max(0, Math.round(p.x)), y: Math.max(0, Math.round(p.y))})
  },

  // ── Edge menus (⋯ punto medio) ──────────────────────────────────────────

  // Delegated clicks: the ⋯ toggle opens its menu; "Linkear step…" enters
  // link mode. The other items are plain phx-click (server-side). Re-bind
  // the picker options on every open — morphdom may have rebuilt them.
  _edgeMenuClick(e) {
    const menu = e.target.closest("[data-wf-edge-menu]")
    if (!menu) return

    if (e.target.closest("[data-edge-menu-toggle]")) {
      // Toggle puro: abrir/cerrar el popup de opciones. El modo "linkear"
      // solo se activa con el ítem "Linkear step…" del menú.
      if (menu.hasAttribute("data-edge-menu-open")) {
        menu.removeAttribute("data-edge-menu-open")
        menu.removeAttribute("data-menu-at-click")
        menu.removeAttribute("data-menu-flip-up")
      } else {
        menu.setAttribute("data-edge-menu-open", "")
      }
      return
    }

    if (e.target.closest("[data-edge-menu-link]")) this._enterLinkMode(menu)
  },

  // Click-away: close every open menu/picker. The toggle's own click also
  // passes through here — it re-opens the menu on the same click, so the
  // net effect is a clean toggle.
  _closeEdgeMenus(e) {
    if (this._linkMode && !e.target.closest("[data-wf-edge-menu]")) {
      this._exitLinkMode()
    }

    this.el.querySelectorAll("[data-edge-menu-open]").forEach((menu) => {
      if (!menu.contains(e.target)) {
        menu.removeAttribute("data-edge-menu-open")
        menu.removeAttribute("data-menu-at-click")
        menu.removeAttribute("data-menu-flip-up")
      }
    })

    // Al hacer clic sobre un alambre (wire), abrir directamente su menú de
    // arista — misma UX que el mini-canvas de steps donde clic en la línea
    // muestra las opciones. Se ejecuta DESPUÉS del bucle de cierre para que
    // el menú recién abierto no sea inmediatamente cerrado por este mismo handler.
    this._maybeOpenEdgeMenu(e)
  },

  // Detectar si un punto del canvas cae sobre una arista renderizada (hit-test
  // sobre los paths SVG). Devuelve `data-edge-key` de la más cercana dentro
  // de EDGE_HIT_SCREEN px (convertido a stage units dividiendo por scale).
  _edgeAt(p) {
    let best = null
    let bestD = EDGE_HIT_SCREEN / this.scale
    for (const path of this.el.querySelectorAll("path[data-edge-key]")) {
      let len = 0
      try { len = path.getTotalLength() } catch { continue }
      if (!len) continue
      const steps = Math.min(64, Math.max(12, Math.ceil(len / 6)))
      for (let i = 0; i <= steps; i++) {
        const pt = path.getPointAtLength((i / steps) * len)
        const d = Math.hypot(p.x - pt.x, p.y - pt.y)
        if (d < bestD) {
          bestD = d
          best = path.dataset.edgeKey
        }
      }
    }
    return best
  },

  // Abrir el menú de arista correspondiente a `edgeKey`, cerrando otros.
  // Solo se llama tras un clic real en el alambre (no pan/drag/conexión).
  // El menú se reposiciona exactamente donde se hizo clic (no en el centro
  // de la arista) para que la UX sea idéntica al mini-canvas de steps.
  _maybeOpenEdgeMenu(e) {
    // Fuera del canvas → solo cerrar (comportamiento existente).
    if (!this.el.contains(e.target)) return
    if (e.button !== 0) return
    // UI ya manejada por sí misma → no abrir menú.
    if (e.target.closest("[data-wf-edge-menu]")) return
    if (e.target.closest(".wfe-node, [data-wf-port], [data-wf-controls], [phx-click]")) return
    // Clic que fue realmente un pan/drag/conexión → suprimir.
    const dc = this._downClient
    this._downClient = null
    if (dc && Math.hypot(e.clientX - dc.x, e.clientY - dc.y) > CLICK_RADIUS * 3) return
    // ¿Pegó un alambre?
    const key = this._edgeAt(this._stagePoint(e))
    if (!key) return
    // Cerrar otros abiertos + abrir este
    this.el.querySelectorAll("[data-edge-menu-open]").forEach((m) => {
      if (m) {
        m.removeAttribute("data-edge-menu-open")
        m.removeAttribute("data-menu-at-click")
        m.removeAttribute("data-menu-flip-up")
      }
    })
    const menu = this.el.querySelector(`[data-wf-edge-menu][data-edge-key="${key}"]`)
    if (!menu) return
    menu.setAttribute("data-edge-menu-open", "")
    // Anclado al clic: _placeEdgeMenus no debe devolverlo al punto medio de
    // la arista mientras esté abierto (el usuario lo abrió donde hizo clic).
    menu.setAttribute("data-menu-at-click", "")
    // Reposicionar el menú exactamente en el punto del clic. El menú vive
    // DENTRO del stage transformado → convertir el punto de overlay a coords
    // de stage ((x - tx) / scale); si se escribiera en coords de overlay el
    // transform del stage lo desplazaría una segunda vez (bug del menú que
    // "sale fuera" del clic).
    const rect = this.el.getBoundingClientRect()
    const ox = e.clientX - rect.left
    const oy = e.clientY - rect.top
    const sx = (ox - this.tx) / this.scale
    const sy = (oy - this.ty) / this.scale
    menu.style.left = `${sx - MENU_HIT_HALF}px`
    menu.style.top = `${sy - MENU_HIT_HALF}px`
    // Cerca del borde inferior el pop (que abre hacia abajo) se clipearía:
    // invertirlo para que abra hacia arriba (decisión en px de overlay).
    if (oy > this.el.clientHeight - 150) {
      menu.setAttribute("data-menu-flip-up", "")
    }
  },

  // "Linkear step…" — enter client-side link mode: edges to this edge's
  // PREREQ side collapse toward it and the dropdown lists candidates
  // (middle step ≠ endpoints). The chosen step fires "link_step_between".
  _enterLinkMode(menu) {
    const {prereqId, dependentId} = menu.dataset
    this._linkMode = {prereqId, dependentId, menu, snap: null}
    this.el.classList.add("wfe-linking")
    const path = this.el.querySelector(`path[data-edge-key='${menu.dataset.edgeKey}']`)
    if (path) path.classList.add("wfe-edge-target")
    this._fillPicker(menu)
    this.el.querySelectorAll("[data-edge-menu-open]").forEach((m) => {
      if (m !== menu) {
        m.removeAttribute("data-edge-menu-open")
        m.removeAttribute("data-menu-at-click")
        m.removeAttribute("data-menu-flip-up")
      }
    })
  },

  _exitLinkMode() {
    this._linkMode = null
    this.el.classList.remove("wfe-linking")
    this.el
      .querySelectorAll(".wfe-edge-target")
      .forEach((path) => path.classList.remove("wfe-edge-target"))
    this.redrawEdges()
  },

  _fillPicker(menu) {
    const picker = menu.querySelector("[data-edge-picker]")
    if (!picker) return
    picker.innerHTML = ""

    const byId = {}
    this.el.querySelectorAll(".wfe-node[data-step-id]").forEach((node) => {
      byId[node.dataset.stepId] = (node.querySelector("[data-step-title]") || node).textContent.trim()
    })

    const candidates = Object.keys(byId)
      .filter((id) => id !== menu.dataset.prereqId && id !== menu.dataset.dependentId)
      .sort((a, b) => byId[a].localeCompare(byId[b]))

    if (candidates.length === 0) {
      const empty = document.createElement("p")
      empty.className = "wfe-edge-picker-empty"
      empty.textContent = "No hay otros steps en este workflow."
      picker.appendChild(empty)
      return
    }

    candidates.forEach((id) => {
      const opt = document.createElement("button")
      opt.type = "button"
      opt.className = "wfe-edge-picker-opt"
      opt.textContent = byId[id]
      opt.addEventListener("click", (e) => {
        e.stopPropagation()
        this.pushEvent("link_step_between", {
          "dependent-id": menu.dataset.dependentId,
          "prereq-id": menu.dataset.prereqId,
          "middle-id": id,
        })
        this._exitLinkMode()
        menu.removeAttribute("data-edge-menu-open")
        menu.removeAttribute("data-menu-at-click")
        menu.removeAttribute("data-menu-flip-up")
      })
      picker.appendChild(opt)
    })
  },

  _portNear(p, fromId) {
    let best = null
    let bestD = PORT_RADIUS

    this.el.querySelectorAll("[data-wf-port='in']").forEach((port) => {
      if (port.dataset.stepId === fromId) return
      const r = this._stageRect(port)
      const d = Math.hypot(p.x - r.cx, p.y - r.cy)
      if (d < bestD) {
        bestD = d
        best = port
      }
    })

    return best
  },

  // Snap point for edge-link mode: the resting midpoint of the target edge
  // (from its ports) blended toward the cursor when it is within
  // LINK_SNAP_RADIUS of the PREREQ side.
  _linkSnapPoint(p) {
    const from = this.el.querySelector(
      `[data-wf-port='out'][data-step-id='${this._linkMode.prereqId}']`
    )
    const to = this.el.querySelector(
      `[data-wf-port='in'][data-step-id='${this._linkMode.dependentId}']`
    )
    if (!from || !to) return {x: 0, y: 0, snapped: false}

    const a = this._stageRect(from)
    const b = this._stageRect(to)
    const sag =
      Math.abs(b.cy - a.cy) < 1 && b.cx - a.cx > 268 ? (96 + 20) * 0.7 : 0
    const mid = {
      x: bezier(a.cx, a.cx + (b.cx - a.cx) * 0.3, b.cx - (b.cx - a.cx) * 0.3, b.cx, 0.5),
      y: bezier(a.cy, a.cy + sag, b.cy + sag, b.cy, 0.5),
    }

    const d = Math.hypot(p.x - a.cx, p.y - a.cy)
    if (d > LINK_SNAP_RADIUS) return {...mid, snapped: false}

    const k = d / LINK_SNAP_RADIUS
    return {
      x: mid.x + (p.x - a.cx) * k,
      y: mid.y + (p.y - a.cy) * k,
      snapped: true,
    }
  },

  // Position every edge menu at its edge's CURRENT midpoint, converted to
  // overlay coordinates (stage mid × scale + pan). Called after pan/zoom/fit
  // and on link-mode pointermove (the target edge's menu rides the snap
  // point instead of the resting midpoint).
  _placeEdgeMenus() {
    this.el.querySelectorAll("[data-wf-edge-menu]").forEach((menu) => {
      // Abierto por clic en el alambre: respeta la posición del clic.
      if (menu.hasAttribute("data-menu-at-click")) return
      const path = this.el.querySelector(`path[data-edge-key='${menu.dataset.edgeKey}']`)
      if (!path) return

      let cx, cy
      if (this._linkMode && this._linkMode.menu === menu && this._linkMode.snap) {
        cx = this._linkMode.snap.x
        cy = this._linkMode.snap.y
      } else {
        const from = this.el.querySelector(
          `[data-wf-port='out'][data-step-id='${menu.dataset.prereqId}']`
        )
        const to = this.el.querySelector(
          `[data-wf-port='in'][data-step-id='${menu.dataset.dependentId}']`
        )
        if (!from || !to) return

        const a = this._stageRect(from)
        const b = this._stageRect(to)
        const sag =
          Math.abs(b.cy - a.cy) < 1 && b.cx - a.cx > 268 ? (96 + 20) * 0.7 : 0
        const t = 0.5
        cx = bezier(a.cx, a.cx + (b.cx - a.cx) * 0.3, b.cx - (b.cx - a.cx) * 0.3, b.cx, t)
        cy = bezier(a.cy, a.cy + sag, b.cy + sag, b.cy, t)
      }

      menu.style.left = `${cx - MENU_HIT_HALF}px`
      menu.style.top = `${cy - MENU_HIT_HALF}px`
    })
  },

  // Center of an element in stage coordinates (it lives inside the
  // transformed stage, so rect math must run through its offset geometry).
  _stageRect(el) {
    const c = el.getBoundingClientRect()
    const s = this.el.getBoundingClientRect()
    return {
      cx: (c.left + c.width / 2 - s.left - this.tx) / this.scale,
      cy: (c.top + c.height / 2 - s.top - this.ty) / this.scale,
    }
  },

  // Re-derive every rendered edge from the CURRENT port positions. The
  // mirror shape of graph_edges/3: horizontal-bezier prereq → dependent,
  // sagging under same-row spans so it never cuts through cards.
  redrawEdges() {
    this.el.querySelectorAll("path[data-edge-key]").forEach((path) => this._drawEdge(path))

    // Link mode: the target edge's wire end chases the snap point (it is
    // dimmed/dashed via .wfe-edge-target until the mode exits).
    const mode = this._linkMode
    if (mode && mode.snap) {
      const path = this.el.querySelector(
        `path[data-edge-key='${mode.menu.dataset.edgeKey}']`
      )
      const to = this.el.querySelector(
        `[data-wf-port='in'][data-step-id='${mode.dependentId}']`
      )
      const from = this.el.querySelector(
        `[data-wf-port='out'][data-step-id='${mode.prereqId}']`
      )
      if (path && from && to) {
        const a = this._stageRect(from)
        const t = mode.snap
        path.setAttribute(
          "d",
          `M ${a.cx} ${a.cy} C ${a.cx + (t.x - a.cx) * 0.3} ${a.cy}, ` +
            `${t.x - (t.x - a.cx) * 0.3} ${t.y}, ${t.x} ${t.y}`
        )
      }
    }
  },

  _drawEdge(path) {
    const [prereqId, dependentId] = path.dataset.edgeKey.split("|")
    const from = this.el.querySelector(
      `[data-wf-port='out'][data-step-id='${prereqId}']`
    )
    const to = this.el.querySelector(
      `[data-wf-port='in'][data-step-id='${dependentId}']`
    )
    if (!from || !to) return

    const a = this._stageRect(from)
    const b = this._stageRect(to)
    const sag =
      Math.abs(b.cy - a.cy) < 1 && b.cx - a.cx > 268
        ? (96 + 20) * 0.7
        : 0
    path.setAttribute(
      "d",
      `M ${a.cx} ${a.cy} C ${a.cx + (b.cx - a.cx) * 0.3} ${a.cy + sag}, ` +
        `${b.cx - (b.cx - a.cx) * 0.3} ${b.cy + sag}, ${b.cx} ${b.cy}`
    )
  },
}

export default WfCanvas
