// Graph3D — 3d-force-graph 3D graph view hook.
//
// Renders graph data with 3d-force-graph (vanilla JS):
//   • Force-directed 3D layout (d3-force-3d under the hood)
//   • Nodes sized by connection count
//   • Curved edges with animated particle flow
//   • Click to select: shows labels for the clicked node and its direct
//     neighbors, dims the rest. No hover behavior.
//   • Double-click a node → navigate to that page.
//   • Background click clears the selection.
//   • Auto zoom-to-fit after layout stabilizes
//   • Dark background matching Dran's brand color
//
// The hook reads graph data from `data-graph` attribute (JSON) on mount and on
// every LiveView `updated()` callback (show mode only; index mode fetches via
// HTTP and keeps the data in fullData).

import ForceGraph3D from "3d-force-graph"
import * as THREE from "three"
import SpriteText from "three-spritetext"

// BFS depth for click-selection neighborhood (1 = direct neighbors only)
const HIGHLIGHT_BFS_DEPTH = 1

// Adaptive render quality: big graphs need cheap geometry, no particle
// streams and a short force simulation to stay fluid. Small graphs keep the
// full polish.
function graphScale(nodeCount, edgeCount) {
  if (nodeCount > 700 || edgeCount > 2500) {
    return { sphereSegments: 8, particles: 0, warmup: 15, cooldown: 500 }
  }
  if (nodeCount > 250 || edgeCount > 800) {
    return { sphereSegments: 12, particles: 1, warmup: 40, cooldown: 1200 }
  }
  return { sphereSegments: 24, particles: 2, warmup: 100, cooldown: 2000 }
}

