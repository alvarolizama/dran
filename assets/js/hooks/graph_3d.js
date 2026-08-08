// Graph3D — 3d-force-graph 3D graph view hook.
//
// Renders graph data with 3d-force-graph (vanilla JS):
//   • Force-directed 3D layout (d3-force-3d under the hood)
//   • Nodes sized by connection count
//   • Curved edges with animated particle flow
//   • Hover highlight with 2-level BFS neighborhood dimming + label reveal
//   • Labels hidden by default, shown only for the hovered neighborhood
//   • Click to navigate (node_click)
//   • Auto zoom-to-fit after layout stabilizes
//   • Dark background matching Dran's brand color
//
// The hook reads graph data from `data-graph` attribute (JSON) on mount and on
// every LiveView `updated()` callback.

import ForceGraph3D from "3d-force-graph"
import SpriteText from "three-spritetext"
import * as THREE from "three"

// Max BFS depth for label reveal on hover (2 = neighbors of neighbors)
const LABEL_BFS_DEPTH = 2

// Adaptive render quality: big graphs need cheap geometry, no particle
// streams and a short force simulation to stay fluid. Small graphs keep the
// full polish.
function graphScale(nodeCount, edgeCount) {
  if (nodeCount > 700 || edgeCount > 2500) {
    return { sphereSegments: 8, particles: 0, warmup: 15, cooldown: 500, labelRetries: 40 }
  }
  if (nodeCount > 250 || edgeCount > 800) {
    return { sphereSegments: 12, particles: 1, warmup: 40, cooldown: 1200, labelRetries: 80 }
  }
  return { sphereSegments: 24, particles: 2, warmup: 100, cooldown: 2000, labelRetries: 120 }
}

