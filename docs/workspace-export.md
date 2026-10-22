# Workspace Export

An org-admin can download a workspace of their Organization as a zip archive,
as a backup or to move the workspace to another Stride instance. This page
covers what the archive holds, how to request and download it, and how a
self-hosted instance imports it.

## Who can export

- Only an org-admin of the workspace's Organization sees the Export section
  and can request or download an export. Members and guests cannot.
- Only Organization workspaces can be exported. A personal workspace has no
  export.

## Requesting an export

1. Open the workspace settings at `/workspace/settings` and choose the
   **Export** section.
2. Click **Request export**. Stride builds the archive in the background, so
   you can leave the page while it runs.
3. **Recent exports** lists the latest exports, newest first, with who
   requested each one and when it expires. When an export is ready, its
   **Download** link appears there.

Only one export of a workspace runs at a time. Requesting another while one is
pending or running is refused until it finishes.

## What the archive holds

The archive is a zip of JSON files: a `manifest.json` and one file for each
kind of record. It holds the workspace's boards and what is on them:

- boards, columns and labels
- tasks, comments and task history
- board and workspace memberships, including guests

Users appear only by id, email and name, and only when something in the
archive refers to them.

The archive never contains anything that signs anyone in: no password or token
hashes, no session or invitation tokens, no API tokens and no webhook secrets.
It also leaves out the Organization itself, webhook endpoints, notifications,
workspace invitations, metrics, audit events and earlier exports.

## How long an archive is kept

A finished archive stays downloadable for 7 days. An hourly cleanup job then
deletes the archive and marks the export expired. The same job marks an export
that has been pending or running for more than 6 hours as failed.

## Importing an archive into a self-hosted instance

On your own Stride instance, an operator restores an archive as a **new**
workspace of an existing Organization:

```bash
mix kanban.import_workspace --file PATH --org-admin-email admin@example.com --dry-run
mix kanban.import_workspace --file PATH --org-admin-email admin@example.com
```

- `--org-admin-email` must belong to an enabled org-admin of the target
  Organization. The workspace is created in that Organization; the archive
  never creates or chooses one.
- `--dry-run` checks the archive and counts what would be imported, then rolls
  everything back.
- The import runs in one transaction, so it either lands whole or not at all.
- Users are matched by email and never created. Anyone with no account on the
  instance, a disabled account, or an account outside the Organization is
  left unattributed and listed in the report, so you can invite them.

In a production release, where Mix is not available, call
`Kanban.Release.import_workspace/3` with `bin/kanban eval` instead.

## Where archives are stored (self-hosting)

Archives are written under the directory named by the `EXPORT_DIR` environment
variable, or a `stride_exports` directory in the system temp directory when it
is unset. With more than one app machine, point `EXPORT_DIR` at storage they
all share. Give each deployment its own `EXPORT_DIR`: the cleanup deletes any
archive directory whose workspace its database does not know.
