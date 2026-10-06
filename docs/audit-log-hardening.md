# Audit Log Ownership Hardening

The security audit log stores one row per event in the `audit_events` table. A
trigger, `audit_events_append_only()`, rejects every edit of a stored row, every
`TRUNCATE`, and every `DELETE` outside the retention purge. In Postgres the role
that owns a table can always disable, drop or replace its triggers, and the
role that owns the schema holding the table can drop it and its trigger
function. So the trigger alone does not protect the log from the application
role that created it. Hardening moves ownership of all of them to a separate
role that the application cannot log in as or assume.

The statements live in one module, `Kanban.AuditLog.Hardening`
(`lib/kanban/audit_log/hardening.ex`). The migration
`priv/repo/migrations/20261006155407_move_audit_events_ownership.exs` applies
them.

## What hardening changes

| Object | Before | After |
|---|---|---|
| `audit_events` table and its id sequence | Owned by the application role | Owned by `kanban_audit_owner` |
| `audit_events_append_only()` trigger function | Owned by the application role | Owned by `kanban_audit_owner`, with `search_path` pinned to `pg_catalog, pg_temp` |
| The schema holding both (normally `public`) | Owned by whoever created it | Owned by `kanban_audit_owner` |
| Application role's rights on `audit_events` | Every right, as owner | `INSERT` and `SELECT` only (every grant to `PUBLIC` is revoked too) |
| Application role's rights on the id sequence | Every right, as owner | `USAGE` only |
| Application role's rights on that schema | Owner's rights, or `USAGE` and `CREATE` | `USAGE` and `CREATE` |

`kanban_audit_owner` is a cluster-wide role with no login. Hardening creates it
only when it is absent and never alters one that exists (`status/2` reports an
existing owner role that can log in), and tolerates another database on the same cluster
creating it at the same moment. The application role is never made a member of
it, because membership would hand back the rights hardening removes.

The search path is pinned because the foreign-key cascade that nulls
`actor_user_id` when a user is deleted runs the trigger function as
`kanban_audit_owner`. With the session's search path, the application role
could create a function in `public` that shadows one the trigger calls, such as
`pg_trigger_depth()`, and it would run with the owner's rights.

Moving the schema means the application role no longer owns `public`. It keeps
`USAGE` and `CREATE` there, so its migrations can still create, alter and drop
the tables it owns.

Hardening an existing table cannot vouch for what was added to it while the
application owned it. `status/2` therefore also checks that nothing extra is
attached: no other trigger, rule or row security, and no default, constraint,
index or policy that calls a function the owner role does not own. Remove
anything it reports before relying on the separation.

Once the application role holds only those rights, it can still write events
and read them for the admin viewer and export. It can no longer disable, drop
or replace the trigger, drop or take back the table, or update, delete or
truncate rows. `status/2` reports `:hardened` only in that state. A user can
still be deleted: the foreign-key cascade that nulls `actor_user_id` runs with
the table owner's rights.

