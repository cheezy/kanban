# Two-Factor Authentication

Stride accounts can add a second factor to their password: a 6-digit,
time-based code (TOTP) from an authenticator app such as 1Password, Google
Authenticator or Authy. This page describes how a person turns it on and
manages it, how the secrets are stored, and what an operator has to configure.

API tokens are not affected. Agents keep authenticating with their bearer
token as described in the [Authentication Guide](AUTHENTICATION.md).

## Turning it on

Two-factor lives under **Settings → Two-factor** (`/users/settings?section=two_factor`).
Like the rest of the settings page, it needs a recent sign-in.

1. Choose **Set up two-factor authentication**. Stride shows a QR code and the
   same key as text, for apps that cannot scan.
2. Add the account to the authenticator app, then enter the 6-digit code it
   shows and choose **Verify and turn on**.
3. Two-factor is on only once that code is accepted. Leaving the page, or
   choosing **Cancel**, before then leaves it off; starting again creates a new
   key and the old one stops working.
4. Stride then shows ten **recovery codes**, once. Save them somewhere safe:
   they are never shown again.

A code is accepted for its own 30-second window and one window either side,
to allow for a phone clock that is slightly off. Each code works only once.

## Signing in

Once two-factor is on, a correct email and password no longer signs the
person in by itself. Stride sends them to **Two-factor authentication**
(`/users/two-factor`) and asks for the 6-digit code from the authenticator
app; **Use a recovery code instead** switches the same form to a recovery
code. Only after a code is accepted does Stride create the session.

- Between the two steps the session holds only a pending-sign-in marker (the
  user id, when it was issued and the **Keep me signed in** choice), never a
  session token. It is accepted for five minutes. After that, or after logging
  out, the person starts again from the password.
- **Keep me signed in** chosen on the password step is honoured once the code
  is accepted, and a person sent to sign in from another page returns to it.
- Signing in with a recovery code uses that code up, and Stride suggests
  creating new codes under **Settings → Two-factor**.
- If the account is disabled, or two-factor is turned off, while a sign-in is
  pending, the code is refused and the person starts again.
- Re-authenticating for sensitive settings (the same sign-in page, reached
  from **Settings**) asks for the second factor too. Changing the password
  from Settings, which already needed a recent sign-in, does not ask again.

## Recovery codes

Each recovery code (for example `a3k9x-q7m2p`) works exactly once. Spaces,
dashes and capital letters are ignored when one is typed in.

- **New recovery codes** replaces all ten codes, after a current code from the
  authenticator app. The old codes stop working straight away.
- A recovery code is the way back in for someone who has lost their
  authenticator: it can be used to turn two-factor off (below) and then set it
  up again on a new device.

## Turning it off

**Turn off two-factor** accepts either a current code from the authenticator
app or an unused recovery code, which is then used up. Turning two-factor off
deletes the stored key and recovery codes.

## Audit events

Each change is recorded in the audit log against the user:

| Event | When |
|---|---|
| `two_factor_enabled` | Enrollment was confirmed with a valid code |
| `recovery_codes_regenerated` | The recovery codes were replaced |
| `two_factor_disabled` | Two-factor was turned off; `method` is `totp` or `recovery_code` |
| `login_succeeded_two_factor` | A sign-in passed the second factor; `method` is `totp` or `recovery_code` |
| `two_factor_recovery_code_used` | A recovery code was used to sign in |
| `two_factor_challenge_failed` | A wrong code was entered at sign-in; `method` is `totp` or `recovery_code` |

No code, key or recovery code is ever written to the audit log.

## Code attempts are throttled

Every place a code is checked (signing in, confirming enrollment, new
recovery codes, turning two-factor off) counts each attempt per user, right or wrong, before
the code is looked at, so requests sent at once cannot get past the limit.
After 10 attempts in 5 minutes, every check is refused with "Too many
attempts. Please wait a few minutes and try again." until the window passes,
even for a correct code. The
limit is the `:two_factor` surface in `Kanban.RateLimit` and can be changed per
environment in config.

Signing in also counts wrong codes in two more ways:

- per IP address, across every account, on the `:two_factor_challenge`
  surface: after 30 wrong codes from one address in 5 minutes, sign-in codes
  from it are refused the same way;
- per account over a day, on the `:two_factor_daily` surface: after 30 wrong
  sign-in codes for one account in 24 hours, its sign-in codes are refused
  until the day's window passes, so someone who has the password cannot keep
  guessing at the 5-minute rate for weeks.

Any of these limits sends the person back to the sign-in page with the same
message a throttled password sign-in shows, so the response does not say
which limit was hit.

## How the secrets are stored

- **The authenticator key** is stored in the `user_totps` table encrypted with
  AES-256-GCM (`Kanban.Encryption`), with a random IV per value and a version
  byte for future key rotation. A database dump alone cannot be used to
  generate codes.
- **Recovery codes** are stored only as HMAC-SHA256 digests, keyed with a key
  derived from `ENCRYPTION_KEY` and bound to the user's id, so a database dump
  alone cannot be searched for them. They are compared in constant time.
- **Replay protection.** The 30-second step of the last accepted code is
  stored, and a code is accepted only for a later step. The check and the
  update are one conditional database write, so two requests racing with the
  same code cannot both succeed.

## Operator setup

Production needs an `ENCRYPTION_KEY` secret: 32 random bytes, base64-encoded
(`openssl rand -base64 32`), different for each environment. A release
refuses to boot without a valid one. Losing or replacing the key makes every
stored authenticator key unreadable, so every enrolled user has to set
two-factor up again. See [Encryption key](../README.md#encryption-key-encryption_key)
in the README.

If the key was lost or replaced, rows encrypted under the old key can no
longer be read, and loading one fails. Clear them so the affected users can
enroll again (this also turns two-factor off for them):

```sql
DELETE FROM user_totps;
```
