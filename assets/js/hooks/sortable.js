import Sortable from "sortablejs"

const SortableHook = {
  mounted() {
    this.isDragging = false
    this.pendingMoveComplete = false
    this.highlightTimeout = null
    this.initSortable()
    this.updateWipHighlight()

    // Listen for move success/failure events from server
    this.handleEvent("move_success", () => {
      console.log("Move succeeded on server")
      // Clear flags immediately to allow LiveView update with correct positions
      this.pendingMoveComplete = false
      this.isDragging = false
    })

    this.handleEvent("move_failed", () => {
      console.log("Move failed on server - will reload")
      // Clear flags immediately to allow LiveView update to revert positions
      this.pendingMoveComplete = false
      this.isDragging = false
    })

    this.handleEvent("wip_limit_violation", ({column_id}) => {
      console.log("WIP limit violation for column:", column_id)
      // Find the column element by column_id
      const columnElement = document.querySelector(`[data-column-id="${column_id}"]`)
      if (columnElement) {
        // Add red highlighting
        columnElement.classList.add("bg-red-50", "border-2", "border-red-200")

        // Remove after 3 seconds
        setTimeout(() => {
          columnElement.classList.remove("bg-red-50", "border-2", "border-red-200")
        }, 3000)
      }
    })
  },

  beforeUpdate() {
    // Prevent updates while actively dragging or waiting for move to complete
    if (this.isDragging || this.pendingMoveComplete) {
      return false
    }

    // Destroy sortable instance before LiveView updates to allow proper reordering
    if (this.sortable) {
      this.sortable.destroy()
      this.sortable = null
    }

    // Allow all other updates (including broadcasts from other clients)
    return true
  },

  updated() {
    // Don't reinitialize if we're actively dragging
    if (this.isDragging) {
      return
    }

    // Use requestAnimationFrame to ensure DOM is fully updated before reordering
    requestAnimationFrame(() => {
      // Get all task elements (exclude empty state)
      const taskElements = Array.from(this.el.children).filter(child => child.dataset.id)

      // Sort elements by their data-position attribute
      const sortedElements = taskElements.slice().sort((a, b) => {
        const posA = parseInt(a.dataset.position || "0")
        const posB = parseInt(b.dataset.position || "0")
        return posA - posB
      })

      // Check if reordering is needed
      const needsReorder = sortedElements.some((el, index) => taskElements[index] !== el)

      if (needsReorder) {
        // Remove all task elements
        taskElements.forEach(el => el.remove())
        // Re-insert in correct order
        const emptyState = this.el.querySelector('.empty-state')
        sortedElements.forEach(el => {
          this.el.appendChild(el)
        })
        // Move empty state to beginning if it exists
        if (emptyState) {
          this.el.insertBefore(emptyState, this.el.firstChild)
        }
      }

      // Reinitialize sortable after reordering
      this.initSortable()
      this.updateWipHighlight()
    })
  },

  updateWipHighlight() {
    const wipLimit = parseInt(this.el.dataset.wipLimit || "0")
    const taskCount = parseInt(this.el.dataset.taskCount || "0")

    // Clear any existing timeout
    if (this.highlightTimeout) {
      clearTimeout(this.highlightTimeout)
      this.highlightTimeout = null
    }

    // Remove highlight first
    this.el.classList.remove("bg-red-50", "border-2", "border-red-200")

    // Only highlight if EXCEEDING limit (over the limit, not at it)
    if (wipLimit > 0 && taskCount > wipLimit) {
      this.el.classList.add("bg-red-50", "border-2", "border-red-200")

      // Remove highlight after 5 seconds
      this.highlightTimeout = setTimeout(() => {
        this.el.classList.remove("bg-red-50", "border-2", "border-red-200")
        this.highlightTimeout = null
      }, 5000)
    }
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
      animation: 200,
      easing: "cubic-bezier(0.4, 0, 0.2, 1)",
      handle: handle || null,
      dragClass: "sortable-drag",
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      forceFallback: false,
      fallbackOnBody: true,
      swapThreshold: 0.5,
      invertSwap: true,
      emptyInsertThreshold: 10,
      scrollSensitivity: 60,
      scrollSpeed: 15,
      bubbleScroll: true,
      filter: ".empty-state",
      preventOnFilter: false,
      delay: 0,
      delayOnTouchOnly: true,
      touchStartThreshold: 3,

      onStart: function(evt) {
        // Mark that we're starting a drag
        hook.isDragging = true
        console.log("Drag started")
      },

      onEnd: function(evt) {
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

        // Calculate the actual position, accounting for the empty-state div
        // The empty-state div is always the first child, so we need to subtract 1
        // from the index if there's an empty-state in the target column
        let newPosition = evt.newIndex
        const targetColumn = evt.to
        const hasEmptyState = targetColumn.querySelector('.empty-state') !== null
        if (hasEmptyState && newPosition > 0) {
          newPosition = newPosition - 1
        }

        console.log("Adjusted position:", {
          rawIndex: evt.newIndex,
          adjustedPosition: newPosition,
          hasEmptyState: hasEmptyState
        })

        // Only send if actually moved
        if (oldColumnId !== newColumnId || evt.oldIndex !== evt.newIndex) {
          console.log("Sending move_task event to server")

          // Clear dragging flag immediately since drag is complete
          hook.isDragging = false
          // Mark that we're waiting for the move to complete
          hook.pendingMoveComplete = true

          // Send the move event to the LiveView
          hook.pushEvent("move_task", {
            task_id: taskId,
            old_column_id: oldColumnId,
            new_column_id: newColumnId,
            new_position: newPosition
          })
        } else {
          // No actual move, safe to clear dragging flag immediately
          hook.isDragging = false
        }
      }
    })
  },

  destroyed() {
    if (this.sortable) {
      this.sortable.destroy()
    }

    // Clear any pending highlight timeout
    if (this.highlightTimeout) {
      clearTimeout(this.highlightTimeout)
      this.highlightTimeout = null
    }
  }
}

export default SortableHook
