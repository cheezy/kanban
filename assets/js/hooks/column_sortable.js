import Sortable from "sortablejs"

const ColumnSortableHook = {
  mounted() {
    this.pendingMove = false
    this.isDragging = false
    this.allowNextUpdate = false
    this.initSortable()

    // Listen for move success/failure events from server
    this.handleEvent("move_column_success", () => {
      console.log("Column move succeeded on server")
      this.pendingMove = false
      this.allowNextUpdate = true
    })

    this.handleEvent("move_column_failed", () => {
      console.log("Column move failed on server - will reload")
      this.pendingMove = false
      this.allowNextUpdate = true
    })
  },

  beforeUpdate() {
    // Allow update if explicitly flagged
    if (this.allowNextUpdate) {
      console.log("Allowing LiveView update after column move completion")
      this.allowNextUpdate = false
      return true
    }

    // Prevent updates while dragging or during pending move
    if (this.isDragging || this.pendingMove) {
      console.log("Prevented LiveView update - isDragging:", this.isDragging, "pendingMove:", this.pendingMove)
      return false
    }
  },

  updated() {
    console.log("updated() called - pendingMove:", this.pendingMove, "isDragging:", this.isDragging)

    // Don't reinitialize if we're dragging
    if (this.isDragging) {
      console.log("Skipping sortable reinit during drag")
      return
    }

    console.log("Reinitializing sortable after LiveView update")
    // Reinitialize sortable after LiveView updates
    this.initSortable()
  },

  initSortable() {
    // Destroy existing instance if it exists
    if (this.sortable) {
      this.sortable.destroy()
    }

    const hook = this

    this.sortable = Sortable.create(this.el, {
      animation: 150,
      handle: ".column-drag-handle",
      dragClass: "sortable-drag",
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      forceFallback: false,
      fallbackOnBody: true,
      swapThreshold: 0.65,

      onStart: function(evt) {
        // Mark that we're starting a drag
        hook.isDragging = true
        hook.pendingMove = true
        console.log("Column drag started")
      },

      onEnd: function(evt) {
        hook.isDragging = false

        console.log("Column drag ended", {
          columnId: evt.item.dataset.columnId,
          oldIndex: evt.oldIndex,
          newIndex: evt.newIndex
        })

        // Get the column ID from the dragged item
        const columnId = evt.item.dataset.columnId

        // Get new position (index in the list)
        const newPosition = evt.newIndex

        // Only send if actually moved
        if (evt.oldIndex !== evt.newIndex) {
          console.log("Sending move_column event to server")

          // Get all column IDs in their new order
          const columnIds = Array.from(hook.el.children)
            .map(el => el.dataset.columnId)
            .filter(id => id) // Filter out any undefined values

          // Send the move event to the LiveView
          // pendingMove will be cleared by move_column_success or move_column_failed event from server
          hook.pushEvent("move_column", {
            column_id: columnId,
            new_position: newPosition,
            column_ids: columnIds
          })
        } else {
          // No actual move, clear immediately
          hook.pendingMove = false
        }
      }
    })
  },

  destroyed() {
    if (this.sortable) {
      this.sortable.destroy()
    }
  }
}

export default ColumnSortableHook
