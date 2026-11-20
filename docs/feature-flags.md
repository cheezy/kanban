# Feature Flags

Stride hides unreleased work behind feature flags, so it can ship to
production switched off and be turned on for a few people before everyone.
This guide covers the flag registry, the admin page that switches a flag,
and what each change records.

## The registry

`Kanban.FeatureFlags` (`lib/kanban/feature_flags.ex`) is the only module that
calls the fun_with_flags library. Every screen, context or job that hides
unreleased work asks it, through `Kanban.FeatureFlags.enabled?/2`.

The `@flags` list in that module is the whole registry. Today it holds one
flag:

| Flag | What it shows |
|---|---|
| `:mobile_app_preview` | The screens that matter only once the phone apps ship: the device lists in account settings and on the Organization members page, the push notification settings, and the Organization policy that hides task titles in pushes |

To add a flag:

1. Add the atom to `@flags`. Every function in the module raises for a flag
   that is not listed, so a misspelt flag fails the tests.
2. Add a `flag_label/1` and a `flag_description/1` clause for it in
   `KanbanWeb.Admin.FeatureFlagLive.Index`, so the admin page can name it.
3. Run `MIX_ENV=test mix gettext.extract --merge` and translate the new
   strings in every locale.

## Gates

A flag is decided by two kinds of gate:

- A **user gate** turns the flag on for one user.
- The **everyone gate** turns the flag on for every user, and for visitors
  who are not signed in.

A flag with no gates is off for everyone. Removing a user's gate never stores
them as forced off; they simply follow the everyone gate again. Turning the
everyone gate off leaves every user gate in place, so those users keep the
flag.

## The admin page

Site admins switch flags at `/admin/feature-flags`. The route is in the same
`live_session :admin` as `/admin/users`, so nobody else can reach it, and the
page re-checks that the viewer is still an enabled site admin on every
action. Like `/admin/messages`, the page has no link in the app yet; open it
by its address.

For each flag the page shows:

- its state: **Off**, **On for N users**, or **On for everyone**;
- the users who have their own gate, with a **Disabled** badge for a disabled
  account and **Deleted account (#id)** for a gate whose account was deleted;
- a form that turns the flag on for one user by email address. The address is
  trimmed and matched without regard to case. An unknown address, a disabled
  account, or a user who already has the gate is refused, and nothing changes;
- a **Remove** button for each user, which removes that user's gate;
- **Turn on for everyone** or **Turn off for everyone**, which acts only after
  the confirmation the page shows next to it.

A change applies to the affected users the next time they load a page; no
restart is needed. Each server keeps an in-memory copy of the flags, and every
change tells every server to drop its copy and read the database again.

Every open copy of the page updates at once: each change is broadcast as
`{:feature_flag_changed, flag}` on the `"feature_flags"` topic of
`Kanban.PubSub` (`Kanban.FeatureFlags.subscribe/0`). The message names only
the flag. An admin who has been demoted or disabled while the page is open is
sent away at the next change, and can make no change in the meantime.

## Audit events

Every change made on the page is written to the audit log, where
`/admin/audit-log` shows it:

| Action | Label | Recorded when |
|---|---|---|
| `feature_flag_enabled` | Feature flag turned on | A user's gate is added, or the everyone gate is turned on |
| `feature_flag_disabled` | Feature flag turned off | A user's gate is removed, or the everyone gate is turned off |

Each event records `user_id` (the admin who made the change), `flag` (the
flag's name), `scope` (`user` or `everyone`) and, for scope `user`,
`target_user_id` (whose gate changed). It never records an email address.
[Telemetry Events](telemetry.md) lists both events with their metadata.

The unaudited `enable_for_user/2`, `disable_for_user/2`,
`enable_for_everyone/1` and `disable_for_everyone/1` functions remain for
tests and the console. A change made through them writes no audit event and
does not refresh an open admin page.
