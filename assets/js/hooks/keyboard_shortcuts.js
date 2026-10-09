// Board keyboard shortcuts (W2236), attached to the board view wrapper:
//
//   /       focus the board search input (#board-search)
//   ?       toggle the shortcut help overlay (server event toggle_shortcuts_help)
//   Escape  close the help overlay, or clear an active bulk selection (only
//           when the server marked one on data-selected-count, which it does
//           only for viewers who may modify the board)
//
// Every shortcut is ignored while the user is typing (input, textarea, select,
// contenteditable), while Ctrl, Meta or Alt is held, and while another dialog —
// such as the task modal — is open, so a key never fires behind a modal.
//
// The hook only ever pushes fixed event names with empty payloads; it never
// sends anything the user typed to the server.
//
// Opening the overlay with ? first runs the JS command in the hook element's
// data-push-focus attribute (the server renders JS.push_focus()) against the
// element that has focus, so the overlay's phx-remove JS.pop_focus() can return
// focus there however the overlay is closed. JS.push_focus() inside the
// overlay's own phx-mounted would remember the overlay instead, which is gone
// by the time focus is popped.
const SEARCH_INPUT_ID = "board-search"
const HELP_OVERLAY_ID = "keyboard-shortcuts-help"

// Input types that hold no typed text, so a shortcut pressed while one is
// focused (e.g. a bulk-select checkbox) is still a shortcut.
const NON_TEXT_INPUT_TYPES = new Set([
  "button", "checkbox", "color", "file", "image", "radio", "range", "reset", "submit"
])

export function isEditableTarget(target) {
  if (!target || typeof target !== "object") return false
  if (target.isContentEditable) return true

  const tag = typeof target.tagName === "string" ? target.tagName.toUpperCase() : ""
  if (tag === "TEXTAREA" || tag === "SELECT") return true
  if (tag !== "INPUT") return false

  const type = (target.type || "text").toLowerCase()
  return !NON_TEXT_INPUT_TYPES.has(type)
}

// Maps a keydown event to a shortcut name, or null when the event is not a
// shortcut: it is typed into an editable element, carries Ctrl/Meta/Alt, is a
// key repeat, or was already handled by something else.
export function shortcutFor(event) {
  if (!event || event.defaultPrevented || event.repeat || event.isComposing) return null
  if (event.ctrlKey || event.metaKey || event.altKey) return null
  if (isEditableTarget(event.target)) return null

  switch (event.key) {
    case "/": return "focus_search"
    case "?": return "toggle_help"
    case "Escape": return "escape"
    default: return null
  }
}

function isShown(el) {
  return !!el && typeof el.getClientRects === "function" && el.getClientRects().length > 0
}

// True when a dialog other than the help overlay is open on the page.
export function otherDialogOpen(doc) {
  const dialogs = doc.querySelectorAll("[role='dialog'][aria-modal='true']")
  return Array.from(dialogs).some((el) => !el.closest(`#${HELP_OVERLAY_ID}`) && isShown(el))
}

const KeyboardShortcuts = {
  mounted() {
    this._onKeyDown = (event) => this.handleKey(event)
    window.addEventListener("keydown", this._onKeyDown)
  },

  destroyed() {
    window.removeEventListener("keydown", this._onKeyDown)
  },

  helpOpen() {
    return !!document.getElementById(HELP_OVERLAY_ID)
  },

  handleKey(event) {
    const shortcut = shortcutFor(event)
    if (!shortcut) return

    // While the help overlay is open only `?` acts here (it closes it again);
    // the overlay's own phx-window-keydown binding handles Escape.
    if (this.helpOpen()) {
      if (shortcut === "toggle_help") this.toggleHelp(event)
      return
    }

    if (otherDialogOpen(document)) return

    if (shortcut === "focus_search") this.focusSearch(event)
    else if (shortcut === "toggle_help") this.toggleHelp(event)
    else this.clearSelection(event)
  },

  focusSearch(event) {
    const input = document.getElementById(SEARCH_INPUT_ID)
    if (!input) return
    // preventDefault stops the slash from being typed into the input it focuses.
    event.preventDefault()
    input.focus()
  },

  toggleHelp(event) {
    event.preventDefault()
    if (!this.helpOpen()) this.rememberFocus()
    this.pushEvent("toggle_shortcuts_help", {})
  },

  rememberFocus() {
    const pushFocus = this.el.dataset.pushFocus
    const active = document.activeElement
    if (pushFocus && active && active !== document.body) this.liveSocket.execJS(active, pushFocus)
  },

  clearSelection(event) {
    if (Number(this.el.dataset.selectedCount || 0) > 0) {
      event.preventDefault()
      this.pushEvent("bulk_clear", {})
    }
  }
}

export default KeyboardShortcuts
