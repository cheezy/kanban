// Unit tests for auto-dismiss-flash.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test, beforeEach, afterEach, mock} from "node:test"
import assert from "node:assert/strict"

import AutoDismissFlash, {DISMISS_AFTER_MS} from "./auto-dismiss-flash.js"

let hook
let clicks
let handlers

function mountHook(id, text) {
  clicks = 0
  handlers = {}

  hook = Object.create(AutoDismissFlash)
  hook.el = {id, innerText: text, click: () => { clicks += 1 }}
  hook.handleEvent = (event, callback) => { handlers[event] = callback }
  hook.mounted()
}

beforeEach(() => mock.timers.enable({apis: ["setTimeout"]}))
afterEach(() => mock.timers.reset())

test("dismisses an info flash after the delay", () => {
  mountHook("flash-info", "Saved.")

  mock.timers.tick(DISMISS_AFTER_MS - 1)
  assert.equal(clicks, 0)

  mock.timers.tick(1)
  assert.equal(clicks, 1)
})

test("restarts the delay when a new message replaces the text", () => {
  mountHook("flash-info", "Org-admin appointed.")
  mock.timers.tick(3000)

  hook.el.innerText = "Org-admin removed."
  hook.updated()

  mock.timers.tick(DISMISS_AFTER_MS - 1)
  assert.equal(clicks, 0)

  mock.timers.tick(1)
  assert.equal(clicks, 1)
})

test("an update with the same text keeps the original deadline", () => {
  mountHook("flash-info", "Saved.")
  mock.timers.tick(3000)

  hook.updated()

  mock.timers.tick(DISMISS_AFTER_MS - 3000)
  assert.equal(clicks, 1)
})

test("restarts the delay when the server says the same message was shown again", () => {
  mountHook("flash-info", "Org-admin appointed.")
  mock.timers.tick(3000)

  handlers["flash:shown"]({kind: "info"})

  mock.timers.tick(DISMISS_AFTER_MS - 1)
  assert.equal(clicks, 0)

  mock.timers.tick(1)
  assert.equal(clicks, 1)
})

test("ignores a flash:shown event for another kind", () => {
  mountHook("flash-info", "Saved.")
  mock.timers.tick(3000)

  handlers["flash:shown"]({kind: "error"})

  mock.timers.tick(DISMISS_AFTER_MS - 3000)
  assert.equal(clicks, 1)
})

test("destroyed cancels the pending dismissal", () => {
  mountHook("flash-info", "Saved.")

  hook.destroyed()
  mock.timers.tick(DISMISS_AFTER_MS * 2)

  assert.equal(clicks, 0)
})
