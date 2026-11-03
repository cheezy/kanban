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
- task attachments: their details in `attachments.json` and each file's bytes
  as its own `attachments/<id>` entry
- board and workspace memberships, including guests

Users appear only by id, email and name, and only when something in the
archive refers to them.

An attachment's row in `attachments.json` holds its id, task, comment,
uploader, file name, content type, size, sha256 and upload time. It never
holds where the file is stored: an import stores every file again under a
key of its own. See [attachments](attachments.md) for the files themselves.

Attachments make an archive about as large as the files attached to the
workspace's tasks, because most attachments (images, PDFs) are compressed
already and barely shrink in the zip. A workspace with gigabytes of
attachments gives a download of gigabytes.

One lost file does not stop the rest of the workspace from being exported.
A file that is missing from storage when the export runs (deleted after the
export started, or lost), or that no longer matches its size and sha256, is
left out together with its `attachments.json` row. The manifest counts only
the attachments the archive holds, and lists each one left out under
`skipped_attachments`, by id, with the reason `missing` or `changed`:

```json
"skipped_attachments": [{"id": 412, "reason": "missing"}]
```

An export that left nothing out has no `skipped_attachments` key. A storage
outage while the files are copied still fails the export, as
`storage_unavailable`, so a retry can get every file.

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
- The report and any error print names from the archive (workspace, board,
  column, label and file names, task identifiers and emails) as given,
  except that a control character is shown as a visible escape: ESC as `\e`,
  newline as `\n`, other control bytes as `\x07` and the like, and
  bidirectional controls as `\u{202E}` and the like. A crafted archive
  cannot send control sequences to your terminal this way. The imported
  names themselves are not changed.

### Attachments in an import

The archive is treated as untrusted, so its attachments are checked before
anything is kept:

- Each file must be an entry named `attachments/<id>`, with one entry for
  every `attachments.json` row and one row for every entry. Directory
  entries, other names under `attachments/`, duplicates, a row with no file
  and a file with no row are all refused as an invalid archive.
- Each file may be at most the per-file limit (`ATTACHMENTS_MAX_FILE_MB`,
  25 MiB by default), and all the files together at most 10 GiB. That budget
  is separate from the 1 GiB limit on the JSON files. An archive whose zip
  headers declare sizes past a limit is refused before anything is
  decompressed. The headers are not trusted, though: each file is also
  measured as it is decompressed, so a file that grows past a limit despite
  smaller declared sizes is refused as too large without being decompressed
  in full.
- Each file's size and sha256 are recomputed and must match its row, or the
  archive is refused.
- Each file's name and content type are checked like an upload's: the same
  file-name rules, the same allowed types, and the file's contents must match
  its type. A file that fails these checks, such as one uploaded before a
  check existed, is skipped and named in the report, and the rest of the
  archive imports.
- The files must fit in the Organization's storage quota
  (`ATTACHMENTS_ORG_QUOTA_GB`). This is checked before any file is written,
  and again just before the import commits, counting files uploaded to the
  Organization meanwhile. Uploads are not held up while the import runs. The
  first check counts every file in the archive, including any later skipped.
- A task keeps no more files than `ATTACHMENTS_MAX_FILES_PER_TASK`: the
  first ones, in id order. Each file beyond the limit is skipped and named
  in the report.
- Each file the export left out (its manifest's `skipped_attachments`) is
  named in the report too, so the report lists every file the new workspace
  does not have.
- `--dry-run` checks every file the same way and stores none.
- If the import is refused or fails after some files were stored, every file
  it stored is deleted again.

An archive from before attachments were exported (`format_version` 1) still
imports, with no attachments. An archive this version writes
(`format_version` 2) cannot be imported by an older Stride instance, which
refuses the unknown version; upgrade the instance first.

In a production release, where Mix is not available, call
`Kanban.Release.import_workspace/3` with `bin/kanban eval` instead.

## Where archives are stored (self-hosting)

Archives are written under the directory named by the `EXPORT_DIR` environment
variable, or a `stride_exports` directory in the system temp directory when it
is unset. With more than one app machine, point `EXPORT_DIR` at storage they
all share. Give each deployment its own `EXPORT_DIR`: the cleanup deletes any
archive directory whose workspace its database does not know.
