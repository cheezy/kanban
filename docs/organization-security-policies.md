# Organization Security Policies

An Organization's org-admins set two security policies for everyone in it:

- **Require two-factor authentication**, with a grace period, for every member.
- **Audit retention**: how long the Organization's audit events are kept
  before a daily job removes them.

This page describes what each setting does, how the requirement is enforced,
what the daily retention job removes, and what an operator has to do after
deploying it. Two-factor itself is described in
[Two-Factor Authentication](TWO-FACTOR-AUTHENTICATION.md), and the database
side of audit retention in
[Audit Log Ownership Hardening](audit-log-hardening.md#retention-purge).

## The settings page

Org-admins open the security policy page (`/org/security`) with **Security**
on the Organization console (`/org`). Only an enabled org-admin of the Organization
reaches it. Anyone else is sent to `/boards` with "You must be an org-admin of
an Organization to access this page." and the refusal is recorded as a
`permission_denied` audit event. The role is checked again on every change and
save, so an org-admin demoted while the page is open cannot save.

| Setting | Allowed values | Default |
|---|---|---|
| Require two-factor authentication | On or off | Off |
| Grace period | 1 to 30 days | 7 days |
| Audit retention | 90 to 3,650 days, or empty to keep events forever | Empty |

An Organization without a saved policy behaves as if it had the defaults.
The policy is stored in `organization_security_policies`, one row per
Organization (`Kanban.Organizations.SecurityPolicy`), and changed only through
`Kanban.Organizations.SecurityPolicies.update_policy/2`, which takes the
Organization from the actor's own membership, never from the request.

Each save that changes something records an `organization_policy_updated`
audit event with the Organization, the org-admin, and the old and new values
of the fields that changed.

## Requiring two-factor

When the requirement is on, every member without two-factor gets a grace
period to turn it on.

- **The deadline** is the later of the moment the requirement was turned on
  and the moment the member first joined the Organization under it, plus the
  grace period. Existing members are never locked out the moment it is
  enabled, and someone who joins later gets their own grace period.
- **Grace counts once per person.** When the grace period starts is recorded
  for each member (`Kanban.Organizations.TwoFactorGrace`): for everyone who is
  a member when the requirement is turned on, and for anyone else the first
  time Stride checks their status. Leaving and re-joining keeps it, so a SCIM
  deactivate and re-activate, being removed and re-added, or a single sign-on
  rejoin never starts a new grace period. Turning the requirement off and on
  again, or shortening the grace period, starts everyone's grace again, and
  someone who first joins after that gets their own.
- **Turning the requirement on** starts the clock (`two_factor_enforced_at`).
  Shortening the grace period while it is on restarts the clock from that
  moment, so no member is put past their deadline by the change. Turning it
  off clears it, and it takes effect on the member's next request.
- **During the grace period** every signed-in page shows a card that cannot be
  dismissed, with the deadline in UTC and links to **Settings → Two-factor**
  and the in-app guide. It replaces the optional two-factor reminder.
- **Once the deadline passes**, every signed-in page and request sends the
  member to **Settings → Two-factor** (`/users/settings?section=two_factor`)
  with a flash asking them to turn it on. The settings page stays open, so
  there is always a way to comply, and it shows the card with the deadline
  marked as passed. A LiveView page left open across the deadline redirects
  at its next navigation.
  Pages that also work signed out, such as signing in or accepting a
  workspace invitation (`/invitations/:token`), are not gated; the board an
  accepted invitation leads to is.
- **While it is required**, a member cannot turn two-factor off. The settings
  page shows why instead of the **Turn off two-factor** form, and
  `Kanban.Accounts.TwoFactor.disable/2` refuses with
  `{:error, :required_by_organization}` without checking or using up a code.
  They can still create new recovery codes.

The requirement covers the browser only. API tokens are not affected, as
described in the [Authentication Guide](AUTHENTICATION.md).

A session signed in through single sign-on is exempt, because the identity
provider enforces its own second factor. The gate treats a session as SSO only
when `"sso_authenticated"` holds the id of the member's current Organization.
Only a single sign-on sign-in sets it, to the Organization it signed the
person in to; a password sign-in removes it. Someone who leaves that
Organization and joins another in the same session is held to the new
Organization's requirement, since its identity provider never signed them
in. The security
policy page says that members who sign in through single sign-on are not
affected. See [Single Sign-On](single-sign-on.md).

The check lives in `KanbanWeb.UserAuth.OrganizationTwoFactorGate`: a plug in
the `:enforce_organization_two_factor` pipeline for controller routes, and
`on_mount` hooks for the LiveView sessions (`:enforce` redirects, `:banner`
only shows the card and is used on the settings pages).

## Audit retention

When an Organization sets an audit retention period, the daily retention job
removes its audit events older than that. Events with no Organization (site
events) and other Organizations' events are never touched by its setting.

The 90-day minimum is enforced twice: by the form, and by the database
function that does the delete,
`audit_events_purge_organization(org_id, cutoff, batch_limit)`. It refuses a
cutoff inside 90 days with SQLSTATE `KAP01`, so even a compromised
application cannot erase recent history. It is installed and hardened the same
way as the site purge; see
[Retention purge](audit-log-hardening.md#retention-purge).

## The daily retention job

`Kanban.Retention.PurgeWorker` runs every day at 03:47 UTC on the
`:maintenance` Oban queue. It:

1. removes each Organization's audit events older than its retention period;
2. removes site events (no Organization) older than
   `site_audit_retention_days`, only when that is set (90 days in
   `config/config.exs`, the period `/privacy` promises);
3. removes archived tasks archived before `archived_task_retention_days` ago,
   only when that is set.

The site and archived-task settings are application config. `config/config.exs`
keeps site events for 90 days and archived tasks for ever; `nil` keeps
everything:

```elixir
config :kanban, Kanban.Retention.PurgeWorker,
  site_audit_retention_days: 90,
  archived_task_retention_days: nil,
  batch_size: 1_000
```

- A site retention below 90 days, or any setting that is not a positive whole
  number of days, removes nothing for that step and logs a warning.
- Every step deletes `batch_size` rows per statement until a batch comes back
  short, so no statement holds a long lock. Running the job twice removes
  nothing the second time.
- An archived goal is kept while any of its children is not archived, or was
  archived after the cutoff. An archived task is kept while a task that is not
  archived on the same board still depends on it.
- A step that fails, for example because the database refuses the purge
  function, is logged and named in `failed_steps`; the other steps still run.
  The job is not retried, because the next day's run repeats it.

Each run records one `retention_purge` audit event with the rows removed per
Organization (`organization_counts`), for site events (`site_count`) and for
archived tasks (`archived_task_count`), plus `failed_steps`. A count is `nil`
when its step did not run.

## After deploying

Production runs migrations as the application role, so the migration that
installs the Organization purge function installs it in degraded form on a
hardened database, and the function cannot delete there. After deploying, run
the hardening command again and check the status, as described in
[Future migrations that alter audit_events](audit-log-database-roles.md#future-migrations-that-alter-audit_events).
Until then `Kanban.Release.audit_log_status/0` reports a reason such as
`:organization_purge_function_not_owned_by_owner_role`, and the daily job
records each Organization's purge in `failed_steps`.

The cron schedule is read when the application boots, so a running server
picks up the job only after a restart.
