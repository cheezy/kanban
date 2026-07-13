# Security Findings — Authentication LiveView Flows (W1676)

> Follow-up to the comprehensive security review (G309). W1592 (Domain 1,
> auth & sessions) **explicitly excluded** the registration, confirmation,
> password-reset, and forgot-password **LiveView** flows and the
> `authenticate_api_token` plug from its file set, and noted its conclusions
> assumed login was the only session-minting path. This document is the
> deferred pass over those surfaces, performed by manual analysis plus an
> independent `stride-security-review` full-file pass and a separate
> fact-mapping exploration, then each item hand-verified against the code.
>
> **Verdict: strong.** 0 critical · 0 high · 1 medium · 3 low · 2 info/accepted ·
> 8 boundaries verified clean. The D105/D106/D107 hardening from W1592 is
> present and correctly implemented on these surfaces.

## Surface reviewed

`lib/kanban_web/live/user_live/registration.ex`, `confirmation.ex`,
`confirmation_pending.ex`, `forgot_password.ex`, `reset_password.ex`,
`login.ex`; `lib/kanban_web/plugs/authenticate_api_token.ex`; supporting
`lib/kanban_web/user_auth.ex`, `lib/kanban_web/controllers/user_session_controller.ex`,
`lib/kanban/accounts.ex`, `lib/kanban/accounts/user.ex`,
`lib/kanban/accounts/user_token.ex`, `lib/kanban/accounts/user_notifier.ex`,
`lib/kanban/api_tokens*`, and the `router.ex` `live_session :current_user` block
(lines 201-213). Rate limiting / brute force is out of scope here (owned by
W1678); pure DoS is excluded per the review policy.

## W1592 assumption re-verified

**Login is the only session-minting path — confirmed.** Every session token is
minted through the single choke point `UserAuth.create_or_extend_session/3`
(`user_auth.ex:118-128`), reached only from
`UserSessionController.create/3` (`user_session_controller.ex:69`) after
`get_user_by_email_and_password` verifies a password. Verified that none of the
reviewed LiveViews mint a session:

- **Registration** does not auto-login — the controller redirects to
  `/users/confirmation-pending` (`user_session_controller.ex:20-36`); pinned by
  `registration_test.exs:65-84` (`refute get_session(conn, :user_token)`). (A
  stale comment at `registration.ex:155` claims the controller "will create user
  and log in" — it does not; the comment is misleading but harmless and left as a
  code-hygiene note, not filed.)
- **Confirmation** confirms the account and `push_navigate`s to `/users/log-in`
  (`confirmation.ex:218-235`); never calls `log_in_user`.
- **Password reset** redirects to `/users/log-in` and deletes all user tokens
  (`reset_password.ex:105-111`, `accounts.ex:281`); pinned by
  `reset_password_test.exs:56-73`.

The only non-login mint is the automatic reissue-on-read of an *already valid*
session ≥7 days old (`user_auth.ex:104`), which is not a new authentication.

## Findings filed

| ID | Defect | Sev | Summary |
|----|--------|-----|---------|
| **M1** | **D133** | **MEDIUM** | Password reset deletes tokens but does not disconnect active LiveView sockets — a hijacked live session survives account recovery |
| L1 | D134 | low | Synchronous in-request email delivery is a timing side channel that re-opens user enumeration on forgot-password / confirmation-resend |
| L2 | D135 | low | API-token plug returns distinct error bodies (`invalid` / `revoked` / `expired`) that disclose token-lifecycle state |
| L3 | D136 | low | Reset page promises a "15 minutes" link lifetime but the enforced window is 1 day — expectation/enforcement mismatch |

### M1 — Reset does not evict live sessions
`reset_user_password/2` (`accounts.ex:272-288`) updates the password and
`Repo.delete_all`s every `UserToken`, but returns `{user, count}` — a count, not
the deleted token rows. The caller
(`ResetPassword.handle_event("reset_password", …)`, `reset_password.ex:105-111`)
discards the result and redirects. Deleting the token rows stops future
HTTP/reconnect attempts, but an attacker's **already-mounted** LiveView socket
retains `current_scope` in process memory and keeps functioning until it
disconnects. Account recovery therefore fails to evict an intruder — the primary
purpose of a reset.

The fix pattern already exists: the change-password flow returns the token rows
(`update_user_and_delete_all_tokens/1` → `{user, tokens_to_expire}`,
`accounts.ex:444-451`) and the controller calls
`UserAuth.disconnect_sessions(expired_tokens)` (`user_session_controller.ex:85`).
`reset_user_password/2` should mirror this: collect the token rows before
deleting, return them, and have the reset flow call
`UserAuth.disconnect_sessions/1` on success.

### L1 — Timing enumeration via synchronous mail
Forgot-password (`forgot_password.ex:84-101`) and confirmation-resend
(`confirmation_pending.ex:153-166`) correctly return an **identical flash**
regardless of whether the email exists (content-level enumeration is closed and
test-pinned — `forgot_password_test.exs:44-75`,
`confirmation_pending_test.exs:73-91`). But delivery runs **in-band**:
`user_notifier.ex:27` calls `Mailer.deliver` synchronously, preceded by a
`Repo.insert!` of the token — both only happen when the account exists. The
measurable latency delta re-opens the enumeration the identical-flash design
closes. Fix: move delivery off the request path (supervised `Task`) so both
branches take equivalent time; async delivery also removes SMTP latency from the
user-facing response.

