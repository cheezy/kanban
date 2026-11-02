# Attachments

This document is for operators who run Stride: where attachment files are
stored, the environment variables that choose and configure that storage, the
limits on uploads, and what to watch for when you self-host. For the exact Fly
commands, see the [Fly attachment storage runbook](attachments-fly-setup.md).

## Where attachment files are stored

Stride stores the bytes of each attachment through one storage interface,
`Kanban.Attachments.Storage`, with two adapters:

| Adapter | `ATTACHMENTS_STORAGE` | Use it for |
|---|---|---|
| Local disk (`Kanban.Attachments.Storage.Local`) | `local`, or unset | Development, tests and a single-machine self-hosted instance |
| S3-compatible (`Kanban.Attachments.Storage.S3`) | `s3` | Fly (with Tigris), AWS S3, MinIO, or any store that speaks the S3 API |

The adapter is chosen at boot from the environment and nothing else. Every
variable below is read by `config/runtime.exs` only when it is set, so an
unset variable keeps the default shown. Each value is trimmed, and a variable
that is empty or only whitespace counts as unset. An invalid value stops the
boot with an error that names the variable and never prints its value.

S3 requests are signed with AWS Signature Version 4 by Req, the HTTP client
Stride already uses, so no AWS SDK is installed.

## Environment variables

### Choosing the adapter

| Variable | Default | Meaning |
|---|---|---|
| `ATTACHMENTS_STORAGE` | `local` | `local` or `s3`, in any case. Any other value stops the boot. |

### Local disk

| Variable | Default | Meaning |
|---|---|---|
| `ATTACHMENTS_DIR` | a `stride_attachments` directory in the system temp directory | The directory files are written under. Created if missing. It must be an absolute path to a writable directory, or to a path that can be created inside one, or the boot stops: a regular file, a read-only directory or a path under either is refused. |

### S3-compatible storage

The bucket, the two keys and the endpoint are read as one set. When any of
`ATTACHMENTS_S3_BUCKET`, `ATTACHMENTS_S3_ACCESS_KEY_ID`,
`ATTACHMENTS_S3_SECRET_ACCESS_KEY` or `ATTACHMENTS_S3_ENDPOINT` is set, all
four are read from those names and the second column is ignored. Otherwise
all four are read from the names in the second column, the secrets that
`fly storage create` sets on a Fly app, so on Fly with Tigris you set only
`ATTACHMENTS_STORAGE=s3` and the region. Reading each setting on its own
would let one deploy mix two providers, such as AWS keys with a Tigris
endpoint left over from an earlier setup. `ATTACHMENTS_S3_REGION` applies to
either set; `AWS_REGION` is used only with the second-column names. When
`ATTACHMENTS_STORAGE` is `s3`, a missing bucket, access key id or secret
access key stops the boot, and the error lists which variables are missing.

| Variable | Falls back to | Default | Meaning |
|---|---|---|---|
| `ATTACHMENTS_S3_BUCKET` | `BUCKET_NAME` | none, required | The bucket that holds every attachment. |
| `ATTACHMENTS_S3_ACCESS_KEY_ID` | `AWS_ACCESS_KEY_ID` | none, required | The access key id requests are signed with. |
| `ATTACHMENTS_S3_SECRET_ACCESS_KEY` | `AWS_SECRET_ACCESS_KEY` | none, required | The secret access key. Never logged. |
| `ATTACHMENTS_S3_ENDPOINT` | `AWS_ENDPOINT_URL_S3` | `https://s3.<region>.amazonaws.com` | The store's base URL, for example `https://fly.storage.tigris.dev` for Tigris or `http://localhost:9000` for a local MinIO. It must be an `http://` or `https://` URL whose host is a name or an IPv4 address, with a port from 1 to 65535 if any, and no user name or password, query or fragment, or the boot stops. A path on it, such as `https://proxy.example/s3`, is kept in front of every object's path. An IPv6 address such as `http://[fdaa::3]:9000` is not supported and stops the boot, because the request signer drops the brackets from the host. Use a host name that resolves to it. |
| `ATTACHMENTS_S3_REGION` | `AWS_REGION` (only with the second-column names) | `us-east-1` | The region requests are signed for. Use `auto` for Tigris. It must be lowercase letters and digits joined by hyphens, such as `eu-west-1`, or the boot stops, since it is also part of the default AWS host name. `auto` needs an endpoint: it has no AWS host, so `auto` with no endpoint stops the boot. |
| `ATTACHMENTS_S3_PATH_STYLE` | none | `false` | `true` (or `1`) addresses objects as `<endpoint>/<bucket>/<key>` instead of `<bucket>.<endpoint host>/<key>`; `false` (or `0`) turns it off. Case is ignored, and any other value stops the boot. MinIO usually needs it. Path style is used anyway when the endpoint is an IPv4 address or the bucket name contains a dot, since neither works with a virtual-hosted address. |

