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
unset variable keeps the default shown. An invalid value stops the boot with
an error that names the variable and never prints its value.

S3 requests are signed with AWS Signature Version 4 by Req, the HTTP client
Stride already uses, so no AWS SDK is installed.

## Environment variables

### Choosing the adapter

| Variable | Default | Meaning |
|---|---|---|
| `ATTACHMENTS_STORAGE` | `local` | `local` or `s3`. Any other value stops the boot. |

### Local disk

| Variable | Default | Meaning |
|---|---|---|
| `ATTACHMENTS_DIR` | a `stride_attachments` directory in the system temp directory | The directory files are written under. Created if missing. |

### S3-compatible storage

Each S3 setting reads its `ATTACHMENTS_S3_*` name first, then the name in the
second column. Those second names are the secrets that `fly storage create`
sets on a Fly app, so on Fly with Tigris you set only `ATTACHMENTS_STORAGE=s3`
and the region. When `ATTACHMENTS_STORAGE` is `s3`, a missing bucket, access
key id or secret access key stops the boot, and the error lists which
variables are missing.

| Variable | Falls back to | Default | Meaning |
|---|---|---|---|
| `ATTACHMENTS_S3_BUCKET` | `BUCKET_NAME` | none, required | The bucket that holds every attachment. |
| `ATTACHMENTS_S3_ACCESS_KEY_ID` | `AWS_ACCESS_KEY_ID` | none, required | The access key id requests are signed with. |
| `ATTACHMENTS_S3_SECRET_ACCESS_KEY` | `AWS_SECRET_ACCESS_KEY` | none, required | The secret access key. Never logged. |
| `ATTACHMENTS_S3_ENDPOINT` | `AWS_ENDPOINT_URL_S3` | `https://s3.<region>.amazonaws.com` | The store's base URL, for example `https://fly.storage.tigris.dev` for Tigris or `http://localhost:9000` for a local MinIO. It must start with `http://` or `https://`, or the boot stops. |
| `ATTACHMENTS_S3_REGION` | `AWS_REGION` | `us-east-1` | The region requests are signed for. Use `auto` for Tigris. |
| `ATTACHMENTS_S3_PATH_STYLE` | none | `false` | `true` addresses objects as `<endpoint>/<bucket>/<key>` instead of `<bucket>.<endpoint host>/<key>`. Only the exact string `true` turns it on. MinIO usually needs it. |

For AWS S3, set the bucket, the region and the two keys, and leave the
endpoint unset. For MinIO, set the endpoint (for example
`http://localhost:9000`) and `ATTACHMENTS_S3_PATH_STYLE=true`, and keep the
region at its default.

Storage calls run inside user requests, so a transient failure (a timeout, a
refused or closed connection, or a 408, 429, 500, 502, 503 or 504 from the
store) is retried twice, 250 and then 500 milliseconds apart, before the
upload or download fails. Redirects are never followed, so a misconfigured
endpoint cannot send a signed request to another host. When the store
refuses a request, the app log shows only the operation and the HTTP
status, such as
`attachment storage put failed with status 403`; it never shows a header, a
signed URL or a credential.

### Limits

| Variable | Default | Meaning |
|---|---|---|
| `ATTACHMENTS_MAX_FILE_MB` | `25` | The largest single file, in mebibytes (25 means 26,214,400 bytes). |
| `ATTACHMENTS_MAX_FILES_PER_TASK` | `20` | How many files one task can hold. |
| `ATTACHMENTS_ORG_QUOTA_GB` | `10` | The total size of every file in one Organization, in gibibytes (10 means 10,737,418,240 bytes). |

Each must be a positive whole number; `0`, a negative number or a value such
as `2.5` stops the boot. They are stored as
`config :kanban, Kanban.Attachments.Limits` with the keys `max_file_bytes`,
`max_files_per_task` and `organization_quota_bytes`.

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
`ATTACHMENTS_DIR`. This is single-machine storage, and it has three caveats:

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
`0o600`, so only the user the app runs as can read them. A file is written
to a temporary name in a private `.staging` directory under
`ATTACHMENTS_DIR`, synced to disk and then renamed into place, so a crash
never leaves a half-written file behind. `.staging` must stay `0o700`: if
group or others can read it, uploads fail with `:untrusted_directory`.
Stride never serves a symbolic link or a file whose real path leaves
`ATTACHMENTS_DIR`, and never writes through a linked directory below it.
`ATTACHMENTS_DIR` itself may be a link, for example to a mounted volume, but
the default directory under the system temp directory may not.

Give each deployment its own `ATTACHMENTS_DIR` or bucket. Two deployments
sharing one would read and delete each other's files.
