// Mermaid preview NodeView for TipTap CodeBlock.
//
// For `language: "mermaid"` blocks, renders ONLY a read-only SVG preview —
// no editable code inside the WYSIWYG editor. To edit the mermaid source,
// switch to markdown mode via the toolbar toggle. This avoids content-editing
// conflicts between ProseMirror's contentDOM and the preview DOM.
//
// For non-mermaid code blocks, falls through to the default <pre><code>
// rendering that ProseMirror manages natively.
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
 * For mermaid blocks: renders a read-only SVG preview (no editable code in
 * WYSIWYG mode). Use the markdown toggle to edit the source.
 * For other blocks: renders the standard <pre><code> structure.
 */
export function mermaidNodeView(editor) {
  return ({ node, getPos, HTMLAttributes, extension }) => {
    const isMermaid = node.attrs.language === "mermaid"

    // ── Mermaid code block — preview only ──
    if (isMermaid) {
      const wrapper = document.createElement("div")
      wrapper.className = "mermaid-codeblock"
      wrapper.setAttribute("data-mermaid", "true")

      const preview = document.createElement("div")
      preview.className = "mermaid-preview"
      wrapper.appendChild(preview)

      // Hint: switch to markdown mode to edit
      const hint = document.createElement("div")
      hint.className = "mermaid-edit-hint"
      hint.textContent = "Edit via markdown mode ↕"
      wrapper.appendChild(hint)

      // ── Mermaid rendering ──
      let renderCounter = 0

      async function renderMermaid(source) {
        if (!source || !source.trim()) {
          preview.innerHTML = '<span class="mermaid-preview-empty">Diagrama vacío — edita en modo markdown</span>'
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

      // Re-render when the node's content changes (e.g. undo/redo, external
      // edits via markdown toggle). We poll textContent since we have no
      // contentDOM for ProseMirror to notify us.
      return {
        dom: wrapper,
        contentDOM: null,
        ignoreMutation(record) {
          // Ignore all mutations — this is a read-only preview
          return true
        },
        update(updatedNode) {
          if (updatedNode.type !== node.type) return false
          if (updatedNode.attrs.language !== "mermaid") return false
          const newText = updatedNode.textContent
          if (newText !== node.textContent) {
            node = updatedNode
            debouncedRender(newText)
          } else {
            node = updatedNode
          }
          return true
        },
        destroy() {
          renderCounter++
        },
      }
    }

    // ── Default code block (non-mermaid) ──
    const pre = document.createElement("pre")
    Object.entries(HTMLAttributes).forEach(([key, val]) => {
      if (key === "class") return
      if (val !== null && val !== undefined) pre.setAttribute(key, val)
    })

    const code = document.createElement("code")
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
