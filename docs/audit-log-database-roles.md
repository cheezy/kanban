# Audit Log Database Roles

This document is for operators running Stride who look after its Postgres
database. The security audit log is only tamper-resistant when the role the
application connects as does not own the `audit_events` table, its trigger
function, its two purge functions or the schema holding them. This document
explains which database roles are involved, what each environment ends up
with, and the one-time step an operator runs to harden production. The
statements themselves, the reason atoms and the retention purge are described in
[Audit Log Ownership Hardening](audit-log-hardening.md).

## Role model

Three roles matter:

| Role | Who uses it | What it may do to the audit log |
|---|---|---|
| **App role** | The running application, through `DATABASE_URL` | Insert and read events, draw ids, and call the two purge functions. Nothing else |
| **Owner role** (`kanban_audit_owner`) | Nobody; it cannot log in | Owns the table, its id sequence, the trigger function, the purge functions `audit_events_purge` and `audit_events_purge_organization`, and their schema |
| **Admin role** | An operator, for one command at a time | A superuser that can create the owner role and hand ownership to it |

The app role is never a member of the owner role. The admin credential is
never given to the application: it is typed for one command and is gone when
that command exits.

## Two modes

- **Hardened:** the owner role owns everything listed above and the app role
  holds only the rights in the first row. The append-only trigger and the
  purge floor then hold even against a compromised application.
- **Degraded:** anything else. The application still works, the append-only
  trigger still rejects edits from ordinary code paths, but the app role could
  remove the protection because it owns the objects.

