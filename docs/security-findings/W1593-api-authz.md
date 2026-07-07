# Security Findings — API Token AuthN & Capability AuthZ (W1593)

> Domain 2 of the comprehensive security review (G309). Manual analysis plus an
> independent `stride-security-review` full-file pass, each finding hand-verified.
>
> **Verdict: strong.** 0 critical · 0 high · 0 medium · 2 low (defense-in-depth) ·
> 5 boundaries verified clean.

## Surface reviewed

`authenticate_api_token.ex`, `api/task_controller.ex`, `api/agent_controller.ex`,
`api/completion_result_gate.ex`, `api_tokens.ex`, `tasks/agent_workflow.ex`.

## Verified-clean boundaries

| Boundary | Evidence |
|----------|----------|
| **Authentication** | Bearer extracted from a strict `"Bearer " <> token` match; SHA-256 hashed lookup with dummy-timing normalization on not-found/revoked; revoked tokens rejected; 256-bit `strong_rand_bytes` generation (`authenticate_api_token.ex`, `api_tokens.ex:69-83`). |
| **Cross-board IDOR** | `fetch_and_verify_task/2` → `verify_board_ownership/2` requires `task.column.board_id == token.board.id`, fail-closed; identifier lookups scoped to the board's columns. A board-A token cannot touch board-B tasks via any action (`task_controller.ex:835-843`). |
| **Mass-assignment** | `board_id`/`column_id`/`status`/`assigned_to_id`/`parent_id`/`created_by_*` stripped at the controller (`@forbidden_api_*_fields`) and re-enforced by the changeset allow-lists; token `user_id`/`board_id` force-overwritten server-side (`api_tokens.ex:122-128`). |
| **changed_files scoping (W1433)** | `authorize_changed_files/2` grants write only to the assignee or a board `:owner`/`:modify` member (`task_controller.ex:552`). |
| **W1430 gate + capabilities** | `board_write_access?` enforced on claim/complete; `authorized_reviewer?` on mark_reviewed/mark_done; complete also checks `assigned_to_id == user.id`. Capabilities are applied as a query-level claim filter, not merely stored; claim race closed by an atomic `update_all` (`agent_workflow.ex:315`). |

## Findings filed (both low, defense-in-depth)

| ID | Finding | Severity | Where |
|----|---------|----------|-------|
| **D108** | `after_goal` endpoint has no live board-write re-check — promotes a goal to Done with only board-token scope verified | low | `task_controller.ex:703` |
| **D109** | `unclaim_task`, API `create`, and API `update` omit the live `board_write_access?` re-check their siblings enforce | low | `agent_workflow.ex:106`, `task_controller.ex:94,269` |

Both are **defense-in-depth inconsistencies, not primary holes**: cross-board access
is impossible (fetch_and_verify_task scoping), tokens are only mintable by
`:owner`/`:modify` members, and are transactionally revoked on downgrade/removal
(`boards.ex:694,750`). The residual exposure is an in-flight request racing a
downgrade transaction, or a future access-losing transition that forgets to revoke
tokens — cases the sibling endpoints' live re-check would catch. **Fix:** reuse the
existing `board_write_access?`/`authorized_reviewer?` gate so W1430 is enforced
in-depth everywhere rather than relying solely on token revocation firing.
