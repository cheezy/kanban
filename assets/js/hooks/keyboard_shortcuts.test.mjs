// Unit tests for keyboard_shortcuts.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"

import KeyboardShortcuts, {isEditableTarget, shortcutFor, otherDialogOpen} from "./keyboard_shortcuts.js"

const body = {tagName: "BODY"}

function keydown(key, overrides = {}) {
  let prevented = false
  return {
    key,
    target: body,
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    shiftKey: key === "?",
    repeat: false,
    isComposing: false,
    defaultPrevented: false,
    preventDefault() { prevented = true },
    get prevented() { return prevented },
    ...overrides
  }
}

// A minimal window/document pair: records keydown listeners, and resolves the
// search input, the help overlay and any open dialogs from `state`.
let state
let listeners

beforeEach(() => {
  listeners = new Set()
  state = {search: null, helpOpen: false, dialogs: [], active: body}

  globalThis.window = {
    addEventListener: (type, fn) => { if (type === "keydown") listeners.add(fn) },
    removeEventListener: (type, fn) => { if (type === "keydown") listeners.delete(fn) }
  }

  globalThis.document = {
    getElementById: (id) => {
      if (id === "board-search") return state.search
      if (id === "keyboard-shortcuts-help") return state.helpOpen ? {id} : null
      return null
    },
    querySelectorAll: () => state.dialogs,
    get activeElement() { return state.active },
    body
  }
})

const PUSH_FOCUS = '[["push_focus",{}]]'

function mountHook(selectedCount = "0", pushFocus = PUSH_FOCUS) {
  const pushed = []
  const executed = []
  const hook = Object.create(KeyboardShortcuts)
  hook.el = {dataset: pushFocus ? {selectedCount, pushFocus} : {selectedCount}}
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  hook.liveSocket = {execJS: (el, js) => executed.push([el, js])}
  hook.mounted()
  return {hook, pushed, executed}
}

function press(event) {
  for (const fn of listeners) fn(event)
  return event
}

function searchInput() {
  const input = {tagName: "INPUT", type: "search", focused: false}
  input.focus = () => { input.focused = true }
  return input
}

function dialog({shown = true, insideHelp = false} = {}) {
  return {
    getClientRects: () => (shown ? [{}] : []),
    closest: () => (insideHelp ? {} : null)
  }
}

test("isEditableTarget treats text fields, selects and contenteditable as typing", () => {
  for (const target of [
    {tagName: "INPUT"},
    {tagName: "INPUT", type: "text"},
    {tagName: "INPUT", type: "search"},
    {tagName: "input", type: "email"},
    {tagName: "TEXTAREA"},
    {tagName: "SELECT"},
    {tagName: "DIV", isContentEditable: true}
  ]) {
    assert.equal(isEditableTarget(target), true, JSON.stringify(target))
  }
})

test("isEditableTarget lets shortcuts through on non-text controls and the page", () => {
  for (const target of [
    body,
    {tagName: "BUTTON"},
    {tagName: "INPUT", type: "checkbox"},
    {tagName: "INPUT", type: "radio"},
    {tagName: "A"},
    null,
    undefined
  ]) {
    assert.equal(isEditableTarget(target), false, JSON.stringify(target))
  }
})

test("shortcutFor maps /, ? and Escape and nothing else", () => {
  assert.equal(shortcutFor(keydown("/")), "focus_search")
  assert.equal(shortcutFor(keydown("?")), "toggle_help")
  assert.equal(shortcutFor(keydown("Escape")), "escape")
  for (const key of ["a", "Enter", "k", " ", "Tab"]) {
    assert.equal(shortcutFor(keydown(key)), null, key)
  }
})

test("shortcutFor ignores keys while Ctrl, Meta or Alt is held, but not Shift", () => {
  for (const modifier of ["ctrlKey", "metaKey", "altKey"]) {
    for (const key of ["/", "?", "Escape"]) {
      assert.equal(shortcutFor(keydown(key, {[modifier]: true})), null, `${modifier}+${key}`)
    }
  }
  assert.equal(shortcutFor(keydown("?", {shiftKey: true})), "toggle_help")
})

test("shortcutFor ignores keys typed into a text field, select or contenteditable", () => {
  for (const target of [
    {tagName: "INPUT", type: "search"},
    {tagName: "TEXTAREA"},
    {tagName: "SELECT"},
    {tagName: "DIV", isContentEditable: true}
  ]) {
    for (const key of ["/", "?", "Escape"]) {
      assert.equal(shortcutFor(keydown(key, {target})), null, `${key} in ${target.tagName}`)
    }
  }
})

