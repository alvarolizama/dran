// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/dran"
import topbar from "../vendor/topbar"
import "../vendor/svg-pan-zoom.min.js"
import MarkdownEditor from "./hooks/markdown_editor.js"
import Mermaid from "./hooks/mermaid.js"
import Graph3D from "./hooks/graph_3d.js"
import TaskDnD from "./hooks/task_dnd.js"
import WfCanvas from "./hooks/wf_canvas.js"

const GraphPanZoom = {
  mounted() {
    this.draggedNode = null
    this.dragMoved = false
    this.lastNodeCount = null
    this.init()
    this.attachNodeDrag()
    // The graph may mount inside a hidden tab panel (display:none) — its
    // bounding rect is 0 so the initial fit is wrong. Re-fit as soon as the
    // element becomes visible.
    this._visibilityObserver = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) requestAnimationFrame(() => this.fitToContent())
      })
    })
    this._visibilityObserver.observe(this.el)
  },
  updated() {
    const svg = this.el
    if (!svg || !svg._panZoom) return
    const count = svg.querySelectorAll("g[data-node-id]").length
    if (this.lastNodeCount !== count) {
      this.lastNodeCount = count
      requestAnimationFrame(() => this.fitToContent())
    }
  },
  destroyed() {
    if (this._visibilityObserver) {
      this._visibilityObserver.disconnect()
      this._visibilityObserver = null
    }
    if (this.el && this.el._panZoom) {
      this.el._panZoom.destroy()
      this.el._panZoom = null
    }
  },
  init() {
    const svg = this.el
    if (!svg) return
    if (svg._panZoom) {
      svg._panZoom.destroy()
      svg._panZoom = null
    }
    svg._panZoom = window.svgPanZoom(svg, {
      controlIconsEnabled: true,
      fit: false,
      center: false,
      minZoom: 0.2,
      maxZoom: 10,
      beforePan: (oldPan, newPan) => {
        if (this.draggedNode) return false
        return newPan
      }
    })
    setTimeout(() => this.fitToContent(), 50)
  },
  fitToContent() {
    const svg = this.el
    if (!svg || !svg._panZoom) return
    const circles = svg.querySelectorAll("g[data-node-id] circle")
    if (circles.length === 0) {
      svg._panZoom.reset()
      return
    }
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    circles.forEach((c) => {
      const cx = parseFloat(c.getAttribute("cx"))
      const cy = parseFloat(c.getAttribute("cy"))
      const r = parseFloat(c.getAttribute("r")) || 12
      minX = Math.min(minX, cx - r)
      minY = Math.min(minY, cy - r)
      maxX = Math.max(maxX, cx + r)
      maxY = Math.max(maxY, cy + r)
    })
    const pad = 60
    const contentW = (maxX - minX) + pad * 2
    const contentH = (maxY - minY) + pad * 2
    const sr = svg.getBoundingClientRect()
    const viewW = Math.min(sr.width, window.innerWidth - sr.left)
    const viewH = Math.min(sr.height, window.innerHeight - sr.top)
    const zoomX = viewW / contentW
    const zoomY = viewH / contentH
    const zoom = Math.min(zoomX, zoomY)
    svg._panZoom.zoom(zoom)
    const panX = (viewW - contentW * zoom) / 2 - (minX - pad) * zoom
    const panY = (viewH - contentH * zoom) / 2 - (minY - pad) * zoom
    svg._panZoom.pan({x: panX, y: panY})
  },
  attachNodeDrag() {
    const svg = this.el
    if (!svg) return

    const toSvgCoords = (clientX, clientY) => {
      const pt = svg.createSVGPoint()
      pt.x = clientX
      pt.y = clientY
      const ctm = svg.getScreenCTM()
      if (!ctm) return {x: 0, y: 0}
      const inv = ctm.inverse()
      const transformed = pt.matrixTransform(inv)
      return {x: transformed.x, y: transformed.y}
    }

    const findNodeG = (target) => {
      let el = target
      while (el && el !== svg) {
        if (el.tagName === "g" && el.hasAttribute("data-node-id")) return el
        el = el.parentElement
      }
      return null
    }

    const onDown = (e) => {
      const nodeG = findNodeG(e.target)
      if (!nodeG) return
      e.stopPropagation()
      e.preventDefault()
      const id = nodeG.getAttribute("data-node-id")
      const {x, y} = toSvgCoords(e.clientX, e.clientY)
      this.draggedNode = {id, g: nodeG, startClientX: e.clientX, startClientY: e.clientY}
      this.dragMoved = false
      if (svg._panZoom) svg._panZoom.disablePan()
    }

    const onMove = (e) => {
      if (!this.draggedNode) return
      const dx = Math.abs(e.clientX - this.draggedNode.startClientX)
      const dy = Math.abs(e.clientY - this.draggedNode.startClientY)
      if (dx > 3 || dy > 3) this.dragMoved = true
      if (!this.dragMoved) return
      const {x, y} = toSvgCoords(e.clientX, e.clientY)
      this.updateNodePosition(this.draggedNode.id, x, y)
    }

    const onUp = (e) => {
      if (!this.draggedNode) return
      const wasDrag = this.dragMoved
      const id = this.draggedNode.id
      this.draggedNode = null
      if (svg._panZoom) svg._panZoom.enablePan()
      if (wasDrag) {
        const {x, y} = toSvgCoords(e.clientX, e.clientY)
        this.pushEvent("node_drag", {id, x: Math.round(x), y: Math.round(y)})
      }
    }

    svg.addEventListener("mousedown", onDown)
    svg.addEventListener("mousemove", onMove)
    window.addEventListener("mouseup", onUp)
    this._nodeDragHandlers = {onDown, onMove, onUp}

    svg.addEventListener("touchstart", (te) => {
      const t = te.touches[0]
      onDown({target: te.target, clientX: t.clientX, clientY: t.clientY, stopPropagation: () => te.stopPropagation(), preventDefault: () => te.preventDefault()})
    }, {passive: false})
    svg.addEventListener("touchmove", (te) => {
      const t = te.touches[0]
      onMove({clientX: t.clientX, clientY: t.clientY})
      if (this.draggedNode) te.preventDefault()
    }, {passive: false})
    svg.addEventListener("touchend", (te) => {
      const t = te.changedTouches[0]
      onUp({clientX: t.clientX, clientY: t.clientY})
    })
  },
  updateNodePosition(id, x, y) {
    const svg = this.el
    const g = svg.querySelector(`g[data-node-id="${id}"]`)
    if (!g) return
    const circle = g.querySelector("circle")
    const text = g.querySelector("text")
    if (circle) {
      circle.setAttribute("cx", x)
      circle.setAttribute("cy", y)
    }
    if (text) {
      const r = parseFloat(circle.getAttribute("r")) || 12
      text.setAttribute("x", x)
      text.setAttribute("y", y + r + 15)
    }
    this.updateEdgesForNode(id, x, y)
  },
  updateEdgesForNode(id, x, y) {
    const svg = this.el
    const lines = svg.querySelectorAll("line[data-source], line[data-target]")
    lines.forEach((line) => {
      const source = line.getAttribute("data-source")
      const target = line.getAttribute("data-target")
      if (source === id) {
        line.setAttribute("x1", x)
        line.setAttribute("y1", y)
      }
      if (target === id) {
        line.setAttribute("x2", x)
        line.setAttribute("y2", y)
      }
    })
  }
}

