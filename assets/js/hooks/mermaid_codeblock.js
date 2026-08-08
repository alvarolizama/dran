// Mermaid preview NodeView for TipTap CodeBlock.
//
// For `language: "mermaid"` blocks, renders a read-only SVG preview with an
// "Edit" button. Clicking the button opens an inline textarea with the raw
// mermaid source — editing it updates the ProseMirror node directly and
// re-renders the preview in real time.
//
// For non-mermaid code blocks, falls through to the default <pre><code>
// rendering that ProseMirror manages natively.

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
      window.mermaid.initialize({
        startOnLoad: false,
        theme: "dark",
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
 * For mermaid blocks: renders a read-only SVG preview with an edit button.
 * For other blocks: renders the standard <pre><code> structure.
 */
export function mermaidNodeView(editor) {
  return ({ node, getPos, HTMLAttributes, extension }) => {
    const isMermaid = node.attrs.language === "mermaid"

    // ── Mermaid code block — preview + inline edit ──
    if (isMermaid) {
      const wrapper = document.createElement("div")
      wrapper.className = "mermaid-codeblock"
      wrapper.setAttribute("data-mermaid", "true")

      // ── Toolbar with edit button ──
      const toolbar = document.createElement("div")
      toolbar.className = "mermaid-toolbar"

      const editBtn = document.createElement("button")
      editBtn.className = "mermaid-edit-btn"
      editBtn.type = "button"
      editBtn.textContent = "✓ Vista previa"
      toolbar.appendChild(editBtn)

      wrapper.appendChild(toolbar)

      // ── Preview container ──
      const preview = document.createElement("div")
      preview.className = "mermaid-preview"
      wrapper.appendChild(preview)

      // ── Code editor (visible by default — raw mermaid source for editing) ──
      const codeArea = document.createElement("textarea")
      codeArea.className = "mermaid-code-editor"
      codeArea.spellcheck = false
      codeArea.style.display = "block"
      wrapper.appendChild(codeArea)

      let isEditing = true

      function toggleEdit(force) {
        isEditing = typeof force === "boolean" ? force : !isEditing
        if (isEditing) {
          codeArea.value = node.textContent
          codeArea.style.display = "block"
          preview.style.display = "none"
          editBtn.textContent = "✓ Vista previa"
          codeArea.focus()
        } else {
          codeArea.style.display = "none"
          preview.style.display = "flex"
          editBtn.textContent = "✎ Editar"
          // Save changes to ProseMirror
          const newText = codeArea.value
          if (newText !== node.textContent) {
            saveToEditor(newText)
          }
          renderMermaid(newText)
        }
      }

      function saveToEditor(newText) {
        const pos = getPos()
        if (pos == null) return
        // Replace the node's content by inserting a new text node
        // and removing the old one via a transaction
        const tr = editor.state.tr
        const $pos = editor.state.doc.resolve(pos + 1)
        if ($pos.parent === node) {
          // Replace the content inside the codeBlock
          tr.insertText(newText, pos + 1, pos + 1 + node.content.size)
        }
        editor.view.dispatch(tr)
      }

      // ── Event handlers ──
      editBtn.addEventListener("click", (e) => {
        e.preventDefault()
        e.stopPropagation()
        toggleEdit()
      })

      codeArea.addEventListener("input", () => {
        debouncedRender(codeArea.value)
      })

      codeArea.addEventListener("keydown", (e) => {
        // Escape to close edit mode
        if (e.key === "Escape") {
          e.preventDefault()
          toggleEdit(false)
        }
      })

      // ── Mermaid rendering ──
      let renderCounter = 0

      async function renderMermaid(source) {
        if (!source || !source.trim()) {
          preview.innerHTML = '<span class="mermaid-preview-empty">Diagrama vacío — escribe algo</span>'
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

      // Initial render — start in edit mode with raw source visible
      codeArea.value = node.textContent
      codeArea.focus()
      renderMermaid(node.textContent)

      return {
        dom: wrapper,
        contentDOM: null,
        ignoreMutation(record) {
          // Ignore all mutations — this is a read-only preview
          return true
        },
        stopEvent(event) {
          // Don't let ProseMirror handle events inside our wrapper
          return true
        },
        update(updatedNode) {
          if (updatedNode.type !== node.type) return false
          if (updatedNode.attrs.language !== "mermaid") return false
          const newText = updatedNode.textContent
          if (newText !== node.textContent && !isEditing) {
            node = updatedNode
            debouncedRender(newText)
          } else {
            node = updatedNode
          }
          return true
        },
        destroy() {
          renderCounter++
          editBtn.removeEventListener("click", toggleEdit)
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
