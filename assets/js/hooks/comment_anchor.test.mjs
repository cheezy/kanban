// Unit tests for comment_anchor.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test} from "node:test"
import assert from "node:assert/strict"

import CommentAnchor, {commentIdFromHash} from "./comment_anchor.js"

test("commentIdFromHash reads a positive comment id from #comment-<id>", () => {
  assert.equal(commentIdFromHash("#comment-105"), "105")
  assert.equal(commentIdFromHash("#comment-1"), "1")
})

test("commentIdFromHash rejects anything else, so the id is selector-safe", () => {
  for (const hash of ["", null, undefined, "#comment-", "#comment-0", "#comment-012",
    "#comment-1a", "#comment-1\"]", "#Comment-5", "#comment-5 ", "comment-5",
    "#comment-1234567890123456789"]) {
    assert.equal(commentIdFromHash(hash), null, `hash ${JSON.stringify(hash)}`)
  }
})

// A thread whose layout appears after `hiddenFrames` animation frames, as the
// delayed modal fades in. Frames are queued and run by `runFrames`.
function threadWith(rows, hash, hiddenFrames = 0) {
  const frames = []
  let shown = hiddenFrames === 0
  let framesSeen = 0

  globalThis.window = {
    location: {hash},
    requestAnimationFrame: fn => frames.push(fn),
  }

  const queries = []
  const el = {
    getClientRects: () => (shown ? [{}] : []),
    querySelector: selector => {
      queries.push(selector)
      const id = /data-comment-id="(\d+)"/.exec(selector)?.[1]
      return rows[id] || null
    },
  }

  const runFrames = (max = 100) => {
    while (frames.length > 0 && max-- > 0) {
      framesSeen++
      if (framesSeen >= hiddenFrames) shown = true
      frames.shift()()
    }
  }

  return {hook: Object.assign(Object.create(CommentAnchor), {el}), queries, frames, runFrames}
}

function row() {
  const attrs = {}
  return {
    attrs,
    scrolled: null,
    setAttribute(name, value) { attrs[name] = value },
    scrollIntoView(opts) { this.scrolled = opts },
  }
}

test("a thread that is already laid out scrolls to the comment at once", () => {
  const target = row()
  const {hook} = threadWith({105: target}, "#comment-105")

  hook.mounted()

  assert.deepEqual(target.scrolled, {block: "center"})
  assert.equal(target.attrs["data-comment-targeted"], "")
})

test("a thread inside a still-hidden modal is marked now and scrolled once it is laid out", () => {
  const target = row()
  const {hook, runFrames} = threadWith({105: target}, "#comment-105", 3)

  hook.mounted()
  assert.equal(target.attrs["data-comment-targeted"], "")
  assert.equal(target.scrolled, null)

  runFrames()
  assert.deepEqual(target.scrolled, {block: "center"})
})

test("it stops waiting when the thread is removed", () => {
  const target = row()
  const {hook, runFrames} = threadWith({105: target}, "#comment-105", 3)

  hook.mounted()
  hook.destroyed()
  runFrames()

  assert.equal(target.scrolled, null)
})

test("it gives up when the thread never becomes visible", () => {
  const target = row()
  const {hook, frames} = threadWith({105: target}, "#comment-105", Infinity)
  const realNow = Date.now
  let now = 1_000
  Date.now = () => now

  try {
    hook.mounted()
    now += 3_001
    frames.shift()()

    assert.equal(frames.length, 0)
    assert.equal(target.scrolled, null)
  } finally {
    Date.now = realNow
  }
})

test("mounting does nothing without a matching fragment or row", () => {
  const other = row()

  const noHash = threadWith({105: other}, "")
  noHash.hook.mounted()
  assert.deepEqual(noHash.queries, [])

  const missing = threadWith({105: other}, "#comment-999")
  missing.hook.mounted()
  assert.equal(other.scrolled, null)
  assert.equal(missing.frames.length, 0)
})