const CommandPalette = {
  mounted() {
    this._keyHandler = (e) => {
      // Cmd+K / Ctrl+K toggles the palette
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault()
        this.pushEventTo(this.el, "toggle", {})
        return
      }

      // If the palette is open, handle Escape and arrow/enter navigation
      const isOpen = this.el.querySelector('[role="dialog"]') !== null
      if (!isOpen) return

      if (e.key === "Escape") {
        e.preventDefault()
        this.pushEventTo(this.el, "close", {})
        return
      }

      if (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "Enter") {
        e.preventDefault()
        this.pushEventTo(this.el, "key", {key: e.key})
      }
    }
    window.addEventListener("keydown", this._keyHandler)
  },

  destroyed() {
    if (this._keyHandler) {
      window.removeEventListener("keydown", this._keyHandler)
    }
  }
}

const ScrollBottom = {
  mounted() {
    this.scrollToBottom()
  },
  updated() {
    this.scrollToBottom()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, GraphPanZoom, MarkdownEditor, Mermaid, Graph3D, CommandPalette, ScrollBottom, TaskDnD, WfCanvas},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// ⌘⇧C / Ctrl+Shift+C — focus and open the context selector dropdown
window.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === "c" || e.key === "C")) {
    const select = document.getElementById("context-selector")
    if (select) {
      e.preventDefault()
      select.focus()
      // Show the dropdown options (works in most browsers)
      try {
        const event = new MouseEvent("mousedown")
        select.dispatchEvent(event)
      } catch (_err) {
        // Fallback: some browsers need a different approach
        select.size = select.options.length
      }
    }
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

