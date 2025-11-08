import Sortable from "sortablejs"

const SortableHook = {
  mounted() {
    this.pendingMove = false
    this.isDragging = false
    this.initSortable()

    // Listen for move success/failure events from server
    this.handleEvent("move_success", () => {
      console.log("Move succeeded on server")
      this.pendingMove = false
    })

    this.handleEvent("move_failed", () => {
      console.log("Move failed on server - will reload")
      this.pendingMove = false
    })
  },

  beforeUpdate() {
    // Prevent updates while dragging or during pending move
    if (this.isDragging || this.pendingMove) {
      console.log("Prevented LiveView update - isDragging:", this.isDragging, "pendingMove:", this.pendingMove)
      return false
    }
  },

  updated() {
    // Don't reinitialize if we have a pending move - let it complete
    if (this.pendingMove || this.isDragging) {
      console.log("Skipping sortable reinit during pending move or drag")
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
    const group = this.el.dataset.group || "shared"
    const handle = this.el.dataset.handle

    this.sortable = Sortable.create(this.el, {
      group: group,
      animation: 150,
      handle: handle || null,
      dragClass: "sortable-drag",
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      forceFallback: false,
      fallbackOnBody: true,
      swapThreshold: 0.65,
      filter: ".empty-state",  // Don't allow dragging the empty state
      preventOnFilter: false,   // Still allow clicks on empty state

      onStart: function(evt) {
        // Mark that we're starting a drag
        hook.isDragging = true
        hook.pendingMove = true
        console.log("Drag started")
      },

      onEnd: function(evt) {
        hook.isDragging = false

        console.log("Drag ended", {
          taskId: evt.item.dataset.id,
          oldColumn: evt.from.dataset.columnId,
          newColumn: evt.to.dataset.columnId,
          oldIndex: evt.oldIndex,
          newIndex: evt.newIndex
        })

        // Get the task ID from the dragged item
        const taskId = evt.item.dataset.id

        // Get the new column ID from the target list
        const newColumnId = evt.to.dataset.columnId

        // Get the old column ID from the source list
        const oldColumnId = evt.from.dataset.columnId

        // Get new position (index in the list)
        const newPosition = evt.newIndex

        // Only send if actually moved
        if (oldColumnId !== newColumnId || evt.oldIndex !== evt.newIndex) {
          console.log("Sending move_task event to server")

          // Send the move event to the LiveView
          // pendingMove will be cleared by move_success or move_failed event from server
          hook.pushEvent("move_task", {
            task_id: taskId,
            old_column_id: oldColumnId,
            new_column_id: newColumnId,
            new_position: newPosition
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

export default SortableHook
