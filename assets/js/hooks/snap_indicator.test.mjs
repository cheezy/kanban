// Unit tests for snap_indicator.js, run with `node --test` (no npm
// dependencies). test/kanban_web/js_hooks_test.exs runs this file as part of
// `mix test` whenever node is installed.
import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"

import SnapIndicator from "./snap_indicator.js"

let observers

function classList(initial) {
  const classes = new Set(initial)
  return {
    add: (name) => classes.add(name),
    remove: (name) => classes.delete(name),
    contains: (name) => classes.has(name)
  }
}

function dot(columnId) {
  return {dataset: {indicatorDot: columnId}, classList: classList(["opacity-30"])}
}

function column(columnId) {
  return {dataset: {columnId}}
}

beforeEach(() => {
  observers = []

  globalThis.IntersectionObserver = class {
    constructor(callback) {
      this.callback = callback
      this.observed = new Set()
      observers.push(this)
    }

    observe(el) { this.observed.add(el) }
    disconnect() { this.observed.clear() }
  }
})

function mountHook(columnIds) {
  const container = {children: columnIds.map(column)}
  globalThis.document = {getElementById: (id) => (id === "columns" ? container : null)}

  const hook = Object.create(SnapIndicator)
  hook.dots = columnIds.map(dot)
  hook.el = {
    dataset: {targetId: "columns"},
    querySelectorAll: () => hook.dots
  }
  hook.mounted()
  return {hook, container, observer: observers[0]}
}

function scrollTo(observer, container, visibleId) {
  observer.callback(
    container.children.map((col) => ({
      target: col,
      intersectionRatio: col.dataset.columnId === visibleId ? 1 : 0
    }))
  )
}

function activeDots(hook) {
  return hook.dots
    .filter((d) => d.classList.contains("opacity-100"))
    .map((d) => d.dataset.indicatorDot)
}

test("the most visible column's dot is the active one", () => {
  const {hook, container, observer} = mountHook(["1", "2", "3"])

  scrollTo(observer, container, "2")

  assert.deepEqual(activeDots(hook), ["2"])
})

test("updated() marks the active dot again after a patch re-renders the dots", () => {
  const {hook, container, observer} = mountHook(["1", "2", "3"])
  scrollTo(observer, container, "2")

  hook.dots = ["1", "2", "3"].map(dot)
  hook.updated()

  assert.deepEqual(activeDots(hook), ["2"])
})

test("updated() observes a newly streamed column", () => {
  const {hook, container, observer} = mountHook(["1", "2"])
  const added = column("3")
  container.children.push(added)

  hook.updated()

  assert.ok(observer.observed.has(added))
})

test("updated() forgets a removed column, so its stale visibility cannot win", () => {
  const {hook, container, observer} = mountHook(["1", "2"])
  scrollTo(observer, container, "2")
  hook.visibilityByColumn["1"] = 0.4

  container.children = [column("1")]
  hook.dots = [dot("1")]
  hook.updated()

  assert.deepEqual(activeDots(hook), ["1"])
})

test("updated() before any intersection leaves every dot dim", () => {
  const {hook} = mountHook(["1", "2"])

  hook.updated()

  assert.deepEqual(activeDots(hook), [])
})
