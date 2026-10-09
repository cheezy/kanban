// Unit tests for focus_after_move.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test} from "node:test"
import assert from "node:assert/strict"

import {focusTarget, holdFocus, install} from "./focus_after_move.js"

const body = {tagName: "BODY"}
let doc

function focusable(id) {
  const el = {id, focused: false, isConnected: true}
  el.focus = () => {
    el.focused = true
    if (doc) doc.activeElement = el
  }
  return el
}

function documentWith(elements) {
  doc = {getElementById: (id) => elements[id] || null, body, activeElement: body}
  return doc
}

function card(control) {
  return {querySelector: () => control}
}

function fakeWindow() {
  const listeners = {}
  const frames = []
  return {
    listeners,
    frames,
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    setTimeout: (fn) => frames.push(fn),
    fire: (type, event = {}) => (listeners[type] || []).forEach((fn) => fn(event)),
    runFrame: () => frames.shift()?.()
  }
}

test("focusTarget prefers the next arrow", () => {
  const next = focusable("move-to-ready-2")
  const doc = documentWith({"move-to-ready-2": next, "task-1": card(focusable("edit"))})
  assert.equal(focusTarget(doc, {to: "move-to-ready-2", fallback: "task-1"}), next)
})

test("focusTarget falls back to the moved card's first control", () => {
  const edit = focusable("edit")
  const doc = documentWith({"task-1": card(edit)})
  assert.equal(focusTarget(doc, {to: null, fallback: "task-1"}), edit)
  assert.equal(focusTarget(doc, {to: "move-to-ready-9", fallback: "task-1"}), edit)
})

test("focusTarget returns null for a missing card or a malformed detail", () => {
  const doc = documentWith({})
  assert.equal(focusTarget(doc, {to: null, fallback: "task-1"}), null)
  assert.equal(focusTarget(doc, null), null)
  assert.equal(focusTarget(doc, {to: 5, fallback: {}}), null)
})

test("install moves focus after keyboard input", () => {
  const next = focusable("move-to-ready-2")
  const win = fakeWindow()
  install(win, documentWith({"move-to-ready-2": next}))

  win.fire("keydown")
  win.fire("phx:move_to_ready:focus", {detail: {to: "move-to-ready-2", fallback: "task-1"}})

  assert.equal(next.focused, true)
})

test("install leaves focus alone after a pointer click", () => {
  const next = focusable("move-to-ready-2")
  const win = fakeWindow()
  install(win, documentWith({"move-to-ready-2": next}))

  win.fire("keydown")
  win.fire("pointerdown")
  win.fire("phx:move_to_ready:focus", {detail: {to: "move-to-ready-2", fallback: "task-1"}})

  assert.equal(next.focused, false)
})

const detail = {to: "move-to-ready-2", fallback: "task-1"}

test("holdFocus puts focus back after a patch drops it to the body", () => {
  const win = fakeWindow()
  const next = focusable("move-to-ready-2")
  documentWith({"move-to-ready-2": next})
  let t = 0

  holdFocus(win, doc, detail, () => t)
  assert.equal(doc.activeElement, next)

  doc.activeElement = body
  t = 100
  win.runFrame()

  assert.equal(doc.activeElement, next)
})

test("holdFocus finds a re-created target instead of the detached one", () => {
  const win = fakeWindow()
  const oldEdit = focusable("edit-old")
  const elements = {"task-1": card(oldEdit)}
  documentWith(elements)

  holdFocus(win, doc, {to: null, fallback: "task-1"}, () => 0)
  assert.equal(doc.activeElement, oldEdit)

  oldEdit.isConnected = false
  const newEdit = focusable("edit-new")
  elements["task-1"] = card(newEdit)
  win.runFrame()

  assert.equal(doc.activeElement, newEdit)
})

test("holdFocus stops once the user focuses something else", () => {
  const win = fakeWindow()
  const next = focusable("move-to-ready-2")
  const elsewhere = focusable("board-search")
  documentWith({"move-to-ready-2": next})

  holdFocus(win, doc, detail, () => 0)
  elsewhere.focus()
  win.runFrame()

  assert.equal(doc.activeElement, elsewhere)
  assert.equal(win.frames.length, 0)
})

test("holdFocus gives up after its window", () => {
  const win = fakeWindow()
  const next = focusable("move-to-ready-2")
  documentWith({"move-to-ready-2": next})
  let t = 0

  holdFocus(win, doc, detail, () => t)
  t = 1000
  win.runFrame()
  assert.equal(win.frames.length, 0)
})

test("holdFocus with nothing to focus leaves the page alone", () => {
  const win = fakeWindow()
  documentWith({})
  holdFocus(win, doc, detail, () => 0)
  win.runFrame()
  assert.equal(doc.activeElement, body)
})