In production, when the storage is local (`ATTACHMENTS_STORAGE` unset or
`local`) and `ATTACHMENTS_DIR` is not set, the boot prints a warning: files would be kept under the system temp
directory, which does not survive a reboot or, on Fly, a redeploy. The app
still starts, so an instance that does not offer attachments yet is not
blocked.

For AWS S3, set the bucket, the region and the two keys, and leave the
endpoint unset. For MinIO, set the endpoint (for example
`http://localhost:9000`) and `ATTACHMENTS_S3_PATH_STYLE=true`, and keep the
region at its default.

Storage calls run inside user requests, so a transient failure (a timeout, a
refused or closed connection, or a 408, 429, 500, 502, 503 or 504 from the
store) is retried twice, 250 and then 500 milliseconds apart, before the
upload or download fails. Each try waits at most 5 seconds to connect and
30 seconds for each read, and an upload, a delete or an existence check also
gives up after 60 seconds in all, so a store that sends its reply a byte at a
time cannot hold the request. A download has no overall limit, since a large
file on a slow link takes as long as it takes. Redirects are never followed, so a misconfigured
endpoint cannot send a signed request to another host. When the store
refuses a request, the app log shows only the operation, the HTTP status
and the store's error code, such as
`attachment storage delete failed with status 404 (NoSuchBucket)`; it never
shows a header, a signed URL, a response body or a credential. Only a 404
with the code `NoSuchKey` counts as a file that is already gone. A 404 for a
bucket that does not exist, or from an endpoint that is not the store, is a
storage failure: the cleanup job keeps its queue entry and tries again, and
a download logs a warning instead of looking like a missing file.

### Limits

| Variable | Default | Meaning |
|---|---|---|
| `ATTACHMENTS_MAX_FILE_MB` | `25` | The largest single file, in mebibytes (25 means 26,214,400 bytes). |
| `ATTACHMENTS_MAX_FILES_PER_TASK` | `20` | How many files one task can hold. |
| `ATTACHMENTS_ORG_QUOTA_GB` | `10` | The total size of every file in one Organization, in gibibytes (10 means 10,737,418,240 bytes). A board outside any Organization, which can hold files only while plans are not enforced, has a quota of this size of its own. |

Each must be a whole number of digits from 1 up to a ceiling: 5120 for
`ATTACHMENTS_MAX_FILE_MB` (5 GiB, the largest single upload S3 accepts), 1000
for `ATTACHMENTS_MAX_FILES_PER_TASK` and 1048576 for
`ATTACHMENTS_ORG_QUOTA_GB`. `0`, a sign, a value such as `2.5` or `25MB`, or
one above its ceiling stops the boot. They are stored as
`config :kanban, Kanban.Attachments.Limits` with the keys `max_file_bytes`,
`max_files_per_task` and `organization_quota_bytes`.
`Kanban.Attachments.Limits` reads them each time a limit is checked, and
falls back to the defaults above for any key that is not set.

## Which files can be attached

An attachment must be one of these types:

| Type | Extensions |
|---|---|
| PNG, JPEG, GIF and WebP images | `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp` |
| PDF | `.pdf` |
| Plain text | `.txt`, `.log` |
| Markdown | `.md`, `.markdown` |
| CSV | `.csv` |
| JSON | `.json` |

SVG and HTML are refused because a browser runs scripts inside them, and zip
archives are refused because their contents cannot be checked and an agent
that unpacks one risks a zip bomb. When an upload declares no type, or
declares `application/octet-stream`, Stride takes the type from the file's
extension. The other names browsers and operating systems report for an
allowed type are read as that type: `image/jpg`, `image/pjpeg` and
`image/x-png`, `application/x-pdf`, `text/x-markdown`, `text/x-csv`,
`text/comma-separated-values` and `application/csv`, `text/x-log`, and
`text/json` and `text/x-json`. `application/vnd.ms-excel`, which Windows
reports for a `.csv` file when Excel is installed, is read as CSV only for a
name ending in `.csv`, since it also names Excel's own formats. A file name's extension must agree with the file's type, so
`report.html` or `logo.svg` declared as plain text is refused rather than
stored under a name that would open it as HTML or SVG. A name with no
extension, such as `README`, is accepted when the upload declares an allowed
type such as `text/plain`; declared as no type or as
`application/octet-stream`, it has no extension to take a type from and is
refused, so rename it (`README.txt`) to attach it. A name that starts with a
dot, such as `.html`, counts that as its extension. Plain text also accepts the extension of any other text
type (`.md`, `.csv`, `.json`, `.log`).

