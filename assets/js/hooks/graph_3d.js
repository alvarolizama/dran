// Graph3D — three.js 3D graph view hook.
//
// Renders the same graph data (nodes + edges) as the SVG 2D view but in 3D:
//   • Spheres for nodes, colored by type (same palette as 2D)
//   • Thin lines for edges, colored by edge type
//   • OrbitControls for rotate / zoom / pan
//   • Dark background
//
// The hook reads graph data from `data-graph` attribute (JSON) on mount and on
// every LiveView `updated()` callback (so toggling 2D↔3D re-syncs positions).

import * as THREE from "three"
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js"

const Graph3D = {
  mounted() {
    this.scene = null
    this.renderer = null
    this.camera = null
    this.controls = null
    this.animationId = null
    this.nodeMeshes = []
    this.resizeHandler = null
    this.init()
  },

  updated() {
    // Re-sync data when LiveView pushes new assigns (e.g. graph refresh)
    const data = this.readGraphData()
    if (data && this.scene) {
      this.clearScene()
      this.buildGraph(data)
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

    // Scene
    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0x0f172a) // slate-900

    // Camera
    this.camera = new THREE.PerspectiveCamera(60, width / height, 0.1, 5000)
    this.camera.position.set(0, 0, 600)

    // Renderer
    this.renderer = new THREE.WebGLRenderer({antialias: true, alpha: false})
    this.renderer.setSize(width, height)
    this.renderer.setPixelRatio(window.devicePixelRatio)
    container.appendChild(this.renderer.domElement)

    // Lights
    const ambient = new THREE.AmbientLight(0xffffff, 0.6)
    this.scene.add(ambient)

    const dir = new THREE.DirectionalLight(0xffffff, 0.8)
    dir.position.set(200, 300, 400)
    this.scene.add(dir)

    // Controls
    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.08
    this.controls.rotateSpeed = 0.8
    this.controls.zoomSpeed = 1.2
    this.controls.minDistance = 50
    this.controls.maxDistance = 2000

    // Build graph
    const data = this.readGraphData()
    if (data) this.buildGraph(data)

    // Resize handling
    this.resizeHandler = () => this.handleResize()
    window.addEventListener("resize", this.resizeHandler)

    // Start animation loop
    this.animate()
  },

  // ── Graph building ────────────────────────────────────────────────────

  buildGraph(data) {
    const nodes = data.nodes || []
    const edges = data.edges || []
    const count = nodes.length
    if (count === 0) return

    // Spherical layout: distribute nodes on a sphere using fibonacci spiral
    const layoutRadius = Math.max(120, count * 12)
    const nodePositions = {}

    const goldenAngle = Math.PI * (3 - Math.sqrt(5))
    nodes.forEach((node, i) => {
      const y = 1 - (i / Math.max(count - 1, 1)) * 2 // 1 → -1
      const r = Math.sqrt(1 - y * y)
      const theta = goldenAngle * i
      const x = Math.cos(theta) * r
      const z = Math.sin(theta) * r

      nodePositions[node.id] = {
        x: x * layoutRadius,
        y: y * layoutRadius,
        z: z * layoutRadius
      }
    })

    // Spheres for nodes
    const sphereGeo = new THREE.SphereGeometry(14, 24, 24)
    const labelGroup = new THREE.Group()

    nodes.forEach((node) => {
      const pos = nodePositions[node.id]
      const color = this.parseColor(node.color, "#94A3B8")

      const mat = new THREE.MeshPhongMaterial({
        color: color,
        emissive: color,
        emissiveIntensity: 0.25,
        shininess: 60
      })

      const mesh = new THREE.Mesh(sphereGeo, mat)
      mesh.position.set(pos.x, pos.y, pos.z)
      mesh.userData = {nodeId: node.id, slug: node.slug, label: node.label}

      // Click → navigate (same as 2D node_click)
      mesh.callback = () => {
        if (node.slug) {
          this.pushEvent("node_click", {slug: node.slug})
        }
      }

      this.scene.add(mesh)
      this.nodeMeshes.push(mesh)

      // Sprite label
      const label = this.makeTextSprite(node.label || "", color)
      label.position.set(pos.x, pos.y + 26, pos.z)
      labelGroup.add(label)
    })

    this.scene.add(labelGroup)

    // Edges as thin lines
    edges.forEach((edge) => {
      const src = nodePositions[edge.source_id]
      const tgt = nodePositions[edge.target_id]
      if (!src || !tgt) return

      const points = [
        new THREE.Vector3(src.x, src.y, src.z),
        new THREE.Vector3(tgt.x, tgt.y, tgt.z)
      ]

      const geo = new THREE.BufferGeometry().setFromPoints(points)
      const color = this.parseColor(edge.color, "#94A3B8")
      const mat = new THREE.LineBasicMaterial({
        color: color,
        transparent: true,
        opacity: 0.5
      })

      const line = new THREE.Line(geo, mat)
      this.scene.add(line)
    })

    // Center camera on graph
    this.camera.position.set(0, 0, layoutRadius * 2.2)
    this.controls.target.set(0, 0, 0)
    this.controls.update()
  },

  // ── Helpers ───────────────────────────────────────────────────────────

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

  parseColor(hex, fallback) {
    try {
      return new THREE.Color(hex || fallback)
    } catch {
      return new THREE.Color(fallback)
    }
  },

  makeTextSprite(text, color) {
    const canvas = document.createElement("canvas")
    const ctx = canvas.getContext("2d")
    const fontSize = 48
    ctx.font = `bold ${fontSize}px Inter, system-ui, sans-serif`
    const metrics = ctx.measureText(text)
    const w = Math.ceil(metrics.width) + 20
    const h = fontSize + 16
    canvas.width = w
    canvas.height = h

    ctx.font = `bold ${fontSize}px Inter, system-ui, sans-serif`
    ctx.fillStyle = "#e2e8f0"
    ctx.textBaseline = "middle"
    ctx.fillText(text, 10, h / 2)

    const texture = new THREE.CanvasTexture(canvas)
    texture.minFilter = THREE.LinearFilter
    const mat = new THREE.SpriteMaterial({
      map: texture,
      transparent: true,
      depthWrite: false
    })
    const sprite = new THREE.Sprite(mat)
    const scale = 0.35
    sprite.scale.set(w * scale, h * scale, 1)
    return sprite
  },

  clearScene() {
    // Remove all meshes and lines, keep lights
    const toRemove = []
    this.scene.children.forEach((child) => {
      if (child.type === "Mesh" || child.type === "Line" || child.type === "Group" || child.type === "Sprite") {
        toRemove.push(child)
      }
    })
    toRemove.forEach((obj) => {
      this.scene.remove(obj)
      if (obj.geometry) obj.geometry.dispose()
      if (obj.material) {
        if (Array.isArray(obj.material)) {
          obj.material.forEach((m) => m.dispose())
        } else {
          obj.material.dispose()
        }
      }
    })
    this.nodeMeshes = []
  },

  handleResize() {
    const container = this.el
    if (!container || !this.renderer) return
    const width = container.clientWidth || 800
    const height = container.clientHeight || 600
    this.camera.aspect = width / height
    this.camera.updateProjectionMatrix()
    this.renderer.setSize(width, height)
  },

  animate() {
    this.animationId = requestAnimationFrame(() => this.animate())
    this.controls.update()
    this.renderer.render(this.scene, this.camera)
  },

  cleanup() {
    if (this.animationId) cancelAnimationFrame(this.animationId)
    if (this.resizeHandler) window.removeEventListener("resize", this.resizeHandler)
    if (this.controls) this.controls.dispose()
    if (this.renderer) {
      this.renderer.dispose()
      if (this.renderer.domElement && this.renderer.domElement.parentNode) {
        this.renderer.domElement.parentNode.removeChild(this.renderer.domElement)
      }
    }
    if (this.scene) this.clearScene()
    this.scene = null
    this.renderer = null
    this.camera = null
    this.controls = null
    this.nodeMeshes = []
  }
}

export default Graph3D