const Graph3D = {
  mounted() {
    this.graph = null
    this.resizeHandler = null
    this.visibilityObserver = null
    this.hoveredNode = null
    this.highlightNodes = new Set()
    this.highlightLinks = new Set()
    this.nodeDepths = new Map()
    this.labelRetryId = null
    // Wave 2: data lives on the client. `fullData` is the raw {nodes, links}
    // from the fetch (or from data-graph in show mode); `visibleTypes` is the
    // Set of page types currently shown. The LiveView only ever receives
    // counters — nodes/edges never cross the socket in index mode.
    this.fullData = null
    this.visibleTypes = null
    // true when in index (progressive) mode: data is fetched via HTTP and
    // rendered client-side, so updated() must not try to re-read data-graph.
    this.progressive = false
    // Wave 2: the LV pushes the sidebar's visible_types after a toggle; filter
    // client-side against our own data. No socket roundtrip of nodes/edges.
    this.handleEvent("set_visible_types", ({ types }) => {
      this.visibleTypes = new Set(types || [])
      if (this.fullData) {
        this.renderVisible()
      }
    })
    // Wave 3: the LV debounces page_changed broadcasts and tells us to
    // re-fetch the graph over HTTP when it's time.
    this.handleEvent("graph_refetch", () => {
      this.fetchGraphData()
    })
    this.init()
  },

  updated() {
    // Wave 2: in index mode the LV no longer carries nodes/edges — the hook
    // owns the data in `fullData`. Re-sync from data-graph only in show mode
    // (small pre-rendered subgraph), where the LV still drives the payload.
    if (this.progressive) return
    const data = this.readGraphData()
    if (data && this.graph) {
      this.fullData = this.transformData(data)
      this.scale = graphScale(this.fullData.nodes.length, this.fullData.links.length)
      this.graph.warmupTicks(this.scale.warmup).cooldownTime(this.scale.cooldown)
      this.graph.graphData(this.fullData)
      this.scheduleLabelRefresh()
    }
  },

  destroyed() {
    this.cleanup()
  },

  // ── Init ──────────────────────────────────────────────────────────────

  init() {
    const container = this.el
    if (!container) return

    const width = container.clientWidth || 800
    const height = container.clientHeight || 600

    // Wave 2: read the initial visible-types from the element (index mode
    // passes the sidebar's current set; show mode omits the attribute → null).
    this.visibleTypes = this.readVisibleTypes()

    // Progressive loading: when data-graph is empty (index mode), fetch the
    // graph JSON via HTTP after the shell renders. When it's pre-populated
    // (show mode / search results), use it directly.
    const initial = this.readGraphData()
    const needsFetch = !initial || initial.nodes.length === 0
    this.progressive = needsFetch

    // Pick render quality from the incoming graph size before wiring accessors
    this.scale = graphScale(initial ? initial.nodes.length : 0, initial ? initial.edges.length : 0)

    // Create the 3D force graph instance
    this.graph = ForceGraph3D()(container)
      .width(width)
      .height(height)
      .backgroundColor("#0a0e27")
      .showNavInfo(false)
      // Rich HTML tooltip for the hovered node (styled in app.css)
      .nodeLabel(node => this.tooltipHtml(node))
      // Node appearance — sphere + adaptive text label
      .nodeThreeObject(node => this.buildNodeObject(node))
      .nodeThreeObjectExtend(false)
      // Edge appearance
      .linkColor(link => this.linkDisplayColor(link))
      .linkOpacity(0.35)
      .linkWidth(link => this.highlightLinks.has(link) ? 3 : 1.5)
      .linkCurvature(0.25)
      .linkDirectionalParticles(link => this.scale.particles === 0 ? 0 : (this.highlightLinks.has(link) ? this.scale.particles * 2 : this.scale.particles))
      .linkDirectionalParticleWidth(1.5)
      .linkDirectionalParticleSpeed(0.006)
      .linkDirectionalParticleColor(link => link.color || "#94A3B8")
      // Interaction
      .onNodeClick(node => this.handleNodeClick(node))
      .onNodeHover(node => this.handleNodeHover(node))
      // Physics / layout — shorter warmup/cooldown on big graphs so the
      // force simulation doesn't peg the CPU for seconds
      .warmupTicks(this.scale.warmup)
      .cooldownTime(this.scale.cooldown)
      .onEngineStop(() => this.handleEngineStop())

    if (needsFetch) {
      this.fetchGraphData()
    } else {
      // Load initial data (show mode, search results)
      this.fullData = this.transformData(initial)
      this.renderVisible()
    }

    // Resize handling
    this.resizeHandler = () => this.handleResize()
    window.addEventListener("resize", this.resizeHandler)

    // Handle hidden tab panels (display:none) — re-fit when visible
    this.visibilityObserver = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          requestAnimationFrame(() => this.handleResize())
        }
      })
    })
    this.visibilityObserver.observe(container)
  },

  // ── Progressive loading (index mode) ──────────────────────────────────

  fetchGraphData() {
    fetch("/api/graph-json")
      .then(r => r.json())
      .then(data => {
        // Update render quality for the fetched size
        this.scale = graphScale(data.nodes.length, data.edges.length)
        this.graph.warmupTicks(this.scale.warmup).cooldownTime(this.scale.cooldown)

        // Wave 2: keep the full dataset client-side; push only counters so
        // the LV updates the sidebar without the graph crossing the socket.
        this.fullData = this.transformData(data)
        this.pushEvent("graph_loaded", {
          total_nodes: data.total_nodes,
          total_edges: data.total_edges,
          type_counts: data.type_counts
        })

        // Render in the 3D view immediately (don't wait for LV roundtrip)
        this.renderVisible()
      })
      .catch(err => {
        console.error("Graph3D: failed to fetch graph data", err)
        this.pushEvent("graph_loaded", { total_nodes: 0, total_edges: 0, type_counts: {} })
      })
  },

  // Wave 2: apply the current visible_types filter to fullData and render.
  // Filters out nodes whose type is hidden and any link whose endpoints are
  // both hidden — never touches the socket. Reports the visible counts back
  // to the LV (index mode) so the sidebar Totals stay accurate.
  renderVisible() {
    if (!this.fullData) return
    const visible = this.visibleTypes
    let nodes = this.fullData.nodes
    let links = this.fullData.links

    if (visible) {
      nodes = nodes.filter(n => visible.has(n.type))
      const visibleIds = new Set(nodes.map(n => n.id))
      links = links.filter(l => visibleIds.has(l.source) && visibleIds.has(l.target))
    }

    this.scale = graphScale(nodes.length, links.length)
    this.graph.warmupTicks(this.scale.warmup).cooldownTime(this.scale.cooldown)
    this.graph.graphData({ nodes, links })
    this.scheduleLabelRefresh()

    if (this.progressive) {
      this.pushEvent("graph_counts", { node_count: nodes.length, edge_count: links.length })
    }
  },

  // ── Node objects (sphere + label sprite) ─────────────────────────────

  buildNodeObject(node) {
    const group = new THREE.Group()
    const color = new THREE.Color(node.color || "#94A3B8")

    // Sphere — sized by connections. Segment count follows the adaptive
    // quality scale: high-poly spheres on small graphs, low-poly on big ones
    // (visually near-identical at this size, but far fewer vertices/GPU work).
    const radius = this.nodeRadius(node)
    const segments = this.scale.sphereSegments
    const sphere = new THREE.Mesh(
      new THREE.SphereGeometry(radius, segments, segments),
      new THREE.MeshLambertMaterial({
        color: color,
        emissive: color,
        emissiveIntensity: 0.35,
        transparent: true,
        opacity: 0.95
      })
    )
    group.add(sphere)
    node.__sphere = sphere

    // Text label — SpriteText, shown only on hover (BFS neighborhood)
    const label = new SpriteText(node.label || "")
    label.color = "#cbd5e1"
    label.textHeight = Math.max(6, radius * 1.1)
    label.fontFace = "'Inter', 'Helvetica Neue', Arial, sans-serif"
    label.fontWeight = "500"
    label.center.y = 1.0
    label.position.y = radius + label.textHeight * 0.35
    label.backgroundColor = "rgba(10, 14, 39, 0.6)"
    label.padding = 3
    label.borderRadius = 3
    label.borderWidth = 0
    label.visible = false // toggled on hover only
    group.add(label)
    node.__label = label

    return group
  },

  nodeRadius(node) {
    return 4 + Math.min(node.connections || 0, 12) * 0.8
  },

  // Rich HTML tooltip for the hovered node — escapes user content
  tooltipHtml(node) {
    const esc = s => String(s).replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]))
    const color = node.color || "#94A3B8"
    return `
      <div class="graph-tooltip">
        <div class="graph-tooltip-title">${esc(node.label)}</div>
        <div class="graph-tooltip-meta">
          <span class="graph-tooltip-type" style="--type-color: ${esc(color)}">${esc(node.type)}</span>
          <span class="graph-tooltip-conn">${node.connections || 0} links</span>
        </div>
      </div>`
  },

  // Show labels: only on hover — the node + its BFS neighborhood (2 levels).
  // 3d-force-graph builds nodeThreeObject asynchronously, so we retry until
  // every node has its __label attached (or give up after ~2s).
  scheduleLabelRefresh(attempts = 0) {
    if (this.labelRetryId) {
      cancelAnimationFrame(this.labelRetryId)
      this.labelRetryId = null
    }
    const tick = () => {
      if (!this.graph) return
      const { nodes } = this.graph.graphData()
      const ready = nodes.every(n => n.__label)
      this.refreshLabelVisibility()
      if (!ready && attempts < this.scale.labelRetries) {
        attempts++
        this.labelRetryId = requestAnimationFrame(tick)
      }
    }
    this.labelRetryId = requestAnimationFrame(tick)
  },

  // BFS from the hovered node up to LABEL_BFS_DEPTH levels, following links
  // in both directions. Returns a Map of node id -> depth (0 = hovered) and
  // the set of links traversed.
  computeNeighborhood(startId, links) {
    const linkId = l => (typeof l === "object" && l !== null ? String(l.id) : String(l))
    const adjacency = new Map()
    links.forEach(link => {
      const s = linkId(link.source)
      const t = linkId(link.target)
      if (!adjacency.has(s)) adjacency.set(s, [])
      if (!adjacency.has(t)) adjacency.set(t, [])
      adjacency.get(s).push({ next: t, link })
      adjacency.get(t).push({ next: s, link })
    })

    const depths = new Map([[startId, 0]])
    const linksInPath = new Set()
    let frontier = [startId]
    for (let depth = 1; depth <= LABEL_BFS_DEPTH; depth++) {
      const nextFrontier = []
      for (const id of frontier) {
        for (const { next, link } of adjacency.get(id) || []) {
          linksInPath.add(link)
          if (!depths.has(next)) {
            depths.set(next, depth)
            nextFrontier.push(next)
          }
        }
      }
      frontier = nextFrontier
    }
    return { depths, links: linksInPath }
  },

  // Text labels show only for the hovered node and its DIRECT neighbors
  // (depth ≤ 1). The hovered node also gets the rich HTML tooltip.
  refreshLabelVisibility() {
    if (!this.graph) return
    const { nodes } = this.graph.graphData()

    nodes.forEach(node => {
      if (!node.__label) return
      const depth = this.nodeDepths.get(node.id)
      node.__label.visible = depth !== undefined && depth <= 1
    })
  },

  // ── Data transformation ───────────────────────────────────────────────

  readGraphData() {
    const raw = this.el.getAttribute("data-graph")
    if (!raw) return null
    try {
      return JSON.parse(raw)
    } catch (e) {
      console.error("Graph3D: failed to parse data-graph JSON", e)
      return null
    }
  },

  // Wave 2: read the initial visible page-types from data-visible-types.
  // Absent (subgraph views) → null = show everything.
  readVisibleTypes() {
    const raw = this.el.getAttribute("data-visible-types")
    if (!raw) return null
    try {
      const types = JSON.parse(raw)
      return Array.isArray(types) ? new Set(types) : null
    } catch (e) {
      console.error("Graph3D: failed to parse data-visible-types JSON", e)
      return null
    }
  },

  transformData(data) {
    // Ids are normalized to strings: the JSON carries Ecto integer ids, and
    // force-graph replaces link source/target with node object references.
    // String ids keep Set/Map lookups consistent everywhere.
    const nodes = (data.nodes || []).map(n => ({
      id: String(n.id),
      slug: n.slug,
      label: n.label || "",
      type: n.type,
      color: n.color || "#94A3B8",
      connections: 0
    }))

    const nodeById = new Map(nodes.map(n => [n.id, n]))

    const links = (data.edges || []).map(e => ({
      source: String(e.source_id),
      target: String(e.target_id),
      color: e.color || "#94A3B8"
    }))

    // Count connections per node (for sizing)
    links.forEach(link => {
      const src = nodeById.get(link.source)
      const tgt = nodeById.get(link.target)
      if (src) src.connections++
      if (tgt) tgt.connections++
    })

    return { nodes, links }
  },

  // ── Interaction handlers ──────────────────────────────────────────────

  handleNodeClick(node) {
    if (node.slug) {
      this.pushEvent("node_click", { slug: node.slug })
    }
  },

  handleNodeHover(node) {
    this.hoveredNode = node || null
    this.highlightNodes = new Set()
    this.highlightLinks = new Set()
    this.nodeDepths = new Map()

    if (node) {
      const { depths, links } = this.computeNeighborhood(
        node.id,
        this.graph.graphData().links
      )
      this.nodeDepths = depths
      this.highlightNodes = new Set(depths.keys())
      this.highlightLinks = links
    }

    // Restyle nodes: highlight the neighborhood, dim everything else.
    // The hovered node pops (scale + strong glow), direct neighbors glow.
    this.graph.graphData().nodes.forEach(n => {
      if (!n.__sphere) return
      const depth = this.nodeDepths.get(n.id)
      const active = !node || depth !== undefined
      const isHovered = node && n.id === node.id
      n.__sphere.material.opacity = active ? 0.95 : 0.15
      n.__sphere.material.emissiveIntensity = active ? (isHovered ? 1.2 : 0.55) : 0.05
      const scale = isHovered ? 1.35 : (depth === 1 ? 1.15 : 1)
      n.__sphere.scale.setScalar(scale)
    })

    // Labels follow highlight
    this.refreshLabelVisibility()

    // Trigger link restyle (linkColor / linkWidth / particles are accessor-based)
    this.graph.refresh()
  },

  linkDisplayColor(link) {
    if (!this.hoveredNode) return link.color || "#94A3B8"
    return this.highlightLinks.has(link)
      ? link.color || "#94A3B8"
      : "rgba(148, 163, 184, 0.05)"
  },

  handleEngineStop() {
    // Zoom to fit after layout stabilizes
    if (this.graph && this.graph.graphData().nodes.length > 0) {
      this.graph.zoomToFit(400, 40)
    }
  },

  // ── Resize ────────────────────────────────────────────────────────────

  handleResize() {
    const container = this.el
    if (!container || !this.graph) return
    const width = container.clientWidth || 800
    const height = container.clientHeight || 600
    if (width > 0 && height > 0) {
      this.graph.width(width).height(height)
    }
  },

  // ── Cleanup ───────────────────────────────────────────────────────────

  cleanup() {
    if (this.labelRetryId) {
      cancelAnimationFrame(this.labelRetryId)
      this.labelRetryId = null
    }
    if (this.resizeHandler) {
      window.removeEventListener("resize", this.resizeHandler)
      this.resizeHandler = null
    }
    if (this.visibilityObserver) {
      this.visibilityObserver.disconnect()
      this.visibilityObserver = null
    }
    if (this.graph) {
      // Dispose sprite textures and sphere geometries
      this.graph.graphData().nodes.forEach(node => {
        if (node.__label) {
          if (node.__label.material && node.__label.material.map) {
            node.__label.material.map.dispose()
          }
          if (node.__label.material) node.__label.material.dispose()
          node.__label = null
        }
        if (node.__sphere) {
          node.__sphere.geometry.dispose()
          node.__sphere.material.dispose()
          node.__sphere = null
        }
      })
      // Clear graph data to free GPU buffers
      this.graph.graphData({ nodes: [], links: [] })
      // Remove canvas from DOM
      const container = this.el
      if (container) {
        container.querySelectorAll("canvas").forEach(canvas => {
          if (canvas.parentNode) canvas.parentNode.removeChild(canvas)
        })
      }
      this.graph = null
    }
    this.hoveredNode = null
    this.highlightNodes = new Set()
    this.highlightLinks = new Set()
    this.nodeDepths = new Map()
  }
}

export default Graph3D
