// Returns keyboard focus after a board card's Move to Ready arrow is used
// (W2348 follow-up). The arrow leaves with its card, which would drop a
// keyboard user on the page body. The server pushes `move_to_ready:focus`
// with `to` (the next Backlog card's arrow id, or null) and `fallback` (the
// moved card's id); focus goes to `to`, else the first focusable control in
// the fallback card.
//
// Only keyboard users are moved: after a pointer click the page keeps its
// focus, so the next card's arrow is not revealed under the mouse.
//
// The board patches twice right after a move (its own render, then its own
// move broadcast), and each patch briefly detaches and re-inserts the target,
// which drops focus to the body. So focus is held for a short window: every
// few milliseconds it is put back on the target while focus sits on the body
// (or on a detached element), and the hold stops as soon as the user focuses
// anything else.
const HOLD_MS = 600
const CHECK_EVERY_MS = 15
const FOCUSABLE = 'a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])'

export function focusTarget(doc, detail) {
  if (!detail || typeof detail !== "object") return null
  const next = typeof detail.to === "string" ? doc.getElementById(detail.to) : null
  if (next) return next
  const card = typeof detail.fallback === "string" ? doc.getElementById(detail.fallback) : null
  return card ? card.querySelector(FOCUSABLE) : null
}

export function holdFocus(win, doc, detail, now = () => Date.now()) {
  const until = now() + HOLD_MS
  let target = focusTarget(doc, detail)
  if (target) target.focus()

  // The target is looked up again on every check: a card moved to another
  // column is re-created, so the element found before the patch is gone.
  const check = () => {
    const active = doc.activeElement
    const lost = !active || active === doc.body || active.isConnected === false
    if (!lost && active !== target) return
    target = focusTarget(doc, detail)
    if (lost && target) target.focus()
    if (now() < until) win.setTimeout(check, CHECK_EVERY_MS)
  }

  win.setTimeout(check, CHECK_EVERY_MS)
}

export function install(win, doc) {
  let lastInputWasKeyboard = false
  win.addEventListener("keydown", () => { lastInputWasKeyboard = true }, true)
  win.addEventListener("pointerdown", () => { lastInputWasKeyboard = false }, true)
  win.addEventListener("phx:move_to_ready:focus", (event) => {
    if (lastInputWasKeyboard) holdFocus(win, doc, event.detail)
  })
}
