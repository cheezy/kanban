import Sortable from "sortablejs"

const SortableHook = {
  mounted() {
    this.isDragging = false
    this.pendingMoveComplete = false
    this.skipNextResort = false
    this.highlightTimeout = null
    this.initSortable()
    this.updateWipHighlight()

    // Listen for move success/failure events from server
    this.handleEvent("move_success", () => {
      this.pendingMoveComplete = false
      this.isDragging = false
      // Sortable already placed the cards in their final order during the
      // drag. The server's diff arrives next and only updates data-position
      // attrs — no need to re-sort the DOM. Skipping the resort prevents the
      // momentary visual jump where the JS rebuilds the task list under us.
      this.skipNextResort = true
    })

    this.handleEvent("move_failed", () => {
      this.pendingMoveComplete = false
      this.isDragging = false
    })

    this.handleEvent("wip_limit_violation", ({column_id}) => {
      const columnElement = document.querySelector(`[data-column-id="${column_id}"]`)
      if (columnElement) {
        columnElement.classList.add("bg-red-50", "border-2", "border-red-200")
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
      // After a local drop, Sortable has already placed the cards correctly
      // and the server's confirmation diff only updates data-position attrs —
      // re-sorting the DOM here would just yank elements out and re-append
      // them, causing a visible flicker. Cross-tab broadcasts still need the
      // resort (data-position changes without matching DOM order).
      const justConfirmedLocalMove = this.skipNextResort
      this.skipNextResort = false

      // Skip position-based re-sorting for server-sorted columns (e.g. Done)
      if (!this.el.dataset.serverSorted && !justConfirmedLocalMove) {
        const taskElements = Array.from(this.el.children).filter(child => child.dataset.id)

        const sortedElements = taskElements.slice().sort((a, b) => {
          const posA = parseInt(a.dataset.position || "0")
          const posB = parseInt(b.dataset.position || "0")
          return posA - posB
        })

        const needsReorder = sortedElements.some((el, index) => taskElements[index] !== el)

        if (needsReorder) {
          taskElements.forEach(el => el.remove())
          const emptyState = this.el.querySelector('.empty-state')
          sortedElements.forEach(el => this.el.appendChild(el))
          if (emptyState) {
            this.el.insertBefore(emptyState, this.el.firstChild)
          }
        }
      }

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
      animation: 150,
      easing: "cubic-bezier(0.4, 0, 0.2, 1)",
      handle: handle || null,
      dragClass: "sortable-drag",
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      // Force Sortable's own DOM-based drag instead of the native HTML5
      // DnD API. Native DnD has browser-imposed timing quirks that can delay
      // the ghost placeholder appearing in the target column by several
      // seconds — forcing the fallback makes the ghost track the cursor
      // immediately and lets us style the drag clone reliably.
      forceFallback: true,
      fallbackOnBody: true,
      // 6px tolerance — a short, deliberate mouse-up still registers as a
      // click and opens the task; pulling the card more than ~6px begins a
      // drag. Below this, click-vs-drag detection fights small hand jitter.
      fallbackTolerance: 6,
      // Lower threshold = swap triggers sooner as the dragged card crosses
      // a neighbour. 1 (full overlap) felt sluggish in long columns.
      swapThreshold: 0.65,
      emptyInsertThreshold: 10,
      scrollSensitivity: 60,
      scrollSpeed: 15,
      bubbleScroll: true,
      // Pointerdowns on these elements never start a drag — the click is
      // forwarded normally so the edit/archive/delete buttons still work
      // and clicks on empty-state placeholders aren't intercepted.
      filter: ".empty-state, .task-actions, .task-actions *",
      preventOnFilter: false,
      delay: 0,
      delayOnTouchOnly: true,
      touchStartThreshold: 3,

      onStart: function(evt) {
        hook.isDragging = true
      },

      onEnd: function(evt) {
        const taskId = evt.item.dataset.id
        const newColumnId = evt.to.dataset.columnId
        const oldColumnId = evt.from.dataset.columnId

        // The empty-state div is always the first child in an empty column;
        // subtract 1 from the raw index so the server position lines up.
        let newPosition = evt.newIndex
        const hasEmptyState = evt.to.querySelector('.empty-state') !== null
        if (hasEmptyState && newPosition > 0) {
          newPosition = newPosition - 1
        }

        if (oldColumnId !== newColumnId || evt.oldIndex !== evt.newIndex) {
          hook.isDragging = false
          hook.pendingMoveComplete = true

          hook.pushEvent("move_task", {
            task_id: taskId,
            old_column_id: oldColumnId,
            new_column_id: newColumnId,
            new_position: newPosition
          })
        } else {
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