Rows still leave the table through the retention purge, which no longer relies
on the `kanban.audit_purge` flag once the table is hardened. See
[Retention purge](#retention-purge).

## When the migration hardens

Handing ownership to a role you are not a member of needs a superuser. The
migration therefore checks the role it runs as:

- **Superuser** (dev, test and CI connect as one): it hardens, then checks the
  result with `status/2` for the role it ran as. In dev and test that role is
  a superuser, so it logs `security_audit_hardening_degraded reason=app_role_is_superuser`.
  A superuser bypasses every right, so the separation only holds for a
  non-superuser application role.
- **Any other role:** it logs `security_audit_hardening_degraded reason=not_superuser`
  once and finishes without changing anything. Production deploys run the
  migration as the application role (`release_command` in `fly.production.toml`),
  so a deploy never fails for lack of privilege.

The migration only knows the role it runs as. If migrations run as a superuser
while the application connects as a different role, ownership moves but that
other role keeps whatever rights it already had. Harden it by calling
`Kanban.AuditLog.Hardening.apply/2` with its name over a superuser connection,
then check it with `status/2`.

Rolling the migration back hands the table, sequence, trigger function and
schema back to the migrating role, again only as a superuser. The schema goes
to that role, not to its original owner, and the function keeps its pinned
search path. It never removes `kanban_audit_owner`, because other databases on
the cluster may still use it.

## Checking the state

`Kanban.AuditLog.Hardening.status/2` takes a runner and the application role's
name, and returns `:hardened` or `{:degraded, reasons}`:

```elixir
# Before hardening, on a database the application role owns:
runner = fn sql -> Kanban.Repo.query!(sql) end
Kanban.AuditLog.Hardening.status(runner, app_role: "kanban_app")
#=> {:degraded,
#=>  [:owner_role_missing, :table_not_owned_by_owner_role,
#=>   :trigger_function_not_owned_by_owner_role,
#=>   :trigger_function_search_path_not_pinned, :app_role_has_extra_table_rights,
#=>   :app_role_owns_schema]}
```

| Reason | Meaning |
|---|---|
| `:owner_role_missing` | `kanban_audit_owner` does not exist |
| `:owner_role_can_login` | The owner role can log in |
| `:table_not_owned_by_owner_role` | `audit_events` belongs to another role |
| `:trigger_function_not_owned_by_owner_role` | The trigger function belongs to another role |
| `:app_role_missing` | The named application role does not exist |
| `:app_role_is_superuser` | The application role is a superuser, which bypasses every right |
| `:app_role_member_of_owner_role` | The application role can assume the owner role |
| `:app_role_missing_insert` | The application role cannot insert events |
| `:app_role_missing_select` | The application role cannot read events |
| `:app_role_missing_sequence_usage` | The application role cannot draw ids, so every insert fails |
| `:app_role_has_extra_table_rights` | The application role can update, delete, truncate, reference or add triggers to the table, or holds a column-level update or reference right, directly or through `PUBLIC` |
| `:app_role_owns_schema` | The application role owns the schema holding the table or the trigger function, so it can drop them |
| `:app_role_can_create_roles` | The application role can create roles, so it could grant itself the owner role |
| `:trigger_function_search_path_not_pinned` | The trigger function's `search_path` is not pinned to `pg_catalog, pg_temp` |
| `:append_only_triggers_missing_or_disabled` | One of the two append-only triggers is missing, disabled, or calls another function |
| `:rewrite_rule_on_table` | A rule on `audit_events` could divert writes away from the table |
| `:unexpected_trigger_on_table` | `audit_events` carries a trigger other than the two append-only ones |
| `:row_security_enabled` | Row-level security is on for `audit_events`, so a policy could hide or block rows |
| `:foreign_code_on_table` | A default, constraint, index, trigger, policy or rule on `audit_events` calls a function the owner role does not own. The foreign-key cascade would run that function with the owner's rights, and its owner can rewrite it |

In dev and test the application connects as a superuser. There the table is
hardened, but `status/2` for that role reports `:app_role_is_superuser`.

## Retention purge

Retention removes old events through one database function,
`audit_events_purge(cutoff timestamptz)`. The statements live in
`Kanban.AuditLog.Hardening.Purge` (`lib/kanban/audit_log/hardening/purge.ex`),
the migration
`priv/repo/migrations/20261006164351_add_audit_events_purge_function.exs`
installs them, and `Kanban.AuditLog.purge_before/1` calls the function with the
cutoff as a bound parameter.

The function:

- refuses a cutoff that is `NULL` or newer than 90 days ago, with SQLSTATE
  `KAP01`, which `purge_before/1` returns as `{:error, :cutoff_too_recent}`.
  The floor is in the function body, so a compromised application calling the
  function directly still cannot erase recent history;
- removes only rows whose `inserted_at` is strictly older than the cutoff (a
  row stamped exactly at the cutoff is kept) and returns how many it removed;
- runs with its owner's rights (`SECURITY DEFINER`), with `search_path`
  pinned to `pg_catalog, pg_temp` and the table name schema-qualified. The
  application role may create objects in the table's schema, so that schema is
  kept off the path of code that runs with another role's rights;
- is executable only by the application role: the `EXECUTE` right every new
  function gives `PUBLIC` is revoked first.

What else changes depends on whether the table is hardened:

| | Hardened | Degraded |
|---|---|---|
| Purge function owner | `kanban_audit_owner` | The application role |
| Trigger rule for `DELETE` | Allowed only when the current role owns `audit_events` and the delete is not fired from another trigger; the `kanban.audit_purge` flag is ignored | Allowed when the transaction-local `kanban.audit_purge` flag is on |
| How the purge gets through | It runs as the owner role | It sets the flag around its own delete and restores the previous value |

In hardened mode the application cannot become the owner role, so the purge
function is the only way the application can delete a row. A superuser that sets the flag and
deletes directly is refused too. The owner is read from the catalog when the
trigger runs, so no role name is embedded in it. The update branch, with its
foreign-key nilify exception, and the always-rejected `TRUNCATE` are unchanged.
The owner role must own no other function the application can call, because any
such function could also delete.

The migration installs the hardened purge only when it runs as a superuser and
the table already belongs to `kanban_audit_owner`. Otherwise it installs the
degraded purge and logs `security_audit_purge_degraded` with a reason
(`not_superuser` or `table_not_owned_by_owner_role`). When it cannot install
the function, it changes nothing and also logs why: `schema_create_denied` when
the migrating role cannot create in the table's schema, and
`purge_function_not_replaceable` when a purge function already exists that the
migrating role does not own. It never fails for lack of privilege. If the table belongs to
the owner role but the migration runs as another role, the application role
cannot delete. `purge_before/1` then raises until a superuser installs the
hardened purge with `Kanban.AuditLog.Hardening.Purge.apply/3`.

Rolling the migration back drops the purge function and restores the
flag-based trigger body from
`priv/repo/migrations/20261006153642_fix_audit_events_truncate_message.exs`,
keeping the pinned search path. Anything the migrating role cannot own is left
in place and named in one degraded notice.

`Kanban.AuditLog.Hardening.Purge.status/2` takes a runner and the application
role's name and returns `:hardened` or `{:degraded, reasons}`:

| Reason | Meaning |
|---|---|
| `:purge_function_missing` | No purge function is installed |
| `:purge_function_not_owned_by_owner_role` | The purge function belongs to another role, such as the application role in degraded mode |
| `:purge_function_not_security_definer` | The purge function runs with its caller's rights, so it cannot delete from a hardened table |
| `:purge_function_search_path_not_pinned` | The purge function's `search_path` is not pinned to `pg_catalog, pg_temp` |
| `:purge_function_executable_by_public` | Every role can execute the purge function |
| `:app_role_cannot_execute_purge_function` | The named application role is missing or cannot execute the purge function |
| `:trigger_function_honors_flag` | The trigger still admits a delete when the `kanban.audit_purge` flag is on |

## Tests

`test/kanban/audit_log/hardening_test.exs` proves the separation. A superuser
bypasses every right, so the tests use `Kanban.AuditLogRoleHelper`
(`test/support/audit_log_role_helper.ex`). It creates a throwaway role with no
superuser inside the sandbox transaction, hardens the table for it, and switches
the transaction to it. Hardening locks `audit_events` until the sandbox rolls
back, so a test module that uses the helper must be `async: false`.

`test/kanban/audit_log/purge_test.exs` covers the purge function, both modes
and `status/2`, using the same helper. The append-only trigger tests in
`test/kanban/audit_log_test.exs` assert that the test database is hardened, so
a degraded test database fails them instead of passing for the wrong reason.
