// Unit tests for analytics.js, run with `node --test` (no npm dependencies).
// test/kanban_web/js_hooks_test.exs runs this file as part of `mix test`
// whenever node is installed.
import {test} from "node:test"
import assert from "node:assert/strict"

import {
  umamiTrack,
  stripQuery,
  beforeSend,
  installCommandFor,
  onCopy,
  signupHook,
  install
} from "./analytics.js"

function tracker() {
  const calls = []
  return {calls, track: (...args) => { calls.push(args) }}
}

// A minimal element: closest() walks parentElement looking for the attribute.
function element(attrs = {}, parent = null) {
  const el = {
    nodeType: 1,
    parentElement: parent,
    attrs,
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    closest(selector) {
      const wanted = selector.replace(/^\[|\]$/g, "")
      for (let node = el; node; node = node.parentElement) {
        if (wanted in node.attrs) return node
      }
      return null
    }
  }
  return el
}

function textIn(el) {
  return {nodeType: 3, parentElement: el}
}

function fakeWindow({umami, selection} = {}) {
  return {umami, getSelection: () => selection || null}
}

function fakeDocument() {
  const listeners = {}
  return {
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    fire: (type, event) => (listeners[type] || []).map((fn) => fn(event))
  }
}

test("umamiTrack sends the event and its data when the tracker loaded", () => {
  const umami = tracker()
  assert.equal(umamiTrack({umami}, "signup"), true)
  assert.equal(umamiTrack({umami}, "install-command-copied", {runtime: "codex"}), true)
  assert.deepEqual(umami.calls, [["signup"], ["install-command-copied", {runtime: "codex"}]])
})

test("umamiTrack does nothing when the tracker is missing or blocked", () => {
  assert.equal(umamiTrack({}, "signup"), false)
  assert.equal(umamiTrack(undefined, "signup"), false)
  assert.equal(umamiTrack({umami: {}}, "signup"), false)
})

test("umamiTrack swallows an error thrown by the tracker", () => {
  const umami = {track: () => { throw new Error("blocked") }}
  assert.equal(umamiTrack({umami}, "signup"), false)
})

test("stripQuery drops the query string and the fragment", () => {
  assert.equal(stripQuery("https://h.test/users/confirmation-pending?email=a%40b.test"),
    "https://h.test/users/confirmation-pending")
  assert.equal(stripQuery("/users/register?invitation_token=abc#top"), "/users/register")
  assert.equal(stripQuery("/pricing#plans"), "/pricing")
  assert.equal(stripQuery("/pricing"), "/pricing")
  assert.equal(stripQuery(""), "")
  assert.equal(stripQuery(undefined), undefined)
})

test("beforeSend strips the url and the referrer and keeps the rest", () => {
  const payload = {
    website: "w",
    url: "/users/confirmation-pending?email=a%40b.test",
    referrer: "https://h.test/users/register?invitation_token=abc",
    name: "signup"
  }

  assert.deepEqual(beforeSend("event", payload), {
    website: "w",
    url: "/users/confirmation-pending",
    referrer: "https://h.test/users/register",
    name: "signup"
  })

  // The original payload is not mutated.
  assert.equal(payload.url, "/users/confirmation-pending?email=a%40b.test")
})

test("beforeSend passes a payload without url or referrer through", () => {
  assert.deepEqual(beforeSend("event", {name: "x"}), {name: "x"})
  assert.equal(beforeSend("event", null), null)
})

test("installCommandFor finds the command from the event target or the selection", () => {
  const command = element({"data-install-command": "", "data-runtime": "codex"})
  const outside = element({})

  assert.equal(installCommandFor(fakeWindow(), {target: textIn(command)}), command)
  assert.equal(
    installCommandFor(fakeWindow({selection: {anchorNode: textIn(command), focusNode: null}}),
      {target: outside}),
    command
  )
  assert.equal(
    installCommandFor(fakeWindow({selection: {anchorNode: textIn(outside), focusNode: textIn(command)}}),
      {target: null}),
    command
  )
  assert.equal(installCommandFor(fakeWindow({selection: {anchorNode: textIn(outside)}}), {target: outside}), null)
  assert.equal(installCommandFor(fakeWindow(), {target: outside}), null)
})

test("the copy listener sends install-command-copied with the runtime slug", () => {
  const umami = tracker()
  const command = element({"data-install-command": "", "data-runtime": "codex"})
  const doc = fakeDocument()
  const win = fakeWindow({umami})

  install(win, doc)
  doc.fire("copy", {target: textIn(command)})

  assert.deepEqual(umami.calls, [["install-command-copied", {runtime: "codex"}]])
})

test("a copy outside an install command sends nothing", () => {
  const umami = tracker()
  const doc = fakeDocument()
  install(fakeWindow({umami}), doc)

  doc.fire("copy", {target: element({})})

  assert.deepEqual(umami.calls, [])
})

test("a runtime value that is not a slug is never sent", () => {
  const umami = tracker()
  const win = fakeWindow({umami})

  for (const runtime of [null, "", "Codex", "a b", "x@y.test", "a".repeat(41)]) {
    const attrs = {"data-install-command": ""}
    if (runtime !== null) attrs["data-runtime"] = runtime
    assert.equal(onCopy(win, {target: element(attrs)}), false)
  }

  assert.deepEqual(umami.calls, [])
})

test("the copy listener does nothing when the tracker is missing", () => {
  const command = element({"data-install-command": "", "data-runtime": "codex"})
  const doc = fakeDocument()
  install(fakeWindow(), doc)

  assert.deepEqual(doc.fire("copy", {target: command}), [false])
})

test("install registers the data-before-send hook on the window", () => {
  const win = fakeWindow()
  install(win, fakeDocument())
  assert.equal(win.strideAnalyticsBeforeSend, beforeSend)
})

test("the signup hook sends the signup event once per page load", () => {
  const umami = tracker()
  const win = {umami}
  const state = {sent: false}

  signupHook(win, state).mounted()
  // A LiveView reconnect mounts a new hook instance on the same page.
  signupHook(win, state).mounted()
  const hook = signupHook(win, state)
  hook.mounted()
  hook.mounted()

  assert.deepEqual(umami.calls, [["signup"]])
})

test("the signup hook does nothing when the tracker is missing", () => {
  const state = {sent: false}
  signupHook({}, state).mounted()
  assert.equal(state.sent, false)

  // With the default state it still sends at most once.
  const umami = tracker()
  const hook = signupHook({umami})
  hook.mounted()
  hook.mounted()
  assert.deepEqual(umami.calls, [["signup"]])
})