Stride also checks the first bytes of every file against its type
(`Kanban.Attachments.ContentType`). An image or PDF must begin with that
format's signature, so a PDF renamed to `.png` is refused. A text file is
refused when it starts with another format's signature or when any byte of
the whole file is a NUL byte, so a zip archive or an executable hidden
behind a text prefix is refused too. Text does not have to be UTF-8, so
Latin-1 CSV exports are accepted. UTF-16 text is refused: always when it
starts with a byte-order mark, and otherwise whenever a character in it
encodes with a NUL byte, as every ASCII character, space and newline does.
UTF-16 text with neither, such as a few words of Chinese with no spaces and
no byte-order mark, cannot be told from other text and is accepted.

File names are cleaned before they are stored
(`Kanban.Attachments.Filename`): any directory part is dropped (`../../x.png`
becomes `x.png`), control characters and right-to-left override characters
are removed, and the name is shortened to 255 characters, keeping its
extension. The zero-width joiner and non-joiner are kept, because emoji such
as 👨‍👩‍👧 and scripts such as Persian need them.

Stride reads an uploaded file once, into a private copy, and checks and
stores that copy, so the stored bytes are always the bytes whose size, type
and checksum were checked.

## When attachment files are deleted

Attachment rows live in the `task_attachments` table. A database trigger on
that table records the storage key of every deleted row in
`attachment_blob_deletions`, whichever path deleted it: deleting the file
itself, its comment, its task or its board, the archived-task retention
purge, or deleting an account. That queue is the list of stored files to
remove from the storage adapter, so a cascaded delete cannot lose track of a
file. Deleting the user who uploaded a file does not by itself remove the
file: its row stays, without an uploader, unless its task or board is
deleted too (account deletion also deletes boards that only that user uses,
and their files with them).

The `Kanban.Attachments.BlobCleanupWorker` job drains that queue every 15
minutes on the `:attachments` Oban queue, deleting each stored file and then
its queue entry. An entry whose key an attachment row still names is dropped
without touching the file, so the job can never remove a file that a live
attachment points to. A file the store cannot delete is retried with a
growing delay, up to one day apart, counted from the moment it was tried.

Each run takes at most 200 entries and stops taking new ones after 10
minutes, leaving the rest for the next run, and Oban ends a run outright at
30 minutes. That keeps a run against a store that hangs well inside Oban's
one-hour Lifeline rescue, which would otherwise start a second run beside
it.

The trigger fires for `DELETE` statements only. Never empty
`task_attachments` with `TRUNCATE`, which skips row triggers and would leave
every stored file in place.

## Fly with Tigris

Fly machines in this deployment have no volume (`fly.production.toml` and
`fly.review.toml` have no `[mounts]`), so files written to local disk vanish
on every redeploy. Fly apps must therefore use the S3 adapter with a Tigris
bucket. In short, for each app:

