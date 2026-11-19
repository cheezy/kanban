# Push Notifications

This document is for operators and developers. It covers how Stride sends
native push notifications to the iOS and Android apps, the environment
variables that turn each platform on, and how the senders are kept away from
Apple and Google in development and tests. The design behind it is in
[Native Mobile Apps, Phase 1](plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md),
sections 7.8 and 15.2.

This page covers the senders only. Choosing which events push, quiet hours and
retries are the push worker's job, and each person's settings are described in
[GET and PUT /api/me/notification_settings](api/me_notification_settings.md).

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
`[REDACTED push credential]` in every warning-or-worse log event. It adds
nothing when no push credentials are configured. `Kanban.Push.Supervisor`'s
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
