// Unit tests for release_modal_focus.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test} from "node:test"
import assert from "node:assert/strict"

import {RELEASE_FOCUS_EVENT, releaseFocus, install} from "./release_modal_focus.js"

const body = {tagName: "BODY"}

function field() {
  const el = {blurred: false}
  el.blur = () => { el.blurred = true }
  return el
}

// A modal that "contains" exactly the nodes it is given.
function modalWith(...nodes) {
  return {contains: (node) => nodes.includes(node)}
}

function selectionAt(anchorNode, rangeCount = 1) {
  const sel = {anchorNode, rangeCount, cleared: false}
  sel.removeAllRanges = () => { sel.cleared = true }
  return sel
}

function fakeWindow(selection = selectionAt(null, 0)) {
  const listeners = {}
  return {
    listeners,
    getSelection: () => selection,
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    fire: (type, event) => (listeners[type] || []).forEach((fn) => fn(event))
  }
}

test("releaseFocus blurs a focused field inside the modal and clears the selection", () => {
  const input = field()
  const selection = selectionAt(input)
  const doc = {body, activeElement: input}

  assert.equal(releaseFocus(fakeWindow(selection), doc, modalWith(input)), true)
  assert.equal(input.blurred, true)
  assert.equal(selection.cleared, true)
})

test("releaseFocus leaves focus and selection outside the modal alone", () => {
  const outside = field()
  const selection = selectionAt(outside)
  const doc = {body, activeElement: outside}

  assert.equal(releaseFocus(fakeWindow(selection), doc, modalWith(field())), false)
  assert.equal(outside.blurred, false)
  assert.equal(selection.cleared, false)
})

test("releaseFocus clears a selection inside the modal when focus is on the body", () => {
  const text = {}
  const selection = selectionAt(text)
  const doc = {body, activeElement: body}

  assert.equal(releaseFocus(fakeWindow(selection), doc, modalWith(text, body)), true)
  assert.equal(selection.cleared, true)
})

test("releaseFocus does nothing with no focus, no selection or no modal", () => {
  const doc = {body, activeElement: null}
  assert.equal(releaseFocus(fakeWindow(selectionAt(null, 0)), doc, modalWith()), false)
  assert.equal(releaseFocus({}, {body, activeElement: body}, modalWith()), false)
  assert.equal(releaseFocus(fakeWindow(), doc, null), false)
  assert.equal(releaseFocus(fakeWindow(), doc, {}), false)
})

test("install releases focus when the modal dispatches the event", () => {
  const input = field()
  const selection = selectionAt(input)
  const win = fakeWindow(selection)
  install(win, {body, activeElement: input})

  win.fire(RELEASE_FOCUS_EVENT, {target: modalWith(input)})

  assert.equal(RELEASE_FOCUS_EVENT, "stride:release-focus")
  assert.equal(input.blurred, true)
  assert.equal(selection.cleared, true)
})