test("shortcutFor ignores repeats, IME composition and already-handled events", () => {
  assert.equal(shortcutFor(keydown("?", {repeat: true})), null)
  assert.equal(shortcutFor(keydown("/", {isComposing: true})), null)
  assert.equal(shortcutFor(keydown("?", {defaultPrevented: true})), null)
  assert.equal(shortcutFor(null), null)
})

test("otherDialogOpen sees a visible modal but not a hidden one or the help overlay", () => {
  state.dialogs = []
  assert.equal(otherDialogOpen(document), false)
  state.dialogs = [dialog({shown: false})]
  assert.equal(otherDialogOpen(document), false)
  state.dialogs = [dialog({insideHelp: true})]
  assert.equal(otherDialogOpen(document), false)
  state.dialogs = [dialog({shown: false}), dialog()]
  assert.equal(otherDialogOpen(document), true)
})

test("/ focuses the board search without typing a slash into it", () => {
  state.search = searchInput()
  const {pushed} = mountHook()

  const event = press(keydown("/"))

  assert.equal(state.search.focused, true)
  assert.equal(event.prevented, true)
  assert.deepEqual(pushed, [])
})

test("/ does nothing on a board with no search input", () => {
  const {pushed} = mountHook()
  const event = press(keydown("/"))
  assert.equal(event.prevented, false)
  assert.deepEqual(pushed, [])
})

test("? pushes only the fixed toggle event with an empty payload", () => {
  const {pushed} = mountHook()
  const event = press(keydown("?"))
  assert.equal(event.prevented, true)
  assert.deepEqual(pushed, [["toggle_shortcuts_help", {}]])
})

test("? remembers the focused element before opening the overlay", () => {
  const toggle = {tagName: "BUTTON", id: "bulk-select-toggle"}
  state.active = toggle
  const {pushed, executed} = mountHook()

  press(keydown("?", {target: toggle}))

  assert.deepEqual(executed, [[toggle, PUSH_FOCUS]])
  assert.deepEqual(pushed, [["toggle_shortcuts_help", {}]])
})

test("? remembers nothing when focus is on the page body", () => {
  const {pushed, executed} = mountHook()
  press(keydown("?"))
  assert.deepEqual(executed, [])
  assert.deepEqual(pushed, [["toggle_shortcuts_help", {}]])
})

test("? remembers nothing when the server rendered no push-focus command", () => {
  state.active = {tagName: "BUTTON"}
  const {pushed, executed} = mountHook("0", null)
  press(keydown("?"))
  assert.deepEqual(executed, [])
  assert.deepEqual(pushed, [["toggle_shortcuts_help", {}]])
})

test("? closing the overlay does not push focus again", () => {
  state.helpOpen = true
  state.active = {tagName: "BUTTON"}
  const {pushed, executed} = mountHook()
  press(keydown("?"))
  assert.deepEqual(executed, [])
  assert.deepEqual(pushed, [["toggle_shortcuts_help", {}]])
})

test("? typed into the search box does not open the overlay", () => {
  const {pushed} = mountHook()
  const event = press(keydown("?", {target: {tagName: "INPUT", type: "search"}}))
  assert.equal(event.prevented, false)
  assert.deepEqual(pushed, [])
})

test("while the overlay is open, ? closes it and / and Escape are left to it", () => {
  state.helpOpen = true
  state.search = searchInput()
  const {pushed} = mountHook("3")

  press(keydown("/"))
  press(keydown("Escape"))
  press(keydown("?"))

  assert.equal(state.search.focused, false)
  assert.deepEqual(pushed, [["toggle_shortcuts_help", {}]])
})

test("no shortcut fires while another dialog, such as the task modal, is open", () => {
  state.dialogs = [dialog()]
  state.search = searchInput()
  const {pushed} = mountHook("2")

  for (const key of ["/", "?", "Escape"]) {
    const event = press(keydown(key))
    assert.equal(event.prevented, false, key)
  }

  assert.equal(state.search.focused, false)
  assert.deepEqual(pushed, [])
})

test("Escape clears an active selection, and does nothing without one", () => {
  const withSelection = mountHook("2")
  press(keydown("Escape"))
  assert.deepEqual(withSelection.pushed, [["bulk_clear", {}]])
  withSelection.hook.destroyed()

  const withoutSelection = mountHook("0")
  const event = press(keydown("Escape"))
  assert.equal(event.prevented, false)
  assert.deepEqual(withoutSelection.pushed, [])
})

test("destroyed() removes the keydown listener, so patches do not stack listeners", () => {
  const first = mountHook()
  assert.equal(listeners.size, 1)
  first.hook.destroyed()
  assert.equal(listeners.size, 0)

  const second = mountHook()
  press(keydown("?"))
  assert.deepEqual(first.pushed, [])
  assert.deepEqual(second.pushed, [["toggle_shortcuts_help", {}]])
  second.hook.destroyed()
  assert.equal(listeners.size, 0)
})
