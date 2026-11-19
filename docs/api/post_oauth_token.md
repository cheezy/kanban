# POST /oauth/token and POST /oauth/revoke

The token half of device sign-in for the Stride mobile apps
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7.1, §9.1, §9.2).
The app opens `GET /oauth/authorize` in the system browser, the person
confirms the sign-in there, and the browser hands the app a one-time
authorization code. These two endpoints take it from there:

- `POST /oauth/token` trades the code and its PKCE verifier for a new device and
  its first access and refresh token, and later rotates the refresh token.
- `POST /oauth/revoke` signs the device out.

They are not agent endpoints. An agent API token is never accepted here, and a
device token is never accepted on an agent route.

## Authentication

None. Neither route reads an `Authorization` header. What proves the caller is
the authorization code with its verifier, or the refresh token, and each travels
only in the request body.

## Request

Send the body as `application/x-www-form-urlencoded` (RFC 6749) or as
`application/json`. Every parameter is a string. A list or map value, such as
`code[]=…`, is refused as `invalid_request`.

Only the body is read. A parameter in the query string is ignored, so a code,
verifier or token put in the URL, where proxy and access logs would keep it,
counts as missing and the request answers `invalid_request` (RFC 6749 §3.2,
RFC 7009 §2.1).

### Redeeming an authorization code

| Parameter | Required | Notes |
|---|---|---|
| `grant_type` | Yes | `authorization_code` |
| `client_id` | Yes | `stride-ios` or `stride-android`, the client the code was issued to |
| `code` | Yes | The code from the redirect. It lives 60 seconds and works once |
| `code_verifier` | Yes | The PKCE verifier (RFC 7636 §4.1): 43 to 128 characters whose S256 hash was sent as `code_challenge` |
| `redirect_uri` | Yes | Exactly the redirect URI the code was issued for, `com.stridelikeaboss.app:/oauth/callback` |
| `platform` | Yes | `ios` or `android` |
| `device_class` | Yes | `phone` or `tablet` |
| `approval_public_key` | Yes | The device's P-256 public key, described below |
| `model`, `os_version`, `app_version` | No | Up to 255 characters each |
| `locale` | No | A language tag such as `en-GB`, or the platform form `en_GB` |
| `time_zone` | No | An IANA time zone, such as `Europe/London`, spelled exactly as the tz database spells it |

The device's name comes from the authorization code, which carries the name the
person saw on the confirmation page. It is never taken from this request.

**The approval public key** is the 65-byte uncompressed P-256 point (`0x04`, then
X, then Y), encoded as base64url with no padding: exactly 87 characters. Both
platforms export this form natively. Any other curve, a compressed point, an
SPKI or PEM wrapper, padding, or a point that is not on the curve is refused.
Stride stores the key in its canonical spelling.

The checks run in this order, and nothing is created until all of them pass:

1. The device details are checked. A bad detail answers `invalid_request` and
   leaves the code unused, so the app can fix the request and retry.
2. The code is redeemed. It must have been issued to this `client_id`, and be
   unused, unexpired and belong to an account that is not disabled. Of two
   requests racing with one code, exactly one gets it.
3. The redirect URI must match, and the verifier must hash to the code's
   challenge.

Steps 2 and 3 answer the same `invalid_grant`. The code is already used up when
step 3 fails, so a wrong verifier cannot be retried against the same code.

### Rotating a refresh token

| Parameter | Required | Notes |
|---|---|---|
| `grant_type` | Yes | `refresh_token` |
| `client_id` | Yes | `stride-ios` or `stride-android` |
| `refresh_token` | Yes | The device's current refresh token. It works only with the `client_id` the device signed in through; under another it is refused with `invalid_grant` and stays usable |

Each refresh token works once. A rotation returns a new pair and uses up the one
sent. Presenting a refresh token that was already used is the sign of a stolen
token, so Stride revokes the device, expires all of its tokens and records
`device_refresh_reuse_detected` in the audit log, even when the account is
disabled at the time, with a `device_revoked` event whose reason is
`reuse_detected` ([device routes](me_devices.md#what-a-revocation-records)).
The person must then sign in again.

A refresh is also refused, with `invalid_grant`, when:

- the account is disabled;
- the device was revoked; or
- the person's Organization requires two-factor and their grace period is over.
  A member still in the grace period can refresh, the same line the web sign-in
  draws. The refresh token is not used up, so it works again once two-factor is
  on.

### Signing a device out

`POST /oauth/revoke` (RFC 7009):

| Parameter | Required | Notes |
|---|---|---|
| `token` | Yes | The device's refresh token, current or already used |
| `client_id` | Yes | `stride-ios` or `stride-android` |
| `token_type_hint` | No | Accepted and ignored |

The device is revoked as its own user, and every token it holds is expired.
It is recorded as a `device_revoked` audit event with reason `sign_out`, the
same as `DELETE /api/me/devices/current`
([device routes](me_devices.md#what-a-revocation-records)).

## Response

Every response carries `cache-control: no-store` and `pragma: no-cache`,
including the errors raised before the request reaches the endpoint's own code,
such as a body that cannot be parsed or an `Accept` header that rules out JSON.

### Success (200 OK)

`POST /oauth/token`:

```json
{
  "access_token": "sdat_…",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "sdrt_…"
}
```

The access token lasts one hour. The refresh token expires 30 days after it was
issued, and never later than 90 days after the device signed in, so a device
signs in again at least every 90 days.

`POST /oauth/revoke` answers `{}` for any well-formed request, whether or not the
token named a live device (RFC 7009 §2.2), so it cannot be used to test tokens.

### Errors (400 Bad Request)

Every refusal is an RFC 6749 §5.2 error. The description is fixed text, or names
the fields that failed, and never echoes a value that was sent. No failure ever
carries a token.

```json
{
  "error": "invalid_grant",
  "error_description": "The authorization code or refresh token is invalid, expired or already used."
}
```

| `error` | When |
|---|---|
| `invalid_request` | A required parameter is missing, empty or not a string; the device details are invalid (the description names the fields); or the body cannot be parsed |
| `invalid_client` | `client_id` is not `stride-ios` or `stride-android` |
| `invalid_grant` | The code or refresh token is unknown, used, expired, issued to another client or redirect URI, or refused; or the PKCE verifier does not match |
| `unsupported_grant_type` | `grant_type` is neither `authorization_code` nor `refresh_token` |

### Too Many Requests (429)

Both routes are rate limited per IP address. A refresh and a revoke are also
limited per device, across addresses, so one device's token cannot be hammered
from many places. The response says how long to wait in `retry-after`, in
seconds:

```json
{ "error": "rate_limited", "error_description": "Too many requests. Try again later." }
```

The limits are in `Kanban.RateLimit` (the `:oauth_token`, `:oauth_revoke` and
`:oauth_device` surfaces).

## Audit events

- `device_signed_in`, when a code is redeemed and the device created. It records
  the device id, platform, device class and app version the app reported.
- `device_refresh_reuse_detected`, when reuse revokes a device. It records the
  device id.

Neither records a token, a code or the approval key. Both are listed under the
person's Organization when they belong to one. See [telemetry](../telemetry.md).

## Logging

`code`, `code_verifier`, `refresh_token`, `token` and `approval_public_key` are
filtered from request logs and from error reports.

## See also

- [OpenAPI specification](get_openapi_json.md): `oauthToken` and `oauthRevoke`.