1. Create a bucket with `fly storage create`, which sets `BUCKET_NAME`,
   `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as
   app secrets.
2. Set `ATTACHMENTS_STORAGE=s3` and `ATTACHMENTS_S3_REGION=auto`.
3. Deploy, then check a put, a read and a delete from a remote console.

Give each app its own bucket, so the review app can never read or delete
production files. The [Fly attachment storage runbook](attachments-fly-setup.md)
has every command, the verification and the rollback.

## Self-hosting on local disk

With `ATTACHMENTS_STORAGE` unset or `local`, files are written under
`ATTACHMENTS_DIR`. This is single-machine storage, and it has four caveats:

- **Use a persistent directory.** The default lives in the system temp
  directory, which many hosts clear on reboot. Set `ATTACHMENTS_DIR` to a
  directory on persistent storage that is backed up with the database. A
  database restored without its files lists attachments that can no longer be
  downloaded.
- **One machine only.** A file is visible only on the machine that wrote it.
  With more than one app machine, use S3-compatible storage, or point every
  machine's `ATTACHMENTS_DIR` at one shared filesystem.
- **No volume, no files.** On a host with no persistent volume, such as a Fly
  machine without `[mounts]`, every file disappears on redeploy.
- **Owned by the app's user.** `ATTACHMENTS_DIR` and every directory under it
  must be owned by the user the app runs as, with no group or other write
  bit. A shared filesystem must present that same user ID on every machine.
  Otherwise Stride refuses the directory and every attachment call fails,
  with a log line such as
  `attachment storage put failed: :untrusted_directory`. The same check stops
  Stride from writing into a directory another local user created first,
  such as the default one under a shared `/tmp`.

Stride creates the directories it writes as `0o700` and its files as
`0o600`, so only the user the app runs as can read them. Files are kept
under `boards/<board id>/`, and when a board's last file is removed the
emptied directory goes too, so a deleted board leaves no directory named
after it. A file is written
to a temporary name in a private `.staging` directory under
`ATTACHMENTS_DIR`, synced to disk and then renamed into place, so a crash
never leaves a half-written file under a file's real name. A write cut off
mid-way (the app killed or restarted during an upload) can leave its
temporary file in `.staging`; the cleanup job removes it once it is an hour
old. `.staging` must stay `0o700`: if
group or others can read it, uploads fail with `:untrusted_directory`.
Stride never serves a symbolic link or a file whose real path leaves
`ATTACHMENTS_DIR`, and never writes through a linked directory below it.
`ATTACHMENTS_DIR` itself may be a link, for example to a mounted volume, but
the default directory under the system temp directory may not.

Give each deployment its own `ATTACHMENTS_DIR` or bucket. Two deployments
sharing one would read and delete each other's files.

## Using attachments

This section is for the people who use attachments on a board. The in-app
Resources guide *Attaching Files to Tasks and Comments*
(`/resources/attaching-files-to-tasks-and-comments`) walks through the same
steps.

Attachments are part of the Organization plan. While plans are enforced, a
free board shows a locked **Attachments** section and an **Available to
organizations** prompt instead of its files; a free board's existing files
stay stored, hidden, and show again once the board moves into an
Organization. [Organizations and Workspaces](organizations.md#plans) covers plans
and moving a board. A task or task form that is already open follows the move
without a reload. If the board loses attachments while files are waiting to be
uploaded, the task's **Attachments** section drops them and names each one in
the error message.

- **Where files are.** A task's details have an **Attachments** section
  above **History** that lists the files attached to the task, and its edit
  form has the same section. A file attached to a comment is listed under that comment.
- **Uploading.** Drag files onto **Drop files here or browse**, or click it to
  pick them, then click **Upload files** once they have finished. A file that
  is too large, of a type that is not allowed, or whose contents do not match
  its type says why and is not attached. **Upload files** waits while a file
  shows an error, or while more files are waiting than the task has room for,
  and says so: cancel those files to upload the rest. A task that already
  holds its limit offers no drop zone until a file is deleted.
- **Images.** PNG, JPEG, GIF and WebP files show a thumbnail; clicking it opens
  the full image. Every other file, PDFs included, shows an icon and is
  opened by downloading it.
- **Comments.** Drag files onto **Attach files** under the comment box, or
  click it, before you post. The files are stored once the comment is saved.
  The comment's author can remove a file while editing the comment, the
  board's owner can delete any comment's file without editing it, and
  deleting a comment deletes its files. Like **Upload files**, **Add
  Comment** waits while a staged file shows an error or more files are
  staged than the task has room for, and says what to cancel.
- **New tasks.** The new-task form has its own **Attachments** field. Its files
  are stored after the task is saved; if one cannot be stored, the task is
  still created and Stride names the file. **Save Task** waits while a staged
  file shows an error, and says to cancel it. The new-goal form works the
  same way, and each form keeps its own files: closing a form, or switching
  from one to the other, leaves nothing staged. On the edit form, uploads and
  deletes happen at once.
- **Deleting.** **Delete** asks you to confirm, and a deleted file cannot be
  brought back. Deleting a task deletes its files.
- **Archived tasks.** The board's **Archive** page shows how many files an
  archived task has under its row, comment files included; open it to
  download them. No file can be uploaded or deleted there. A task's files
  can be deleted again once it is restored.
- **Downloading.** A download declares the file's recorded size. A file whose
  stored bytes are gone or cannot be read is "not found". If the bytes end
  early, the download fails, so the browser never saves part of a file as
  if it were whole. The server logs the attachment id with the reason. A
  `HEAD` request gets the same status and headers with no body, and does not
  read the file. Range requests are not supported: a download is always the
  whole file.

Who can do what follows the board's access, checked on every request:

| Who | Can |
|---|---|
| The board's owner (an org-admin counts as the owner of their Organization's boards) | Upload, download, and delete any file |
| Members with modify access | Upload, download, attach files to their own comments, and delete the files they uploaded |
| Members with read-only access | See and download every file; no upload box, and **Delete** only on a file they uploaded before their access changed |
| Anyone who is not a member, including someone viewing a shared board | Nothing: the files are not listed, and the task says only board members can see its files |

Anyone who can see a task's files can download them, so check who is on the
board before attaching something sensitive.

With the default [limits](#limits), each file can be up to 25 MiB, a task can
hold 20 files counting the files on its comments, and the files in one
Organization share 10 GiB (a board outside an Organization has 10 GiB of its
own). The [types that can be attached](#which-files-can-be-attached)
are PNG, JPEG, GIF and WebP images, PDF, plain text and log files, Markdown,
CSV and JSON; SVG, HTML and zip files are refused.
