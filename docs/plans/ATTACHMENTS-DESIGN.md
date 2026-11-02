# Task Attachments — Implementation Design

**Roadmap item:** *Attachments* — "Add files such as screenshots, logs and designs to tasks and comments." ([ROADMAP](../../ROADMAP.md), under *In progress*).

**Status:** planned. Nothing in this document is built yet. It brings together the four Stride goals that deliver the feature, as they stood on 2026-10-28:

| Goal | Title | Tasks | State on 2026-10-28 |
| --- | --- | --- | --- |
| G488 | Store task attachments: storage backends, data model, access rules and cleanup | W2505–W2509 | W2505, W2506, W2507 ready to start; W2508, W2509 blocked |
| G489 | Attach and view files on tasks and comments in the board UI | W2510–W2515 | all blocked on G488 |
| G490 | Give agents task attachments through the REST API, MCP and workspace export | W2516–W2520 | all blocked on G488 |
| G491 | Make the Stride agent plugins download and use task attachments | W2521–W2533 | W2521 ready to start; the rest blocked on G490 |

The goals and their tasks are the source of record. When this document and a task disagree, the task wins; [§12](#12-open-points) lists the places where the goals disagree with each other.

**Attachments are only for boards in an Organization.** When paid plans are enforced, a free board has no attachments at all: it cannot add, list, preview, download or delete files, through the UI, the REST API or MCP. Files already on a board that leaves its Organization are kept, but hidden, and come back if the board returns to an Organization ([§4.3](#43-plan-gate)). On an instance that does not enforce plans (the self-hosted default), every board is unlocked, as with every other Organization feature. The hosted service at stridelikeaboss.com has enforced plans since 1 November 2026, so there attachments ship as Organization-only from day one.

**Agents only read attachments.** People upload files in the browser. No agent, API or MCP upload is in scope.

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [How the four goals fit together](#2-how-the-four-goals-fit-together)
3. [Storage and data model (G488)](#3-storage-and-data-model-g488)
4. [Access rules, limits and the plan gate (G488)](#4-access-rules-limits-and-the-plan-gate-g488)
5. [Cleanup (G488)](#5-cleanup-g488)
6. [Board UI (G489)](#6-board-ui-g489)
7. [Serving files safely (G489 and G490)](#7-serving-files-safely-g489-and-g490)
8. [Agent API, MCP and export (G490)](#8-agent-api-mcp-and-export-g490)
9. [Agent plugins (G491)](#9-agent-plugins-g491)
10. [Telemetry, audit and docs](#10-telemetry-audit-and-docs)
11. [Task list and order](#11-task-list-and-order)
12. [Open points](#12-open-points)

---

## 1. Goals and non-goals

### Goals

- People on Organization-plan boards can attach screenshots, logs, PDFs and data files to a task or to one of its comments, preview images, and download any file.
- Agents that work a task on an Organization board can see its attachments: the metadata in the task JSON they already read, a token-authenticated download endpoint, an MCP read tool, and plugins that fetch the files for them.
- Files survive a redeploy (production Fly machines have no volume, so production uses S3-compatible storage) and are removed from storage when their attachment, comment, task or board is deleted, by any path.
- Workspace exports carry attachments, and the self-host import restores them.

### Non-goals

- Attachments on free boards while plans are enforced, including read-only access to files a board had before it left its Organization.
- Uploads by agents, the REST API or MCP.
- Any file type that can run as script when served (SVG, HTML) and any archive type (zip).
- Previewing anything other than raster images. PDFs, text and every other type are downloaded.
- The lite plugin variants (stride-lite, stride-copilot-lite, stride-opencode-lite), which never call the Stride API.
- New dependencies. The S3 adapter is built on `Req` with `aws_sigv4`.

---

## 2. How the four goals fit together

```text
G488  storage + schema + context + cleanup      (everything below the UI)
  │
  ├── G489  board UI: routes, task view, comments, task form, user docs
  │
  └── G490  agent surfaces: task JSON, download endpoint, MCP tool, export, agent docs
        │
        └── G491  plugins: contract doc, then download + use per port (6 ports)
```

G488's `Kanban.Attachments` context is the only place that authorizes, enforces limits and checks the plan. G489 and G490 call it and never re-implement storage, the schema, limits or access rules.

G490's attachment JSON object is a stable contract that G491's plugins depend on ([§8.1](#81-attachment-metadata-in-task-json-w2516)).

---

## 3. Storage and data model (G488)

### 3.1 Storage behaviour (W2505)

`Kanban.Attachments.Storage` defines four callbacks:

| Callback | Success | Notes |
| --- | --- | --- |
| `put(key, source, opts)` | `:ok` | `source` is `{:file, path}` or `{:binary, iodata}` |
| `stream(key)` | `{:ok, enumerable}` | never reads a whole object into memory |
| `delete(key)` | `:ok` | also `:ok` when the object is already gone |
| `exists(key)` | `{:ok, boolean}` | |

Failures are `{:error, :invalid_key | :not_found | :storage_unavailable}`.

The facade validates every key before any adapter sees it. A key may contain only lowercase letters, digits, `/`, `_` and `-`, must not start with `/`, must have no empty segment, and is at most 512 characters. Keys are generated by the context as `boards/<board_id>/<uuid>`.

There are two adapters:

- **`Storage.Local`**, the default, for dev, test and self-hosting. It writes under a root directory through a temp file plus an atomic rename, with `0o700` directories and `0o600` files. It refuses to serve a symlink or any path whose real path leaves the real root.
- **`Storage.S3`**, for production (Tigris on Fly, or AWS S3). It signs requests with `aws_sigv4` (service `s3`), uses virtual-hosted URLs by default and path-style when configured, and streams uploads with an explicit `content-length`. It never decodes bodies and never follows redirects. A 404 maps to `:not_found`, and any other failure maps to `:storage_unavailable`.

### 3.2 Configuration (W2505)

`config/runtime.exs` sets values only from environment variables that are present:

| Variable | Purpose |
| --- | --- |
| `ATTACHMENTS_STORAGE` | `local` or `s3` |
| `ATTACHMENTS_DIR` | local-disk root |
| `ATTACHMENTS_S3_BUCKET`, `ATTACHMENTS_S3_ENDPOINT`, `ATTACHMENTS_S3_REGION`, `ATTACHMENTS_S3_ACCESS_KEY_ID`, `ATTACHMENTS_S3_SECRET_ACCESS_KEY`, `ATTACHMENTS_S3_PATH_STYLE` | S3 settings |
| `ATTACHMENTS_MAX_FILE_MB`, `ATTACHMENTS_MAX_FILES_PER_TASK`, `ATTACHMENTS_ORG_QUOTA_GB` | limits ([§4.2](#42-limits)) |

The S3 settings fall back to the names Fly's Tigris integration sets: `BUCKET_NAME`, `AWS_ENDPOINT_URL_S3`, `AWS_REGION`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. With `ATTACHMENTS_STORAGE=s3`, boot fails if an S3 variable is missing; the error names the variable and never prints a value. A limit that is not a positive integer also fails the boot. Tests use `tmp/test_attachments` and a `Req.Test` stub for S3, so no test touches the network.

### 3.3 Tables (W2506)

**`task_attachments`**

| Column | Type and rule |
| --- | --- |
| `task_id` | references `tasks`, on delete cascade, not null |
| `comment_id` | references `task_comments`, on delete cascade, nullable (null means a task-level attachment) |
| `board_id` | references `boards`, on delete cascade, not null |
| `uploaded_by_id` | references `users`, on delete nilify (the file stays when its uploader is deleted) |
| `filename` | sanitised |
| `content_type` | allow-listed |
| `byte_size` | bigint, check constraint positive |
| `sha256` | 64 lowercase hex characters |
| `storage_key` | unique index |
| `inserted_at`, `updated_at` | timestamps |

Indexes cover `task_id`, `comment_id`, `board_id` and `uploaded_by_id`. `Task` and `TaskComment` each get `has_many :attachments`.

**`attachment_blob_deletions`** is a tombstone table: `storage_key`, `delete_after` (not null, default now), `attempts` (default 0), `last_error` (a short reason code) and `inserted_at`, indexed on `delete_after`.

A row-level `AFTER DELETE` trigger on `task_attachments` inserts a tombstone for the deleted row's `storage_key`. Because the trigger fires on cascades too, deleting an attachment, comment, task, board or archived task by any path queues its blobs for removal ([§5](#5-cleanup-g488)).

### 3.4 Validation (W2506)

`TaskAttachment.create_changeset(attachment, attrs, sniff_head)` casts only `filename`, `content_type`, `byte_size` and `sha256`. The caller sets `task_id`, `comment_id`, `board_id`, `uploaded_by_id` and `storage_key` on the struct; they are never cast from input.

- **Allowed types:** png, jpeg, gif, webp, pdf, plain text, markdown, csv and json. An empty or `application/octet-stream` declared type is inferred from the extension.
- **Magic bytes:** a declared type that the file's bytes contradict is refused, so a PDF labelled as a PNG, or a binary labelled as text, is never stored. An image or PDF type is checked against the first 512 bytes; a text type is checked over the whole file, since only the whole file can show it holds no NUL byte.
- **Size:** `byte_size` must be between 1 and the per-file limit, inclusive. The context computes it with `File.stat`, never from a client value.
- **Filename:** directory parts, control characters and format characters (bidi overrides included) are stripped, except the zero-width joiner and non-joiner that emoji and scripts such as Persian need; the name is capped at 255 codepoints keeping the extension, and an empty name or one equal to `.` or `..` is refused.

---

## 4. Access rules, limits and the plan gate (G488)

### 4.1 Who can do what (W2508)

`Kanban.Attachments` resolves access once through `Boards.get_user_access/2` (`Kanban.Attachments.Policy`). The board always comes from the task's column, never from the request.

| Action | Allowed |
| --- | --- |
| Add a file to a task | board owner and `modify` members |
| Add a file to a comment | the comment's author, on a comment on the same task, with owner or `modify` access |
| List and download | every board member, including `read_only` |
| Delete | the uploader or the board owner |

Every action in the table checks the plan first ([§4.3](#43-plan-gate)): while plans are enforced, none of them is allowed on a free board, whatever the person's board access.

A non-member gets `{:error, :not_found}`, so attachment ids reveal nothing. A member without the right gets `{:error, :unauthorized}`, as `Kanban.Tasks.Comments` does.

The public functions are `create_attachment(scope, task, upload, opts)` (with `comment:` in `opts` for a comment upload), `list_task_attachments(scope, task)` and `list_comment_attachments(scope, comment)` (both oldest first), `fetch_for_download(scope, attachment_id)` and `delete_attachment(scope, attachment)`.

### 4.2 Limits

| Limit | Default | Config key |
| --- | --- | --- |
| Per file | 25 MiB (26,214,400 bytes) | `max_file_bytes` |
| Files per task | 20 | `max_files_per_task` |
| Storage per Organization | 10 GiB (10,737,418,240 bytes) | `organization_quota_bytes` |

`Kanban.Attachments.Limits` reads `config :kanban, Kanban.Attachments.Limits` at call time. While plans are enforced, every board that can hold attachments is in an Organization, so the quota is always the Organization's. Only on an instance that does not enforce plans can a board outside an Organization hold files; there the quota is counted per board (`Kanban.Attachments.Usage`).

The limits hold under concurrent uploads. `create_attachment`:

1. checks access, the plan and the limits, then reads the temp file exactly once, into a private snapshot capped one byte past the per-file limit. `byte_size`, `sha256`, the sniff and the stored bytes all come from that snapshot, so a temp file that changes afterwards can never store bytes that differ from what was checked. It builds the changeset before storing anything;
2. records a pending tombstone for the new key, due one hour later, then puts the blob;
3. in one transaction, takes `FOR KEY SHARE` locks on the uploader, board and comment rows the new row references, locks the task row, takes a transaction-scoped advisory lock keyed by the Organization id (or the board id), checks the count and quota again, inserts the row and removes the pending tombstone. The key-share locks come first because a board, comment or account deletion locks those rows before its cascade reaches the task; taking them only through the insert's foreign-key checks, after the task row, deadlocked an upload with a concurrent board deletion (found in the G488 exploratory session, 2026-11-01).

If the transaction fails, the blob is deleted, and then its tombstone. If that delete fails, the tombstone stays and the cleanup worker removes the blob later. A refused or failed upload never leaves an attachment row.

### 4.3 Plan gate

W2507 adds `:attachments` as the last entry in `Kanban.Plans` `@features`, gives it a `parse_feature("attachments")` clause and a translated *Attachments* label in `KanbanWeb.LockedFeature`, and adds it to the "What a free board cannot do" table in [Organizations and Workspaces](../organizations.md#what-a-free-board-cannot-do).

When plans are enforced, every public function of `Kanban.Attachments` (`create_attachment`, `list_task_attachments`, `list_comment_attachments`, `fetch_for_download` and `delete_attachment`) returns `{:error, {:plan_required, :attachments}}` for a free board, and stores, lists or removes nothing. The check runs after the board is resolved from the task and before any attachment lookup.

A board that leaves its Organization keeps its files in storage. While the board is free, nobody can see, download or delete them, and they count toward no quota. If the board moves back into an Organization they appear again, and count toward that Organization's quota from then on. Deleting the task, a comment or the board still removes their files through the cascade and the tombstones ([§5](#5-cleanup-g488)), because those deletions do not go through `Kanban.Attachments`.

The row W2507 adds to "What a free board cannot do" says: *Attachments — Free boards — Files cannot be added, listed, previewed or downloaded. Files already on a board that left its Organization are kept, and reappear if it moves back into one.*

The UI ([§6](#6-board-ui-g489)), the REST API ([§8.2](#82-download-endpoint-w2517)), the task JSON ([§8.1](#81-attachment-metadata-in-task-json-w2516)) and MCP ([§8.3](#83-mcp-tool-w2518)) all follow this rule.

---

## 5. Cleanup (G488)

`Kanban.Attachments.BlobCleanupWorker` (W2509) is an Oban cron job on a new `:attachments` queue (concurrency 1). It runs every 15 minutes, with `max_attempts: 3`, and a `unique` option over the available, scheduled, executing and retryable states so runs never overlap.

Each run takes up to `batch_size` (default 200) tombstones whose `delete_after` has passed, oldest first. A tombstone whose key a `task_attachments` row still names is stale (a pending upload whose grace period ran out before its row committed, for example), so it is deleted without touching the blob; the row's own deletion queues the key again through the trigger. Without that check the worker removed the file of a live attachment (found in the G488 exploratory session, 2026-11-01). Every other tombstone gets `Storage.delete/1`:

| Result | Action |
| --- | --- |
| `:ok`, including an object that is already gone | delete the tombstone |
| `{:error, :invalid_key}` | delete the tombstone and log an error (the key can never be removed) |
| any other error | increment `attempts`, store the reason in `last_error`, and push `delete_after` out by 2^attempts minutes, capped at one day |

The worker only deletes keys the database wrote, and those keys still pass the facade's validation, so it cannot be steered to delete arbitrary paths. It accepts a `now` job argument for tests, as `Export.CleanupWorker` does.

---

## 6. Board UI (G489)

All UI text is translated in every locale with no fuzzy entries, and every new surface passes `mix dark_mode.scan` in light and dark mode.

### 6.1 Shared building blocks (W2511)

- **`KanbanWeb.TaskLive.AttachmentUploads`** wraps `allow_upload`, with the accepted extensions, file size and entry count taken from G488's allow-list and limits. It stores consumed entries through `Kanban.Attachments` and maps upload and context errors to translated messages.
- **`KanbanWeb.TaskLive.Components.AttachmentItems`** renders an attachment list and the staged uploads:
  - each attachment shows a type icon, filename, human-readable size, uploader (or *Unknown*), relative date, a download link and an optional delete button with a confirmation;
  - each staged upload shows its progress as a bar and as a percentage beside its size (the bar alone falls under 3:1 against its track in the light theme), a cancel control and its errors.

### 6.2 Task detail view (W2511)

`KanbanWeb.TaskLive.AttachmentsComponent` adds an **Attachments** section to the task detail view, directly above History, with a file count. It lists task-level attachments (rows with no `comment_id`) and offers a drop zone and file browser to anyone allowed to upload.

- A `read_only` member sees and can download the files but gets no drop zone or upload button. They see a delete control only on a file they uploaded themselves (before their access changed), because `Kanban.Attachments.Policy` lets an uploader delete their own file at any access level.
- A free board under enforcement shows the LockedFeature panel instead of the list and upload controls.
- Every upload, cancel and delete event checks `Plans.check_board(board_id, :attachments, surface: :live_view)` again and calls the context's authorizing functions, so a forged event is refused with a flash.
- A board moving into or out of an Organization changes its plan and broadcasts `{Kanban.Boards, :members_changed, id}`. `KanbanWeb.BoardLive.BoardEvents` then refreshes the open task's Attachments section and comment thread, and sends an open task form `refresh_plan: true`, so the drop zone, the LockedFeature panel and the form's Attachments and telemetry fields follow the new plan without a reload.
- When the section finds the viewer can no longer upload (the plan lapsed or their access changed) while files are staged, it cancels them and names each in the flash ("Could not upload a.txt: …"), as the comment composer and the new-task form do on submit; the staged files would otherwise sit hidden behind the locked panel.
- A staged file, and a flash naming a file that could not be stored, shows the name the file would be stored under (`KanbanWeb.TaskLive.AttachmentUploads.display_name/1`, which runs `Kanban.Attachments.Filename.sanitize/1`), never the raw client name; a name with nothing left reads "unnamed file". This holds on all three upload surfaces: the task view, the comment composer and the new-task form.

### 6.3 Image previews (W2512)

- PNG, JPEG, GIF and WebP attachments show a lazy-loaded thumbnail from the preview route. Every other type keeps its icon.
- Clicking a thumbnail opens a lightbox: a `role="dialog"` overlay toggled with `Phoenix.LiveView.JS`, with a Close button that takes focus, a backdrop click to close, the full image and a download link. Closing it never closes the task modal.
- Staged uploads of those four types show a `live_img_preview` before they are stored. To allow this, `KanbanWeb.Plugs.CspNonce` adds `blob:` to `img-src` and changes nothing else in the policy.

### 6.4 Comments (W2513)

- The comment composer gets an **Attach files** input under the mention field; a free board under enforcement shows no input and no comment files. After **Add Comment**, the files are stored on the comment the server returned, never on an id from the client.
- If the comment fails validation, the staged files stay. If a file fails to store after the comment is saved, the comment stays and a flash names the failed files.
- The thread loads every comment's attachments with one context call (`KanbanWeb.TaskLive.CommentAttachments.group_by_comment/1`).
- The comment's author, in edit mode, can remove a comment's files, and so can the board's owner (an org-admin counts) at any time, as the delete rule in §4 allows; the owner can take a file down without deleting the author's comment. Deleting a comment removes its files through the cascade and the tombstone, so no extra attachment code is needed.

### 6.5 Task form (W2514)

- The new-task form gets an **Attachments** field with `auto_upload: false`, through `KanbanWeb.TaskLive.Form.AttachmentStaging`. On a free board under enforcement the field shows the LockedFeature prompt instead.
- Staged files are stored on the task id returned by `Tasks.create_task`, after the save succeeds. A validation error or a WIP-limit refusal stores nothing and keeps the staged files.
- The edit form mounts `AttachmentsComponent` outside the `<.form>`.
- `form_component.ex` may grow by at most 15 lines; any more code must move into a `Form.*` module first.

---

## 7. Serving files safely (G489 and G490)

User-uploaded bytes must never run as part of the Stride origin. There are two serving surfaces, and they share these rules.

### 7.1 Browser routes (W2510)

`GET /attachments/:id/download` and `GET /attachments/:id/preview` are plain controller routes (`KanbanWeb.AttachmentController`). They sit in the router scope that pipes through `:browser`, `:require_authenticated_user` and `:enforce_organization_two_factor`, outside any `live_session`, beside the export downloads.

- **Authorization:** every request goes through `Kanban.Attachments.fetch_for_download/2` for the signed-in user. The board comes from the attachment row; the URL id is only a hint.
- **Uniform 404:** no access, another board's attachment, an unknown or malformed id, a locked plan and a missing storage object all return the same 404 page, so ids cannot be enumerated. A signed-out request redirects to log in.
- **Preview** serves PNG, JPEG, GIF and WebP inline and returns 404 for every other type, including SVG, HTML and PDF.
- **Streaming:** bytes are streamed with `send_chunked/2`, and the object's existence is confirmed before any header is sent.

### 7.2 Response headers (both surfaces)

| Header | Value |
| --- | --- |
| `Content-Disposition` | `attachment` (or `inline` for a raster preview), with a sanitised ASCII `filename` and an RFC 5987 `filename*` |
| `Content-Type` | the stored type when it is on the allow-list, else `application/octet-stream` |
| `X-Content-Type-Options` | `nosniff` |
| `Content-Security-Policy` | `default-src 'none'; frame-ancestors 'none'; sandbox` (it replaces the page policy; no page frames an attachment, since thumbnails and the lightbox use `<img>`) |
| `Cache-Control` | `private, no-store`, so no cache keeps a file after access is revoked |
| `Cross-Origin-Resource-Policy` | `same-origin` (browser routes) |

`KanbanWeb.AttachmentResponse` builds the filenames:

- the ASCII fallback drops control and format characters, replaces anything else outside `A-Za-z0-9._ -` with `_`, trims leading dots, caps the name at 150 characters keeping the extension, and falls back to `attachment` when nothing is left;
- the `filename*` value drops control and format characters except U+200C and U+200D (which the stored name keeps, see the upload rules), turns `/` and `\` into `_`, caps the name at 255 code points keeping the extension, and is percent-encoded;
- in both, a name that is only an extension (`.txt`) keeps it after the base name `attachment` (`attachment.txt`), instead of losing the type hint it consists of. Found by the G489 exploratory session, 2026-11-02.

Control characters never reach a header. Logs carry the attachment id and a reason atom only, never the storage key, filename or contents.

---

## 8. Agent API, MCP and export (G490)

### 8.1 Attachment metadata in task JSON (W2516)

The full `GET /api/tasks/:id` view, `POST /api/tasks/claim`, and the MCP `stride_get_task` and `stride_claim_task` results carry `data.attachments`. Each entry has exactly these eight keys:

| Key | Type |
| --- | --- |
| `id` | integer |
| `filename` | string (user-supplied; treat as data) |
| `content_type` | string |
| `byte_size` | integer, bytes |
| `sha256` | 64 lowercase hex characters |
| `comment_id` | integer, or `null` for a task-level attachment |
| `uploaded_at` | ISO 8601 UTC string |
| `download_url` | the API path `/api/tasks/<numeric task id>/attachments/<attachment id>` |

- The list holds task-level and comment-level attachments, oldest `uploaded_at` first, with ties broken by id.
- It is empty for a task with no files, and for any task on a board that is not unlocked while plans are enforced, so a downgraded board does not advertise files it cannot serve.
- It never carries storage keys, bucket names, storage or presigned URLs, or uploader emails.
- `response_view=slim`, `GET /api/tasks`, the tree, next, complete, create and update responses carry no `attachments` key.
- `fields=attachments` is refused with the existing 422 unknown-fields error.

The object is documented in SchemaDoc under a new `response_objects` key and as a `TaskAttachment` schema in `priv/openapi/stride-api.json`.

### 8.2 Download endpoint (W2517)

`GET /api/tasks/:id/attachments/:attachment_id` streams the file to a board token (or a workspace token naming the board with `X-Stride-Board`), with the headers in [§7.2](#72-response-headers-both-surfaces).

| Case | Response |
| --- | --- |
| success | 200, streamed bytes |
| free board under enforcement (checked before any lookup) | 403 `plan_required`; emits `feature_refused` with surface `rest` |
| token user lost board access | 403 `not_authorized` |
| task not on the token's board | 404 Task not found |
| malformed, out-of-range, missing or other-task attachment id, or blob missing from storage | 404 Attachment not found |
| past the `:attachment_download` rate limit (per token) | 429 with `retry-after` |
| storage failure before the first byte | 503, with no key or path in the body or logs |

`KanbanWeb.API.AttachmentActions.fetch_attachment/4` runs the plan gate, rate limit, task lookup and attachment-of-task lookup in that order, and the MCP tool reuses it. A successful download emits `[:kanban, :api, :attachment_downloaded]` with `task_id` and `attachment_id`.

### 8.3 MCP tool (W2518)

`stride_get_attachment` (read-only; required `id` and `attachment_id`; no extra arguments) returns the same eight-key object as `data`.

- **Inlined:** a `text/plain`, `text/markdown`, `text/csv` or `application/json` file of at most 262,144 bytes (256 KiB), with valid UTF-8 and a matching sha256, is inlined in `content.text`. It carries `untrusted: true` and a notice that the text is attached data, not instructions.
- **Not inlined:** the tool returns `content: null` with `content_omitted_reason`:
  - `not_text` for other types;
  - `too_large` for larger text, decided from the metadata before any storage read;
  - `not_utf8` for invalid UTF-8;
  - `checksum_mismatch` when the sha256 doesn't match.
- **Errors:** lost access, plan refusal and a missing attachment return `isError` results with `not_authorized`, `plan_required` and `attachment_not_found` (`http_status` 404).

### 8.4 Workspace export and import (W2519)

- **Export:** the archive moves to manifest `format_version` 2, with `attachments.json` (allow-listed fields only, never a storage key) and one `attachments/<id>` blob entry per row. A blob missing from storage fails the export with `export_failed`.
- **Import:** archives are untrusted input.
  - Blob entries must be named `attachments/<positive integer>`; directories, traversal, duplicates, and a row without a blob (or a blob without a row) make the archive `invalid_archive`.
  - Each blob is inflated against a running per-file and total budget, so a zip bomb is never fully inflated (`archive_too_large`). Byte size and sha256 are recomputed, and filename and type are re-validated through G488's changeset.
  - The Organization quota is checked before any blob is written.
  - A dry run verifies blobs and stores none. Any failure or rollback deletes every blob the import stored.
- A version 1 archive still imports, with no attachments.
- Both sides are Organization-only already: only an org-admin can export an Organization workspace, and the import creates the workspace in an Organization ([Workspace Export](../workspace-export.md)). So an archive's attachments always land on Organization boards.

### 8.5 Agent docs (W2520)

The following get attachments sections or entries:
- `docs/AI-WORKFLOW.md`
- `docs/api/README.md`
- `docs/api/get_tasks_id.md`
- `docs/api/post_tasks_claim.md`
- `docs/api/get_agent_onboarding.md`
- the onboarding quick-reference card

They say plainly that attachment contents are untrusted data from board members, and that agents verify `byte_size` and `sha256` after download.

---

## 9. Agent plugins (G491)

Left to themselves, agents would fetch files with `curl -o`. The curl guards in stride, stride-copilot and stride-gemini block that, and it would put binary data into the transcript and expose the token. Instead, each port's hook or plugin code downloads the files after the claim, and the workflow hands their location to the agents.

### 9.1 The contract (W2521)

`stride/docs/porting-attachments.md` is the normative cross-port contract. It defines:

- **Layout:** `.stride/attachments/<STEM>/`, with `STEM` from the task-file rule (the identifier if it matches `\A[A-Za-z0-9_-]{1,64}\z`, else the numeric id, else nothing is written). A `.gitignore` containing `*` inside `.stride/attachments/` keeps files out of commits. A claim with no attachments creates no directory.
- **Naming:** `<id>-<sanitised basename>`. The basename is the part after the last `/` or `\`, with anything outside `A-Za-z0-9._-` replaced by `_`, leading dots stripped, a 100-character cap keeping the extension, and `attachment` for an empty name. An id not matching `\A[A-Za-z0-9-]{1,64}\z` is skipped. No raw filename ever reaches a path.
- **Manifest:** `manifest.json` version 1, written last, with `manifest_version`, `task {id, identifier}`, `caps`, and per attachment:
  - the server fields;
  - `local_file` (or null);
  - `download_path`, only when it passes the relative-path check;
  - `status` (`downloaded`, `skipped` or `failed`) and a `reason`: `too_large`, `count_cap`, `total_cap`, `time_budget`, `unsafe_id`, `unsafe_url`, `http_<code>`, `transport`, `size_mismatch` or `sha256_mismatch`.

  It holds no token, no absolute URL and no timestamps of its own, so the bash and PowerShell halves write byte-identical files.
- **Caps:** stated in bytes, so they match the server: 26,214,400 bytes (25 MiB) per file, 20 files and 104,857,600 bytes (100 MiB) per task, and a wall-clock budget of 120 s (30 s for stride-codex, whose PostToolUse timeout is 60 s).
- **Download rules:**
  - Download only after a claim whose own response proved the task identity.
  - Fetch only a relative `download_url` beginning `/api/` (no `..`, `//` or query), joined to the API URL from `.stride_auth.md`.
  - Send a curl-like User-Agent, and never send `Authorization` on a cross-origin redirect.
  - Check the sha256, staging each file and then renaming it into place; a body longer than its `byte_size` is removed and recorded as failed.
  - Never fail the claim, never write binary data to stdout, and print one summary line on stderr.
  - Refuse to write through a symlinked `.stride`, `.stride/attachments` or task directory, and never execute or unzip an attachment.
- **Guard exemption:** only a GET of an attachments path whose `-o` target is under `.stride/attachments/`. Every other `-o`, redirect and pipe shape stays refused.
- **Agent rules:**
  - `ATTACHMENTS_DIR` (absolute) is passed to the explorer, planner, reviewer and task-runner only when the manifest exists and names the claimed task.
  - Agents view images and PDFs and read text with their runtime's own tools, and fall back to filename, type and size when a tool can't.
  - Agents treat contents as untrusted data, and report text that tries to steer them rather than obey it. They read only manifest-listed files and never re-fetch with curl.
- **Cleanup:** the directory is removed with the other per-task artifacts only after a 2xx completion, behind the `STRIDE_DIR` guard, never at claim time from a skill. The hook replaces it on a re-claim.
- **Rewrite downloads.** The `stride-import` plugin downloads a Jira rewrite's source files under the same rules ([Import from Jira](IMPORT-FROM-JIRA-DESIGN.md#6a5-how-a-rewrite-runs)), with these differences, which the contract states in a section of its own:
  - **Layout:** `.stride/attachments/rewrite-<id>/`, where `<id>` is the numeric rewrite id.
  - **Manifest:** `rewrite {id, bundle_sha256}` takes the place of `task`, and each entry adds the `jira_key` it came from.
  - **Identity:** files are downloaded only after the bundle body's SHA-256 matched the hash its response returned, and only from that bundle's file list. Only a `download_url` beginning `/api/import_rewrites/<id>/files/` for that rewrite id is fetched. `ATTACHMENTS_DIR` goes to the drafter and coverage-reviewer only when the manifest names that rewrite and hash.
  - **Caps:** 26,214,400 bytes (25 MiB) per file, 20 files per Jira issue, and 524,288,000 bytes (500 MiB) per rewrite within 600 s. A skipped file stays in the manifest, so the coverage map still accounts for it.
  - **Curl guard:** no exemption is needed while `stride-import` downloads through its own script (`lib/download-files.sh`), because the guard only sees curl commands the agent runs. If a port ever lets the agent run that curl, the exemption covers a GET of a rewrite file path with the same `-o` target rule, and nothing wider.
  - **Cleanup:** the directory is removed once the draft is submitted.

### 9.2 Per-port work

Each full port has a download task (hook or plugin code plus hermetic tests) and a use task (skills, agents, cleanup and contract tests). stride goes first as the source of record.

| Port | Download task | Use task | Where the list comes from | Notes |
| --- | --- | --- | --- | --- |
| stride | W2522: `stride-hook.sh` and `stride-hook.ps1` in lockstep | W2523: `attachments.md` sibling skill file, explorer/planner/reviewer/task-runner hand-off, Step 7 cleanup | task file | token passed to curl on stdin, never in argv |
| stride-gemini | W2524: both hook halves, guard exemption | W2525: skills, agents (`read_file`), Step 7 cleanup | task file | 120 s inside the 300 s AfterTool timeout |
| stride-copilot | W2526: own-call identity check in `before_doing`, guard exemption | W2527: manual reading, explorer, self-review, Step 7 cleanup | observed claim response | agents have only read/search/glob |
| stride-codex | W2528: PostToolUse claim arm | W2529: skills, agents, Step 8 cleanup | observed claim response | 30 s budget; its guard covers only claim/complete/mark_reviewed, so no exemption is expected |
| stride-opencode | W2530: new `src/attachments.ts`, download and removal in code | W2531: skills and agents | task file | `fetch` with `redirect: 'manual'` |
| stride-pi | W2532: new `extensions/hook-bridge/attachments.ts` | W2533: skills, both agent copies, Step 7 cleanup | observed claim response | |

Every use task checks what the installed runtime's read tool returns for images and PDFs, and degrades where the tool cannot show them. No port's version or versioned CHANGELOG heading changes during the goal; releases are a separate step.

---

## 10. Telemetry, audit and docs

- **Context telemetry (W2508):** `[:kanban, :attachment, :uploaded]`, `:downloaded`, `:deleted` and `:upload_refused`, declared in a new `Catalog.AttachmentEvents` module. Refusals carry a `reason` tag: `too_large`, `type_not_allowed`, `type_mismatch`, `empty`, `too_many_files`, `quota_exceeded` or `storage_unavailable`. Every upload event also carries a `source` tag, `upload` for a person's upload; the Jira import's `import_attachment/4` emits the same events with `source` set to `import`.
- **API telemetry (W2517):** `[:kanban, :api, :attachment_downloaded]`.
- Metadata carries ids, sizes and reason codes only, never filenames, contents or hashes. [Telemetry](../telemetry.md) gets an *Attachment events* section and a refreshed event reference.
- **Audit:** an owner deleting someone else's attachment emits `:attachment_deleted_by_owner`, with ids only and a translated label.
- **Real-time updates:** creates and deletes broadcast `{Kanban.Attachments, :attachment_changed, %{task_id, board_id}}` on `board:<id>`.
- **Docs:**
  - `docs/attachments.md`: W2505 creates it as the operator guide (environment variables, limits, Fly/Tigris setup, local-disk caveats); W2515 adds a user section.
  - Resources gets an *attaching files to tasks and comments* guide.
  - The CHANGELOG gets an *Attachments* entry under `[Unreleased]`, mirrored in `priv/changelog/body.html`.
  - [Organizations and Workspaces](../organizations.md), [Workspace Export](../workspace-export.md) and [MCP](../MCP.md) get the attachment rules.

---

## 11. Task list and order

| Task | Goal | Size | Depends on | Title |
| --- | --- | --- | --- | --- |
| W2505 | G488 | medium | — | Add an attachment storage behaviour with local-disk and S3-compatible adapters |
| W2506 | G488 | medium | — | Create the task_attachments table, blob-deletion tombstones and TaskAttachment schema |
| W2507 | G488 | small | — | Add the attachments plan feature to Kanban.Plans and the LockedFeature prompt |
| W2508 | G488 | medium | W2505, W2506, W2507 | Build the Kanban.Attachments context with access rules, limits, plan gate and telemetry |
| W2509 | G488 | small | W2505, W2506 | Add an Oban cron worker that drains attachment blob deletions from storage |
| W2510 | G489 | medium | W2508 | Add authenticated attachment download and preview routes with AttachmentController |
| W2511 | G489 | medium | W2510 | Add an Attachments section to the task detail view with AttachmentsComponent |
| W2512 | G489 | small | W2511 | Add raster image thumbnails, a preview lightbox and upload previews to AttachmentItems |
| W2513 | G489 | medium | W2511 | Add file attachments to comments in CommentThreadComponent and CommentRow |
| W2514 | G489 | medium | W2511 | Stage attachments in the task form and store them after the task is saved |
| W2515 | G489 | small | W2511–W2514 | Document attachments in Resources, docs/attachments.md, CHANGELOG and ROADMAP |
| W2516 | G490 | medium | W2508 | Add attachment metadata to task JSON on the show and claim responses |
| W2517 | G490 | medium | W2516, W2508 | Add the GET /api/tasks/:id/attachments/:attachment_id download endpoint |
| W2518 | G490 | medium | W2517 | Add the stride_get_attachment MCP tool with bounded inline text content |
| W2519 | G490 | medium | W2505, W2508 | Carry task attachments in workspace export archives and the self-host import |
| W2520 | G490 | small | W2516, W2517, W2518 | Document task attachments for agents in the workflow, API and onboarding docs |
| W2521 | G491 | medium | — | Write the cross-port task-attachments contract in stride/docs/porting-attachments.md |
| W2522 | G491 | medium | W2521, W2516, W2517 | Download task attachments in the stride claim hook |
| W2523 | G491 | medium | W2522 | Use downloaded attachments in the stride workflow, its agents and the Step 7 cleanup |
| W2524 | G491 | medium | W2522, W2516, W2517 | Download task attachments in the stride-gemini claim hook |
| W2525 | G491 | medium | W2523, W2524 | Use downloaded attachments in stride-gemini skills and agents, and remove them at Step 7 |
| W2526 | G491 | medium | W2522, W2516, W2517 | Download task attachments from the observed claim response in the stride-copilot hook |
| W2527 | G491 | medium | W2523, W2526 | Use downloaded attachments in stride-copilot's reading, explorer and self-review steps |
| W2528 | G491 | medium | W2522, W2516, W2517 | Download task attachments in the stride-codex PostToolUse claim arm |
| W2529 | G491 | medium | W2523, W2528 | Use downloaded attachments in stride-codex skills and agents, and remove them at Step 8 |
| W2530 | G491 | medium | W2522, W2516, W2517 | Download and remove task attachments in the stride-opencode plugin |
| W2531 | G491 | small | W2523, W2530 | Use downloaded attachments in stride-opencode skills and agents |
| W2532 | G491 | medium | W2522, W2516, W2517 | Download task attachments in the stride-pi hook-bridge extension |
| W2533 | G491 | medium | W2523, W2532 | Use downloaded attachments in stride-pi skills and both agent copies, and add Step 7 cleanup |

The critical path runs W2505/W2506/W2507 → W2508 → W2516 → W2517 → W2522 → W2523 → the five other ports. G489 runs in parallel with G490 once W2508 is done, and W2521 can start at any time.

---

## 12. Open points

These were the places where the goals disagreed with each other or with the current repository. All of them were settled on 2026-11-01, apart from point 5, which is a standing rule for G491. The affected tasks were updated to match the same day.

1. **Can a free board still read its files?** Settled on 2026-11-01: **no.** Attachments are only for Organization boards, so a free board under enforcement cannot list, download or delete files either ([§4.3](#43-plan-gate)). G489's and G490's tasks already follow this rule. G488's do not: its acceptance criteria, W2507 and W2508 keep files readable and deletable on a board that left its Organization, so they must be changed to gate every `Kanban.Attachments` function before they are claimed.
2. **MB or MiB.** Settled on 2026-11-01: **25 MiB everywhere.** The server's per-file limit stays 26,214,400 bytes. The plugin contract states every cap in bytes ([§9.1](#91-the-contract-w2521)), so a plugin never skips a file the server stored, and the UI text that W2511 and W2515 write names the limit as 25 MiB.
3. **ROADMAP placement.** Settled on 2026-11-01: the Attachments bullet is now in the *🚧 In progress* section, so W2515's ROADMAP step only checks that it is still there and still accurate.
4. **ROADMAP wording.** Settled on 2026-11-01: **the roadmap text changes, not the scope.** The entry now says people drag a file onto a task or comment or browse for one, that agents read a task's files through the API, and that attachments are for Organization boards. Pasting screenshots and agent uploads stay out of scope.
5. **Shipped shape before plugin work.** G491's tasks require re-checking the shipped `data.attachments` shape before coding, and any difference from the contract must be followed and named in the completion notes.
6. **The download contract has a second user.** Settled on 2026-11-01: **W2521's contract defines the rewrite case** in a section of its own, as [§9.1](#91-the-contract-w2521) summarises under *Rewrite downloads*. The Jira import's `stride-import` plugin ([Import from Jira](IMPORT-FROM-JIRA-DESIGN.md#6a5-how-a-rewrite-runs)) follows that section rather than listing its own exceptions. It covers the layout, the manifest's `rewrite` field and `jira_key`, identity by the bundle hash, the curl guard (no exemption while the plugin downloads through its own script), cleanup after the draft is submitted, and the caps: 25 MiB per file, 20 files per Jira issue, and 500 MiB per rewrite within 600 s.
7. **What the import adds to G488.** Settled on 2026-11-01. The Jira import builds these itself, on top of G488:
   - `Kanban.Attachments.import_attachment/4`. It takes no user scope, sets `uploaded_by_id` to the matched Jira author, keeps the Jira upload time and sends no per-file broadcast. It emits the normal `uploaded` and `upload_refused` events with `source` set to `import`, so G488 gives those events a `source` tag from the start ([§10](#10-telemetry-audit-and-docs)).
   - The `import_rewrite_files` table. It holds a rewrite's source files until sign-off, uses the same tombstone table, and **counts against the quota** while it holds them. The import extends `Kanban.Attachments.Usage` to count it beside `task_attachments`.
   - The copy at sign-off. The worker streams each stored file to a temp file and `put`s it under the new key. The storage behaviour gets no copy callback, so W2505 does not change.
