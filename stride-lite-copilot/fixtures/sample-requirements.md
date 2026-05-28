# Real-time notifications for board comments

## Goal

Add real-time notifications so users see new comments on boards they follow without refreshing the page.

## Problem

Today, comments on a board only become visible when the user navigates away and back, or hits refresh. Users frequently miss timely feedback during async review sessions because they don't notice that a teammate has replied. This costs ~15 minutes per missed comment in delayed response time, and active reviewers report it as the top source of "did I miss something?" anxiety in support tickets.

## Outcome

A user with a board open sees new comments appear in the comment thread within 2 seconds of the comment being created by anyone else, without taking any action. Comments authored by the user themselves do not produce a notification — that would be noise.

## Assumptions

1. The application already uses Phoenix LiveView for the board view, so a PubSub broadcast can drive the live update without adding a new transport layer. (Riskiest — if false, the work doubles.)
2. The comment count visible in the header should increment alongside the live insertion in the thread.
3. Users on the same board across multiple browser tabs should each see the notification independently.

## Constraints

- Must not break existing comment-creation behavior in tests.
- Must not introduce a polling loop — push only.
- Must respect the existing per-user authorization on the board (do not broadcast to users who cannot read the board).

## Non-goals

- Mobile push notifications. Out of scope for this iteration.
- Email digest of unread comments. Out of scope.
- Notifications on board-level events other than comments (e.g., card moves, status changes). Out of scope.

## Success metrics

- **Leading:** PubSub broadcast count per minute during a peak review session is non-zero and matches the comment-create rate within 5%.
- **Lagging:** "Missed comment" complaints in support tickets drop by >50% in the 30 days after release vs. the 30 days before.
