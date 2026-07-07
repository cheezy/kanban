# Security Findings — Authentication & Session Management (W1592)

> Domain 1 of the comprehensive security review (G309). Reviewed by manual
> analysis plus an independent `stride-security-review` full-file pass, then
> each finding hand-verified against the code before filing.
>
> **Verdict: strong.** 0 critical · 0 high · 0 medium · 3 low (all
> defense-in-depth) · 4 boundaries verified clean.

## Surface reviewed

`lib/kanban_web/user_auth.ex`, `lib/kanban_web/controllers/user_session_controller.ex`,
`lib/kanban/accounts.ex`, `lib/kanban/accounts/user.ex`,
`lib/kanban/accounts/user_token.ex`, `lib/kanban/api_tokens.ex`,
`lib/kanban/api_tokens/api_token.ex`.

## Verified-clean boundaries

| Boundary | Evidence |
|----------|----------|
| **Session fixation** | On login, `create_or_extend_session/3` → `renew_session/2` runs `configure_session(renew: true)` + `clear_session()` + `delete_csrf_token()` (`user_auth.ex:118,152`). The same-user guard (`:132`) suppresses renewal only on the extend/reissue path, avoiding CSRF churn across tabs. Session id rotates on privilege elevation. |
| **Remember-me cookie** | Signed (`sign: true`), `SameSite=Lax`, 14-day max_age matching `@session_validity_in_days`; stores the server-side 32-byte token (not a bare credential), rotated on reissue, invalidated on password change/reset, cleared on logout (`user_auth.ex:15,127,168`). |
| **API token entropy/hash/timing/revocation** | 256-bit `crypto.strong_rand_bytes` token (`api_token.ex:56`), stored as unsalted SHA-256 hex (acceptable — pre-image is high-entropy, not a password), indexed-hash lookup with a dummy count query normalizing not-found/revoked timing (`api_tokens.ex:69,74,81`); only `revoked_at: nil` authenticates; board-scoped bulk revocation on access change (`:208`, W1430). |
| **Login confirmation gate + user enumeration** | `get_user_by_email_and_password/2` returns a user only after `Bcrypt.verify_pass`, and `valid_password?/2` calls `Bcrypt.no_user_verify/0` on the no-user path (`user.ex:191`), equalizing timing. The `%{confirmed_at: nil}` branch is reachable only after the correct password, so it leaks nothing; invalid-credential and unknown-email both converge on the generic "Invalid email or password" (`user_session_controller.ex:49,62,73`). Registration does not auto-login. |

## Findings filed (all low severity)

| ID | Finding | Severity | Where |
|----|---------|----------|-------|
| **D105** | Password-reset tokens reuse the 7-day change-email validity window | low | `accounts.ex:252` → `user_token.ex:138` (`@change_email_validity_in_days`, `:9`) |
| **D106** | Confirmation gate omitted from `require_admin`/`require_admin_user`/`require_sudo_mode` | low (defense-in-depth) | `user_auth.ex:256,272,338` |
| **D107** | API tokens have no `expires_at`/TTL — a leaked token is valid until manual revocation | low | `api_token.ex` schema, `api_tokens.ex:59` |

### D105 — reset-token window
`verify_email_token_query(token, "reset_password")` filters on the same 7-day
window as change-email/confirm. A reset link is an account-takeover primitive;
7 days is a long exposure horizon for an intercepted link. Single-use (all
tokens deleted on successful reset) limits blast radius but not the window.
**Fix:** a dedicated short reset validity (15–60 min or 1 day).

### D106 — confirmation invariant not enforced at every gate
Not exploitable today (login blocks unconfirmed sessions, so no unconfirmed
session can exist), but the invariant should hold at every authorization gate
rather than depend on login remaining the only session-minting path. **Fix:**
add the `is_nil(confirmed_at)` short-circuit to the admin/sudo gates, or
centralize it in `mount_current_scope`.

### D107 — no token TTL
`get_api_token_by_token/1` rejects only `revoked_at != nil`; there is no time
cutoff. **Fix:** add optional `expires_at`, enforce it through the same
dummy-timing path, and default new tokens to a bounded lifetime.

## Scope note

The API-token authentication plug (`authenticate_api_token.ex`) and the
registration/confirmation/reset **LiveView** flows were out of this domain's
file set — the plug is covered by W1593 (API authZ) and the LiveView
enumeration surface should get a follow-up pass. The enumeration/confirmation
conclusions here assume login is the only session-minting path for password
users, which holds in the reviewed code.
