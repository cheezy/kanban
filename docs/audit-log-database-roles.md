# Audit Log Database Roles

The security audit log is only tamper-resistant when the role the application
connects as does not own the `audit_events` table, its trigger function, its
purge function or the schema holding them. This document explains which
database roles are involved, what each environment ends up with, and the
one-time step an operator runs to harden production. The statements themselves,
the reason atoms and the retention purge are described in
[Audit Log Ownership Hardening](audit-log-hardening.md).

## Role model

Three roles matter:

| Role | Who uses it | What it may do to the audit log |
|---|---|---|
| **App role** | The running application, through `DATABASE_URL` | Insert and read events, draw ids, and call the purge function. Nothing else |
| **Owner role** (`kanban_audit_owner`) | Nobody; it cannot log in | Owns the table, its id sequence, the trigger function, the purge function and their schema |
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
reconnect), runs the table hardening and then the purge hardening in one
transaction, and stops the connection whatever happens. A failing statement
rolls everything back. It logs only result tags and, on a failure, the
exception type and database error code. It never logs the admin URL, its host
or its password. Postgrex's own connection-error line can name the host and
port; the password is never shown.

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
`:hardened`, or `{:degraded, reasons}` combining the table check and the purge
check. Before provisioning, production reports reasons such as
`:owner_role_missing` and `:table_not_owned_by_owner_role`; afterwards it
reports `:hardened`.

## Future migrations that alter audit_events

Once hardened, the app role no longer owns `audit_events`, its trigger
function or its purge function, and `release_command` runs migrations as the
app role. A later migration that alters any of them (adding a column or index,
replacing the trigger or the purge function, changing their ownership) fails
with `insufficient_privilege` in production.

Such a migration must run through the admin path. Write it so it runs as the
owner role or a superuser, ship it, and apply it with the admin credential
supplied for that one command, the same way as the provisioning step above.
Then run `harden_audit_log` again and check the status, because ownership of
any object the migration created belongs to the role that created it. A
migration that only reads `audit_events` or inserts into it is unaffected.

## Rollback

There is no release command that undoes hardening. The two hardening
migrations can be rolled back only by a superuser: their down steps hand the
table, sequence, trigger function and schema back to the role running the
rollback, and drop the purge function
([When the migration hardens](audit-log-hardening.md#when-the-migration-hardens),
[Retention purge](audit-log-hardening.md#retention-purge)). Run as the app
role, a rollback degrades instead and changes nothing. The owner role is never
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
- The purge function still refuses a cutoff newer than 90 days.

What it does not give: the application role owns `audit_events`, its trigger
function and its purge function. A compromised application could therefore
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
