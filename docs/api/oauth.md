# Device sign-in: the OAuth flow

How a Stride mobile app signs a device in
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7.1, §9.1, §9.2).
It is the OAuth 2.0 authorization code flow with PKCE (S256), for two public
clients that share one fixed redirect URI. This page walks the flow from end to
end. The token endpoints have their own page,
[POST /oauth/token and POST /oauth/revoke](post_oauth_token.md), with every
parameter and error.

These are not agent endpoints. Agents keep using the routes in the
[API reference](README.md) with their API token.

**Device tokens are not for agents.** A device token is made for one person on
one phone or tablet, and it only works on `/api/me`. Every agent route that
takes an API token refuses a device token with the same `401` an unknown API
token gets, and `/api/me` refuses an agent API token with `401`. An agent that
needs access uses an API token, as described in
[Authentication](../AUTHENTICATION.md).

## The flow at a glance

1. The app makes a PKCE verifier and its S256 challenge, a `state` value and a
   P-256 approval key pair, whose private half stays on the device.
2. It opens `GET /oauth/authorize` in the system browser, never in a web view.
3. The person signs in to Stride as on the web. Their Organization's single
   sign-on and two-factor rules apply. They then see "Sign in to Stride on
   *device name*?", the email they are signed in as, and **Allow** and
   **Cancel**.
4. **Allow** redirects the browser to
   `com.stridelikeaboss.app:/oauth/callback?code=…&state=…`. **Cancel**
   redirects with `error=access_denied` and the same `state`.
5. The app checks that `state` is the one it sent, then trades the code and its
   verifier for the device's tokens with `POST /oauth/token`
   ([redeeming a code](post_oauth_token.md#redeeming-an-authorization-code)).
6. It calls the [person API](me.md) with the access token, renews it with the
   refresh token
   ([rotating a refresh token](post_oauth_token.md#rotating-a-refresh-token)),
   and signs out with `POST /oauth/revoke`
   ([signing a device out](post_oauth_token.md#signing-a-device-out)).

## The clients

| Client | Platform | Redirect URI |
|---|---|---|
| `stride-ios` | iPhone and iPad | `com.stridelikeaboss.app:/oauth/callback` |
| `stride-android` | Android | `com.stridelikeaboss.app:/oauth/callback` |

Both are public clients with no client secret. A request naming any other
client, or any other redirect URI, is refused. The comparison is exact, with no
trimming or case folding. The only place a sign-in ever redirects to is built
from that fixed URI, never from a request parameter.

## GET /oauth/authorize

The page the app opens in the system browser. It is a browser route, not an API
route: a signed-out visitor is sent to the sign-in page and brought back, and
the Organization's two-factor gate applies before the page is shown.

| Parameter | Required | Notes |
|---|---|---|
| `response_type` | No | When sent, it must be `code` |
| `client_id` | Yes | `stride-ios` or `stride-android` |
| `redirect_uri` | Yes | Exactly `com.stridelikeaboss.app:/oauth/callback` |
| `code_challenge_method` | Yes | `S256` |
| `code_challenge` | Yes | The S256 hash of the verifier: 43 characters of base64url with no padding |
| `state` | Yes | 1 to 255 printable ASCII characters, returned unchanged on the redirect |
| `device_name` | Yes | The name shown on the page, up to 255 characters, with no control or bidirectional characters |
| `device_class` | Yes | `phone` or `tablet` |

The checks run in the order of the table. A parameter sent twice, or sent as a
list or map such as `state[]=…`, is refused. A signed-out request too long to
come back to after signing in is refused before the sign-in page.

An example, with placeholders in place of real values:

```text
https://stride.example/oauth/authorize?response_type=code&client_id=stride-ios&redirect_uri=com.stridelikeaboss.app%3A%2Foauth%2Fcallback&code_challenge_method=S256&code_challenge=<challenge>&state=<state>&device_name=<device name>&device_class=phone
```

The confirmation is shown even when the browser is already signed in. Without
it, a link someone else sent could hand a code to an app that is not the
person's. The page says to allow only if the person just started signing in
from the Stride app on that device.

The response carries `cache-control: no-store` and `referrer-policy:
no-referrer`, because the page's URL holds the challenge and the state. Its
content security policy adds the app's scheme to the places the form may
submit to, beside the page's own origin.

## POST /oauth/authorize

The page's own form, protected by its CSRF token. It sends `decision=allow` or
`decision=cancel` with the request's fields, and those fields are checked again,
since they came back from the browser. A POST that carries a query string did
not come from the page and is refused.

**Allow** issues an authorization code that works once, lives 60 seconds and is
stored only as a hash. The code carries the device name the person saw, so
`POST /oauth/token` never takes a name. When the browser session signed in
through the person's Organization's single sign-on, the code records that too
([rotating a refresh token](post_oauth_token.md#rotating-a-refresh-token)
explains what it changes).

**Cancel** redirects with `error=access_denied` and issues nothing.

## When a request is refused

Any request that fails a check gets a `400` page that reads "This sign-in
request isn't valid" and "Open the Stride app and start signing in again." It
is never redirected to the app, so a bad request cannot carry a code or an error
to an app that did not start it.

## Tokens

| Token | Prefix | Lifetime |
|---|---|---|
| Authorization code | `sdac_` | 60 seconds, one use |
| Access token | `sdat_` | 1 hour |
| Refresh token | `sdrt_` | 30 days from issue, never past 90 days from sign-in; one use, replaced on every refresh |

A device therefore signs in again after 30 days unused, and at least every 90
days. Presenting a used code or a used refresh token again is the sign of a
leak: Stride revokes the device and expires every token it holds, with reason
`reuse_detected`. The response shapes are in
[success](post_oauth_token.md#success-200-ok) and
[errors](post_oauth_token.md#errors-400-bad-request).

## Signing out

`POST /oauth/revoke` with the refresh token, or `DELETE /api/me/devices/current`
with the access token, revokes the device and expires all of its tokens. Both
record reason `sign_out`. The person can also revoke a device from the web, and
an Organization admin can revoke a member's devices
([the device routes](me_devices.md)).

## Rate limits

- `POST /oauth/token`: 60 requests a minute per IP address.
- `POST /oauth/revoke`: 30 requests a minute per IP address.
- A refresh and a revoke: also 10 a minute per presented refresh token, across
  addresses.

A limited request gets `429` with `retry-after`
([too many requests](post_oauth_token.md#too-many-requests-429)).

## Audit events

- `device_signed_in` when a code is redeemed and the device created.
- `device_refresh_reuse_detected` when a reused refresh token revokes a device.
- `device_revoked` on every revocation, with its reason
  ([what a revocation records](me_devices.md#what-a-revocation-records)).

None records a token, a code or the approval key.

## See also

- [POST /oauth/token and POST /oauth/revoke](post_oauth_token.md)
- [The person API: /api/me](me.md)
- [OpenAPI specification](get_openapi_json.md)
- [The Stride Mobile Apps](../mobile-apps.md)
