// Unit tests for the pure helpers of mention_autocomplete.js, run with
// `node --test` (no npm dependencies). test/kanban_web/js_hooks_test.exs runs
// this file as part of `mix test` whenever node is installed.
import {test} from "node:test"
import assert from "node:assert/strict"

import {findTrigger, sanitizeMembers, mentionToken, placeAbove} from "./mention_autocomplete.js"

const at = value => findTrigger(value, value.length)

test("an @ at the start of the text or after whitespace triggers with the typed query", () => {
  assert.deepEqual(at("@gr"), {start: 0, query: "gr"})
  assert.deepEqual(at("hi @ad"), {start: 3, query: "ad"})
  assert.deepEqual(at("line\n@ad"), {start: 5, query: "ad"})
  assert.deepEqual(at("hi @"), {start: 3, query: ""})
  assert.deepEqual(at("@grace ho"), {start: 0, query: "grace ho"})
})

test("an @ typed inside an email address mid-word never triggers", () => {
  assert.equal(at("mail ada@ex"), null)
  assert.equal(at("bob@"), null)
})

test("the trigger is the last @ before the caret, and the query ends at the caret", () => {
  assert.deepEqual(at("@ad and @bo"), {start: 8, query: "bo"})
  assert.deepEqual(findTrigger("@ad and more", 3), {start: 0, query: "ad"})
})

test("a caret inside or just after an inserted token does not re-trigger", () => {
  assert.equal(at("x @[Grace Hopper](user:7) "), null)
  assert.equal(at("x @[ada@b.c](user:7) "), null)
  assert.equal(at("x @[Ann @Bo](user:7) "), null)
})

test("a newline, a leading or doubled space, or an over-long query ends the trigger", () => {
  assert.equal(at("@gr\nx"), null)
  assert.equal(at("@ gr"), null)
  assert.equal(at("@grace  "), null)
  assert.equal(at("@" + "a".repeat(51)), null)
  assert.deepEqual(at("@" + "a".repeat(50)), {start: 0, query: "a".repeat(50)})
})

test("sanitizeMembers keeps at most eight well-formed members", () => {
  const reply = {
    members: [
      {id: 1, label: "Ada"},
      {id: "2", label: "Bo"},
      {id: 3, label: ""},
      null,
      {id: -1, label: "X"},
      {id: 4.5, label: "Y"},
      {id: 5, label: 7},
    ],
  }

  assert.deepEqual(sanitizeMembers(reply), [{id: 1, label: "Ada"}])

  const many = {members: Array.from({length: 12}, (_, i) => ({id: i + 1, label: `M${i}`}))}
  assert.equal(sanitizeMembers(many).length, 8)
})

test("sanitizeMembers turns a malformed reply into an empty list", () => {
  assert.deepEqual(sanitizeMembers(null), [])
  assert.deepEqual(sanitizeMembers({}), [])
  assert.deepEqual(sanitizeMembers({members: "x"}), [])
})

test("mentionToken builds the canonical token followed by a space", () => {
  assert.equal(mentionToken({id: 7, label: "Grace Hopper"}), "@[Grace Hopper](user:7) ")
})

test("placeAbove opens upward only when there is no room below but room above", () => {
  // Field near the bottom of an 800px viewport, 200px list: no room below, room above.
  assert.equal(placeAbove(700, 760, 200, 800), true)
  // Plenty of room below.
  assert.equal(placeAbove(100, 160, 200, 800), false)
  // No room below, but no room above either: stay below.
  assert.equal(placeAbove(150, 760, 200, 800), false)
})
