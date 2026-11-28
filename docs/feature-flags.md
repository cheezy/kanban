# Feature Flags

Stride hides unreleased work behind feature flags, so it can ship to
production switched off and be turned on for a few people before everyone.
This guide covers the flag registry, how to add and check a flag, the admin
page that switches a flag, what each change records, and, in detail, the
`:mobile_app_preview` flag: what it hides, what it leaves alone, and how it is
rolled out and then removed.

## The registry

`Kanban.FeatureFlags` (`lib/kanban/feature_flags.ex`) is the only module that
calls the fun_with_flags library. Every screen, context or job that hides
unreleased work asks it, through `Kanban.FeatureFlags.enabled?/2`.

The `@flags` list in that module is the whole registry. Today it holds two
flags:

| Flag | What it shows |
|---|---|
| `:mobile_app_preview` | The web screens that matter only once the Stride app ships: the push settings on `/users/notifications`, the Devices section of `/users/settings`, and the **Notification privacy** card on `/org/security`. [The mobile app preview](#the-mobile-app-preview) has the exact rules |
| `:blog` | The blog experiment at `/blog`, file-based posts copied from cheezyworld.ca (`KanbanWeb.Blog`), for the users it is on for |

To add a flag:

1. Add the atom to `@flags` and to the `@type flag` union in the same module.
   Every function in the module raises `ArgumentError` for a flag that is not
   listed, so a misspelt flag fails the tests.
2. Add a `flag_label/1` and a `flag_description/1` clause for it in
   `KanbanWeb.Admin.FeatureFlagLive.Index`, so the admin page can name it.
3. Run `MIX_ENV=test mix gettext.extract --merge` and translate the new
   strings in every locale.
4. Check it with the scope where the screen is built, as
   [Checking a flag](#checking-a-flag) describes, and test both states.
5. Add it to the registry pin in `test/kanban/feature_flags_test.exs`, which
   asserts the exact `flags/0` list.

Nothing checks `@type flag` against `@flags`, so keep the two in step by hand.

Only `lib/kanban/feature_flags.ex`, the files under `lib/kanban/feature_flags/`
(today only its actor), and `FunWithFlags.Supervisor` in `Kanban.Application`
may call the library; `test/kanban/feature_flags_test.exs` scans `lib/` and
fails otherwise. The
flags are stored in the `fun_with_flags_toggles` table, so turning one on or
off needs no deploy.

## Checking a flag

Call `Kanban.FeatureFlags.enabled?(scope, flag)`, with the current scope
first, as every context function takes it. A `nil` scope, or one with no
user, sees only the everyone gate. A flag name always comes from the
compiled list; never build one from request input.

- **Read the flag at mount.** A change then applies the next time the person
  loads a page.
- **Put the decision in one context function** when it also depends on data,
  as `Kanban.Devices.show_devices?/1` and `Kanban.Devices.show_push?/1` do,
  so every screen that shows the same thing asks the same question.
- **Refuse a hidden control's events on the server too.** A hidden control
  can still be sent by a crafted request: `KanbanWeb.UserLive.NotificationPreferences`
  refuses its push events while the push settings are hidden, and
  `KanbanWeb.OrgLive.Security` drops a hide-titles value while its checkbox
  is hidden.
- **Keep people out of logs.** Never put a user id, email address or token
  in a log line, telemetry metadata or an error message about a flag.
  [Telemetry Events](telemetry.md#privacy-rule) has the rule.

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

- its name and a one-line description of what it shows, from
  `flag_label/1` and `flag_description/1`;
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

## The mobile app preview

`:mobile_app_preview` hides the web screens that only make sense once the
Stride app ships (goal G532). It is deliberately not `:mobile_app`, which is
the paid plan feature in `Kanban.Plans`.

Each rule is "the flag is on, or something is already in force", so the flag
never hides a device or a setting that exists. Each screen reads its rule
when it mounts, and two read it again: Settings after a revoke, and the
security page after each save. The flag hides exactly three screens:

1. **The push settings on `/users/notifications`**: the **Push** switch on
   each event that can push, **Notify me** under **Push notifications**, and
   **Quiet hours**. They show while the flag is on for the person, or while
   they have a device a push can reach: not revoked, with a push token, the
   same rule `Kanban.Devices.PushTokens` applies when sending.
   `Kanban.Devices.show_push?/1` decides it. While they are hidden, the
   server refuses their events and writes nothing. The **In-app** and
   **Email** switches are unchanged.
2. **The Devices section of `/users/settings`**, and its tab. It shows while
   the flag is on for the person, or while they have any device that is not
   revoked (`Kanban.Devices.show_devices?/1`). Asked for with
   `?section=devices` while it is hidden, the page opens Profile instead.
   Revoking the person's last device without the flag hides the section at
   once; if it was open, Profile opens and reports "Device revoked.". The
   settings menu on `/users/notifications` leaves out its Devices link by the
   same rule.
3. **The Notification privacy card on `/org/security`**, which holds **Hide
   task titles in push notifications**. It shows while the flag is on for the
   org-admin viewing the page, or while the setting is already on, so a policy
   in force can always be turned off. An org-admin without the flag who turns
   the setting off and saves sees the card go at once, and cannot turn it back
   on until the flag is on for them. While it is hidden, the form sends no
   value for the setting, so a save keeps what is stored, and a value a
   crafted request sends is dropped.

A member's **Devices** button on the Organization members page in `/org` is
not one of them: it never reads the flag. It shows for a member, never for an
org-admin, who has a device that is not revoked, and revoking their last one
removes it. The flag of the org-admin viewing the page makes no difference.

[Devices](api/me_devices.md#when-the-device-lists-show),
[GET and PUT /api/me/notification_settings](api/me_notification_settings.md)
and [Organization Security Policies](organization-security-policies.md)
describe the same screens from their side.

## What the flag leaves alone

The flag decides only what the web shows. These never check it:

- `/oauth/authorize`, `/oauth/token` and `/oauth/revoke`, which sign the app
  in and out;
- `GET /api/me` and the other `/api/me` routes the app calls;
- the `/api/socket` socket;
- the push workers, `Kanban.Push.PushWorker` and `Kanban.Push.SummaryWorker`,
  so pushes keep going to every device a push can reach;
- `/.well-known/apple-app-site-association` and
  `/.well-known/assetlinks.json`, which iOS and Android fetch with nobody
  signed in.

They are what the app itself, or the phone's operating system, calls. Gating
them would break a signed-in app for anyone without the flag, and turning the
flag on for everyone would no longer be the only step at launch. Who can use
the app is decided by signing in, device tokens and plans, not by this flag.

## Turning a user's flag off

Removing a user's gate, or turning the everyone gate off, signs out no
device. Nothing that signs a device in or out reads the flag: not the OAuth
routes, not token issuance or refresh, and not revocation. In
`Kanban.Devices`, only `show_devices?/1` and `show_push?/1` read it, to decide
what the web shows. So while the device is not revoked, that person's Devices
section stays visible, and the device can still be revoked there and, for an
ordinary member of an Organization, by an org-admin on the members page.
Their push settings stay visible too while
that device has a push token.

## Rollout and removal

1. **Testers.** Turn the flag on for each tester by email address at
   `/admin/feature-flags`.
2. **Everyone.** When the app is released, click **Turn on for everyone**.
   User gates stay in place and no longer matter.
3. **Removal.** Once the flag has been on for everyone through a release,
   remove it in one change:
   - Make the three screens always shown. Delete `show_push?/1` and
     `show_devices?/1`, the helpers only they call
     (`Kanban.Devices.push_device?/1`, and `has_active_device?/1` and
     `push_device?/1` in `Kanban.Devices.Lookup`), the `:show_push?` and
     `:show_devices?` assigns and the conditions that read them, the
     `show_devices` attribute of the settings shell in
     `KanbanWeb.UserLive.SettingsComponents`, the push-event refusal in
     `KanbanWeb.UserLive.NotificationPreferences`, and the `:mobile_preview?`
     and `:show_hide_titles?` assigns and the value-dropping clause in
     `KanbanWeb.OrgLive.Security`. Keep the members page's device rule, which
     is not part of the flag.
   - Drop the atom from `@flags` and `@type flag`, drop its `flag_label/1`
     and `flag_description/1` clauses, and run
     `MIX_ENV=test mix gettext.extract --merge`.
   - Delete its stored rows from `fun_with_flags_toggles` in a migration.
   - Update the tests and docs that name the flag;
     `grep -rn mobile_app_preview lib test docs` lists them. Also reword the
     Resources guides that say a control appears once you use the Stride app,
     and their pins in `test/kanban_web/live/resources_live/how_to_data_test.exs`.
   - If it is the last flag, removing it empties the `@type flag` union, which
     does not compile. Remove it in the same change that adds the next flag,
     or keep the atom registered, with nothing reading it, until then.

Keep `Kanban.FeatureFlags`, its table and the admin page for the next flag.