The migrations harden only when they run as a superuser
([When the migration hardens](audit-log-hardening.md#when-the-migration-hardens)).
Otherwise they degrade, log why and finish, so a deploy never fails for lack of
privilege.

## What each environment gets

| Environment | Who runs the migrations | Result | Boot check |
|---|---|---|---|
| Dev and test | A superuser (`postgres`) | Ownership moves, but the status names `app_role_is_superuser`, because the app connects as that same superuser | Off |
| Review apps | The app role, through `release_command` | Degraded until the release command below is run against that database | On |
| Production | The app role, through `release_command` | Degraded until the release command below is run once. On Fly Managed Postgres it stays degraded; see [Fly Managed Postgres](#fly-managed-postgres) | On |

The boot check runs once after the application starts, off the boot path. When
the status is degraded it logs one warning naming every reason, for example
`security_audit_boot_check_degraded reason=owner_role_missing,table_not_owned_by_owner_role`.
It never blocks or crashes startup; if the check itself fails it logs only the
exception type. It runs only where `config/prod.exs` sets
`config :kanban, :audit_log_boot_check, true`.

`release_command` in `fly.production.toml` and `fly.review.toml` stays
`/app/bin/migrate`. Hardening is a separate, manual operator step.

## One-time production provisioning

Run this once per database, after the deploy that ships the hardening
migrations. It is safe to run again: a second run changes nothing and reports
`{:ok, :hardened}`.

This step needs a superuser. A database on Fly Managed Postgres has none, so
skip this section there and read [Fly Managed Postgres](#fly-managed-postgres)
instead.

1. **Get an admin credential** for the production database: a role that is a
   superuser on that cluster. Do **not** run `fly secrets set` with it. Every
   Fly secret is in the running application's environment, so a compromised
   application could read it and undo the separation.
2. **Run the command where `DATABASE_URL` is set** (the release reads the app
   role's name from it) but not inside a long-running app process. Prefer a
   one-off machine started from the current release image and destroyed
   afterwards; see [Open questions](#open-questions).
3. **Type the admin URL so it never lands in shell history or a file**, and
   pass it to that one command only:

   ```bash
   read -rs ADMIN_URL
   AUDIT_LOG_ADMIN_DATABASE_URL="$ADMIN_URL" /app/bin/kanban eval 'Kanban.Release.harden_audit_log() |> IO.inspect()'
   unset ADMIN_URL
   ```

   The URL has the usual shape, `ecto://ADMIN_USER:ADMIN_PASSWORD@HOST/DATABASE`.
   `HOST` and `DATABASE` must be the ones in `DATABASE_URL`: when the app
   connects without TLS (`DATABASE_SSL=disable`, normal on Fly's private
   network), the command refuses an admin URL that names a different host.
   The admin connection uses the same TLS setting as the app.
4. **Check the result.** `{:ok, :hardened}` means done. The next boot logs no
   warning.

The command opens one connection of its own (never the app pool, and no
reconnect), runs the table hardening, the purge hardening and the
Organization purge hardening, in that order, in one transaction, and stops
the connection whatever happens. A failing statement rolls everything back.
It logs only result tags and, on a failure, the exception type and database
error code. It never logs the admin URL, its host or its password. Postgrex's
own connection-error line can name the host and port; the password is never
shown.

| Result | Meaning |
|---|---|
| `{:ok, :hardened}` | Hardened |
| `{:ok, {:degraded, reasons}}` | The statements ran but the status check still finds something; the reasons are listed in [Checking the state](audit-log-hardening.md#checking-the-state) |
| `{:error, :admin_url_missing}` | `AUDIT_LOG_ADMIN_DATABASE_URL` is unset or blank |
| `{:error, :admin_url_invalid}` | The URL cannot be parsed, or names no user or host |
| `{:error, :app_role_unknown}` | The app role's name could not be read from the app's database configuration |
| `{:error, :admin_is_app_role}` | The admin URL's user is the app role. Hardening never runs with the app's own rights |
| `{:error, :admin_host_differs_without_tls}` | The app connects without TLS and the admin URL names a different host |
| `{:error, :admin_not_superuser}` | The admin role is not a superuser, so it cannot hand ownership to the owner role |
| `{:error, :admin_connection_failed}` | The admin host could not be reached or refused the login, or the connection dropped mid-command (including a statement that ran past its two-minute limit) |
| `{:error, :admin_timeout}` | The command as a whole did not finish within five minutes |
| `{:error, :hardening_failed}` | A statement failed and nothing was changed. The log line names the database error code, such as `insufficient_privilege`, or `lock_not_available` when another transaction held a lock on `audit_events` for more than ten seconds; run it again when that transaction has finished |

## Checking the status

Before and after hardening, ask the running release:

```bash
/app/bin/kanban eval 'Kanban.Release.audit_log_status() |> IO.inspect()'
```

It connects as the app role through the normal Repo configuration and returns
`:hardened`, or `{:degraded, reasons}` combining the table check, the purge
check and the Organization purge check. Before provisioning, production
reports reasons such as `:owner_role_missing` and
`:table_not_owned_by_owner_role`; afterwards it reports `:hardened`.

## Future migrations that alter audit_events

Once hardened, the app role no longer owns `audit_events`, its trigger
function or its purge functions, and `release_command` runs migrations as the
app role. A later migration that alters any of them (adding a column or index,
replacing the trigger or a purge function, changing their ownership) fails
with `insufficient_privilege` in production.

Such a migration must run through the admin path. Write it so it runs as the
owner role or a superuser, ship it, and apply it with the admin credential
supplied for that one command, the same way as the provisioning step above.
Then run `harden_audit_log` again and check the status, because ownership of
any object the migration created belongs to the role that created it. A
migration that only reads `audit_events` or inserts into it is unaffected.

`20261017210324_add_organization_id_to_audit_events` is such a migration. It
adds the nullable `organization_id` column, a foreign key to `organizations`
with no cascade, and an index on `organization_id`, `inserted_at` and `id`. It
updates no row. On a hardened database apply it through the admin path. The
foreign key adds only internal triggers backed by built-in functions, and the
index calls no user function, so `status/2` reports the same state afterwards.
Dev, test and CI migrate as a superuser, and a degraded database migrates it as
usual.

`20261021120409_add_audit_events_organization_purge_function` is another. Run
as the app role on a hardened database, it installs the Organization purge
function in degraded form, owned by the app role, and the function cannot
delete. Run `harden_audit_log` again after deploying it: until then the status
reports `:organization_purge_function_not_owned_by_owner_role` and the daily
retention job names each Organization in its `failed_steps`
([Organization Security Policies](organization-security-policies.md#after-deploying)).
The site step calls the same function, so it fails too: `failed_steps` also
holds `"site"`, and audit events with no Organization are kept past
`site_audit_retention_days` (90 days by default) until `harden_audit_log` has
been run again.

`20261019230522_add_actor_in_organization_to_audit_events` is another. It adds
the nullable boolean column `actor_in_organization` and updates no row. On a
hardened database apply it through the admin path. A plain boolean column with
no default calls no function, so `status/2` reports the same state afterwards.

`20261112124501_add_txid_to_audit_events` and
`20261112124502_add_audit_events_org_txid_id_index` are another pair, and the
worked example of the procedure in both modes. The first adds the bigint
`txid` column, NOT NULL with a constant default of `0`, which does not rewrite
the table, so every older row reads `0`. It then sets the default to the
inserting transaction's id, `pg_current_xact_id()::text::bigint`, so audit
streaming can read rows in (`txid`, `id`) order below its snapshot horizon
without skipping one that commits late. That order is not commit order: a
transaction that takes its id early and commits last sorts first, which the
horizon accounts for. It updates no row, because the
append-only trigger rejects every update. Both statements run under a
transaction-local `lock_timeout` of 10 seconds. The second builds
`audit_events_org_txid_id_index` on `organization_id`, `txid` and `id` with
`CREATE INDEX CONCURRENTLY`, outside a transaction. The new default calls only
`pg_catalog` functions and the index calls none, so `status/2` reports the same
state afterwards. Dev, test and CI migrate as a superuser.

- **Degraded (Fly Managed Postgres, which is production today).** The app role
  owns `audit_events`, so both migrations run through `release_command` as
  usual. `harden_audit_log` still returns `{:error, :admin_not_superuser}`
  there, as before.
- **Hardened.** `release_command` fails on the first migration with
  `insufficient_privilege`, and the deploy stops with nothing changed. Then:
  1. From a one-off machine started from the new release image, run the
     migrations with the admin URL as `DATABASE_URL` for that one command
     only. Type it so it never lands in shell history or a file, never store
     it with `fly secrets set`, and never log it:

     ```bash
     read -rs ADMIN_URL
     DATABASE_URL="$ADMIN_URL" /app/bin/migrate
     unset ADMIN_URL
     ```

     `HOST` and `DATABASE` must be the ones in the app's usual `DATABASE_URL`.
     Do not connect as the app role and switch to the owner role with
     `SET ROLE` instead: Ecto records each migration in `schema_migrations` on
     the same connection, and the owner role has no rights there.
  2. Redeploy, so `release_command` finds both migrations applied.
  3. Run `Kanban.Release.harden_audit_log()` exactly as in
     [One-time production provisioning](#one-time-production-provisioning),
     with the admin URL supplied again as `AUDIT_LOG_ADMIN_DATABASE_URL` for
     that one command only (without it the call returns
     `{:error, :admin_url_missing}`), expecting `{:ok, :hardened}`:

     ```bash
     read -rs ADMIN_URL
     AUDIT_LOG_ADMIN_DATABASE_URL="$ADMIN_URL" /app/bin/kanban eval 'Kanban.Release.harden_audit_log() |> IO.inspect()'
     unset ADMIN_URL
     ```

     Then run `Kanban.Release.audit_log_status()`, which needs no admin URL,
     expecting `:hardened` ([Checking the status](#checking-the-status)).
- **`lock_not_available`.** Another transaction held a lock on `audit_events`
  for more than 10 seconds, and the migration changed nothing. Run it again
  when that transaction has ended. The timeout is there so the `ALTER`, which
  needs an `ACCESS EXCLUSIVE` lock, never waits indefinitely behind a long
  transaction with every audit insert queued behind it. It bounds that wait
  rather than removing it: for up to 10 seconds, audit inserts queue behind
  the waiting `ALTER` and hold their pool connections, so under heavy traffic
  some can time out and be logged as `security_audit_persist_failed` instead
  of stored. Apply these migrations when traffic is low.
- **An `INVALID` index.** `CREATE INDEX CONCURRENTLY` also waits for every
  transaction open when it starts. A failed or cancelled build leaves an
  `INVALID` index and the migration unrecorded. If only the migrate command
  was interrupted, the build can keep running on the server
  (`pg_stat_activity` shows its `CREATE INDEX CONCURRENTLY`) and end with a
  valid index that is still unrecorded. Either way a rerun fails with
  `duplicate_table`. Once no build for it is running, drop that index with
  `DROP INDEX CONCURRENTLY IF EXISTS audit_events_org_txid_id_index`, as the
  role that ran the migration (the admin URL on a hardened database), then run
  the migration again.
- **Rehearsal.** Rehearse the hardened procedure on a local database hardened
  with `harden_audit_log`, not on a review app: review apps run on Managed
  Postgres, which cannot be hardened.
- **What the database does not enforce.** Application code never sets
  `txid`, but the database does not refuse one: the app role's `INSERT` right
  covers every column, so a compromised app role could set a `txid` that hides
  a row from streaming, just as it could leave the row out altogether.
  Enforcing it would mean changing the append-only trigger and re-hardening,
  and that risk is accepted ([D10](plans/AUDIT-LOG-STREAMING-DESIGN.md#15-decisions-needed)).

## Rollback

There is no release command that undoes hardening. Three migrations take
part in it, and on a hardened database each can be rolled back only by a
superuser:

- `20261006155407_move_audit_events_ownership` hands the table, sequence,
  trigger function and schema back to the role running the rollback
  ([When the migration hardens](audit-log-hardening.md#when-the-migration-hardens)).
- `20261006164351_add_audit_events_purge_function` drops `audit_events_purge`
  and restores the flag-based trigger body
  ([Retention purge](audit-log-hardening.md#retention-purge)).
- `20261021120409_add_audit_events_organization_purge_function` drops
  `audit_events_purge_organization`
  ([Organization retention purge](audit-log-hardening.md#organization-retention-purge)).

The two purge migrations drop their function only when the role running the
rollback owns it, holds its owner's rights, or is a superuser. On a hardened database, a rollback run as
the app role degrades instead and changes nothing. The owner role is never
dropped, because other databases on the cluster may use it.

## Fly Managed Postgres

Production runs on Fly Managed Postgres, which gives no Postgres superuser.
Its most privileged role, `schema_admin` (held by the default `fly-user`), can
create and alter tables and functions but cannot do anything that needs a
superuser, and a `CREATE ROLE` sent over a database connection is refused.
Users and their roles are managed only through the Fly dashboard or
`fly mpg users`.

So the owner-role separation cannot be set up there:

- `harden_audit_log` stops at its superuser check with
  `{:error, :admin_not_superuser}` and changes nothing. Running it is harmless,
  but do not expect it to succeed.
- The database stays degraded, and the boot check logs its warning after
  every boot. On such a database that warning is a known limitation, not a
  missed step.

What degraded mode still gives on Managed Postgres:

- The append-only trigger rejects every update, except the cascade that clears
  the actor link when a user is deleted, and every `TRUNCATE` sent through the
  application's normal code paths.
- Both purge functions still refuse a cutoff newer than 90 days.

What it does not give: the application role owns `audit_events`, its trigger
function and its purge functions. A compromised application could therefore
disable or replace the trigger, or set the purge flag and delete rows directly
without the 90-day floor.

Partial hardening with Managed Postgres's own roles has not been built. The
application would connect as a separate `writer` user, and the objects would
stay owned by the `schema_admin` user. Two things block it today: the status
check recognises only the owner-role model, and `release_command` runs with the
application's secrets, so migrations would have to become a manual operator
step. Full hardening needs a Postgres where you hold a superuser.

## Open questions

- **Which privileges does production's Fly Postgres give?** Answered for Fly
  Managed Postgres: no superuser, so production stays degraded. See
  [Fly Managed Postgres](#fly-managed-postgres). On a provider that does
  grant a superuser, the provisioning step above applies unchanged.
- **Where should the command run?** Running it inside the long-running app
  machine shares that machine's operating-system user with the application
  process for the length of the command. A one-off machine from the same image,
  or a local release reaching the database through a Fly proxy, avoids that.
  Which of those the team uses is not settled.
