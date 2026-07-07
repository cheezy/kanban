# Security Findings — IDOR & Cross-Board Access Scoping (W1594)

> Domain 3 of the comprehensive security review (G309). Manual analysis plus an
> independent `stride-security-review` full-file pass. The HIGH finding was
> hand-verified against the current code before filing.
>
> **Verdict: one real privilege-escalation.** 0 critical · **1 high** · 0 medium ·
> 0 low · 2 boundaries verified clean.

## Surface reviewed

`boards.ex`, `tasks/queries.ex`, `tasks/goals.ex`, `messages/message.ex`,
`columns/column.ex`, `boards/board_user.ex`, `tasks/task_comment.ex`,
`board_live/show.ex`, `task_live/form_component.ex`, `board_live/authorization.ex`.

## D110 — task create/edit save path lacks modify-access authorization (HIGH)

**Verified.** The task FormComponent `save` path performs no user modify-access check:

- `handle_event("save")` (`form_component.ex:101`) → `save_task/3` only validates
  that relational fields (`column_id`/`parent_id`/`assigned_to_id`) live on the
  board — it never checks `Boards.can_modify?`.
- The `handle_params` resolve paths for `:new_task`/`:edit_task`/`:edit_task_in_column`
  (`show.ex` `resolve_task_only`, `resolve_column_and_task`, `assign_board_with_column`)
  verify the task/column belongs to the board but **do not gate on `user_access`** —
  unlike delete/move, which route through `Authorization.authorize_modify_for_task`
  (which checks `can_modify`).
- `Tasks.create_task`/`update_task` perform no access check.

**Attack path:** an authenticated `:read_only` member — or, on a public
`read_only` board, an authenticated **non-member** (nil access, granted read via
`Boards.get_board`) — opens `/boards/:id/tasks/:task_id/edit`, the FormComponent
mounts, and pushes a `save` event over the websocket (independent of whether a
submit button renders), persisting the create/edit. **Write privilege escalation
from read-only** (CWE-862). Cross-board access remains blocked (`get_task_for_board`
scoping) and delete/move stay gated — hence HIGH, not critical.

**Fix (D110, needs_review):** gate the `save` handle_event on
`Boards.can_modify?(board, user)` server-side, and gate the task-form
`handle_params` actions on `user_access in [:owner, :modify]` so read-only users
are redirected before the form renders.

## D111 — TaskComment casts `:task_id` (low, defense-in-depth)

`TaskComment.changeset` casts `:task_id` from attrs (mass-assignment surface).
Clean in current code — the only caller `do_add_comment/2` overwrites `task_id`
with the server-held task and `commenter_authorized?/1` requires membership — but
set it server-side so a future caller can't inherit an unscoped `task_id`.

## Verified-clean boundaries

- **`boards.ex` scoping:** `get_board/2` returns `{:error, :not_found}` for
  non-members unless `read_only`; `update_board`/`delete_board`/`add_user_to_board`/
  `remove_user_from_board`/`update_user_access`/`update_field_visibility` all
  re-check `owner?/2` server-side. `BoardUser` mass-assignment not reachable with
  attacker-controlled values.
- **D93/D94 hold:** `Column` does not cast `board_id` (`column.ex`), `Message`
  does not cast `sender_id` (`message.ex`).
- Most mutating `handle_event`s (archive, delete, move, promote, column ops,
  tokens, field toggle) correctly re-check via `BoardLive.Authorization`.
