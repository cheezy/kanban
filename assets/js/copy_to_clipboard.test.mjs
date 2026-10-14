// Unit tests for copy_to_clipboard.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test} from "node:test"
import assert from "node:assert/strict"

import {copyText, showOutcome, install} from "./copy_to_clipboard.js"

function status(id) {
  return {id, visible: null}
}

function documentWith(elements) {
  return {getElementById: (id) => elements[id] || null}
}

const setVisible = (el, visible) => { el.visible = visible }

function fakeWindow(navigator) {
  const listeners = {}
  return {
    navigator,
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    fire: (type, event) => Promise.all((listeners[type] || []).map((fn) => fn(event)))
  }
}

function clipboard(writeText) {
  return {clipboard: {writeText}}
}

test("copyText resolves true when the browser accepts the text", async () => {
  const written = []
  const nav = clipboard((text) => { written.push(text); return Promise.resolve() })
  assert.equal(await copyText(nav, "whsec_abc"), true)
  assert.deepEqual(written, ["whsec_abc"])
})

test("copyText resolves false when the browser refuses", async () => {
  const nav = clipboard(() => Promise.reject(new Error("NotAllowedError: Document is not focused")))
  assert.equal(await copyText(nav, "whsec_abc"), false)
})

test("copyText resolves false when writeText throws instead of rejecting", async () => {
  const nav = clipboard(() => { throw new Error("boom") })
  assert.equal(await copyText(nav, "whsec_abc"), false)
})

test("copyText resolves false without a clipboard (plain-http page)", async () => {
  assert.equal(await copyText({}, "whsec_abc"), false)
  assert.equal(await copyText(undefined, "whsec_abc"), false)
  assert.equal(await copyText({clipboard: {}}, "whsec_abc"), false)
})

test("showOutcome shows copied and hides failed after a copy", () => {
  const ok = status("ok")
  const fail = status("fail")
  showOutcome(documentWith({ok, fail}), {copied: "ok", failed: "fail"}, true, setVisible)
  assert.equal(ok.visible, true)
  assert.equal(fail.visible, false)
})

test("showOutcome shows failed and hides copied after a refusal", () => {
  const ok = status("ok")
  const fail = status("fail")
  showOutcome(documentWith({ok, fail}), {copied: "ok", failed: "fail"}, false, setVisible)
  assert.equal(ok.visible, false)
  assert.equal(fail.visible, true)
})

test("showOutcome ignores a missing element or a malformed detail", () => {
  const ok = status("ok")
  showOutcome(documentWith({ok}), {copied: "ok", failed: "gone"}, false, setVisible)
  assert.equal(ok.visible, false)
  showOutcome(documentWith({ok}), null, true, setVisible)
  showOutcome(documentWith({ok}), {copied: 5}, true, setVisible)
  assert.equal(ok.visible, false)
})

test("install copies the target's trimmed text and reports the outcome", async () => {
  const written = []
  const win = fakeWindow(clipboard((text) => { written.push(text); return Promise.resolve() }))
  const ok = status("ok")
  const fail = status("fail")
  install(win, documentWith({ok, fail}), setVisible)

  await win.fire("stride:copy", {
    target: {textContent: "  whsec_abc\n"},
    detail: {copied: "ok", failed: "fail"}
  })

  assert.deepEqual(written, ["whsec_abc"])
  assert.equal(ok.visible, true)
  assert.equal(fail.visible, false)
})

test("install shows the failure when the clipboard refuses", async () => {
  const win = fakeWindow(clipboard(() => Promise.reject(new Error("denied"))))
  const ok = status("ok")
  const fail = status("fail")
  install(win, documentWith({ok, fail}), setVisible)

  await win.fire("stride:copy", {target: {textContent: "x"}, detail: {copied: "ok", failed: "fail"}})

  assert.equal(ok.visible, false)
  assert.equal(fail.visible, true)
})
