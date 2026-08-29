// TaskDnD — native HTML5 drag & drop for the task board.
//
// Zero dependencies (decision: native over SortableJS). Supports drag
// between columns and reordering within a column. Drops report to the
// server as a "move" event with {id, to_status, before_id} — the server
// computes the position (midpoint gap) and renumbers when needed.
//
// Missing vs SortableJS: no touch support (mobile users get the column
// select fallback), no drag handle auto-scroll. Acceptable for a desktop
// personal tool; upgrade path documented in docs.
const TaskDnD = {
  mounted() {
    this.draggedId = null
    this.bindEvents()
  },

  bindEvents() {
    // Dragstart on a task card
    this.el.addEventListener("dragstart", (e) => {
      const card = e.target.closest("[data-task-id]")
      if (!card) return
      this.draggedId = card.dataset.taskId
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", this.draggedId)
      card.classList.add("opacity-40")
    })

    this.el.addEventListener("dragend", (e) => {
      const card = e.target.closest("[data-task-id]")
      if (card) card.classList.remove("opacity-40")
      // Clear drop indicators
      this.el.querySelectorAll("[data-drop-before]").forEach((el) => {
        el.classList.remove("border-t-2", "border-primary")
      })
      this.el.querySelectorAll("[data-column]").forEach((el) => {
        el.classList.remove("bg-primary/5")
      })
      this.draggedId = null
    })

    // Highlight the column under the cursor
    this.el.addEventListener("dragover", (e) => {
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
    })

    // Drop indicator: show where the card would land
    this.el.addEventListener("dragover", (e) => {
      const dropZone = e.target.closest("[data-drop-zone]")
      if (!dropZone) return
      const cards = [...dropZone.querySelectorAll("[data-task-id]:not([data-dragging])")]

      const afterCard = cards.find((card) => {
        const rect = card.getBoundingClientRect()
        return e.clientY < rect.top + rect.height / 2
      })

      // Clear previous indicators on this column
      dropZone.querySelectorAll("[data-task-id]").forEach((el) => {
        el.classList.remove("task-drop-before")
      })

      if (afterCard) afterCard.classList.add("task-drop-before")
      // else: appending at end — the column itself could show a hint
    })

    // Drop: compute before_id and push the move event
    this.el.addEventListener("drop", (e) => {
      e.preventDefault()
      const id = e.dataTransfer.getData("text/plain") || this.draggedId
      if (!id) return

      const column = e.target.closest("[data-column]")
      if (!column) return
      const toStatus = column.dataset.column

      const dropZone = column.querySelector("[data-drop-zone]")
      let beforeId = null

      if (dropZone) {
        const cards = [...dropZone.querySelectorAll("[data-task-id]")]
          .filter((c) => c.dataset.taskId !== id)

        const afterCard = cards.find((card) => {
          const rect = card.getBoundingClientRect()
          return e.clientY < rect.top + rect.height / 2
        })

        beforeId = afterCard ? afterCard.dataset.taskId : null
      }

      this.pushEvent("move", {
        id: id,
        to_status: toStatus,
        before_id: beforeId
      })
    })
  }
}

export default TaskDnD
