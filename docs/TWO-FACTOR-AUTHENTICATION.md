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

No code, key or recovery code is ever written to the audit log.

## Code attempts are throttled

Every place a code is checked (confirming enrollment, new recovery codes,
turning two-factor off) counts each attempt per user, right or wrong, before
the code is looked at, so requests sent at once cannot get past the limit.
After 10 attempts in 5 minutes, every check is refused with "Too many
attempts. Please wait a few minutes and try again." until the window passes,
even for a correct code. The
limit is the `:two_factor` surface in `Kanban.RateLimit` and can be changed per
environment in config.

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
