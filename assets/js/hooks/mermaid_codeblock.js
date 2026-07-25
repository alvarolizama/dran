// Mermaid preview NodeView for TipTap CodeBlock.
//
// Replaces the default CodeBlock NodeView. For `language: "mermaid"` blocks,
// it renders the code editor on top and a live SVG preview below (like
// Notion/Obsidian). For all other languages, it renders the standard
// `<pre><code>` structure that ProseMirror manages natively.
//
// The mermaid library is loaded lazily from CDN (same as the read-mode hook).
// Preview is debounced (400ms) and re-renders on content changes.

const MERMAID_CDN = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"

let mermaidPromise = null

function loadMermaid() {
  if (window.mermaid) return Promise.resolve(window.mermaid)
  if (mermaidPromise) return mermaidPromise

  mermaidPromise = new Promise((resolve, reject) => {
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
    script.onerror = () => {
      mermaidPromise = null
      reject(new Error("Failed to load mermaid from CDN"))
    }
    document.head.appendChild(script)
  })
  return mermaidPromise
}

function debounce(fn, ms) {
  let timer
  return (...args) => {
    clearTimeout(timer)
    timer = setTimeout(() => fn(...args), ms)
  }
}

/**
 * NodeView factory for CodeBlock.
 *
 * For mermaid blocks: renders code editor + live SVG preview.
 * For other blocks: returns a simple <pre><code> that ProseMirror manages.
 */
export function mermaidNodeView(editor) {
  return ({ node, getPos, HTMLAttributes, extension }) => {
    const isMermaid = node.attrs.language === "mermaid"

    // ── Mermaid code block with preview ──
    if (isMermaid) {
      const wrapper = document.createElement("div")
      wrapper.className = "mermaid-codeblock"

      const pre = document.createElement("pre")
      pre.className = "mermaid-code-input"

      const code = document.createElement("code")
      code.className = "language-mermaid"
      pre.appendChild(code)

      const preview = document.createElement("div")
      preview.className = "mermaid-preview"

      wrapper.appendChild(pre)
      wrapper.appendChild(preview)

      // ── Mermaid rendering ──
      let renderCounter = 0

      async function renderMermaid(source) {
        if (!source || !source.trim()) {
          preview.innerHTML = '<span class="mermaid-preview-empty">La preview aparecerá aquí…</span>'
          preview.classList.remove("mermaid-preview-error")
          return
        }

        const myId = ++renderCounter
        try {
          const mermaid = await loadMermaid()
          if (myId !== renderCounter) return

          const id = `mermaid-preview-${Date.now()}-${myId}`
          const { svg } = await mermaid.render(id, source)
          if (myId !== renderCounter) return

          preview.innerHTML = svg
          preview.classList.remove("mermaid-preview-error")
        } catch (e) {
          if (myId !== renderCounter) return
          preview.classList.add("mermaid-preview-error")
          preview.innerHTML = `<p>⚠️ ${e.str || e.message}</p>`
        }
      }

      const debouncedRender = debounce(renderMermaid, 400)

      // Initial render
      renderMermaid(node.textContent)

      // Re-render on content changes (ProseMirror updates contentDOM)
      const observer = new MutationObserver(() => {
        debouncedRender(code.textContent)
      })
      observer.observe(code, { childList: true, characterData: true, subtree: true })

      return {
        dom: wrapper,
        contentDOM: code,
        ignoreMutation(record) {
          // Ignore mutations on the preview div
          if (preview.contains(record.target)) return true
          return false
        },
        update(updatedNode) {
          if (updatedNode.type !== node.type) return false
          if (updatedNode.attrs.language !== "mermaid") return false
          node = updatedNode
          return true
        },
        destroy() {
          renderCounter++
          observer.disconnect()
        },
      }
    }

    // ── Default code block (non-mermaid) ──
    // Render the standard <pre><code> structure. ProseMirror manages the
    // content via contentDOM.
    const pre = document.createElement("pre")
    Object.entries(HTMLAttributes).forEach(([key, val]) => {
      if (key === "class") return
      if (val !== null && val !== undefined) pre.setAttribute(key, val)
    })

    const code = document.createElement("code")
    // Apply language class if present
    if (node.attrs.language) {
      code.className = `language-${node.attrs.language}`
    }
    pre.appendChild(code)

    return {
      dom: pre,
      contentDOM: code,
    }
  }
}
