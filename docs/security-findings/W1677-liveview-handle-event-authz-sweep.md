# Security Findings — LiveView `handle_event` Authorization Sweep (W1677)

> Systematic follow-up to defect D110 (the one privilege-escalation found in the
> G309 review: a task `save` `handle_event` that mutated without re-checking
> modify authorization — a read-only member could escalate to write by invoking
> the event directly over the websocket). D110 was found by chance, not by sweep.
> This task enumerates **every** `handle_event` clause in `lib/kanban_web/live/`,
> classifies each as state-changing or read-only, and verifies every
> state-changing handler re-checks authorization server-side.
>
> **Coverage:** 137 `handle_event` clauses across 23 files — 100% inventoried.
> **Verdict:** 1 high · 1 medium · 1 low · the rest clean. The high finding is a
> genuine read-only→write escalation of the exact D110 class.
>
> Method: four parallel `stride-security-review` passes (grouped by subsystem),
> each required to open the delegated context function and confirm the check
> rather than assume it; the two most severe findings then hand-verified against
> source by tracing the scope query to `BoardScope.apply_board_scope`.

## Scope and reference pattern

Handler count by group: board/column (30), task/goal/target/issue/review (24),
agents/archive/metrics/resources/admin (43), user_live auth+settings (40). The
"correct" pattern is the D110 remediation: an authoritative server-side check on
the current user (`Boards.can_modify?` / `authorize_modify_for_task` /
`board_write_access?`) performed **inside** the handler's context call — not a
mount-time check that stale socket assigns could outlive, and not UI button
hiding. Rate limiting is out of scope (owned by W1678).

## Findings filed

| ID | Defect | Sev | Handler | Summary |
|----|--------|-----|---------|---------|
| **H1** | **D138** | **HIGH** | `review_live.ex:109` `submit_request_changes` | Read-only board member can stamp `changes_requested` + arbitrary review notes on any pending task — the `board_write_access?` check is bypassed on the request-changes path |
| M1 | D139 | medium | `target_live/form.ex:51,62` `assign_goal`/`unassign_goal` | Target owner with only read-only access to a goal's board can set/clear that goal's `target_id` — write to a board resource without modify access |
| L1 | D140 | low | `column_live/form_component.ex:26` `save` | Column create/update has no authz in the handler or context; safe only because the modal never renders for non-owners — latent D110 shape with a single layer of defense |

### H1 — `submit_request_changes` bypasses the write-access check (D110 class)
`review_live.ex:109` → `Reviews.request_changes_review/3` (`reviews.ex:208`) runs
`perform_review` with `move_after_review?: false` (`reviews.ex:222`). In
`commit_review!` (`reviews.ex:258-268`) the only authorization is
`get_pending_review(scope, task.id)` (line 261), which scopes through
`BoardScope.apply_board_scope` — an inner join on `BoardUser` by `user_id` with
**no access-level filter** (`board_scope.ex:32-36`), i.e. any board *member*
including read-only. `persist_review_fields` then commits `review_status:
:changes_requested`, attacker-controlled `review_notes`, `reviewed_by_id`, and
`reviewed_at` (`reviews.ex:275-284`). `maybe_mark_reviewed(prepared, user,
false)` (`reviews.ex:273`) short-circuits to `{:ok, task}` and **never** calls
`AgentWorkflow.mark_reviewed`, which is the only place `board_write_access?`
(`agent_workflow.ex:307-314`, requires `:owner`/`:modify`) runs. The **approve**
path is safe only incidentally, because it runs with `move_after_review?: true`
and therefore reaches that check.

