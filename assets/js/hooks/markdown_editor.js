// TipTap-based markdown editor with custom wikilink and embed nodes.
//
// The editor stores content as markdown (bidirectional via @tiptap/markdown).
// Custom inline nodes handle [[slug|display]] wikilinks and ![[slug|display]]
// embeds, preserving them across markdown round-trips.
//
// Syncs the markdown body back to the LiveView via the "body_change" event
// (debounced) for autosave. The toolbar buttons emit custom events that this
// hook listens for, so the toolbar can live in the HEEx template.

import { Editor, Node, mergeAttributes } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import CodeBlock from "@tiptap/extension-code-block"
import { Markdown } from "@tiptap/markdown"
import Link from "@tiptap/extension-link"
import Image from "@tiptap/extension-image"
import { Table, TableRow, TableCell, TableHeader } from "@tiptap/extension-table"
import { mermaidNodeView } from "./mermaid_codeblock.js"

const WIKILINK_RE = /^\[\[([^|\]]+)(?:\|([^\]]+))?\]\]/
const EMBED_RE = /^!\[\[([^|\]]+)(?:\|([^\]]+))?\]\]/

// ── External embeds: URL → canonical reference ──
//
// The SERVER is the authority: `Dran.Embeds` validates the id again and builds
// the iframe, and `Dran.Embeds.normalize_markdown/1` rewrites raw provider
// URLs found in a body. This copy exists only so that a pasted URL becomes the
// canonical reference (`![[yt:ID]]`) at the moment of insertion instead of a
// plain link. Keep the two in sync when a provider is added.
const YOUTUBE_HOSTS = [
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
  "music.youtube.com",
  "youtube-nocookie.com",
  "www.youtube-nocookie.com",
]

const YOUTUBE_ID = /^[A-Za-z0-9_-]{11}$/
const VIMEO_ID = /^[0-9]{4,12}$/

