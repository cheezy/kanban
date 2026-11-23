# Push Notifications

This document is for operators and developers. It covers how Stride sends
native push notifications to the iOS and Android apps, the environment
variables that turn each platform on, and how the senders are kept away from
Apple and Google in development and tests. The design behind it is in
[Native Mobile Apps, Phase 1](plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md),
sections 7.8 and 15.2.

This page covers the senders, the push worker that decides which
notifications push, and quiet hours with the summary push that follows them.
Each person's settings are described in
[GET and PUT /api/me/notification_settings](api/me_notification_settings.md).

Until the app ships, the web controls for those settings, the **Push**
switches, the push mode and quiet hours on `/users/notifications`, are behind
the `:mobile_app_preview` feature flag. They show while the flag is on for the
person, or while that person has a device a push can reach. The senders and
the push workers never check the flag, so pushes reach every such device
whatever it says.
[Feature Flags](feature-flags.md) describes the flag and its rollout.

## The senders

Stride sends one push to one device through the `Kanban.Push.Adapter`
behaviour. Its one callback is `send(device, payload)`. There is one adapter
per platform, and both use the [Pigeon](https://hex.pm/packages/pigeon)
library:

| Platform | Adapter | Service | Auth |
|---|---|---|---|
| iOS, iPadOS | `Kanban.Push.APNs` | Apple Push Notification service | Token-based, with a `.p8` auth key |
| Android | `Kanban.Push.FCM` | Firebase Cloud Messaging HTTP v1 | A Google service account |

`Kanban.Push.send/2` looks at the device's platform and calls the adapter
configured for it under `config :kanban, Kanban.Push, adapters:`. The payload
is a `Kanban.Push.Payload`: a collapse id, an optional title, body and badge,
and string data for the app.

The collapse id is the decision id for a decision event, such as
`review:task:4812`, or `event_type:subject_id` for an update, such as
`goal_completed:977`. APNs sends it as the `apns-collapse-id` header. FCM sends
it as the Android notification `tag` and the `collapse_key`, so a newer push
replaces an older one for the same subject. A payload with no title and no body
is a silent push: APNs gets `content-available` and FCM gets a data-only
message. A silent APNs push never carries the badge, because Apple allows only
`content-available` in a background push. On a visible push the badge is any
whole number, and `0` clears the count on the app icon.

### Results

| Result | Meaning |
|---|---|
| `:ok` | The service accepted the push |
| `:unregistered` | APNs answered `410 Unregistered` or FCM answered `UNREGISTERED`: the token is dead, and the caller clears the device's push token |
| `{:error, :not_configured}` | No credentials are set for this platform, so nothing was sent |
| `{:error, :no_push_token}` | The device has no push token |
| `{:error, :no_push_environment}` | An iOS device has no `push_environment`, so the APNs endpoint is unknown |
| `{:error, :unsupported_platform}` | No adapter is configured for the device's platform |
| `{:error, :rate_limited}` | APNs answered `429 TooManyRequests` or FCM answered `QUOTA_EXCEEDED` |
| `{:error, reason}` | Any other answer, as the atom Pigeon gives it, such as `:expired_provider_token`, `:bad_device_token` or `:timeout` |

Only the `:unregistered` result clears a token. A malformed token
(`:bad_device_token`) is reported as an error and the token is kept.

## The push worker

`Kanban.Push.PushWorker` is the third delivery channel beside in-app and
email (design sections 7.8, 9.4 and 10).

**Enqueueing.** `Kanban.Notifications.notify/3` enqueues one job per new
notification, in the same transaction that inserts the rows and enqueues the
emails, so a rolled-back notification never pushes and `notify/3` never
sends. A recipient gets a job only when all three hold:

- push is on for the event type: their saved switch, else the default (on
  for the four decision events, off for the four updates; the other four
  event types never push);
- they have at least one device that is not revoked and has a push token;
- they have paid access (`Kanban.Plans.unlocked_user_ids/1`).

A recipient with in-app and email off but push on gets a hidden row
(`in_app: false`) only when a push can reach them.

**Sending.** Jobs run on the `:push` Oban queue, unique per notification, with
5 attempts. Each job reads everything again and, in order:

1. checks the plan, for the recipient and for the board when there is one;
2. checks the push switch; one turned off since the enqueue holds the push
   with reason `:mode`. Then it checks quiet hours: a push due inside them is
   held with reason `:quiet_hours` (see [Quiet hours](#quiet-hours) below);
3. for `review_requested`, `task_unclaimed`, `claim_expired` and
   `after_goal_failed`, checks that the decision is still open in
   `Kanban.Decisions`; one that is not holds the push with reason
   `:resolved`. A released or expired-claim decision is checked on its own
   row, so it is judged the same with in-app on or off; a review or failed
   hook ranked below the first 100 decisions is sent without its counts;
4. builds the payload in each device's locale (`Kanban.Push.PayloadBuilder`),
   mapped by `Kanban.Locales.resolve/1`: a locale Stride is translated into
   is used as it is, else the tag's base language (`de-AT` is German, `pt-BR`
   Portuguese, `zh-Hant-TW` Chinese), else English (`ko`). The match ignores
   case and accepts `_` separators;
5. sends it to each device that is still active with a push token, reading
   each device again just before its send, so one revoked while the job runs
   gets nothing.

A missing notification, a disabled or unconfirmed recipient, one no longer on
the board, a lost plan or no device left sends nothing: the job logs the
notification id and the reason and ends, with no telemetry. The device list
is read right after the plan, so a job with no device left never emits
`held`.

**What a push shows.** Only the event kind, the identifier, the task or goal
title, a target's name and date, and the checks passed and failed and tasks
held up for a decision. A line break in a title or name becomes a space, so
free text never adds a line to the body. Format characters (bidi overrides
and isolates, zero-width spaces, direction marks) are removed, so a title
cannot read differently from what it is. What text needs is kept: the
zero-width joiner and non-joiner, emoji tag sequences such as the England
flag, and the visible marks some scripts write with a format character. Where
a removal would fuse two characters into one, such as a skin tone onto an
emoji, a space keeps them apart. A title or name with nothing visible left,
variation selectors and fillers included, is left out, as an empty one is. Never review notes, an unclaim reason, hook output,
code, comment text or the name of the person who acted. When the recipient's
Organization turns on **Hide task titles in push notifications**, the title
is left out and the push reads, for example, "W2701 is ready for review"; a
target's name is replaced too ("A target is at risk"). The iOS badge is the person's
decisions count, and the data says where a tap opens (`route`) plus the ids
it needs.

**Results.** A dead token (`:unregistered`) is cleared and the job carries on
with the other devices. When a device was rate limited or the service was
unavailable, the job fails so Oban retries it. Delivery is at least once: a
retry sends again to the devices that already got the push, and the collapse
id lets the device replace the duplicate. The worker emits
`[:kanban, :push, :sent]`, `[:kanban, :push, :failed]` and
`[:kanban, :push, :held]`; see [Telemetry](telemetry.md#push-events). It never
logs a token, a title or a body.

## Quiet hours

A person can turn on quiet hours, 22:00 to 07:00 unless they choose other
times (design section 7.9 and decision 5). They are read in the time zone in
the person's push settings, `user_push_settings.time_zone`, and never in a
device's zone, so someone travelling with the phone keeps the quiet hours of
the zone they set until they change it (`Kanban.Push.QuietHours`).

- **What counts as inside.** A quiet period starts the first time the clock in
  that zone reads the start time and ends the first time after it that the
  clock reads the end time. A start later than the end crosses midnight. The
  end is excluded: 07:00 is outside 22:00 to 07:00, and 06:59 is inside.
- **Daylight saving.** A start or end the clock skips in spring resolves to
  the end of the gap. One the clock reads twice in autumn resolves to its
  first reading, so a period ends once and the repeated hour is outside it.
- **Held, not dropped.** A push due inside quiet hours is held
  (`reason: :quiet_hours`) and never sent later on its own, so the end of the
  night is not a burst of pushes. The notification stays in Now. A push
  switch turned off wins: that push is held with reason `:mode`.

### The summary push

`Kanban.Push.SummaryWorker` runs every 15 minutes from the Oban crontab, on
the `:push` queue. For each person with quiet hours on, it takes the latest
quiet period that has ended, when it ended less than two hours ago and no
summary has been taken since (`last_summary_at`). If decisions are still
waiting it sends one push with their count, such as "3 things waited
overnight", in each device's locale. The push opens Now, its badge is the
count, and it carries no task title, identifier or name, so it reads the same
when the Organization hides titles.

- **Exactly once.** The worker takes a period with a conditional update of
  `last_summary_at` before it sends, and only one run can win it, so two runs
  at once send one summary. A period with nothing to send is still taken.
- **The same checks as the push worker.** After taking a period it reads
  again that the person is enabled and confirmed, has paid access, has at
  least one decision event's push switch on and has a device with a push
  token, and it reads each device again just before its send.
- **Failures.** A dead token is cleared. When no device got the summary
  because one was rate limited or the service was unavailable, the period is
  given back and the next run sends it. A run that stops between taking and
  sending loses that summary rather than sending it twice.
- **Settings changes.** A change to quiet hours made outside them sets
  `last_summary_at` to now, so turning them on after a period has ended sends
  no summary for it. A change that ends quiet hours while they hold, such as
  turning them off at night or moving to a zone where they are over, enqueues
  the summary for that period at once, and so does a change made while a
  period's summary is due, so a change never cancels one. A change made while
  such a one-person summary is still queued, retrying or being sent leaves it
  to that job, with no second job and no new `last_summary_at`, so it is sent
  once. A change that leaves them holding changes nothing.
- **Short gaps.** When the next quiet period starts less than 30 minutes
  after one ends, the 15-minute run may fall in neither gap, so the summary
  goes at the first run after the period ended, inside the next one.

The worker emits `[:kanban, :push, :summarized]` with its `outcome` once per
period it takes, and `sent` and `failed` per device with
`event_type: :quiet_hours_summary`; see [Telemetry](telemetry.md#push-events).

## Environment variables

`config/runtime.exs` reads these variables in production only. Each platform
stays off until its variables are set, and then it needs all of them. Each
value is trimmed, and a value that is empty or only whitespace counts as unset.
These cases stop the boot with an error that names the variable and never
prints its value:

- Only some of a platform's variables are set.
- A value does not parse.

| Variable | Platform | Value |
|---|---|---|
| `APNS_KEY` | iOS | The contents of the APNs `.p8` auth key file. A value pasted on one line may use `\n` for each line break |
| `APNS_KEY_ID` | iOS | The 10-character key id of that key |
| `APNS_TEAM_ID` | iOS | The 10-character Apple team id |
| `APNS_TOPIC` | iOS | The iOS app's bundle id |
| `FCM_PROJECT_ID` | Android | The Firebase project id |
| `FCM_SERVICE_ACCOUNT_JSON` | Android | The JSON key file of a service account that may send FCM messages for that project |

No team id, key id, bundle id or project id is written in the code; each comes
from these variables. On Fly, set them as secrets. The review app uses its own
Firebase project and the APNs sandbox.

### Which APNs endpoint a device uses

APNs has a sandbox endpoint for development and TestFlight builds and a
production endpoint for App Store builds. Each iOS device records which one
its token belongs to in `push_environment`. With APNs configured, Stride runs
one connection to each endpoint: `Kanban.Push.APNs.SandboxDispatcher` and
`Kanban.Push.APNs.ProductionDispatcher`. It sends each push through the one
that matches the device. One `.p8` key works for both endpoints.

## What starts at boot

`Kanban.Push.Supervisor` starts a Pigeon dispatcher only for a platform whose
credentials are configured. For FCM it first starts a `Goth` token server,
which fetches an access token for the service account. With nothing
configured it starts no children, and no connection to Apple or Google is
opened.

## Keeping the keys out of the log

Pigeon and Goth keep the APNs key and the service account's private key in
their own processes and start arguments, and OTP can print those in crash and
supervisor reports. `Kanban.Push.LogRedaction` adds a `:logger` filter at boot
that replaces each line of either key's body with
`[REDACTED push credential]` in every warning-or-worse log event. A body
line shorter than 16 characters, such as the short last line of an Apple
`.p8` key, is too short to redact wherever it appears, since ordinary text
could hold it, so it is replaced together with the line next to it, joined
by a line break, an escaped `\n` or nothing; wherever the key itself is
logged, that line is redacted too. It adds nothing when no push credentials
are configured. `Kanban.Push.Supervisor`'s
own child specs never hold a credential: each child reads the credentials when
it starts.

## Development and tests

Development and tests never contact APNs or FCM:

- **Development.** `config/runtime.exs` reads the push variables only in
  production, so they are never set in development, even if your shell
  exports them. Both adapters answer `{:error, :not_configured}`, and the
  supervisor starts nothing.
- **Tests.** `config/test.exs` points both platforms at the Mox doubles
  `Kanban.Push.APNsMock` and `Kanban.Push.FCMMock`, defined in
  `test/test_helper.exs`. A test that needs a push result sets one with
  `Mox.expect/3`. Mapping an APNs or FCM answer is a pure function
  (`map_response/1` on each adapter) and is tested without a network.
  `test/kanban/push/runtime_config_test.exs` evaluates the production block of
  `config/runtime.exs` on its own, with generated keys.

Never configure real credentials in `config/dev.exs` or `config/test.exs`, and
never send a real push from a test.
