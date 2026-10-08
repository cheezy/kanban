// Scrolls a comment thread to the comment named in the URL fragment,
// `#comment-<id>`, which mention notifications link to. The browser's own
// fragment scroll cannot do this: the thread renders inside a delayed modal,
// after the browser has already looked for the anchor, and the thread scrolls
// in its own container.
//
// The thread mounts while that modal is still `hidden` (display: none), and
// scrolling inside a hidden container does nothing. So the hook marks the
// comment straight away, then waits, a frame at a time, until the thread is
// actually laid out before scrolling to it. It gives up after MAX_WAIT_MS.

const TARGETED_ATTR = "data-comment-targeted"
const MAX_WAIT_MS = 3000

// The comment id named by `hash`, or null. Only a positive whole number is
// accepted, so the value is safe to put in an attribute selector.
export function commentIdFromHash(hash) {
  const match = /^#comment-([1-9][0-9]{0,17})$/.exec(hash || "")
  return match ? match[1] : null
}

// An element inside a display: none ancestor has no layout boxes.
export function isLaidOut(el) {
  return el.getClientRects().length > 0
}

const CommentAnchor = {
  mounted() {
    const id = commentIdFromHash(window.location.hash)
    if (!id) return

    const row = this.el.querySelector(`[data-comment-id="${id}"]`)
    if (!row) return

    row.setAttribute(TARGETED_ATTR, "")
    this.waitStartedAt = Date.now()
    this.scrollWhenLaidOut(row)
  },

  destroyed() {
    this.stopped = true
  },

  scrollWhenLaidOut(row) {
    if (this.stopped) return
    if (isLaidOut(this.el)) return row.scrollIntoView({block: "center"})
    if (Date.now() - this.waitStartedAt > MAX_WAIT_MS) return

    window.requestAnimationFrame(() => this.scrollWhenLaidOut(row))
  },
}

export default CommentAnchor