const EMBED_PROVIDERS = [
  {
    key: "yt",
    label: "YouTube",
    id: YOUTUBE_ID,
    match(url) {
      const host = url.hostname.toLowerCase()
      if (host === "youtu.be") return firstSegment(url.pathname)
      if (!YOUTUBE_HOSTS.includes(host)) return null
      const v = url.searchParams.get("v")
      if (v) return v
      const seg = url.pathname.match(/^\/(?:embed|shorts|live|v)\/([^/?#]+)/)
      return seg ? seg[1] : null
    },
  },
  {
    key: "vimeo",
    label: "Vimeo",
    id: VIMEO_ID,
    match(url) {
      const host = url.hostname.toLowerCase()
      if (!["vimeo.com", "www.vimeo.com", "player.vimeo.com"].includes(host)) return null
      const seg = url.pathname.split("/").find((part) => VIMEO_ID.test(part))
      return seg || null
    },
  },
  {
    // The canonical reference prefix is `map:` — `Dran.Embeds` accepts
    // `maps:` too on input, but it always emits `map:`, and this table has to
    // agree with it or the editor chip loses its provider.
    key: "map",
    label: "Google Maps",
    // A map "id" is the search query, not a fixed-width token.
    id: null,
    match(url) {
      const host = url.hostname.toLowerCase()
      if (!["maps.google.com", "www.google.com", "google.com"].includes(host)) return null
      // Only `/maps…` is a map: a google.com URL with a `q` elsewhere is a
      // search (same rule as the server).
      if (!url.pathname.startsWith("/maps")) return null
      const query =
        url.searchParams.get("q") ||
        url.searchParams.get("query") ||
        url.searchParams.get("daddr")
      if (query) return query
      // A `pb=` blob is deliberately NOT handled here: the `+` inside it means a
      // space for Google's parser and the URL API would eat it. The server
      // normalizes that form (`Dran.Embeds.normalize_markdown/1`).
      const place = url.pathname.match(/^\/maps\/place\/([^/@?]+)/)
      return place ? decodeURIComponent(place[1].replace(/\+/g, " ")) : null
    },
  },
]

function firstSegment(pathname) {
  const seg = pathname.match(/^\/([^/?#]+)/)
  return seg ? seg[1] : null
}

// The canonical reference for a pasted URL, or null when it is not one of the
// supported providers.
function embedRefFromUrl(raw) {
  const value = (raw || "").trim()
  if (!/^https?:\/\//i.test(value)) return null

  let url
  try {
    url = new URL(value)
  } catch {
    return null
  }

  for (const provider of EMBED_PROVIDERS) {
    const id = provider.match(url)
    if (!id) continue
    if (provider.id && !provider.id.test(id)) continue
    return { ref: `${provider.key}:${id}`, label: provider.label }
  }

  return null
}

function embedProviderLabel(slug) {
  const prefix = String(slug || "").split(":")[0]
  const provider = EMBED_PROVIDERS.find((p) => p.key === prefix)
  return provider ? provider.label : null
}

// ── Wikilink node: [[slug|display]] ──
const Wikilink = Node.create({
  name: "wikilink",
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      slug: { default: null },
      display: { default: null },
    }
  },

  parseHTML() {
    return [
      {
        tag: "a[data-wikilink]",
        getAttrs: (el) => {
          const slug = el.getAttribute("data-wikilink") || el.getAttribute("href") || ""
          return { slug, display: el.textContent || slug }
        },
      },
    ]
  },

  renderHTML({ node }) {
    const slug = node.attrs.slug || ""
    const display = node.attrs.display || slug
    return [
      "a",
      mergeAttributes({
        href: `/-/q/${slug}`,
        class: "wikilink",
        "data-wikilink": slug,
      }),
      display,
    ]
  },

  renderText({ node }) {
    const slug = node.attrs.slug || ""
    const display = node.attrs.display || ""
    return display && display !== slug ? `[[${slug}|${display}]]` : `[[${slug}]]`
  },

  markdownTokenName: "wikilink",
  markdownTokenizer: {
    name: "wikilink",
    level: "inline",
    start(src) { return src.indexOf("[[") },
    tokenize(src) {
      const match = WIKILINK_RE.exec(src)
      if (!match) return
      return {
        type: "wikilink",
        raw: match[0],
        attrs: {
          slug: match[1].trim(),
          display: match[2] ? match[2].trim() : match[1].trim(),
        },
      }
    },
  },
  parseMarkdown(token) {
    return {
      type: "wikilink",
      attrs: {
        slug: token.attrs.slug,
        display: token.attrs.display,
      },
    }
  },
  renderMarkdown(node) {
    const slug = node.attrs?.slug || ""
    const display = node.attrs?.display || ""
    return display && display !== slug ? `[[${slug}|${display}]]` : `[[${slug}]]`
  },

  addCommands() {
    return {
      insertWikilink:
        (attrs) =>
        ({ commands, chain }) => {
          return chain().focus().insertContent({
            type: "wikilink",
            attrs: { slug: attrs?.slug || "", display: attrs?.display || attrs?.slug || "" },
          }).run()
        },
    }
  },
})

// ── Embed node: ![[slug|display]] ──
const Embed = Node.create({
  name: "embed",
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      slug: { default: null },
      display: { default: null },
    }
  },

  parseHTML() {
    return [
      {
        tag: "span[data-embed]",
        getAttrs: (el) => ({
          slug: el.getAttribute("data-embed") || "",
          display: el.textContent || "",
        }),
      },
    ]
  },

  renderHTML({ node }) {
    const slug = node.attrs.slug || ""
    const display = node.attrs.display || slug
    const provider = embedProviderLabel(slug)
    const glyph = provider ? "▶" : "📎"
    return [
      "span",
      mergeAttributes({
        class: "embed-placeholder",
        "data-embed": slug,
        title: provider ? `${provider}: ${slug}` : `embed: ${slug}`,
      }),
      `${glyph} ${display}`,
    ]
  },

  renderText({ node }) {
    const slug = node.attrs.slug || ""
    const display = node.attrs.display || ""
    return display && display !== slug ? `![[${slug}|${display}]]` : `![[${slug}]]`
  },

  markdownTokenName: "embed",
  markdownTokenizer: {
    name: "embed",
    level: "inline",
    start(src) { return src.indexOf("![[") },
    tokenize(src) {
      const match = EMBED_RE.exec(src)
      if (!match) return
      return {
        type: "embed",
        raw: match[0],
        attrs: {
          slug: match[1].trim(),
          display: match[2] ? match[2].trim() : match[1].trim(),
        },
      }
    },
  },
  parseMarkdown(token) {
    return {
      type: "embed",
      attrs: {
        slug: token.attrs.slug,
        display: token.attrs.display,
      },
    }
  },
  renderMarkdown(node) {
    const slug = node.attrs?.slug || ""
    const display = node.attrs?.display || ""
    return display && display !== slug ? `![[${slug}|${display}]]` : `![[${slug}]]`
  },

  addCommands() {
    return {
      insertEmbed:
        (attrs) =>
        ({ chain }) => {
          return chain().focus().insertContent({
            type: "embed",
            attrs: { slug: attrs?.slug || "", display: attrs?.display || attrs?.slug || "" },
          }).run()
        },
    }
  },
})

// ── LiveView hook ──
const MarkdownEditor = {
  mounted() {
    const el = this.el
    const contentEl = el.querySelector(".tiptap-content")
    const initialBody = el.dataset.body || ""
    const contextId = el.dataset.contextId || ""
    // New-page forms mount the editor with autosave disabled: nothing exists
    // in the DB yet, so a debounced save would be a lie. The body is synced
    // into a hidden form field on submit instead (see submitHandler below).
    this.autosave = el.dataset.autosave !== "false"

    this.editor = new Editor({
      element: contentEl,
      extensions: [
        StarterKit.configure({
          codeBlock: false,
        }),
        // Custom CodeBlock with mermaid preview NodeView
        CodeBlock.extend({
          addNodeView() {
            return mermaidNodeView(this.editor)
          },
        }),
        Link.configure({ openOnClick: false }),
        Image,
        Table,
        TableRow,
        TableCell,
        TableHeader,
        Wikilink,
        Embed,
        Markdown.configure({
          html: false,
          breaks: false,
          linkify: true,
          transformPastedText: true,
          transformCopiedText: true,
        }),
      ],
      content: initialBody,
      contentType: "markdown",
      editorProps: {
        attributes: {
          class: "tiptap prose prose-base dark:prose-invert max-w-none focus:outline-none",
        },
        // A pasted provider URL becomes an embed reference, not a link.
        handlePaste: (view, event) => this.handlePaste(view, event),
      },
    })

    // Debounced body change → autosave (only when the page already exists).
    // The hidden field is synced on every update regardless, so a submit
    // that fires between debounces still carries the current markdown.
    this.saveTimer = null
    this.editor.on("update", () => {
      this.syncHiddenField()
      if (!this.autosave) return
      this.pushSaveStatus("saving")
      if (this.saveTimer) clearTimeout(this.saveTimer)
      this.saveTimer = setTimeout(() => {
        const md = this.editor.getMarkdown ? this.editor.getMarkdown() : ""
        this.pushEvent("body_change", { body: md })
        this.pushSaveStatus("saved")
      }, 1000)
    })

    // Force sync body before form submit — update a hidden field. The field
    // name comes from data-hidden-field (default page[body]) so non-page
    // forms (e.g. the task detail panel) can reuse the hook.
    const form = el.closest("form")
    this.hiddenFieldName = el.dataset.hiddenField || "page[body]"
    if (form) {
      this.submitHandler = () => {
        if (this.saveTimer) { clearTimeout(this.saveTimer); this.saveTimer = null }
        this.syncHiddenField()
      }
      form.addEventListener("submit", this.submitHandler)
    }

    // Toolbar wiring: listen for clicks on [data-editor][data-cmd] buttons
    this.toolbarHandler = (e) => {
      const btn = e.target.closest("[data-editor][data-cmd]")
      if (!btn || btn.dataset.editor !== el.id) return
      e.preventDefault()
      const cmd = btn.dataset.cmd
      this.runCommand(cmd)
    }
    // Attach to the wrapper so it survives editor re-renders
    const wrapper = document.getElementById(`editor-wrapper-${el.id}`)
    if (wrapper) wrapper.addEventListener("click", this.toolbarHandler)

    // Expose for debugging
    el._editor = this.editor
  },

  updated() {
    // We use phx-update="ignore" so this is rarely called, but if the
    // underlying data changes we don't want to clobber the editor.
  },

  destroyed() {
    if (this.saveTimer) clearTimeout(this.saveTimer)
    if (this.submitHandler) {
      const form = this.el.closest("form")
      if (form) form.removeEventListener("submit", this.submitHandler)
    }
    if (this.editor) this.editor.destroy()
  },

  // ── Helpers ──

  // Write the current markdown into the form's hidden body field.
  syncHiddenField() {
    const form = this.el.closest("form")
    if (!form || !this.editor) return
    const md = this.editor.getMarkdown ? this.editor.getMarkdown() : ""
    let hidden = form.querySelector(`input[name="${this.hiddenFieldName}"]`)
    if (!hidden) {
      hidden = document.createElement("input")
      hidden.type = "hidden"
      hidden.name = this.hiddenFieldName
      form.appendChild(hidden)
    }
    hidden.value = md
  },

  pushSaveStatus(status) {
    // Update the status indicator via DOM (cheaper than a round-trip)
    const wrapper = document.getElementById(`editor-wrapper-${this.el.id}`)
    if (!wrapper) return
    const statusEl = wrapper.querySelector(".editor-status span")
    if (!statusEl) return
    if (status === "saving") {
      statusEl.innerHTML = '<span class="inline-block w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span> Guardando…'
      statusEl.className = "flex items-center gap-1"
    } else if (status === "saved") {
      statusEl.innerHTML = "✓ Guardado"
      statusEl.className = "flex items-center gap-1 text-green-500"
      setTimeout(() => {
        if (statusEl) {
          statusEl.innerHTML = ""
          statusEl.className = ""
        }
      }, 2000)
    }
  },

  // ── External embeds ──

  // Pasting a bare provider URL inserts the canonical embed reference and asks
  // the server for the oEmbed title. Any other paste (including a URL inside a
  // sentence, which should stay text) returns false and TipTap handles it.
  handlePaste(view, event) {
    const clipboard = event.clipboardData
    if (!clipboard) return false

    const text = (clipboard.getData("text/plain") || "").trim()
    if (!/^https?:\/\/\S+$/.test(text)) return false

    const embed = embedRefFromUrl(text)
    if (!embed) return false

    const { state } = view
    const embedNode = state.schema.nodes.embed
    if (!embedNode) return false

    const { from, to } = state.selection
    view.dispatch(
      state.tr.replaceRangeWith(from, to, embedNode.create({ slug: embed.ref, display: "" }))
    )
    this.requestEmbedTitle(embed.ref)
    return true
  },

  // Ask the server (this LiveView) for the oEmbed title. Only surfaces that
  // delegate the `resolve_embed` event opt in with data-embed-resolve="true":
  // everywhere else the reference is inserted as-is and no event is sent.
  requestEmbedTitle(ref) {
    if (this.el.dataset.embedResolve !== "true") return

    this.pushEvent("resolve_embed", { ref }, (reply) => {
      if (!reply || !reply.ok || !reply.title) return
      this.setEmbedDisplay(ref, reply.title)
    })
  },

  // Fill the display text of the embed nodes that reference `ref` and carry
  // none, so the body ends up as `![[yt:ID|Title]]`.
  setEmbedDisplay(ref, title) {
    const editor = this.editor
    if (!editor) return

    const { state } = editor.view
    let target = null

    state.doc.descendants((node, pos) => {
      if (target) return false

      if (node.type.name === "embed" && node.attrs.slug === ref && !node.attrs.display) {
        target = { pos, attrs: node.attrs }
        return false
      }

      return true
    })

    if (!target) return

    editor.view.dispatch(
      state.tr.setNodeMarkup(target.pos, null, { ...target.attrs, display: title })
    )
  },

  runCommand(cmd) {
    const editor = this.editor
    if (!editor) return
    const chain = editor.chain().focus()

    switch (cmd) {
      case "bold": chain.toggleBold().run(); break
      case "italic": chain.toggleItalic().run(); break
      case "strike": chain.toggleStrike().run(); break
      case "code": chain.toggleCode().run(); break
      case "h1": chain.toggleHeading({ level: 1 }).run(); break
      case "h2": chain.toggleHeading({ level: 2 }).run(); break
      case "h3": chain.toggleHeading({ level: 3 }).run(); break
      case "bulletList": chain.toggleBulletList().run(); break
      case "orderedList": chain.toggleOrderedList().run(); break
      case "blockquote": chain.toggleBlockquote().run(); break
      case "codeBlock": chain.toggleCodeBlock().run(); break
      case "link": {
        const url = prompt("URL:")
        if (url) chain.setLink({ href: url }).run()
        break
      }
      case "wikilink": {
        const input = prompt("Wikilink (slug or slug|display):")
        if (!input) break
        const [slug, ...rest] = input.split("|")
        const display = rest.join("|").trim() || slug.trim()
        chain.insertContent({
          type: "wikilink",
          attrs: { slug: slug.trim(), display },
        }).run()
        break
      }
      case "embed": {
        // Trigger file upload via LiveView event
        this.pushEvent("request_upload", {})
        break
      }
      case "mediaEmbed": {
        // A video or a map hosted somewhere else: paste the URL of the item.
        const url = prompt("URL del video o del mapa (YouTube, Vimeo, Google Maps):")
        if (!url) break

        const embed = embedRefFromUrl(url)

        if (!embed) {
          alert("Proveedor no soportado: pega una URL de YouTube, Vimeo o Google Maps.")
          break
        }

        chain.insertContent({ type: "embed", attrs: { slug: embed.ref, display: "" } }).run()
        this.requestEmbedTitle(embed.ref)
        break
      }
      case "table":
        chain.insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run()
        break
      case "mermaid": {
        const stub = "graph TD\n    A[Start] --> B{Decision}\n    B -->|Yes| C[Action 1]\n    B -->|No| D[Action 2]\n    C --> E[End]\n    D --> E"
        chain.insertContent({
          type: "codeBlock",
          attrs: { language: "mermaid" },
          content: [{ type: "text", text: stub }],
        }).run()
        break
      }
      case "undo": chain.undo().run(); break
      case "redo": chain.redo().run(); break
      case "toggleMode": this.toggleMode(); break
    }
  },

  toggleMode() {
    const wrapper = document.getElementById(`editor-wrapper-${this.el.id}`)
    if (!wrapper) return

    const mountEl = this.el
    const isMdMode = mountEl.dataset.mdMode === "true"

    if (isMdMode) {
      // Switch back to WYSIWYG: parse textarea content into editor
      const textarea = wrapper.querySelector(".md-raw-textarea")
      if (textarea && this.editor) {
        const md = textarea.value
        // TipTap v3: editor.markdown.parse() returns JSON, pass to setContent
        const json = this.editor.markdown?.parse(md)
        if (json) {
          this.editor.commands.setContent(json, { emitUpdate: false })
        } else {
          this.editor.commands.setContent(md)
        }
        mountEl.dataset.mdMode = "false"
        wrapper.classList.remove("md-raw-mode")
        textarea.remove()
        mountEl.style.display = ""
      }
    } else {
      // Switch to raw markdown: get current content as markdown, show textarea
      if (this.editor) {
        // TipTap v3: editor.getMarkdown() is the public API
        const md = this.editor.getMarkdown() || ""
        mountEl.dataset.mdMode = "true"
        wrapper.classList.add("md-raw-mode")

        const textarea = document.createElement("textarea")
        textarea.className = "md-raw-textarea w-full flex-1 min-h-[300px] p-4 font-mono text-sm bg-base-100 border-0 outline-none resize-none"
        textarea.value = md
        textarea.spellcheck = false

        // Save changes back to editor on blur
        textarea.addEventListener("blur", () => {
          if (this.editor) {
            const mdVal = textarea.value
            const json = this.editor.markdown?.parse(mdVal)
            if (json) {
              this.editor.commands.setContent(json, { emitUpdate: false })
            } else {
              this.editor.commands.setContent(mdVal)
            }
            mountEl.dataset.mdMode = "false"
            wrapper.classList.remove("md-raw-mode")
            textarea.remove()
            mountEl.style.display = ""
          }
        })

        // Hide the editor mount, show the textarea
        mountEl.style.display = "none"
        wrapper.appendChild(textarea)
        textarea.focus()
      }
    }
  },
}

export default MarkdownEditor