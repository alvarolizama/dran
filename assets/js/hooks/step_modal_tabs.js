// Step modal: client-side tabs (Intent / Claims / Gates / Grafo /
// Contexto) + visual contract editor.
//
// Tab state exists only in the client DOM (aria-selected + hidden panels).
// Per liveview-client-dom-vs-morphdom: a patch morphs the server-rendered
// buttons, so updated() re-asserts the active tab in the same tick the
// morph lands — no flicker, no MutationObserver races.
//
// The visual editor never talks to the server directly: it serializes into
// the `step[contract_json]` textarea it owns (inside phx-update="ignore")
// and dispatches input → phx-debounce → validate_step → live lint. Save
// keeps using the same textarea (maybe_put_contract): blank drops the
// contract, unparseable JSON never clobbers it — the server pipeline is
// untouched.
//
// Contexto tab: the search input pushes `search_context` with the query
// and renders the reply (Knowledge/Memory results, workspace-scoped) into
// a dropdown. Picking an entry writes a `ctx` row (type/id/why) into the
// visual list; remove buttons drop it. All rows serialize into
// contract.context_snapshot via the same _collect() path.

const StepModalTabs = {
  mounted() {
    this.__activeTab = this.el.dataset.activeTab || "intent"
    this.jsonEl = this.el.querySelector("[data-contract-json]")
    this.visualBody = this.el.querySelector("[data-visual-body]")
    this._lastJson = this.jsonEl ? this.jsonEl.value : null
    // Keys of the stored contract the visual form does not edit
    // (fingerprint, history…) ride along untouched.
    this._passthrough = {}
    this._canvasGraph = null

    this._wireTabs()
    if (this.jsonEl && this.visualBody) {
      this._wireVisual()
      this._wireToggle()
      this._wireCtxSearch()
      this._buildFromJson()
    }
  },

  updated() {
    // morphdom re-synced server HTML: re-assert client-only tab state.
    this._setTab(this.__activeTab || "intent")
    // Re-assert visual/JSON mode — morphdom strips the hidden attrs we set
    // client-side. jsonEl lives inside phx-update="ignore" (never touched),
    // but visualBody is a plain div whose hidden gets reset.
    if (this.__jsonMode) {
      this.jsonEl.hidden = false
      this.visualBody.hidden = true
      const btn = this.el.querySelector("[data-toggle-json]")
      if (btn) btn.textContent = "Visual"
    } else {
      this.jsonEl.hidden = true
      this.visualBody.hidden = false
      const btn = this.el.querySelector("[data-toggle-json]")
      if (btn) btn.textContent = "JSON"
    }
    // Rebuild the visual form only when the JSON changed behind our back —
    // never clobber fields the user is typing into. The textarea lives in
    // an ignored container, so patches don't touch it; this only fires on
    // hand-written JSON edits followed by a toggle back to visual.
    if (this.jsonEl && this.visualBody && this.jsonEl.value !== this._lastJson) {
      this._buildFromJson()
    }
  },

  destroyed() {
    // Nothing to tear down: listeners are bound to elements inside the
    // LiveView DOM and die with it.
  },

  // ── Tabs ──────────────────────────────────────────────────────────────

  _wireTabs() {
    this.el.querySelectorAll('[role="tab"]').forEach((btn) => {
      btn.addEventListener("click", () => this._setTab(btn.dataset.tab))
    })
    this._setTab(this.__activeTab)
  },

  _setTab(name) {
    this.__activeTab = name
    this.el.querySelectorAll('[role="tab"]').forEach((btn) => {
      const on = btn.dataset.tab === name
      btn.setAttribute("aria-selected", on ? "true" : "false")
      btn.setAttribute("tabindex", on ? "0" : "-1")
      btn.classList.toggle("border-primary", on)
      btn.classList.toggle("text-primary", on)
      btn.classList.toggle("border-transparent", !on)
      btn.classList.toggle("text-base-content/55", !on)
    })
    this.el.querySelectorAll("[data-panel]").forEach((panel) => {
      panel.hidden = panel.dataset.panel !== name
    })
  },

  // ── Visual contract editor ────────────────────────────────────────────

  _wireVisual() {
    // Any keystroke on a visual field re-serializes → textarea → live lint.
    this.visualBody.addEventListener("input", () => this._sync())

    // Graph canvas sync: the canvas reports every change (new node, drag,
    // edge, edit) via graph-canvas:sync → re-serialize the contract.
    this.visualBody.addEventListener("graph-canvas:sync", (e) => {
      this._canvasGraph = e.detail
      this._sync()
    })
    // Graph canvas feed request: on mount the canvas asks for the current
    // contract's graph (it may mount after _buildFromJson).
    this.visualBody.addEventListener("graph-canvas:request-feed", () => {
      const { contract, ok } = this._parse()
      if (!ok) return
      const graph = contract.graph && typeof contract.graph === "object" ? contract.graph : {}
      this._feedGraphCanvas(graph)
    })

    this.visualBody.addEventListener("click", (e) => {
      const add = e.target.closest("[data-add]")
      if (add) {
        this._addRow(add.dataset.add)
        this._sync()
        return
      }
      const del = e.target.closest("[data-remove]")
      if (del) {
        const row = del.closest("[data-row]")
        const list = row && row.closest("[data-list]")
        if (row) row.remove()
        // Keep at least one empty row so the list never dead-ends.
        if (list && !list.querySelector("[data-row]")) this._addRow(list.dataset.list)
        this._sync()
      }
    })
  },

  _wireToggle() {
    const btn = this.el.querySelector("[data-toggle-json]")
    if (!btn) return
    btn.addEventListener("click", () => {
      if (this.jsonEl.hidden) {
        // Visual → JSON: flush current visual state first.
        this._sync()
        this.visualBody.hidden = true
        this.jsonEl.hidden = false
        this.jsonEl.focus()
        this.__jsonMode = true
      } else {
        // JSON → Visual: parse what the user wrote.
        this.visualBody.hidden = false
        this.jsonEl.hidden = true
        this.__jsonMode = false
        this._buildFromJson()
        this._sync()
      }
    })
  },

  // Contexto tab: search pages/memories via pushEvent("search_context") →
  // reply → dropdown. Picking an entry appends a ctx row (type/id/why).
  _wireCtxSearch() {
    const input = this.el.querySelector("[data-ctx-search]")
    const dropdown = this.el.querySelector("[data-ctx-dropdown]")
    if (!input || !dropdown) return

    let timer = null
    input.addEventListener("input", () => {
      clearTimeout(timer)
      const q = input.value.trim()
      if (!q) {
        dropdown.classList.add("hidden")
        return
      }
      timer = setTimeout(() => {
        this.pushEvent("search_context", { q }, (reply) => {
          this._renderCtxDropdown(reply)
        })
      }, 250)
    })

    dropdown.addEventListener("mousedown", (e) => {
      const item = e.target.closest("[data-ctx-item]")
      if (!item) return
      e.preventDefault()
      this._addCtxEntry(item.dataset)
    })
  },

  _renderCtxDropdown(reply) {
    const dropdown = this.el.querySelector("[data-ctx-dropdown]")
    if (!dropdown) return
    const results = (reply && reply.results) || []
    dropdown.innerHTML = ""
    if (!results.length) {
      const empty = document.createElement("div")
      empty.className = "px-3 py-2 text-xs text-base-content/50"
      empty.textContent = "Sin resultados"
      dropdown.appendChild(empty)
    } else {
      for (const r of results) {
        const item = document.createElement("button")
        item.type = "button"
        item.dataset.ctxItem = ""
        item.dataset.type = r.type || "page"
        item.dataset.id = r.id || ""
        item.dataset.why = r.title || ""
        item.className =
          "w-full text-left px-3 py-2 text-xs hover:bg-base-300/60 flex items-start gap-2"
        const badge = document.createElement("span")
        badge.className =
          "badge badge-xs mt-0.5 font-mono uppercase " +
          (r.type === "memory" ? "badge-secondary" : "badge-primary")
        badge.textContent = r.type === "memory" ? "MEM" : "PAGE"
        const label = document.createElement("span")
        label.textContent = (r.title || r.id || "—") + (r.summary ? " — " + r.summary : "")
        item.appendChild(badge)
        item.appendChild(label)
        dropdown.appendChild(item)
      }
    }
    dropdown.classList.remove("hidden")
  },

  _addCtxEntry(dataset) {
    const list = this.el.querySelector('[data-list="ctx"]')
    if (!list) return
    const row = this._row("ctx", {}, [
      ['[data-cf="ctx_id"]', "id"],
      ['[data-cf="ctx_why"]', "why"],
    ])
    row.querySelector('[data-cf="ctx_id"]').value = dataset.id || ""
    row.querySelector('[data-cf="ctx_why"]').value = dataset.why || ""
    this._styleCtxBadge(row.querySelector('[data-cf="ctx_type"]'), dataset.type)
    list.appendChild(row)
    const dropdown = this.el.querySelector("[data-ctx-dropdown]")
    if (dropdown) dropdown.classList.add("hidden")
    const input = this.el.querySelector("[data-ctx-search]")
    if (input) input.value = ""
    this._sync()
  },

  _buildFromJson() {
    const { contract, ok } = this._parse()
    if (!ok) {
      // Hand-written or corrupt JSON: keep it editable as raw JSON.
      this.jsonEl.hidden = false
      this.visualBody.hidden = true
      const btn = this.el.querySelector("[data-toggle-json]")
      if (btn) btn.textContent = "Visual"
      return
    }

    this._passthrough = {}
    // Visual-owned keys are rebuilt fresh from the form; every other key
    // that ISN'T server-managed rides through untouched (hand-written JSON
    // extras). Server-managed columns (status, version, history,
    // fingerprint, model, generated_by) are dropped — the sidebar/schema
    // own them now, the JSON must not echo them back.
    const serverManaged = [
      "status", "version", "history", "fingerprint", "model", "generated_by",
    ]
    for (const [key, value] of Object.entries(contract)) {
      if (!["intent", "claims", "gates", "graph", "context_snapshot"].includes(key) &&
          !serverManaged.includes(key)) {
        this._passthrough[key] = value
      }
    }

    const intentEl = this.visualBody.querySelector('[data-cf="intent"]')
    if (intentEl) intentEl.value = contract.intent || ""

    this._fillList("claims", contract.claims, [
      ['[data-cf="claim_id"]', "id"],
      ['[data-cf="claim"]', "claim"],
      ['[data-cf="verify"]', "verify"],
    ])
    this._fillList("gates", contract.gates, [
      ['[data-cf="name"]', "name"],
      ['[data-cf="expect"]', "expect"],
      ['[data-cf="cmd"]', "cmd"],
    ])
    const graph = contract.graph && typeof contract.graph === "object" ? contract.graph : {}
    this._feedGraphCanvas(graph)
    this._fillCtx(contract.context_snapshot)
  },

  // ── Graph canvas bridge ─────────────────────────────────────────────────
  // The Grafo panel is a client-side mini-canvas owned by the GraphCanvas
  // hook. The contract's `graph` key is read from / written by it; the two
  // hooks talk via synchronous DOM CustomEvents on `this.el`:
  //
  //   graph-canvas:request-feed  (canvas → tabs, on canvas mount)
  //   step-tabs:feed-graph       (tabs → canvas, direct reply: feed())
  //   graph-canvas:sync          (canvas → tabs, on every canvas change)
  //
  // Sync events bubble to `this.el` where `_wireVisual` listens and runs
  // the normal _sync() serialization → textarea → live lint.

  _feedGraphCanvas(graph) {
    const canvas = this.el.querySelector("[data-graph-canvas]")
    if (!canvas) return
    // The GraphCanvas hook listens for this on its own element.
    canvas.dispatchEvent(
      new CustomEvent("step-tabs:feed-graph", {
        detail: {nodes: graph.nodes || [], edges: graph.edges || []},
      })
    )
  },

  _collectGraphCanvas() {
    // Canvas cache: refreshed on every `graph-canvas:sync` (see _wireVisual).
    const data = this._canvasGraph
    if (!data) return null
    // Same empty semantics as the old row-based path: no nodes/edges = no graph key.
    return data.nodes.length || data.edges.length ? data : null
  },

  _parse() {
    try {
      const raw = (this.jsonEl.value || "").trim()
      if (raw === "") return { contract: {}, ok: true }
      const parsed = JSON.parse(raw)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return { contract: parsed, ok: true }
      }
      return { contract: {}, ok: false }
    } catch (_) {
      return { contract: {}, ok: false }
    }
  },

  _fillList(kind, items, map) {
    const list = this.el.querySelector(`[data-list="${kind}"]`)
    if (!list) return
    list.querySelectorAll("[data-row]").forEach((row) => row.remove())
    const rows = Array.isArray(items) && items.length ? items : [{}]
    for (const item of rows) {
      const data = item && typeof item === "object" ? item : {}
      list.appendChild(this._row(kind, data, map))
    }
  },

  // context_snapshot rows: a PAGE/MEM badge + id + why. The badge's
  // textContent is the row's type — _row/map only touches inputs/selects,
  // so badge styling is applied here.
  _fillCtx(entries) {
    const list = this.el.querySelector('[data-list="ctx"]')
    if (!list) return
    list.querySelectorAll("[data-row]").forEach((row) => row.remove())
    const rows = Array.isArray(entries) && entries.length ? entries : [{}]
    for (const entry of rows) {
      const data = entry && typeof entry === "object" ? entry : {}
      const row = this._row("ctx", data, [
        ['[data-cf="ctx_id"]', "id"],
        ['[data-cf="ctx_why"]', "why"],
      ])
      this._styleCtxBadge(row.querySelector('[data-cf="ctx_type"]'), data.type)
      list.appendChild(row)
    }
  },

  _styleCtxBadge(el, type) {
    if (!el) return
    const t = type === "memory" ? "MEM" : "PAGE"
    el.textContent = t
    el.className =
      "badge badge-xs px-2 font-mono uppercase text-[9px] tracking-wider " +
      (type === "memory" ? "badge-secondary" : "badge-primary")
  },

  _row(kind, data, map) {
    const tpl = this.el.querySelector(`template[data-tpl="${kind}"]`)
    if (!tpl) return document.createComment(`missing template ${kind}`)
    const row = tpl.content.firstElementChild.cloneNode(true)
    for (const [sel, key] of map) {
      const input = row.querySelector(sel)
      if (input && input.tagName === "SELECT" && input.options.length === 0) {
        // Edge from/to selects: their options are built later (they depend
        // on node ids) — remember the intended value; _syncEdgeSelects()
        // applies it. Selects with options (verb) get the value directly.
        input.dataset.pendingValue = data[key] || ""
      } else if (input) {
        input.value = data[key] || ""
      }
    }
    return row
  },

  _addRow(kind) {
    const list = this.el.querySelector(`[data-list="${kind}"]`)
    const tpl = this.el.querySelector(`template[data-tpl="${kind}"]`)
    if (!list || !tpl) return
    list.appendChild(tpl.content.firstElementChild.cloneNode(true))
  },

  _collect() {
    const val = (sel) => {
      const el = this.visualBody.querySelector(sel)
      return el ? el.value.trim() : ""
    }

    const claims = [...this.visualBody.querySelectorAll('[data-list="claims"] [data-row]')]
      .map((row) => ({
        id: row.querySelector('[data-cf="claim_id"]').value.trim(),
        claim: row.querySelector('[data-cf="claim"]').value.trim(),
        verify: row.querySelector('[data-cf="verify"]').value.trim(),
      }))
      .filter((c) => c.id || c.claim || c.verify)

    const gates = [...this.visualBody.querySelectorAll('[data-list="gates"] [data-row]')]
      .map((row) => ({
        name: row.querySelector('[data-cf="name"]').value.trim(),
        expect: row.querySelector('[data-cf="expect"]').value.trim(),
        cmd: row.querySelector('[data-cf="cmd"]').value.trim(),
      }))
      .filter((g) => g.name || g.expect || g.cmd)

    const ctx = [...this.visualBody.querySelectorAll('[data-list="ctx"] [data-row]')]
      .map((row) => {
        const type = row.querySelector('[data-cf="ctx_type"]').textContent.trim().toLowerCase()
        return {
          type: type === "mem" ? "memory" : type === "page" ? "page" : "page",
          id: row.querySelector('[data-cf="ctx_id"]').value.trim(),
          why: row.querySelector('[data-cf="ctx_why"]').value.trim(),
        }
      })
      .filter((c) => c.id)

    const contract = {}
    const intent = val('[data-cf="intent"]')
    if (intent) contract.intent = intent
    if (claims.length) contract.claims = claims
    if (gates.length) contract.gates = gates
    const gcData = this._collectGraphCanvas()
    if (gcData) contract.graph = gcData
    // ctx: expanded form wins over whatever snapshot rode in _passthrough.
    if (ctx.length) contract.context_snapshot = ctx
    return Object.assign(contract, this._passthrough)
  },

  _sync() {
    const contract = this._collect()
    // Empty visual form = no contract (same semantics as a blank textarea:
    // saving drops meta.contract instead of storing an empty object).
    const hasContent =
      contract.intent || contract.claims || contract.gates || contract.graph
    const json = hasContent ? JSON.stringify(contract, null, 2) : ""
    this._lastJson = json
    this.jsonEl.value = json
    this._syncEdgeSelects()
    // Same channel as typing in the textarea: phx-debounce → validate_step
    // → live lint feedback next to the editor. Never blocks the form.
    this.jsonEl.dispatchEvent(new Event("input", { bubbles: true }))
  },

  // Edge from/to selects list the CURRENT node ids — rebuild the options
  // after every sync, preserving the selected value when it still exists.
  // A select freshly cloned from the template may carry a pendingValue
  // (its options don't exist yet at _row() time); apply it once options
  // are in place.
  _syncEdgeSelects() {
    const ids = [
      ...this.visualBody.querySelectorAll('[data-list="nodes"] [data-cf="node_id"]'),
    ]
      .map((input) => input.value.trim())
      .filter(Boolean)

    this.visualBody.querySelectorAll('[data-list="edges"] select').forEach((select) => {
      const current =
        select.dataset.pendingValue !== undefined ? select.dataset.pendingValue : select.value
      delete select.dataset.pendingValue
      select.innerHTML = ""
      const blank = document.createElement("option")
      blank.value = ""
      blank.textContent = "—"
      select.appendChild(blank)
      for (const id of ids) {
        const opt = document.createElement("option")
        opt.value = id
        opt.textContent = id
        select.appendChild(opt)
      }
      if ([...select.options].some((opt) => opt.value === current)) select.value = current
    })
  },
}

export default StepModalTabs
