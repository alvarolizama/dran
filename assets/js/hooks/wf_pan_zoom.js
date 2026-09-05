// Workflow DAG canvas pan/zoom.
// Applies a CSS transform (scale + translate) to an inner "stage" that holds
// both the HTML task cards and the SVG overlay, so they always stay aligned.
// Wheel zooms toward the cursor; drag on the background pans; buttons zoom
// in/out and fit. Drags that start on a card (which has phx-click) do not pan.
const WfPanZoom = {
  mounted() {
    this.stage = this.el.querySelector("[data-wf-stage]")
    if (!this.stage) return

    this.scale = 1
    this.tx = 0
    this.ty = 0
    this.minScale = 0.15
    this.maxScale = 3
    this._panning = null

    this._onWheel = (e) => {
      e.preventDefault()
      const rect = this.el.getBoundingClientRect()
      const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15
      this.zoomAt(e.clientX - rect.left, e.clientY - rect.top, factor)
    }

    this._onDown = (e) => {
      if (e.button !== 0) return
      // Never start a pan on a card (phx-click) or on the zoom controls.
      if (e.target.closest("[phx-click]") || e.target.closest("[data-wf-controls]")) return
      this._panning = {startX: e.clientX, startY: e.clientY, startTx: this.tx, startTy: this.ty}
    }

    this._onMove = (e) => {
      if (!this._panning) return
      this.tx = this._panning.startTx + (e.clientX - this._panning.startX)
      this.ty = this._panning.startTy + (e.clientY - this._panning.startY)
      this._apply()
    }

    this._onUp = () => {
      this._panning = null
    }

    this.el.addEventListener("wheel", this._onWheel, {passive: false})
    this.el.addEventListener("mousedown", this._onDown)
    window.addEventListener("mousemove", this._onMove)
    window.addEventListener("mouseup", this._onUp)
    this._bindButtons()

    // The DAG may mount on live navigation; fit once the canvas has size.
    requestAnimationFrame(() => this.fit())
  },

  destroyed() {
    if (!this.stage) return
    this.el.removeEventListener("wheel", this._onWheel)
    this.el.removeEventListener("mousedown", this._onDown)
    window.removeEventListener("mousemove", this._onMove)
    window.removeEventListener("mouseup", this._onUp)
  },

  _bindButtons() {
    this.el.querySelectorAll("[data-wf-zoom]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const f = btn.dataset.wfZoom === "in" ? 1.3 : 1 / 1.3
        const rect = this.el.getBoundingClientRect()
        this.zoomAt(rect.width / 2, rect.height / 2, f)
      })
    })
    const fitBtn = this.el.querySelector("[data-wf-fit]")
    if (fitBtn) fitBtn.addEventListener("click", () => this.fit())
  },

  zoomAt(mx, my, factor) {
    const next = Math.min(this.maxScale, Math.max(this.minScale, this.scale * factor))
    if (next === this.scale) return
    this.tx = mx - (mx - this.tx) * (next / this.scale)
    this.ty = my - (my - this.ty) * (next / this.scale)
    this.scale = next
    this._apply()
  },

  fit() {
    const contentW = this.stage.offsetWidth
    const contentH = this.stage.offsetHeight
    const viewW = this.el.clientWidth
    const viewH = this.el.clientHeight
    if (!contentW || !contentH || !viewW || !viewH) return
    const s = Math.min(viewW / contentW, viewH / contentH, 1)
    this.scale = Math.max(s, this.minScale)
    this.tx = (viewW - contentW * this.scale) / 2
    this.ty = (viewH - contentH * this.scale) / 2
    this._apply()
  },

  _apply() {
    // A server patch can REPLACE the stage node (not just strip its inline
    // transform); re-query if the cached node left the document.
    if (!this.stage || !this.stage.isConnected) {
      this.stage = this.el.querySelector("[data-wf-stage]")
      if (!this.stage) return
    }
    this.stage.style.transform = `translate(${this.tx}px, ${this.ty}px) scale(${this.scale})`
  }
}

export default WfPanZoom