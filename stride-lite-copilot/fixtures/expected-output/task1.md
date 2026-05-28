# Emit PubSub broadcast on comment insert in Kanban.Comments

> Type: work · Complexity: small · Priority: medium

## Description

After a successful comment insert in `Kanban.Comments.create_comment/2`, broadcast a `{:new_comment, comment}` message on the `"board:#{board_id}"` PubSub topic. The broadcast happens inside the context module so downstream consumers (LiveViews, future websocket clients) don't need to know about the comment insertion mechanics.

## Why

Without the broadcast, the LiveView in the next task has nothing to react to — every other piece of the live-update flow depends on this signal existing.

## What

Add a `Phoenix.PubSub.broadcast/3` call after the successful changeset insert in `create_comment/2`, with topic `"board:#{comment.board_id}"` and payload `{:new_comment, comment}`. The broadcast must NOT fire on insert failure (changeset errors).

## Where

`lib/kanban/comments.ex` — the `create_comment/2` function. No other files in this task.

## Acceptance criteria

`Kanban.Comments.create_comment/2` broadcasts `{:new_comment, comment}` on topic `"board:#{board_id}"` on a successful insert.
The broadcast does NOT fire when `create_comment/2` returns `{:error, changeset}`.
Existing tests for `create_comment/2` continue to pass.
A new test asserts the broadcast is received by a subscriber on the matching topic.

## Patterns to follow

Mirror the existing `Kanban.Boards.create_board/2` broadcast pattern (boards.ex:42) — same topic-string format, same `with` chain placement.
Use `Phoenix.PubSub.broadcast(Kanban.PubSub, topic, payload)` — `Kanban.PubSub` is the application's already-configured PubSub server.

## Pitfalls

- Don't broadcast on changeset errors — wrap the broadcast inside the `{:ok, comment}` arm.
- Don't broadcast the changeset; broadcast the inserted comment struct so consumers have the persisted id and timestamps.

## Security considerations

- Broadcasts must respect existing per-board read authorization — the subscriber on the LiveView side is responsible for filtering, but document the topic-naming contract here so future consumers don't assume open access.
- Do not include user PII in the broadcast payload beyond what is already in the `Comment` struct (author_id, body) — extending the payload to include email or session metadata expands the audit surface unnecessarily.

## Integration points

- `Kanban.PubSub` — the application-wide PubSub server registered in `application.ex`.
- `"board:<board_id>"` — the topic namespace shared with `Kanban.Boards.create_board/2` and (later) the BoardLive.Show subscribe.
- `Kanban.Comments.Comment` schema — the broadcast payload struct.

## Technology requirements

- `Phoenix.PubSub` (already vendored via `phoenix_pubsub` dep — no Mix.exs change needed).
- Ecto changeset success/failure tuples (`{:ok, struct}` / `{:error, changeset}`).

## Logging requirements

- No new application log lines required for this task — the broadcast itself is the signal.
- Telemetry: emit `[:kanban, :comments, :broadcast]` with measurements `%{count: 1}` and metadata `%{board_id: bid}` so the existing telemetry handler in `Kanban.Telemetry` can roll it up for the existing comment-rate dashboard.

## Key files

| File | Note |
|---|---|
| `lib/kanban/comments.ex` | Add broadcast inside the success arm of `create_comment/2` |
| `test/kanban/comments_test.exs` | Add a subscriber test asserting the broadcast fires |

## Verification steps

1. **command** — `mix test test/kanban/comments_test.exs` → expected: all tests pass, including the new broadcast assertion
2. **command** — `mix test` → expected: full suite green
3. **manual** — Open two iex sessions, subscribe to `"board:1"` in one, call `Kanban.Comments.create_comment/2` from the other, observe the message arrive → expected: subscriber receives `{:new_comment, %Kanban.Comments.Comment{...}}`

## Testing strategy

- **Coverage target:** 100% for the modified `create_comment/2` clause
- **Unit tests:**
  - Subscribe to the topic, insert a valid comment, assert the message is received within 100ms
  - Subscribe to the topic, attempt insert with an invalid changeset, assert no message is received within 100ms
- **Integration tests:**
  - (none for this task — the LiveView wiring task adds the integration coverage)
- **Manual tests:**
  - Two-iex-session verification described above
- **Edge cases:**
  - Comment insert fails — no broadcast
  - Two comments inserted rapidly — both broadcasts delivered in order
