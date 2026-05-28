# Add real-time notifications for board comments

## Why

Today, comments on a board only become visible after a manual refresh; users miss timely feedback during async review and consistently report this as the top "did I miss something?" friction in support tickets. Closing the loop with a live update preserves the async review workflow that already works while removing the manual-refresh failure mode.

## What

Broadcast a PubSub event whenever a comment is created on a board, and have the LiveView mounted on that board append the new comment to the thread and increment the header comment count. Suppress the notification for the comment's own author so users do not get echoed.

## Description

Wires a PubSub broadcast on comment insert through to the LiveView showing the board, so any user with the board open sees the new comment within two seconds without taking action. The broadcast respects existing per-user board authorization — only users who could already read the comment receive the live update.

## Acceptance criteria

A user with the board open sees a comment authored by another user appear in the comment thread within 2 seconds, with no manual refresh.
The header comment count increments alongside the live insertion.
Comments authored by the viewing user themselves do NOT trigger a notification.
Existing comment-creation tests continue to pass without modification.
The broadcast respects board-level read authorization — users without access do not receive the live update.

## Pitfalls

- Don't introduce a polling loop — push-only via PubSub.
- Don't broadcast to users who cannot read the board — respect the existing authorization plug.
- Don't include the comment's own author in the broadcast recipients.

## Decomposition notes

Three-task seam split along data → context → UI: schema/migration is unchanged here (comments table already exists), so the seams are (1) broadcast emission inside the context module, (2) LiveView subscribe + handle_info wiring, and (3) the heex template update that renders the new entry. The three tasks are dependency-ordered.

## Tasks

1. [Emit PubSub broadcast on comment insert in Kanban.Comments](task1.md)

> Note: a real run of `/stride-lite:create-goal` against `sample-requirements.md` would produce two additional sibling tasks — "Subscribe to comment broadcasts in BoardLive.Show" and "Render appended comment and updated header count in board show template" — at `task2.md` and `task3.md`. Only `task1.md` is shipped in the fixture directory to keep the example focused; the full per-task template shape is identical across all child tasks.
