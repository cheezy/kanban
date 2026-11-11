// Unit tests for theme_toggle.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"

import ThemeToggle, {currentChoice, syncPressed} from "./theme_toggle.js"

function button(theme) {
  const attributes = {}
  return {
    dataset: {phxTheme: theme},
    setAttribute: (name, value) => { attributes[name] = value },
    getAttribute: (name) => attributes[name]
  }
}

function pressed(buttons) {
  return buttons.map((b) => b.getAttribute("aria-pressed"))
}

let listeners

beforeEach(() => {
  listeners = {}
  globalThis.window = {
    addEventListener: (name, fn) => { (listeners[name] ||= new Set()).add(fn) },
    removeEventListener: (name, fn) => { listeners[name]?.delete(fn) }
  }
  globalThis.document = {documentElement: {dataset: {}}}
})

test("currentChoice keeps the three stored choices", () => {
  assert.equal(currentChoice("system"), "system")
  assert.equal(currentChoice("light"), "light")
  assert.equal(currentChoice("dark"), "dark")
})

test("currentChoice reads an absent or unknown value as system", () => {
  assert.equal(currentChoice(undefined), "system")
  assert.equal(currentChoice(""), "system")
  assert.equal(currentChoice("blue"), "system")
})

test("syncPressed marks only the current choice as pressed", () => {
  const buttons = ["system", "light", "dark"].map(button)

  syncPressed(buttons, "dark")
  assert.deepEqual(pressed(buttons), ["false", "false", "true"])

  syncPressed(buttons, "blue")
  assert.deepEqual(pressed(buttons), ["true", "false", "false"])
})

test("the hook syncs on mount, on phx:set-theme and on storage, and unbinds on destroy", () => {
  const buttons = ["system", "light", "dark"].map(button)
  const hook = Object.create(ThemeToggle)
  hook.el = {querySelectorAll: () => buttons}

  hook.mounted()
  assert.deepEqual(pressed(buttons), ["true", "false", "false"])

  document.documentElement.dataset.themeChoice = "light"
  listeners["phx:set-theme"].forEach((fn) => fn())
  assert.deepEqual(pressed(buttons), ["false", "true", "false"])

  document.documentElement.dataset.themeChoice = "dark"
  listeners.storage.forEach((fn) => fn())
  assert.deepEqual(pressed(buttons), ["false", "false", "true"])

  document.documentElement.dataset.themeChoice = "system"
  hook.updated()
  assert.deepEqual(pressed(buttons), ["true", "false", "false"])

  hook.destroyed()
  assert.equal(listeners["phx:set-theme"].size, 0)
  assert.equal(listeners.storage.size, 0)
})