### L2 — API-token error strings disclose token state
`authenticate_api_token.ex:55-80` returns three distinguishable 401 bodies:
`"Invalid API token"` (`:not_found`), `"API token has been revoked"`
(`:revoked`), `"API token has expired"` (`:expired`). Timing is correctly
normalized by the dummy `timing_query` (`api_tokens.ex:69-90`, verified clean),
but the message content still tells a caller holding a candidate token whether it
ever corresponded to a real token. Low impact (only helps someone already
holding a plausible value). Fix: return one uniform body for all three failure
modes; keep the `reason` distinction in the server-side telemetry only (it
already stays server-side — `authenticate_api_token.ex:92-102`).

### L3 — Reset link lifetime copy/enforcement mismatch
`forgot_password.ex:26` renders "The link expires in 15 minutes." The enforced
window is `@reset_password_validity_in_days = 1` day
(`user_token.ex:13`, `verify_reset_password_token_query`
`user_token.ex:157-171`). Reset links therefore live ~96× longer than the UI
promises. Fix (implementer's choice, security-preferred first): shorten the
enforced window toward the promised 15 minutes, or correct the copy to state the
true window. Note this is still tighter than the pre-D105 state (D105 already
split reset onto its own 1-day window, down from the 7-day change-email window).

## Documented, not filed

### I1 (info) — No explicit `Referrer-Policy` on token-bearing pages
`/users/reset-password/:token` and `/users/confirm/:token` carry a single-use
secret in the URL. `put_secure_browser_headers` is set but `Referrer-Policy` is
not (`router.ex:24-26`). Exposure today is negligible — the auth pages load no
external resources, the CSP is `default-src 'self'`, and the reset page links only
to `/users/log-in`, so there is no realistic cross-origin `Referer` leak path.
Recorded as cheap future-proofing: adding
`"referrer-policy" => "strict-origin-when-cross-origin"` (or `no-referrer`) to the
`:browser` pipeline would protect the token if any external link/image is ever
added to a token page.

### A1 (accepted risk) — Registration confirms whether an email is registered
On submit, registration builds the changeset with `validate_unique: true`
(`registration.ex:146-161`, `user.ex:86-103`); a taken email surfaces "has
already been taken". This is an enumeration channel, and it is the weakest
enumeration link in the set (the sibling flows go to lengths to avoid exactly
this). It is the inherent phx.gen.auth trade-off — you cannot silently allow
duplicate registrations — so it is **accepted**, not a regression. Full
mitigation requires a flow redesign (always show "check your email" and send
either a confirm link or an "you already have an account" notice out-of-band),
which is a product decision. Pinned as current behavior by
`registration_test.exs:86-99`.

## Verified-clean boundaries

1. **No session minting from confirmation or magic links** — every mint path
   funnels through `create_or_extend_session` after password verification; no
   auto-login on register/confirm/reset (see "assumption re-verified" above).
2. **Confirmation gate (D106) consistent across all gates** —
   `is_nil(user.confirmed_at)` is checked in the `require_authenticated` (232),
   `require_admin` (264), `require_sudo_mode` (286) on_mounts and the
   `require_authenticated_user` (340) / `require_admin_user` (371) plugs, and
   login blocks unconfirmed users (`user_session_controller.ex:50-60`). An
   unconfirmed account cannot reach an authenticated surface.
3. **Token single-use + context separation** — confirm tokens deleted after use
   (`accounts.ex:385-388`); reset consumes by deleting all tokens
   (`accounts.ex:281`). Contexts strictly separated (`session` / `confirm` /
   `reset_password` / `change:<email>`), each with its own verifier and TTL
   (reset 1 day, confirm/change-email 7 days, session 14 days).
4. **Email tokens hashed at rest** — `build_hashed_token` stores `sha256(token)`
   and emails only the raw token (`user_token.ex:85-96`); DB-read access cannot
   replay a link.
5. **Session fixation / CSRF** — `renew_session` calls `configure_session(renew:
   true)` + `clear_session()` + `delete_csrf_token()` on login
   (`user_auth.ex:152-158`); remember-me cookie is `sign: true`,
   `same_site: "Lax"`; `protect_from_forgery` is in the `:browser` pipeline.
6. **API token: timing-safe path, expiry enforced, no token logging** — all
   failure branches route through the dummy `timing_query`; lookup is by
   `sha256` hash; D107 expiry enforced via `ApiToken.expired?`; telemetry emits
   `reason`/`path`/`method` only, never the token value.
7. **Reflected `?email=` param is safe** — gated by an email regex + 160-byte cap
   (`confirmation_pending.ex:175-185`) and rendered through HEEx auto-escaping;
   no reflected XSS.
8. **LiveView handlers do not trust stale/forgeable assigns for authz** —
   `ResetPassword` derives `@user` from server-side token verification in `mount`
   (`reset_password.ex:118-126`), not client params; the `reset_password` event
   reuses that server-assigned user. Name field rejects `< > &` and CR/LF,
   closing email-template injection (`user.ex:78-84`).

## Method

Rebased onto latest `origin/main`. Two independent passes (an exploration
fact-map and a `stride-security-review` full-file review), reconciled, then every
finding hand-verified against the source before filing. No code was changed in
this task — findings are filed as separate Stride defects (M1 medium; L1/L2/L3
low) so each carries its own review gate, per the W1676 task pitfalls.
