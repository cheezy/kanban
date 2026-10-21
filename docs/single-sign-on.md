# Single Sign-On

An Organization can let its people sign in to Stride through its own identity
provider with OpenID Connect (OIDC). Org-admins claim the Organization's email
domains, prove they own them with a DNS record, and connect one identity
provider. People with an address on a verified domain then sign in with
**Sign in with SSO** on the login page, and their first sign-in
creates their account and makes them a member of the Organization.

This page describes the setup, what happens at sign-in, what is refused, and
what an operator has to know. Organizations themselves are described in
[Organization Security Policies](organization-security-policies.md), and
password and two-factor sign-in in the
[Authentication Guide](AUTHENTICATION.md).

## Setting it up

Org-admins open the single sign-on page (`/org/sso`) with **Single sign-on**
on the Organization console (`/org`). Only an enabled org-admin of the
Organization reaches it. Anyone else is sent to `/boards` with "You must be an
org-admin of an Organization to access this page." and the refusal is
recorded as a `permission_denied` audit event. The role and paid access are
checked again on every add, verify, remove and save, so an org-admin demoted
while the page is open cannot change anything.

### Verified domains

1. Add the domain, such as `example.com`. It is stored lowercased and starts
   unverified.
2. Publish the TXT record the page shows: the name is
   `_stride-verification.<domain>` and the value is
   `stride-verification=<token>`, where the token is random and different for
   each domain.
3. Select **Verify**. Stride looks the record up in DNS; verification succeeds
   only when the exact value is present. DNS changes can take a while to
   appear, so a failed check can be repeated later.

Several Organizations may add the same domain, but only one can verify it: the
database admits a single verified row per domain, so the first verification
wins. Adding or verifying a domain another Organization has already verified
is refused with "Another Organization has already verified this domain."

Only verified domains are used for sign-in. An unverified domain does nothing.

### The identity provider

Register Stride as an application (a confidential client using the
authorization code flow) in the identity provider, with the redirect URI the
page shows, which ends in `/users/sso/callback`. Then enter on the page:

| Field | What it is |
|---|---|
| Issuer URL | The provider's issuer, such as `https://login.example.com`. Stride reads `/.well-known/openid-configuration` under it. |
| Client ID | The application's client ID. |
| Client secret | The application's client secret. |
| Allow sign-in | Off until you turn it on. |

The client secret is stored encrypted and is never sent back to the browser:
the field is always empty, and saving with it empty keeps the stored secret.
The page says when a secret is stored.

The issuer must be an `https` URL on a public address. Stride resolves the
host and refuses private, loopback and link-local addresses, and checks the
other addresses it requests itself (the JWKS and the token endpoint named in
the discovery document) the same way, so a connection cannot be used to reach
internal services. Each request then goes to the address that was checked,
with the host name sent for TLS and in the `host` header, so a DNS answer that
changes between the check and the connection (DNS rebinding) cannot point it
somewhere else. The authorization endpoint is not checked: Stride never
requests it, it only sends the person's browser there. In development,
`config :kanban, Kanban.SSO, allow_private_issuers: true` (set in
`config/dev.exs`) allows a local provider such as Keycloak on
`http://localhost`.

## Signing in

1. On the login page the person enters their work email under **Work email for
   single sign-on** and selects **Sign in with SSO**. Only the domain is used: Stride finds the Organization
   that verified it and sends the browser to its identity provider.
2. The request uses the authorization code flow with PKCE (`S256`), a random
   `state` and a random `nonce`. All three are kept in the person's session,
   are used once and are removed when the provider sends the browser back. A
   sign-in has 10 minutes to finish.
3. On the way back Stride checks that the `state` matches, exchanges the code
   for tokens with the PKCE verifier, and validates the ID token: its
   signature against the provider's published keys (only asymmetric
   algorithms are accepted, never `none` or a shared-secret algorithm), the
   issuer, the audience, the expiry and the `nonce`.
4. Stride then decides the account, as described below, and signs the person
   in. The session is marked as a single sign-on session.

Every sign-in is recorded as an `sso_login` audit event, and every refusal as
`sso_login_refused` with the reason. The person sees the same message for
every refusal, "Single sign-on could not sign you in.", so the page never
says whether an account exists or which Organization it belongs to.

### Which account

Accounts are linked to the identity provider by the provider's issuer and the
person's subject (`sub`), never by email alone.

- **A known identity** signs in to the account it is linked to, even if the
  provider now sends a different email address.
- **A new person** gets an account when their email is on a domain the
  connection's Organization verified and the provider asserts
  `email_verified`. The account is confirmed, has no password, gets a personal
  workspace like any new account, and becomes a member of the Organization.
  This is recorded as `sso_user_provisioned`.
- **An existing account with the same email** is linked under the same two
  conditions, and becomes a member of the Organization if it is not already
  one. An account whose email was never confirmed is confirmed, its password
  is removed and its sessions are ended, because whoever created it never
  proved they own the address. This is recorded as `sso_account_linked`.

Single sign-on only ever makes someone a **member**. It never makes anyone an
org-admin, and it never changes the role of an existing org-admin.

### What is refused

- An email on a domain the Organization has not verified, or no
  `email_verified` from the provider.
- An account that belongs to another Organization. Nothing about its
  membership changes; a person belongs to one Organization at a time.
- A disabled account.
- A connection that is turned off, or a provider that cannot be reached or
  sends something invalid.
- A missing, expired, reused or mismatched `state`, and an ID token whose
  signature, issuer, audience, expiry or `nonce` is wrong.

A person removed from the Organization who signs in again through single
sign-on is made a member again, as long as the provider still asserts their
verified address on a verified domain. Stop them in the identity provider.

## Two-factor and single sign-on

The identity provider enforces its own sign-in rules, so a single sign-on
session satisfies the Organization's require-two-factor policy: the session
holds `"sso_authenticated" => true`, which
`KanbanWeb.UserAuth.OrganizationTwoFactorGate` accepts. A password sign-in
never sets it, and removes it from a session that had it. See
[Requiring two-factor](organization-security-policies.md#requiring-two-factor).

## Paid access and rate limits

Single sign-on is a paid feature (`:sso`). The org-admin page and every sign-in
check paid access through `Kanban.Plans`; while paid plans are enforced, the
single sign-on section of a user's settings shows the shared lock to a user
without an Organization.

The start and callback requests are throttled per IP address through the
`:sso` surface of `Kanban.RateLimit` (60 a minute by default).

## Known limits

- Turning a connection off stops new sign-ins; it does not end sessions that
  are already signed in.
- An account created by single sign-on has no password, so it cannot use
  actions that ask for the password, such as deleting the account.
- Stride does not cache the discovery document or the provider's signing keys.
  Every sign-in fetches both again, so a slow or unavailable identity provider
  slows or stops sign-in for that Organization.

## Where it lives

| Module | What it does |
|---|---|
| `Kanban.SSO` | The context: domains, the connection, access checks. |
| `Kanban.SSO.DomainVerification` | The TXT record and its lookup. |
| `Kanban.SSO.OIDC` | Discovery, the token request and ID token validation, through `oidcc`. |
| `Kanban.SSO.OIDCLogin` | The sign-in flow: start and callback. |
| `Kanban.SSO.Provisioning` | Which account, and its membership. |
| `KanbanWeb.SSOController` | `/users/sso/start` and `/users/sso/callback`. |
| `KanbanWeb.OrgLive.SSO` | The org-admin page at `/org/sso`. |

The audit events are listed in the [Telemetry Guide](telemetry.md).