const Graph3D = {
  mounted() {
    this.graph = null
    this.resizeHandler = null
    this.visibilityObserver = null
    // Click selection state (replaces the old hover system)
    this.selectedNode = null
    this.labeledNodes = new Set()
    this.highlightNodes = new Set()
    this.highlightLinks = new Set()
    this.nodeDepths = new Map()
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
      this.clearSelection()
      this.graph.graphData(this.fullData)
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
      // Node appearance — sphere only (labels are added on click selection)
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
      // Interaction: click to select (show labels + dim), double-click to
      // navigate, background click to clear. No hover callbacks.
      .onNodeClick((node, event) => this.handleNodeClick(node, event))
      .onBackgroundClick(() => this.handleBackgroundClick())
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

    // Handle hidden tab panels (display:none) — re-fit when the container
    // becomes visible. When the graph mounts inside a hidden tab its
    // dimensions are 0×0 and the initial layout is wrong; this observer
    // fires when it becomes visible so we can resize AND re-fit the camera.
    this.visibilityObserver = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          requestAnimationFrame(() => this.handleVisible())
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
    // Selection state becomes stale once the scene rebuilds — clear it.
    this.clearSelection()

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

    if (this.progressive) {
      this.pushEvent("graph_counts", { node_count: nodes.length, edge_count: links.length })
    }
  },

  // ── Node objects (sphere only — labels added on click selection) ────────

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

    return group
  },

  nodeRadius(node) {
    return 4 + Math.min(node.connections || 0, 12) * 0.8
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

  handleNodeClick(node, event) {
    // Double-click → navigate to the page.
    if (event && event.detail === 2) {
      if (node.slug) {
        this.pushEvent("node_click", { slug: node.slug })
      }
      return
    }
    // Single click → select: show labels for this node and its direct
    // neighbors, dim the rest. Does NOT navigate.
    this.selectNode(node)
  },

  // Background click clears the selection.
  handleBackgroundClick() {
    this.clearSelection()
  },

  // Show labels and highlight the clicked node + its direct neighbors.
  // Does NOT navigate — the next click on a labeled node navigates.
  selectNode(node) {
    // Reset previous selection first.
    this.clearSelection()

    this.selectedNode = node
    const { depths, links } = this.computeNeighborhood(
      node.id,
      this.graph.graphData().links
    )
    this.nodeDepths = depths
    this.highlightNodes = new Set(depths.keys())
    this.highlightLinks = links

    // Dim non-neighborhood spheres, glow the selected neighborhood, and add
    // a clickable SpriteText label above each labeled node. The label faces
    // the camera (SpriteText extends THREE.Sprite) and is a child of the
    // node's Group, so raycasting reports it as the parent node — clicking
    // it lands in handleNodeClick, which sees the node as already selected
    // and triggers navigation.
    this.graph.graphData().nodes.forEach(n => {
      if (!n.__sphere) return
      const depth = this.nodeDepths.get(n.id)
      const isLabeled = depth !== undefined
      const isCenter = n.id === node.id

      n.__sphere.material.opacity = isLabeled ? 0.95 : 0.15
      n.__sphere.material.emissiveIntensity = isLabeled ? (isCenter ? 1.2 : 0.55) : 0.05
      const scale = isCenter ? 1.35 : (depth === 1 ? 1.15 : 1)
      n.__sphere.scale.setScalar(scale)

      // Add a clickable label sprite for this node and its direct neighbors.
      if (isLabeled && n.label) {
        const group = n.__sphere.parent
        const sprite = new SpriteText(n.label)
        sprite.color = "#f1f5f9"
        sprite.textHeight = 6
        sprite.backgroundColor = "rgba(10, 14, 39, 0.88)"
        sprite.borderColor = "rgba(148, 163, 184, 0.4)"
        sprite.borderWidth = 1
        sprite.padding = [4, 6]
        sprite.position.y = this.nodeRadius(n) + 10
        group.add(sprite)
        n.__label = sprite
        this.labeledNodes.add(n.id)
      }
    })

    // Trigger link restyle (linkColor / linkWidth / particles are accessor-based)
    this.graph.refresh()
  },

  // Remove the active selection, dispose labels, restore spheres/links.
  clearSelection() {
    if (this.graph) {
      this.graph.graphData().nodes.forEach(n => {
        if (n.__label) {
          if (n.__label.parent) n.__label.parent.remove(n.__label)
          if (n.__label.material.map) n.__label.material.map.dispose()
          n.__label.material.dispose()
          n.__label = null
        }
        if (n.__sphere) {
          n.__sphere.material.opacity = 0.95
          n.__sphere.material.emissiveIntensity = 0.35
          n.__sphere.scale.setScalar(1)
        }
      })
      this.graph.refresh()
    }
    this.selectedNode = null
    this.highlightNodes = new Set()
    this.highlightLinks = new Set()
    this.nodeDepths = new Map()
    this.labeledNodes = new Set()
  },

  // BFS from the selected node up to HIGHLIGHT_BFS_DEPTH levels, following
  // links in both directions. Returns a Map of node id -> depth (0 = clicked)
  // and the set of links traversed. Used for click-selection neighborhood.
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
    for (let depth = 1; depth <= HIGHLIGHT_BFS_DEPTH; depth++) {
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

  linkDisplayColor(link) {
    if (!this.selectedNode) return link.color || "#94A3B8"
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

    // Called by the IntersectionObserver when the container transitions from
    // hidden (display:none in a tab panel) to visible. Resize the canvas to
    // the now-correct dimensions, re-trigger the force simulation so nodes
    // re-settle, and re-fit the camera so all nodes are framed — the initial
    // mount in a 0×0 container left everything mis-positioned.
    handleVisible() {
      this.handleResize()
      if (!this.graph || !this.fullData) return
      const nodes = this.graph.graphData().nodes
      if (nodes.length === 0) return
      // Re-trigger the force simulation so nodes settle in the now-correct
      // canvas dimensions, then zoom-to-fit when the engine stops.
      this.graph.d3AlphaTarget(0.001)
      // d3ReCountdown that should exist on the inner forceGraph; call via the
      // engine re-heat method if available, otherwise graphData re-assign
      this.graph.graphData({ nodes, links: this.graph.graphData().links })
      this.graph.zoomToFit(400, 40)
    },

  // ── Cleanup ───────────────────────────────────────────────────────────

  cleanup() {
    if (this.resizeHandler) {
      window.removeEventListener("resize", this.resizeHandler)
      this.resizeHandler = null
    }
    if (this.visibilityObserver) {
      this.visibilityObserver.disconnect()
      this.visibilityObserver = null
    }
    if (this.graph) {
      // Dispose sphere geometries/materials and any active labels
      this.graph.graphData().nodes.forEach(node => {
        if (node.__label) {
          if (node.__label.material.map) node.__label.material.map.dispose()
          node.__label.material.dispose()
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
    this.selectedNode = null
    this.highlightNodes = new Set()
    this.highlightLinks = new Set()
    this.nodeDepths = new Map()
    this.labeledNodes = new Set()
  }
}

export default Graph3D