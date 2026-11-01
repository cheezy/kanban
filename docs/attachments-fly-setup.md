# Fly Attachment Storage Runbook

This runbook is for the operator who deploys Stride to Fly. It lists, in
order, exactly what to run to store attachment files in a Tigris bucket for
the two Fly apps, how to check that it works, and how to roll it back. The
variables it sets are explained in [Attachments](attachments.md).

| App | Config file | Bucket name used below |
|---|---|---|
| `kanban-prod` | `fly.production.toml` | `stride-attachments-prod` |
| `kanban-review` | `fly.review.toml` | `stride-attachments-review` |

Do the review app first, so a mistake surfaces there. Each app gets its own
bucket and its own keys, so the review app can never read or delete
production files. Bucket names are global across Tigris; if a name is taken,
choose another and use it in every later step.

Why this is needed: neither config file has a `[mounts]` section, so a Fly
machine has no persistent disk and files written locally vanish on the next
deploy.

## Before you start

1. Install `flyctl` and sign in to the organization that owns both apps:

   ```bash
   fly auth login
   fly apps list
   ```

   Both `kanban-prod` and `kanban-review` must appear.
2. Work from the repository root, on a commit that contains the attachment
   storage code (`lib/kanban/attachments/storage/s3.ex` exists).

## Set up the review app (`kanban-review`)

1. **Create the bucket.** This also sets `BUCKET_NAME`, `AWS_ENDPOINT_URL_S3`,
   `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as secrets on the app:

   ```bash
   fly storage create -a kanban-review -n stride-attachments-review
   ```

   Keep the bucket private when asked. The command prints the credentials
   once; you do not need to copy them, because they are already app secrets.
2. **Check the secrets landed.** `fly secrets list` shows names and digests,
   never values:

   ```bash
   fly secrets list -a kanban-review
   ```

   `BUCKET_NAME`, `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY` must all be listed. If one is missing, set it with
   `fly secrets set NAME=value -a kanban-review --stage`, using the value from
   the Tigris dashboard.
3. **Switch Stride to the S3 adapter.** `--stage` stores the secrets without
   restarting the machines, so the deploy in the next step picks them up:

   ```bash
   fly secrets set ATTACHMENTS_STORAGE=s3 ATTACHMENTS_S3_REGION=auto -a kanban-review --stage
   ```

4. **Deploy** from the repository root. This is the command the CI deploy
   job runs; there is no plain `Dockerfile`, so name the review one:

   ```bash
   fly deploy --remote-only --config fly.review.toml --dockerfile Dockerfile.review
   ```

   If the boot fails, read the log. A missing variable is named there, without
   its value:

   ```bash
   fly logs -a kanban-review
   ```

   The line reads `ATTACHMENTS_STORAGE is s3 but these environment variables
   are missing:` followed by the missing names. Set them as in step 2 and
   deploy again.
5. **Verify a put, a read and a delete.** Machines stop when idle, so open the
   app in a browser first (or run `fly machine start -a kanban-review`). Then
   open a remote console on a running machine:

   ```bash
   fly ssh console -a kanban-review -C "/app/bin/kanban remote"
   ```

   Paste these lines into the console, one at a time:

   ```elixir
   alias Kanban.Attachments.Storage
   Storage.adapter()
   Storage.put("verify/fly-setup", {:binary, "stride attachment check"})
   with {:ok, stream} <- Storage.stream("verify/fly-setup"), do: stream |> Enum.to_list() |> IO.iodata_to_binary()
   Storage.delete("verify/fly-setup")
   Storage.exists("verify/fly-setup")
   ```

   Expected results, in order: `Kanban.Attachments.Storage.S3`, `:ok`,
   `"stride attachment check"`, `:ok`, `{:ok, false}`. Leave the console with
   `Ctrl+C` twice.

   If a call returns `{:error, :storage_unavailable}`, run
   `fly logs -a kanban-review` and look for `attachment storage put failed`.
   A status `403` means the keys do not match the bucket: repeat step 2. A
   failure with no status (a transport error) usually means the endpoint
   cannot be reached with virtual-hosted addressing; set
   `ATTACHMENTS_S3_PATH_STYLE=true` with
   `fly secrets set ATTACHMENTS_S3_PATH_STYLE=true -a kanban-review`, which
   restarts the machines, and repeat this step.

## Set up the production app (`kanban-prod`)

Repeat the same five steps with the production names:

1. `fly storage create -a kanban-prod -n stride-attachments-prod`
2. `fly secrets list -a kanban-prod`, and check the four Tigris secrets are
   listed.
3. `fly secrets set ATTACHMENTS_STORAGE=s3 ATTACHMENTS_S3_REGION=auto -a kanban-prod --stage`
4. `fly deploy --remote-only --config fly.production.toml --dockerfile Dockerfile.production`,
   and on a failed boot read `fly logs -a kanban-prod`.
5. `fly ssh console -a kanban-prod -C "/app/bin/kanban remote"`, then paste
   the same verification lines and expect the same results.

## Roll back

Rolling back sends new uploads to the machine's temporary disk again, where
they are lost on the next deploy. Files already in the bucket stay there,
untouched, and become reachable again once you re-enable S3.

1. **Return the app to the local adapter.** This restarts the machines:

   ```bash
   fly secrets unset ATTACHMENTS_STORAGE -a kanban-review
   ```

   Use `-a kanban-prod` for production. Without `ATTACHMENTS_STORAGE` the
   other `ATTACHMENTS_S3_*` secrets are ignored, so they can stay.
2. **Check the adapter** from a remote console as in step 5:
   `Storage.adapter()` must return `Kanban.Attachments.Storage.Local`.
3. **Only if you are abandoning the bucket for good**, destroy it and remove
   its secrets. Destroying a bucket deletes every file in it and cannot be
   undone:

   ```bash
   fly storage destroy stride-attachments-review
   fly secrets unset BUCKET_NAME AWS_ENDPOINT_URL_S3 AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY -a kanban-review
   ```

   Never destroy the production bucket while any attachment row still points
   at it.
