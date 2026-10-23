# Single Sign-On

An Organization can let its people sign in to Stride through its own identity
provider with OpenID Connect (OIDC) or, for providers that only speak it,
SAML 2.0. Org-admins claim the Organization's email
domains, prove they own them with a DNS record, and connect one identity
provider. People with an address on a verified domain then sign in with
**Sign in with SSO** on the login page, and their first sign-in
creates their account and makes them a member of the Organization.

This page describes the setup, what happens at sign-in, what is refused, and
what an operator has to know. Organizations themselves are described in
[Organizations and Workspaces](organizations.md), their two-factor and audit
retention policies in
[Organization Security Policies](organization-security-policies.md), and
password and two-factor sign-in in the
[Authentication Guide](AUTHENTICATION.md). An identity provider can also
create and deprovision people through
[SCIM Provisioning](scim-provisioning.md).

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

**Keep the record published.** A domain can lapse or change hands after it
was verified, so `Kanban.SSO.DomainRecheckWorker` looks every verified
domain's record up again each day at 04:11 UTC
(`Kanban.SSO.DomainRecheck`):

- When the record is found, nothing changes.
- When it is not found, the miss is counted and the domain's row on the
  single sign-on page shows a warning with the date of the first miss and the
  record to publish again. A later check that finds the record clears it.
- When three checks in a row miss it, the domain stops being verified: single
  sign-on and SCIM stop accepting addresses on it, and another Organization
  may verify it. This is recorded as `organization_domain_unverified`. The
  row and its token are kept, so publishing the record and selecting
  **Verify** makes it verified again. People already in the Organization stay
  members.

A DNS lookup that fails counts as a miss, so a resolver outage on Stride's
side would have to last for three daily runs before a domain is unverified.
The cron schedule is read when the application boots, so a running server
starts the daily check after its next restart.

### The identity provider

Register Stride as an application (a confidential client using the
authorization code flow) in the identity provider, with the redirect URI the
page shows, which ends in `/users/sso/callback`. Then enter in the page's
**OpenID Connect identity provider** section:

| Field | What it is |
|---|---|
| Issuer URL | The provider's issuer, such as `https://login.example.com`. Stride reads `/.well-known/openid-configuration` under it. |
| Client ID | The application's client ID. |
| Client secret | The application's client secret. |
| Allow sign-in through this identity provider | Off until you turn it on. |

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
somewhere else. Each request is also bounded: it must connect within 5
seconds and finish within 10, and a response body over 1 MB is refused, so a
slow or oversized answer from a provider cannot hold a sign-in open or fill
the server's memory. The authorization endpoint is not checked: Stride never
requests it, it only sends the person's browser there. In development,
`config :kanban, Kanban.SSO, allow_private_issuers: true` (set in
`config/dev.exs`) allows a local provider such as Keycloak on
`http://localhost`.

