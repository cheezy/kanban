# iOS Live Channel

This document is for contributors who work on the native iOS and iPadOS app in
`mobile/ios`. It describes `LiveChannel` in StrideKit: the one socket that
brings the app the live Now and Agents updates, how it connects and connects
again, and how it finds out that a sign-in has ended. The server's side is in
[The live-updates socket](api/me_socket_token.md) and
[The live channels](api/me_channels.md); the platform choice is section 12 of
the [Phase 1 design](plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).

## Listening

A screen's view model reads `updates(of:)` for the topic it shows:

| Topic | Channel | Event | Each update |
|---|---|---|---|
| `.inbox` | `me:inbox` | `decisions` | `LiveUpdate.decisions`, the body of `GET /api/me/decisions` |
| `.agents` | `me:agents` | `agents` | `LiveUpdate.agents`, the body of `GET /api/me/agents` |

- **Full state, never a difference.** Each channel sends its whole state on
  join and after each change, so the newest update replaces the one before and
  nothing is merged. A push that does not decode as its API body, or that
  arrives on an event the topic does not send, is dropped.
- **The newest only.** The stream keeps only the newest update for a slow
  reader, and the same state twice in a row is delivered once.
- **Shared joins.** The first listener of a topic joins its channel, later
  listeners share that join and get the newest state at once, and the channel
  is left when its last listener stops. Both channels ride one socket, which
  closes when nobody listens to either.
- **The state.** `states()` reports `idle`, `connecting`, `live`, `waiting`
  (pausing before the next connect), `signedOut` or `unavailable`, the state now
  first.

The app holds one `LiveChannel` in `StrideApp.live`. Never make a second: each
would hold its own socket.

## Connecting

Every connect asks the API for a new socket token (`POST /api/me/socket_token`,
through `StrideAPI`, which refreshes the access token once when it has
expired). The token is used once and lasts 60 seconds, so `LiveChannel` makes a
new connection for every connect and never lets the socket library reconnect
on its own: a second connect with the same token is refused.

`SocketTokenAnswer` reads the answer:

| Answer | Then |
|---|---|
| 201 | connect with the token |
| 401, or a refresh the server refuses | the sign-in has ended: clear `AuthStore` and stop (`signedOut`) |
| 403 `plan_required`, or 426 | stop until `resume()` (`unavailable`) |
| anything else, or no network | pause, then ask again |

After a drop, a refused connect, a refused join or a closed channel,
`LiveChannel` closes the socket, pauses and connects again with a new token.
The pause grows with each failure in a row, 1, 2, 5, 10 and then 30 seconds,
and starts over once the server accepts every channel listened to on that
connection: one channel joining while another is refused still counts as a
failure. Asking for a new token is also
how a refused join finds out why: an ended sign-in or a lapsed plan shows in
the token answer.

`resume()` connects again at once, with no pause, so each channel sends its
full state. `AppRouter.refresh()` calls it each time the app becomes active. It
does nothing while nobody listens.

## Revoking a device

When a device is revoked, the server closes its socket with a plain close and
sends no message, so a revoke looks like any other drop. The next connect asks
for a token, the API answers 401, the refresh is refused, and `APIClient`
clears `AuthStore`. `LiveChannel` then reports `signedOut` and stops, and
`SignInModel` shows the Sign in screen.

A sign-out drops each channel's newest state, so whoever signs in next never
gets the last person's decisions or agents from a new listener. `LiveChannel`
drops it itself on `signedOut`, and `AppRouter.follow(_:)` calls `forget()`
when the app leaves the shell, which also closes the socket. Listeners stay,
and `resume()` connects again for them after the next sign-in.

## Where it lives

- `StrideKit/Sources/StrideKit/Live/` holds `LiveChannel`, `LiveTopic`,
  `LiveUpdate`, `LiveState`, `SocketTokenAnswer` and `PhoenixConnection`, the
  one type that names SwiftPhoenixClient. `Package.swift` pins it at 5.3.5.
- `PhoenixConnection` connects to `wss://www.stridelikeaboss.com/api/socket`
  through an ephemeral `URLSession`, with no cookies or cache. The socket URL
  carries the token, so never set the library's logger and never log the URL,
  a push or a `SocketTokenAnswer`, whose description hides the token.
- Tests drive `LiveChannel` through its internal initialiser with a
  `FakeLiveServer` and `FakeLiveConnection` (`StrideKitTests`), which record
  each token request, connect, join, leave, close and pause.
- `PhoenixConnectionTests` drive `PhoenixConnection` through its internal
  initialiser, which takes the socket's transport, with a `FakePhoenixTransport`
  that plays the server: it records each message the socket sends and answers
  with the protocol's `[join_ref, ref, topic, event, payload]` arrays, so the
  events come from SwiftPhoenixClient's own message handling. A join reply's
  reason is read from the message's `payload`, which the library has already
  unwrapped from the reply's `response`.
