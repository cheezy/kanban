# GET /api/me

The first route of the person API the Stride mobile apps call
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7.1–§7.3, §9.2).
The app calls it at launch and after every sign-in. It returns the person, their
Organization and its workspaces, whether their plan includes the app, the
minimum app versions, the phone guard limits and the device the token belongs to.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`. The app gets it
from [POST /oauth/token](post_oauth_token.md). It lasts one hour, and the app
renews it with its refresh token.

The two kinds of token never cross:

- An agent API token is refused here with `401`.
- A device token is refused with `401` on every agent route that takes an API
  token, the same response an unknown API token gets.

## The version header

Every app request carries the app's platform, version and build:

```text
X-Stride-App: ios/1.0.0 (42)
X-Stride-App: android/1.0.0 (42)
```

Only the `MAJOR.MINOR.PATCH` version is compared. The build number is ignored.
Below the platform's minimum the request is refused with `426` before the token
is checked, so an outdated app reaches its update screen even when its token has
expired.

The `426` carries no `Upgrade` header, although RFC 9110 asks for one. That
header names a protocol to switch the connection to, and here nothing about the
connection changes: the app needs a newer store build, which the JSON body's
`store_url` points at. `Upgrade` is also a connection-specific header that
HTTP/2 forbids, so sending it could break the response on an HTTP/2 hop.

A request is **not** refused for a missing header, a header that does not match
that shape exactly, an unknown platform, or a header sent twice. Only the
official apps send the header, and a modified client can send anything, so
refusing those would lock out scripts and tools without protecting anything.
The minimum is there to move old store builds forward. It is not a way to
authenticate the client.

The minimums are runtime configuration (`config :kanban, :mobile_min_versions`).
A deployment sets them with `STRIDE_IOS_MIN_VERSION`,
`STRIDE_ANDROID_MIN_VERSION`, `STRIDE_IOS_STORE_URL` and
`STRIDE_ANDROID_STORE_URL`, then restarts. A variable that is unset, or a version
that is not `MAJOR.MINOR.PATCH`, keeps the built-in default of `1.0.0`.

## Response

`200 OK`. Every request also records the device as seen now.

```json
{
  "data": {
    "user": {"id": 15, "display_name": "Ada Lovelace", "initials": "AL"},
    "organization": {"id": 3, "name": "Analytical Engines", "role": "member"},
    "workspaces": [{"id": 7, "name": "Research", "slug": "research"}],
    "app_unlocked": true,
    "min_app_versions": {
      "ios": {"min_version": "1.0.0", "store_url": "https://apps.apple.com/app/stride"},
      "android": {
        "min_version": "1.0.0",
        "store_url": "https://play.google.com/store/apps/details?id=com.stridelikeaboss.app"
      }
    },
    "limits": {"phone_max_files": 10, "phone_max_lines": 500},
    "device": {
      "id": 42,
      "name": "Ada's iPhone",
      "platform": "ios",
      "device_class": "phone",
      "model": "iPhone15,2",
      "os_version": "18.1",
      "app_version": "1.0.0 (42)",
      "last_seen_at": "2026-11-18T12:00:00Z",
      "signed_in_at": "2026-11-01T09:30:00Z"
    }
  }
}
```

| Field | Notes |
|---|---|
| `user.display_name` | The person's name, or their email when they have set none |
| `user.initials` | One or two avatar initials, or `?` |
| `organization` | The person's Organization and their role in it (`org_admin` or `member`), or `null` |
| `workspaces` | The Organization workspaces the person can see, for the board picker's grouping. There is no current workspace. Empty without an Organization |
| `app_unlocked` | Whether the person's plan includes the mobile app (the `mobile_app` paid feature). It comes from the server's plan check, never from anything the app sends, and is always `true` while paid plans are not enforced |
| `min_app_versions` | Each platform's minimum version and store link |
| `limits` | The phone guard limits: the most files and lines a change may have to be approved on a phone |
| `device` | The device the token belongs to. Its push token and approval key are never returned |

The response only ever gains fields. A field is never removed or renamed while a
supported app version reads it. A breaking change gets a new path and a new
minimum version.

A person removed from their Organization after signing in gets
`"organization": null` and `"workspaces": []` on their next request.

## Errors

| Status | Body | When |
|---|---|---|
| `401` | `{"error": "Missing or invalid Authorization header"}` | No `Authorization` header, or one that is not `Bearer` |
| `401` | `{"error": "Invalid access token"}` | The token is unknown, expired or a refresh token, the device is revoked, the account is disabled, or the token is an agent API token. A device revoked, or an account disabled, while the request was in flight gets it too, never the data. The body is the same for every cause |
| `426` | `{"error": "app_update_required", "store_url": "…"}` | The `X-Stride-App` version is below the platform's minimum |
| `429` | `{"error": "Too many requests"}` | Too many failed authentications from this address. Wait for the `retry-after` seconds |

The `400` and `406` responses every `/api` route can return are described in the
[API reference](README.md#errors).

## Telemetry

A `426` emits `[:kanban, :api, :outdated_app_refused]` with only the platform. A
failed authentication emits `[:kanban, :api, :auth_failed]` with reason
`missing_token`, `device_token_invalid` or `rate_limited`. See
[Telemetry](../telemetry.md).
