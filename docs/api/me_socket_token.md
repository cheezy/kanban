# POST /api/me/socket_token and the /api/socket connect

The Stride mobile app's live-updates socket
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7.7). The app asks
for a single-use socket token, then connects the socket at `/api/socket` with
it. The app's channels (`me:inbox` and `me:agents`) come in later releases;
today the socket connects and closes on revoke.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token, and an agent API token is
never accepted here.

## Authentication

`POST /api/me/socket_token` takes a device access token, sent as
`Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication), with the same
[`X-Stride-App` header](get_me.md#the-version-header). An agent API token is
refused with `401`.

The socket itself takes only the socket token. Never send the access token to
`/api/socket`: it is refused.

Every response of `POST /api/me/socket_token`, success or error, is
`cache-control: private, no-store`
([caching](README.md#caching-of-the-person-api)).

## Plans

The route is plan-gated with the `mobile_app` feature. While paid plans are
enforced, a person whose plan does not include the Stride app gets the
[`plan_required` body](me_reviews.md#plans).

## POST /api/me/socket_token

`201 Created` with a new token:

```json
{
  "data": {
    "token": "SFMyNTY.EXAMPLE0socket0token0for0documentation0only",
    "expires_at": "2026-11-20T09:31:00Z",
    "expires_in": 60
  }
}
```

- `token` is the socket token. It is shown once and never stored.
- `expires_at` is when it stops connecting, 60 seconds after the whole
  second it was issued in, in UTC. Go by `expires_at`: the token can stop
  connecting up to a second before 60 seconds have passed.
- `expires_in` is always `60`, the token's nominal lifetime in seconds.

Ask for a new token for every connect, a reconnect included.

## Connecting

Connect the Phoenix socket at `/api/socket`, with the token as the `token`
connect parameter. Over the websocket transport that is:

```text
wss://<host>/api/socket/websocket?token=<socket token>&vsn=2.0.0
```

Only the websocket transport is served; there is no long-poll fallback. The
socket is not mounted with the browser session.

A connect is accepted only when the token:

- was issued by `POST /api/me/socket_token` less than 60 seconds ago;
- names a device that is still signed in, whose user is still enabled, so a
  token issued before the device was revoked cannot connect;
- was never used before. The socket records a SHA-256 hash of the token's id
  the first time it connects, and refuses the same token after that. Of two
  connects racing with one token, exactly one is accepted.

Every refusal is the same: the connect is rejected, with no reason, whether
the token is missing, malformed, expired, used, or the device is revoked.
The reason is never logged: the server logs only that a connection was
refused, with the `token` parameter filtered out.

## Revoking the device closes the socket

The socket's id is the device's own topic, `"device:<id>"`. Revoking the
device, by signing out, from another device, from the web, by an
Organization admin or through refresh-token reuse, broadcasts a disconnect on
that topic, and every socket the device opened closes. One narrow window is
not covered: a revoke that commits while a connect is being accepted, after
the device was checked but before the socket listens on its topic, does not
close that socket. The socket carries no channels yet, so it receives
nothing; channels added later check the device again when they are joined.
After a revoke the app cannot get a new socket token, because its access
token is refused too.

## Errors

- `401 {"error": "Missing or invalid Authorization header"}` when no
  `Authorization: Bearer` header is sent.
- `401 {"error": "Invalid access token"}` for an unknown, expired or revoked
  device token, and for an agent API token.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `426` for an app version below the platform's minimum and `429` after too
  many failed authentications from one address, as for
  [GET /api/me](get_me.md#errors).