**Exploit:** a `:read_only` member of a board opens `/review` (the queue is
membership-scoped, so it already lists that board's pending tasks), selects a
pending task, and pushes `submit_request_changes` with a `review[notes]` string
over the websocket. The task flips to `:changes_requested` — removing it from
every reviewer's pending queue — and arbitrary reviewer notes are injected into
the agent workflow. A read-only member disrupts the board's review pipeline and
feeds instructions to the agent. (The `approve_review` docstring even advertises
`:not_authorized` "(user has read-only board access)" as an outcome — the
request-changes path never produces it.)

**Fix:** enforce `board_write_access?` on the request-changes path before
`persist_review_fields` — e.g. re-check `authorized_reviewer?` inside
`commit_review!` regardless of `move?`, or make `maybe_mark_reviewed(_, user,
false)` still assert authorization. Add a regression test: a read-only member's
`submit_request_changes` returns `{:error, :not_authorized}` and writes nothing.

### M1 — `assign_goal`/`unassign_goal` accept read-only board access
`target_live/form.ex:51,62` → `Targets.assign_goal/3` / `unassign_goal/2`
(`targets.ex:182,197`) → `fetch_scoped_task/2` (`targets.ex:508`), which scopes
the goal task via `apply_board_scope_with_column_join` — membership only, no
`:modify` (`board_scope.ex:45-50`). The target is owner-gated, but the goal task
being written (`update_task(fetched, %{target_id: …})`) can live on a board where
the acting user holds only `:read_only`. A target owner who is a read-only member
of the goal's board can therefore set/clear `target_id` on that board's goal — a
persistent write to a board resource without modify access. Narrower than H1
(single FK, requires owning a target), hence medium. **Fix:** add a
`board_write_access?`/`can_modify?` check on the goal's board in
`assign_goal`/`unassign_goal`.

### L1 — Column save relies solely on the mount-time owner redirect
`column_live/form_component.ex:26` `save` calls `Columns.update_column/2` /
`Columns.create_column/2` (`columns.ex:98,68`), both pure
`changeset |> Repo.update/insert` with no owner check. Columns are an owner-only
resource everywhere else (`delete_column` show.ex:106, `move_column` show.ex:242,
and the `check_column_action_authorization`/`check_new_column_authorization`
`handle_params` gates). The only thing stopping a non-owner column write is that
`handle_params` redirects non-owners before the modal renders (show.ex:44-58,
942-961), so the component's `cid` never exists and a crafted `phx-target` cannot
reach it — **not exploitable as written**. But this is the single-layer version
of the D110 shape (D110 was hardened on both the redirect *and* an authoritative
`save`-path re-check). **Fix (defense-in-depth):** push the owner check into
`Columns.create_column`/`update_column` — the way `Boards.update_board` and
`update_field_visibility` already do — so it holds regardless of how the
component is reached.

## Verified-clean highlights (state-changing handlers confirmed safe)

- **Board/column (group A, 29/30 OK):** `delete_column`/`move_column` (in-handler
  `user_access != :owner`), `archive_task`/`delete_task`/`promote_goal_to_ready`
  (`authorize_modify_for_task`), `move_task` (`authorize_move_task` + both columns
  re-scoped to board), `toggle_field` (owner check + context `owner?`),
  token create/revoke/delete (in-handler `can_modify` + `board_id` IDOR guard),
  board `save`/`delete`/member add/remove (context `owner?` re-checks
  `boards.ex:609,628,659,682`).
- **Task form (group B):** `save` uses the D110 fix
  (`modify_authorized?` → `Boards.can_modify?`, `form_component.ex:102`);
  `add_comment` gated by membership (read-only may comment by design; `task_id`
  server-set per D111); all `add-*`/`remove-*` handlers mutate only the in-memory
  changeset and persist nothing until `save`.
- **Review approve path:** `approve` reaches `AgentWorkflow.mark_reviewed` →
  `board_write_access?`; a read-only user's transaction rolls back with
  `:not_authorized` (this is exactly the check H1's request-changes path skips).
- **Agents interventions (W1616-W1623):** `confirm_reassign`,
  `confirm_reprioritize`, `undo_intervention` each re-run `can_intervene?/2`
  inside the context immediately before the mutation
  (`interventions.ex:107,212,313`); `can_intervene?` fails closed on nil scope.
- **Archive:** `bulk_archive_old`/`unarchive`/`delete` gate on the server-derived
  `can_modify` assign and load targets through the board-scoped
  `get_archived_task_for_board`.
- **Admin messages:** each mutating handler re-checks `admin?/1` against
  `current_scope.user.type`, not just the on_mount gate.
- **User settings/auth (group D):** every handler acts on
  `socket.assigns.current_scope.user` — the session user acts only on itself,
  with no target-user param, so there is no IDOR surface (auth flows themselves
  reviewed under W1676).
- **Metrics/resources:** no persistent mutation; reads scoped by `current_scope`
  and intersected with the viewer's visible boards.

## Method note

No code changed in this task. Findings filed as separate Stride defects (H1 high
→ D138 with `needs_review`; M1 medium → D139; L1 low → D140) so each fix carries
its own review gate and regression test, per the W1677 task pitfalls
("one handler class per commit keeps review tractable").
