# PUT /api/tasks/:id/changed_files

Upload the per-file diff snapshot for a task. This is the **sole writer** for `tasks.changed_files`; the completion endpoint silently ignores any `changed_files` it receives in its body.

The endpoint is intentionally separate from completion: it lets the agent's hook upload a diff snapshot independently of the completion request, and protects the snapshot from being clobbered by a stale `changed_files: []` in a late-arriving completion body.

The diff encoding rules — truncation marker, binary placeholder, 500-line cap — are defined once in [docs/diff-contract.md](../diff-contract.md). This page is a *contract* doc; do not duplicate encoding rules here.

## Authentication

Requires a valid API token in the Authorization header:

```bash
Authorization: Bearer <your_api_token>
```

## Request

**Method:** PUT
**Endpoint:** `/api/tasks/:id/changed_files`
**Content-Type:** application/json

### URL Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Task ID (numeric) or task identifier (e.g., `"W777"`) |

### Request Body Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `changed_files` | array | Yes | Array of per-file diff entries. An empty array (`[]`) is a valid explicit-clear value. See [diff-contract.md](../diff-contract.md) for the per-entry shape. |

### Per-Entry Shape

Each element of `changed_files` is an object:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | Yes | Non-empty repo-relative file path. |
| `diff` | string | No | Unified-patch text. Capped per [diff-contract.md](../diff-contract.md). Binary files use the `"[binary file — no diff captured]"` placeholder. |

### Request Body Example

```json
{
  "changed_files": [
    {
      "path": "lib/foo.ex",
      "diff": "@@ -1,3 +1,4 @@\n defmodule Foo do\n+  @moduledoc \"hello\"\n   def bar, do: :ok\n end\n"
    },
    {
      "path": "assets/logo.png",
      "diff": "[binary file — no diff captured]"
    }
  ]
}
```

To explicitly clear the snapshot:

```json
{ "changed_files": [] }
```

## Authorization

The caller must satisfy **one** of these conditions:

- The task is currently assigned to the calling agent (`assigned_to_id == current_user.id`), or
- The task is currently in the **Review** column (so re-uploads after a `changes_requested` review work without re-claiming).

Otherwise the endpoint returns 403.

## Response

### Success (200 OK)

Returns the updated task. The persisted snapshot appears under `data.changed_files`.

```json
{
  "data": {
    "id": 2819,
    "identifier": "W777",
    "title": "...",
    "status": "in_progress",
    "column_id": 128,
    "changed_files": [
      {
        "path": "lib/foo.ex",
        "diff": "@@ -1,3 +1,4 @@\n defmodule Foo do\n+  @moduledoc \"hello\"\n   def bar, do: :ok\n end\n"
      },
      {
        "path": "assets/logo.png",
        "diff": "[binary file — no diff captured]"
      }
    ]
  },
  "current_skills_version": "1.0"
}
```

The task is not transitioned. `status` and `column_id` are unchanged by this endpoint.

### Unauthorized (401)

Missing or invalid Bearer token.

```json
{ "error": "Authentication required" }
```

### Forbidden (403)

Two distinct cases produce 403:

- The task belongs to a different board:

```json
{ "error": "Task does not belong to this board" }
```

- The caller is neither the task assignee nor is the task in the Review column:

```json
{
  "error": "You can only update changed_files on tasks you are assigned to or that are in Review",
  "documentation": "..."
}
```

### Not Found (404)

The task ID or identifier does not match any task the caller can see.

```json
{ "error": "Task not found" }
```

### Unprocessable Entity (422)

Validation failed. The envelope matches the [completion endpoint's validation envelope](patch_tasks_id_complete.md#completion-validation-format-g65) — same `error`, `failures`, and `required_format` keys — scoped here to `changed_files` only.

```json
{
  "error": "completion validation failed",
  "failures": [
    {
      "field": "changed_files",
      "errors": [
        { "field": "changed_file_path", "message": "changed_files[0] must have a non-empty string \"path\"" }
      ]
    }
  ],
  "required_format": {
    "changed_files": [
      {
        "path": "lib/foo.ex",
        "diff": "Unified-patch text — see docs/diff-contract.md"
      },
      {
        "path": "assets/logo.png",
        "diff": "[binary file — no diff captured]"
      }
    ]
  },
  "documentation": "..."
}
```

The validation rules are owned by `Kanban.Tasks.CompletionValidation.validate_changed_files/1` — the same validator the completion endpoint uses for shape-checking. Plugins that already conform to that contract require no change.

## Example Usage

### Upload a snapshot for a claimed task

```bash
curl -X PUT \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "changed_files": [
      { "path": "lib/foo.ex", "diff": "@@ -1 +1 @@\n-old\n+new" }
    ]
  }' \
  $STRIDE_API_URL/api/tasks/W777/changed_files
```

### Clear the snapshot

```bash
curl -X PUT \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"changed_files": []}' \
  $STRIDE_API_URL/api/tasks/W777/changed_files
```

### Re-upload after a `changes_requested` review

Once a task moves to the Review column, the original assignee (or any other agent on the board, depending on workflow) can re-upload an updated snapshot without re-claiming:

```bash
curl -X PUT \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @snapshot.json \
  $STRIDE_API_URL/api/tasks/W777/changed_files
```

## Notes

- **The PUT endpoint is the only writer.** The completion endpoint at `PATCH /api/tasks/:id/complete` no longer mutates `tasks.changed_files`. Sending `changed_files` in the completion body is tolerated for backwards compatibility but silently ignored at the schema cast layer. See [patch_tasks_id_complete.md](patch_tasks_id_complete.md) for the migration note.
- **Last-write-wins.** Repeated PUTs overwrite. The empty list (`[]`) is a legitimate explicit-clear value.
- **No status transition.** This endpoint does not move the task between columns or change `status`. Use the completion endpoint for that.
- **Race-safe.** Because the completion endpoint cannot write the field, an agent's completion request finishing after the hook's PUT cannot clobber the snapshot.
- **Validation is reused.** The 422 envelope and per-entry shape come from `Kanban.Tasks.CompletionValidation.validate_changed_files/1` — the same validator used by the completion gate.

## See Also

- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) — Mark task complete (does NOT write `changed_files` after the W778 change)
- [Diff Contract](../diff-contract.md) — Authoritative encoding rules (truncation marker, binary placeholder, 500-line cap)
- [POST /api/tasks/claim](post_tasks_claim.md) — Claim a task before uploading a snapshot for it
