# Documentation Example Enum Contract

This document defines the rules for enum values written in the JSON examples
of the API reference (`docs/api/*.md`) and the top-level guides (`docs/*.md`).
The test `test/kanban_web/controllers/api/doc_examples_enum_test.exs` enforces
them in the default `mix test` run. Introduced by D358, after several endpoint
docs were found giving a task the `type` value `task`, which `POST /api/tasks`
rejects with a 422, and complexity values from a retired five-level scale.

Agents copy these examples into real requests, so every value an example shows
must be one the server accepts.

## Valid values

The test takes these sets from the `Ecto.Enum` fields of `Kanban.Tasks.Task`.
When the schema changes, the test follows it.

| Field | Valid values |
|---|---|
| `type` | `work`, `defect`, `goal` |
| `complexity` | `small`, `medium`, `large` |
| `actual_complexity` | `small`, `medium`, `large` |
| `priority` | `low`, `medium`, `high`, `critical` |
| `status` | `open`, `in_progress`, `blocked`, `completed` |

Values are case-sensitive: `Work` and `Small` are rejected.

When you pick a value for an example:

- **`type`** — use `work` for an ordinary task (`W` identifier), `defect` for a
  bug fix (`D` identifier) and `goal` for a parent (`G` identifier). A goal
  contains only `work` and `defect` tasks, never another goal.
- **`complexity` / `actual_complexity`** — `small` is under an hour, `medium`
  is one to two hours, and `large` is more than two hours. `trivial`, `low`,
  `high` and `very_high` are not complexity values. `low` and `high` are only
  valid as priorities.
- **`status`** — there is no `review` status. Completing a task that needs
  review moves it to the Review column, but its `status` stays `in_progress`
  until a reviewer approves it, and then it becomes `completed`. Show the
  column in `column_name`, not in `status`.

## What is checked

| Covered | Not covered |
|---|---|
| `"type"`, `"complexity"`, `"actual_complexity"` and `"priority"` pairs with a quoted value | `status`, see below |
| Every `docs/api/*.md` file and every top-level `docs/*.md` file | Subdirectories of `docs/` other than `docs/api/` |
| Backslash-escaped JSON in a shell body, such as `-d "{\"type\": \"work\"}"` | `null` and numeric values |
| Several pairs on one line | Keys that only end in a scanned name, such as `step_type` |

A covered pair fails the test when its value is not in the field's valid set.
Every failure names the file and the line, then the key and the rejected value
as they appear in the doc, then the valid values. For a `type` of `task` on
line 39 of `docs/api/get_tasks_id.md`, the message starts with
`docs/api/get_tasks_id.md:39:` and ends with `is not one of work, defect, goal`.
This page cannot quote the whole message, because the check would flag it.

The test also requires that it found more than 100 pairs, so a pattern that
silently matches nothing cannot pass.

### Exceptions

- **`docs/multi-agent-instructions/` is never scanned.** Its "DON'T" sections
  show `task` as a `type` on purpose, as the wrong value an agent must not send.
  Leave those anti-examples as they are.
- **`"type": "http"` is allowed.** It is the OpenAPI `securitySchemes` entry in
  `docs/api/get_openapi_json.md`, not a task type.
- **`status` is not scanned.** Reviewer, hook and verification payloads in the
  same docs use other statuses, such as `failed`, `success` and `met`. Check
  task `status` values in an example by hand against the table above.

## Fixing a failure

Change the value in the doc to one from the table that fits the example. Do not
add the value to an allow-list. The only allow-list entry is `"type": "http"`,
for the reason above. If the server really does accept a new value, change the
`Ecto.Enum` field in `Kanban.Tasks.Task` and the test will follow.

## Running the check

```bash
mix test test/kanban_web/controllers/api/doc_examples_enum_test.exs
```

It reads local files only and makes no network calls.
