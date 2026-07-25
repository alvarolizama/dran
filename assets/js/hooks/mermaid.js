// Mermaid diagram rendering hook.
//
// Scans for <pre><code class="language-mermaid"> blocks produced by MDEx
// in reading mode, replaces them with rendered SVG diagrams via the mermaid
// library (loaded lazily from CDN to avoid bloating the JS bundle).
//
// The hook attaches to the rendered-body container in page_components.ex.

const MERMAID_CDN = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"

function loadMermaid() {
  return new Promise((resolve, reject) => {
    if (window.mermaid) return resolve(window.mermaid)

    const script = document.createElement("script")
    script.src = MERMAID_CDN
    script.crossOrigin = "anonymous"
    script.onload = () => {
      const isDark = document.documentElement.getAttribute("data-theme") === "dark"
      window.mermaid.initialize({
        startOnLoad: false,
        theme: isDark ? "dark" : "default",
        securityLevel: "strict",
      })
      resolve(window.mermaid)
    }
    script.onerror = () => reject(new Error("Failed to load mermaid from CDN"))
    document.head.appendChild(script)
  })
}

const Mermaid = {
  mounted() {
    this._render()
  },

  updated() {
    this._render()
  },

  _render() {
    const blocks = this.el.querySelectorAll("code.language-mermaid")
    if (blocks.length === 0) return

    // Debounce: clear any pending render
    if (this._timer) clearTimeout(this._timer)
    this._timer = setTimeout(() => this._processBlocks(blocks), 50)
  },

  async _processBlocks(blocks) {
    let mermaid
    try {
      mermaid = await loadMermaid()
    } catch (e) {
      console.error("Mermaid load failed:", e)
      return
    }

    // Re-query after async load — DOM may have changed
    const pending = this.el.querySelectorAll("code.language-mermaid")

    for (let i = 0; i < pending.length; i++) {
      const codeEl = pending[i]
      const pre = codeEl.closest("pre")
      if (!pre) continue

      // Skip if already rendered (pre was replaced by a div.mermaid-rendered)
      if (pre.dataset.mermaidDone) continue

      const source = codeEl.textContent
      const id = `mermaid-${Date.now()}-${i}`

      try {
        const { svg } = await mermaid.render(id, source)
        const wrapper = document.createElement("div")
        wrapper.className = "mermaid-rendered"
        wrapper.innerHTML = svg
        pre.dataset.mermaidDone = "true"
        pre.replaceWith(wrapper)
      } catch (e) {
        // Show error inline so the user sees the broken diagram source
        pre.dataset.mermaidDone = "true"
        const errDiv = document.createElement("div")
        errDiv.className = "mermaid-error"
        errDiv.innerHTML = `<p>⚠️ Mermaid error: ${e.message}</p><pre>${source}</pre>`
        pre.replaceWith(errDiv)
      }
    }
  },
}

export default Mermaid
