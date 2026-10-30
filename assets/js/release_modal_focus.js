// Releases the cursor from a modal that is closing (field report, Safari 26).
// A task modal focuses its first text field when it opens. When it closes,
// LiveView removes it while the cursor is still in that field, and Safari
// then leaves the caret where the field was (the modals render at the end of
// <main>) and scrolls the page down to it about 50ms later.
//
// CoreComponents.hide_modal/2 dispatches `stride:release-focus` on the modal
// as its first command, so the field is blurred and the selection cleared
// before anything is hidden or removed. Focus and selections outside the
// modal are left alone.
export const RELEASE_FOCUS_EVENT = "stride:release-focus"

export function releaseFocus(win, doc, modal) {
  if (!modal || typeof modal.contains !== "function") return false

  const active = doc.activeElement
  const focusInside = Boolean(active) && active !== doc.body && modal.contains(active)
  if (focusInside && typeof active.blur === "function") active.blur()

  const selection = typeof win.getSelection === "function" ? win.getSelection() : null
  const selectionInside =
    Boolean(selection) && selection.rangeCount > 0 && modal.contains(selection.anchorNode)
  if (selection && (focusInside || selectionInside)) selection.removeAllRanges()

  return focusInside || selectionInside
}

export function install(win, doc) {
  win.addEventListener(RELEASE_FOCUS_EVENT, (event) => releaseFocus(win, doc, event.target))
}
