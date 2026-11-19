# The device routes: /api/me/devices

The routes the Stride mobile apps use to list, sign out and revoke a person's
devices, and to keep the current device's push token, locale and time zone up
to date ([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7.10,
§9.5, §16).

| Method | Path | What it does |
|---|---|---|
| GET | `/api/me/devices` | Lists the person's signed-in devices |
| PUT | `/api/me/devices/current` | Updates the device making the request |
| DELETE | `/api/me/devices/current` | Signs the device making the request out |
| DELETE | `/api/me/devices/:id` | Revokes one of the person's devices |

These are not agent endpoints. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication). The app sends the same
[`X-Stride-App` header](get_me.md#the-version-header), and an outdated app is
answered `426` before its token is checked.

These routes are **never plan-gated** (design §10). A person on a plan that does
not include the app can still see and sign out their devices.

A person sees and revokes only their own devices. Another person's device
answers `404`, the same as an id that names no device.

A device revoked while one of its own requests is in flight, from another of
the person's devices or by refresh-token reuse, gets
`401 {"error": "Invalid access token"}` from every route here, exactly as its
token would on the next request. It sees no device list, changes nothing and
revokes nothing, itself included.

## GET /api/me/devices

`200 OK` with the person's devices that are signed in, newest first:

```json
{
  "data": [
    {
      "id": 42,
      "name": "Jane's iPhone",
      "platform": "ios",
      "device_class": "phone",
      "model": "iPhone16,1",
      "os_version": "18.1",
      "app_version": "1.0.0",
      "locale": "en_GB",
      "time_zone": "Europe/London",
      "push_environment": "production",
      "push_registered": true,
      "current": true,
      "last_seen_at": "2026-11-18T09:30:00Z",
      "signed_in_at": "2026-11-01T08:00:00Z"
    }
  ]
}
```

`current` is `true` for the device whose token made the request.
`push_registered` says whether the device has a push token. The token itself is
never returned, nor the device's approval key or any token hash.

## PUT /api/me/devices/current

Updates the device whose token made the request. The body may carry any of
these keys. Any other key is ignored, and a key that is not sent is left as it
is:

| Key | Value |
|---|---|
| `push_token` | The APNs or FCM token. `""` or `null` clears it, so the device gets no pushes |
| `push_environment` | `"sandbox"` or `"production"` |
| `locale` | A BCP 47 language tag, or the platform form with underscores, such as `en_GB` |
| `time_zone` | An IANA time zone name, such as `Europe/London` |
| `app_version` | The app's version |

```json
{"push_token": "<APNs token>", "push_environment": "production", "time_zone": "Europe/London"}
```

`200 OK` returns the device in the shape `GET /api/me/devices` uses.

A push token belongs to one app install, so it is unique among devices. If
another device still holds the token, for example the device the same phone was
signed in as before, the token **moves**: it is cleared from the other device
and set on this one. Anyone who registers a token takes the pushes for that
install away from whichever device held it before, until the app registers it
again. Two devices registering the same token at the same moment are handled one
after the other: both answer `200`, and the device that registered last holds
the token.

Errors:

- `422` when a field is invalid: an unknown `push_environment`, a time zone the
  tz database does not know exactly as sent, a malformed locale, a value that
  is too long, or one carrying a character that cannot be stored, such as a NUL
  byte. The body is `{"errors": {"<field>": ["<message>"]}}`. It never
  echoes the value sent.
- `401 {"error": "Invalid access token"}` when the device was revoked while the
  request was in flight. That is the same response a revoked device's token
  gets, so the app handles both the same way.

## DELETE /api/me/devices/current

Signs the device making the request out. The device is revoked, its push token
is cleared, and all of its tokens expire, so every later call with them answers
`401`. `204 No Content`.

A repeat sign-out answers `401 {"error": "Invalid access token"}`: the request
authenticates with the device's own access token, which stopped working when the
device was revoked, so it never reaches the sign-out and records nothing. Signing
out is the same as [POST /oauth/revoke](post_oauth_token.md) with the device's
refresh token.

## DELETE /api/me/devices/:id

Revokes one of the person's devices, this one or another, in the same way.
`204 No Content`.

A device that is already revoked answers `204` and changes nothing, so a retry
after a lost response is safe. Another person's device, a missing device, and an
id that is not a positive integer answer `404 {"error": "Not Found"}`.

## What a revocation records

However a device is revoked, once the revocation commits Stride:

- writes a `device_revoked` audit event with a `reason`:
  - `sign_out`: the app signed itself out, through
    `DELETE /api/me/devices/current` or `POST /oauth/revoke`;
  - `user`: the person revoked it through `DELETE /api/me/devices/:id`;
  - `org_admin`: an Organization admin revoked it;
  - `reuse_detected`: an old refresh token was presented again (see
    [POST /oauth/token](post_oauth_token.md)).
- emits `[:kanban, :device, :revoked]` with the platform and the reason
  ([telemetry](../telemetry.md#mobile-app-events)).
- broadcasts a `disconnect` on the PubSub topic `device:<id>`, so a socket the
  device opened is closed.

A device that was already revoked records nothing again. Neither the audit event
nor the telemetry carries a token, and the telemetry never carries the device's
name.