**Shared identity providers.** Some issuers serve many tenants at one URL,
such as Google (`https://accounts.google.com`). Stride trusts any verified
email on the Organization's verified domains that the issuer signs, and checks
no tenant claim (such as Google's `hd`). That includes a personal account
someone created on a work address, such as a consumer Google account on
`name@example.com`, which a former employee may still control. Limit the
client to your own tenant in the identity provider: in Google Cloud, make the
OAuth consent screen **Internal**. Where a provider offers a tenant-specific
issuer, use it, such as Microsoft Entra ID's
`https://login.microsoftonline.com/<tenant id>/v2.0`.

## Signing in

1. On the login page the person enters their work email under **Work email for
   single sign-on** and selects **Sign in with SSO**. Only the domain is used: Stride finds the Organization
   that verified it and sends the browser to its identity provider.
   A sign-in that another site starts (the browser's `Sec-Fetch-Site` header
   says `cross-site` or `same-site`) is sent to the login page instead, with
   no flow started. Otherwise any page could bounce a visitor through an
   identity provider its author controls and sign them in to the author's
   account (login CSRF). The same applies to SAML, which starts here too.
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
every refusal, "Single sign-on could not sign you in. Contact your
Organization's administrator if this continues.", so the page never
says whether an account exists or which Organization it belongs to.

### Which account

Accounts are linked to the identity provider by the provider's issuer and the
person's subject (`sub`), never by email alone. The email the provider sends
is compared case-insensitively and without trailing dots, so
`pat@example.com.` names `pat@example.com`.

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
- **An existing account with two-factor turned on** is not linked straight
  away. Stride sends the person to **Two-factor authentication**
  (`/users/two-factor`) and asks for the code from the account's authenticator
  app, or a recovery code, once; nothing is linked or recorded until a code is
  accepted. The account is then read again and linked under the same rules,
  and the person is signed in through single sign-on. Later single sign-on
  sign-ins find the linked identity and do not ask again. Without this, an
  identity provider could sign in to an account protected by a second factor
  it never checked. See [Two-factor and single sign-on](#two-factor-and-single-sign-on).

Single sign-on only ever makes someone a **member**. It never makes anyone an
org-admin, and it never changes the role of an existing org-admin.

### What is refused

- An email on a domain the Organization has not verified, or no
  `email_verified` from the provider.
- An account that belongs to another Organization. Nothing about its
  membership changes; a person belongs to one Organization at a time.
- A disabled account.
- A site admin. Site admins sign in with their password (and two-factor), so
  no Organization's identity provider can sign anyone in with site-admin
  powers. This holds for an identity linked before the account became a site
  admin, too.
- A person [SCIM](scim-provisioning.md) deprovisioned from the Organization,
  until SCIM re-activates them.
- A connection that is turned off, or a provider that cannot be reached or
  sends something invalid.
- A missing, expired, reused or mismatched `state`, and an ID token whose
  signature, issuer, audience, expiry or `nonce` is wrong.

A person removed from the Organization who signs in again through single
sign-on is made a member again, as long as the provider asserts a verified
address and the account's own email is still on a domain the Organization
verified. Stop them in the identity provider. Someone SCIM deprovisioned is
the exception: they stay out until SCIM re-activates them, even when the
identity provider still lets them sign in. Someone who has since moved
their account to an address on another domain is refused: it is no longer
the Organization's to sign in as.

## SAML 2.0

An Organization whose identity provider only speaks SAML 2.0 configures it in
the **SAML identity provider** section of the same page. People still start
with **Sign in with SSO** and their work email; when the Organization that
verified the domain has no enabled OIDC connection, Stride starts a SAML
sign-in instead. OIDC is preferred: when both are enabled, Stride starts a
SAML sign-in only if the OIDC identity provider cannot be reached.

### Setting up SAML

Register Stride in the identity provider with the two values the page shows,
or with the SP metadata from **Download Stride's SP metadata**
(`/org/sso/saml/metadata`, org-admins only):

| Value | What it is |
|---|---|
| Stride entity ID | `<site>/users/sso/saml/<organization id>`, the audience Stride requires. |
| Assertion consumer service URL | The entity ID followed by `/acs`; the provider posts responses there (HTTP-POST binding). |

Stride signs nothing and asks for signed assertions or responses
(`WantAssertionsSigned`). Then either paste the provider's metadata XML into
**Identity provider metadata XML**, which fills the fields, or enter them:

| Field | What it is |
|---|---|
| Identity provider entity ID | The provider's issuer; every response must name it. |
| Single sign-on URL | The provider's HTTP-Redirect sign-on service, an `https` URL. |
| Signing certificates (PEM) | One RSA certificate of at least 2048 bits, or two while the provider rotates its key. Bare base64, as metadata carries it, is accepted too. |
| Allow sign-in through this SAML identity provider | Off until you turn it on. |

Certificates are public, so they are stored unencrypted. Saving records an
`sso_connection_updated` audit event with `protocol: saml`.

### A SAML sign-in

1. Stride stores a request record: the AuthnRequest ID, a random RelayState
   token, the local path to return to, and a 10-minute expiry. It sends the
   browser to the provider with a deflated AuthnRequest and that RelayState,
   and sets a signed, `SameSite=None`, `Secure` cookie holding the token,
   scoped to `/users/sso/saml`.
2. The provider posts the response to the Organization's assertion consumer
   service. That route has no CSRF token and the session cookie is not sent
   with the cross-site POST, so Stride finds the request by its RelayState in
   the database, never the session, and requires the binding cookie to hold the
   same token, so a response cannot be posted into another browser.
3. The response is checked against that Organization's connection only. It
   must be no larger than 256 KB, carry no DOCTYPE, entity, comment, CDATA or
   processing instruction and no element with the same attribute written
   twice, hold exactly one assertion directly under the
   response, and be signed (the response, the assertion or both) with
   RSA-SHA256, SHA-256 digests and exclusive canonicalization by one of the
   configured certificates. The assertion must name the configured issuer,
   have Success status, list Stride's entity ID in every audience restriction,
   carry one bearer subject confirmation whose recipient is the assertion
   consumer service URL and whose `InResponseTo` is the stored request, and be
   inside `NotBefore` and `NotOnOrAfter` with 2 minutes of clock skew. A
   transient NameID is refused, because it changes on every sign-in.
4. In one transaction Stride records the assertion ID for that connection and
   marks the request used. An assertion ID seen before is refused, recorded as
   `saml_assertion_replayed` and as `sso_login_refused` with reason
   `assertion_replayed`. A request answers at most one response.
5. The person's NameID is their subject, and their email comes from the email
   attribute (`email`, `mail` or the claims URI) or an email-shaped NameID.
   From here the [Which account](#which-account) and
   [What is refused](#what-is-refused) rules apply unchanged: the email must
   be on a domain the Organization verified, people in another Organization,
   disabled users and site admins are refused, and the session is marked as a
   single sign-on session.

Responses the identity provider starts on its own (IdP-initiated sign-in) are
refused, because they answer no request. Every refusal shows the same
message and is recorded with its reason and `protocol: saml`.

Expired request records and assertion IDs are deleted by the daily
`Kanban.Retention.PurgeWorker` (its `saml_count`). An assertion ID is kept
until its `NotOnOrAfter` plus the skew, after which the assertion would be
refused as expired anyway.

## Two-factor and single sign-on

The identity provider enforces its own sign-in rules, so a single sign-on
session satisfies the Organization's require-two-factor policy: the session
holds `"sso_authenticated"` set to the Organization's id, which
`KanbanWeb.UserAuth.OrganizationTwoFactorGate` accepts only while the person
is still a member of that Organization. A password sign-in never sets it,
and removes it from a session that had it. See
[Requiring two-factor](organization-security-policies.md#requiring-two-factor).

The first time single sign-on would link an existing account that has its own
two-factor turned on, the account's code is asked for once before the link is
made (see [Which account](#which-account)). Between the two steps the session
holds the same pending-sign-in marker as a password sign-in, which also
carries the connection's id and the identity provider's subject; it is
accepted for five minutes, never remembers the device, and the challenge's
attempt limits apply. The session is a cookie of at most 4096 bytes, so a
subject longer than 1024 bytes is refused (`invalid_claims`), and a page to
return to whose path and the subject together pass 2048 bytes is dropped:
the person lands on their boards instead. `Kanban.SSO.TwoFactorLink` makes the link once the code
is accepted and records `sso_login`, or `sso_login_refused` with the reason;
a refused link sends the person back to the log-in page with the usual single
sign-on message.

## Paid access and rate limits

Single sign-on is a paid feature (`:sso`). The org-admin page and every sign-in
check paid access through `Kanban.Plans`, which refuses only while paid plans
are enforced (the `:plans_enforced` setting). Then the page and sign-in are
refused to someone without paid access, and the single sign-on section of a
user's settings shows the shared lock to a user without an Organization. With
enforcement off, nothing is refused. SCIM and the security policy page are not
paid features and never check it.

The start, callback and SAML assertion consumer service requests are
throttled per IP address through the `:sso` surface of `Kanban.RateLimit` (60
a minute by default).

## Known limits

- Turning a connection off stops new sign-ins; it does not end sessions that
  are already signed in.
- An account created by single sign-on has no password, so it cannot use
  actions that ask for the password, such as deleting the account.
- Stride does not cache the discovery document or the provider's signing keys.
  Every sign-in fetches both again, so a slow or unavailable identity provider
  slows or stops sign-in for that Organization.
- SAML supports only signed, unencrypted assertions over the HTTP-Redirect
  request and HTTP-POST response bindings, with RSA-SHA256. Encrypted
  assertions, single logout and IdP-initiated sign-in are not supported.
- SAML is read through `simple_saml` and `simple_xml`, whose canonicalization
  is simpler than a full XML signature library. Responses signed by Microsoft
  Entra ID and Okta are covered by tests; a provider whose signed XML uses
  constructs Stride refuses (comments, entity references, deep nesting) or
  canonicalizes differently fails closed with `signature_invalid` or
  `unsafe_xml`. Test a new provider before turning sign-in on.
- A SAML sign-in is bound to the browser by one cookie, so starting a second
  SAML sign-in in another tab replaces the first one's binding. The first tab's
  sign-in is then refused (`browser_mismatch`); starting it again works.

## Where it lives

| Module | What it does |
|---|---|
| `Kanban.SSO` | The context: domains, the connection, access checks. |
| `Kanban.SSO.DomainVerification` | The TXT record and its lookup. |
| `Kanban.SSO.OIDC` | Discovery, the token request and ID token validation, through `oidcc`. |
| `Kanban.SSO.OIDCLogin` | The sign-in flow: start and callback. |
| `Kanban.SSO.Provisioning` | Which account, and its membership. |
| `Kanban.SSO.DomainRecheck` | The daily re-check of verified domains (run by `Kanban.SSO.DomainRecheckWorker`). |
| `Kanban.SSO.TwoFactorLink` | Links an account with two-factor on once its code is accepted. |
| `Kanban.SSO.SAML` | SAML response validation and the AuthnRequest, through `simple_saml`. |
| `Kanban.SSO.SAML.XML` | Hardened XML reading for SAML responses and metadata. |
| `Kanban.SSO.SAML.Metadata` | IdP metadata, certificates and Stride's SP metadata. |
| `Kanban.SSO.SAMLLogin` | The SAML sign-in flow: request records, the assertion consumer service, replay protection. |
| `KanbanWeb.SSOController` | `/users/sso/start` and `/users/sso/callback`. |
| `KanbanWeb.SAMLController` | `/users/sso/saml/:organization_id/acs` and `/org/sso/saml/metadata`. |
| `KanbanWeb.OrgLive.SSO` | The org-admin page at `/org/sso`. |

The audit events are listed in the [Telemetry Guide](telemetry.md).
