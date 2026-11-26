# iOS Sign-in

This document is for contributors who work on the native iOS and iPadOS app in
`mobile/ios`. It describes how the app signs a device in, where each part lives,
and how to see and test the Sign in screen without a server. The server's side
of the flow is in [Device sign-in: the OAuth flow](api/oauth.md), and what a
person sees is in [The Stride Mobile Apps](mobile-apps.md#signing-in).

## What the screen does

The Sign in screen is the first screen of a device that is not signed in. It
shows the logo, the name, what the app is for and three points, with the
**Sign in** button and a link to create an account on the web at the foot. The
first point names what the person will approve with: Face ID, Touch ID or the
passcode, whichever the device has. The link is underlined in the text colour
rather than the system blue, which reaches only about 4:1 on white, under the
4.5:1 that small text needs.

**Sign in** opens Stride's `/oauth/authorize` page in the system's secure
browser window (`ASWebAuthenticationSession`). It shares cookies with Safari,
so a company sign-in or a two-step check the person already passed on the web
carries over, and the app never sees a password. When the person presses
**Allow**, the web sends the browser back to `com.stridelikeaboss.app:/oauth/callback`
with a code, and the app trades the code for the device's first token pair.

The screen then asks `GET /api/me` whether the person's plan includes the app.
When it does not, the button gives way to a panel that says the app is part of
the Organization plan, with a link to the pricing page. The device stays signed
in, and the app asks again each time it becomes active, so a person who joins
an Organization on the web gets in without signing in again. When `/api/me`
cannot be reached, the app carries on as signed in and asks again later.

## The steps of one attempt

`SignInModel.signIn` runs these in order. Each press of **Sign in** is a new
attempt, and any failure returns to the screen with a message, except Cancel,
which returns with none.

1. **Make the approval key.** `ApprovalKeyMaking.makeKey()` makes a P-256 key in
   the Secure Enclave, before the browser opens, because the code lives only 60
   seconds and a device that cannot hold the key should not send the person
   through the web first. A device without a passcode is told to set one: the
   key needs it. The simulator has no Secure Enclave, so it makes a software key.
2. **Start the attempt.** `OAuthAttempt()` makes a new PKCE verifier and `state`,
   32 random bytes each, and builds the authorize URL with the S256 challenge,
   the device's name and its class (phone or tablet).
3. **Open the browser.** `SystemWebAuthenticator` waits for the callback scheme.
   Closing the window cancels the sign-in.
4. **Check the callback.** `OAuthAttempt.code(from:)` takes the callback only
   when its scheme and path are the redirect URI and it carries exactly one
   `state` equal to the attempt's, which it checks first. `error=access_denied`
   (the person pressed **Cancel** on the web) cancels; any other error, a
   repeated parameter or a missing code fails.
5. **Trade the code.** `OAuthFlow.exchange` sends `POST /oauth/token` once, with
   the code, the verifier, the device's details and the public half of the
   approval key. The device's details are cut to the 255 code points (Unicode
   scalars) the server accepts, keeping whole characters so an accent or an
   emoji is never split. The name loses control and direction characters and
   the other invisible format characters, but keeps the joiners and tags that
   emoji and some scripts need; a name with nothing that shows is sent as
   iPhone or iPad.
6. **Keep the sign-in.** `AuthStore.save(_:approvalKey:)` stores the key's handle
   and then the token pair, as two Keychain items of the same service, and
   announces the sign-in. Every `clear` removes both.

## Rules

- **Never repeat the exchange.** The server burns a code it refuses, so a second
  try could only fail. `APIClient` repeats only reads, and the exchange sends no
  access token.
- **Never log the attempt.** The verifier, the code, the tokens and the approval
  key stay out of logs, errors and snapshots. `SignInError` holds none of them,
  and `ApprovalKey` prints as `ApprovalKey(redacted)`.
- **Keep logic in the model.** The views render `SignInModel` and send its
  intents. The model reaches the server, the Keychain and the browser through
  `SignInServices` and `WebAuthenticating`, so tests replace each one.
- **Ignore an answer that comes late.** The model applies an answer from
  `/api/me` only if the phase did not change meanwhile, and a sign-out during an
  attempt wins over the attempt.

## Where each part lives

| Part | File |
|---|---|
| PKCE verifier, state, authorize URL and callback check | `StrideKit/Sources/StrideKit/Auth/OAuthAttempt.swift` |
| The token exchange | `StrideKit/Sources/StrideKit/Auth/OAuthFlow.swift` |
| What the server records about the device | `StrideKit/Sources/StrideKit/Auth/DeviceDetails.swift` |
| The approval key | `StrideKit/Sources/StrideKit/Auth/ApprovalKey.swift` |
| Whether the plan includes the app | `StrideKit/Sources/StrideKit/Auth/AppAccess.swift` |
| Why a sign-in did not finish | `StrideKit/Sources/StrideKit/Auth/SignInError.swift` |
| The model and its phases | `Stride/Features/SignIn/SignInModel.swift`, `SignInPhase.swift` |
| The screen | `Stride/Features/SignIn/SignInView.swift` and the views beside it |
| The debug stubs | `Stride/Debug/` |

The paths are under `mobile/ios/`.

## Seeing the screen without a server

Start a debug build with `-StrideStubSignIn` and one of these. Each signs in
through a stub browser, the fixtures in `mobile/shared/fixtures/` and a store
kept in memory, so nothing is written to the Keychain.

| Value | What happens after **Sign in** |
|---|---|
| `allow` | The web allows the device and the plan includes the app |
| `cancel` | The person closes the browser window |
| `locked` | The web allows the device and the plan does not include the app |
| `offline` | The token exchange cannot reach the server |

For example, in the app's scheme or with `xcrun simctl launch`:

```bash
xcrun simctl launch booted com.stridelikeaboss.app -StrideStubSignIn locked
```

A release build ignores the argument.

## Tests

- `StrideKitTests` checks the challenge against the server's PKCE vector, the
  authorize URL, every way a callback is refused, the exchange's body and that
  it is sent once, the approval key's shape, and the two Keychain items.
- `SignInModelTests` and `SignInLaunchTests` in `StrideTests` drive the model
  through the stubs: a completed flow, a wrong state, cancel, a network error,
  the locked plan, a fresh state on each attempt, and following the stored
  sign-in.
- `SnapshotTests` checks the screen in both appearances, at the largest text
  size, and its readable width on an iPad.
- `SignInUITests` in `StrideUITests` signs in through the stub and runs the
  accessibility audit, including in German at the largest text size, where it
  audits the top of the screen and again after scrolling to each link. The
  audit does not report the three points as clipped text: each point grows to
  its full height, so nothing in it is cut off, but the audit measures text a
  little wider than SwiftUI draws it and flags a point whose line fills the
  column. Every other issue, and clipped text anywhere else, still fails.

[iOS Mix Tasks](ios-mix-tasks.md) has the command that runs them.
