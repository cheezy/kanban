# SCIM Provisioning

An Organization can let its identity provider (Okta, Microsoft Entra ID or
any other SCIM 2.0 client) manage who belongs to it. The identity provider
creates people, keeps their workspace memberships in step with its groups,
and removes their access when it deprovisions them, all through the SCIM 2.0
API at `/scim/v2`. Every request is authenticated with an
Organization-scoped bearer token, and a token never reaches a user or a
workspace outside its own Organization.

SCIM works alongside [Single Sign-On](single-sign-on.md). It uses the same
verified domains, and the people it creates sign in through that
connection. Organizations themselves are described in
[Organizations and Workspaces](organizations.md), and their security policies
in [Organization Security Policies](organization-security-policies.md).

## Setting it up

Org-admins open the SCIM page (`/org/scim`) with **SCIM provisioning** on the
Organization console (`/org`). As with the single sign-on page, only an
enabled org-admin of the Organization reaches it. Anyone else is sent to
`/boards` and the refusal is recorded as a `permission_denied` audit event.
The role is checked again on every create and revoke.

1. Copy the **SCIM base URL** the page shows (it ends in `/scim/v2`) into the
   identity provider's SCIM settings.
2. Create a token with a name that says which identity provider holds it.
   The token, which starts with `stride_scim_`, is shown **once**. Copy it into
   the identity provider as the bearer token. Stride stores only a SHA-256
   hash of it, so it cannot be shown again; create a new one if it is lost.
3. Revoke a token from the same page. A revoked token stops working at once
   and cannot be restored.

An Organization can hold several tokens, for example while rotating one. The
page lists each token with its creator, its creation date and when it was
last used (updated at most once a minute).

## Users

`userName` is the person's email address, compared case-insensitively and
without trailing dots, so `ada@example.com.` names `ada@example.com`. Its
domain must be one of the Organization's verified domains.

| Request | What happens |
|---------|--------------|
| `POST /Users` | No account has the email: a confirmed, passwordless account is created with a `member` membership, and the Organization **manages** it. An enabled account has the email: it gains a `member` membership (an org-admin keeps their role) and is **linked**, not managed. |
| `GET /Users`, `GET /Users/:id` | The Organization's members, plus people SCIM deprovisioned who have not joined any Organization since (shown with `active: false`). A former member the Organization removed some other way, from the org console for example, is not found, and neither is anyone who joined an Organization after SCIM deprovisioned them, even once they leave it again. |
| `PUT /Users/:id` | Replaces the name and `externalId`. Leaving out `active` or `externalId` leaves it unchanged. |
| `PATCH /Users/:id` | The Okta form (`{"op": "replace", "value": {"active": false}}`) and the Entra form (`{"op": "Replace", "path": "active", "value": "False"}`) are both accepted. Changing one name part (`name.givenName`, say) keeps the others. |
| `DELETE /Users/:id` | Deprovisions the user, then forgets the link (its `externalId` and name parts), so the user is no longer found. A later `POST` with the same `userName` re-activates an account the Organization manages. |

The name comes from `name.formatted`, else `name.givenName` and
`name.familyName`, else `displayName`, and is changed only on accounts the
Organization manages. The given and family name read back as they were sent
while they still make up the name; once the name changes some other way, it
is split at its first space. `userName` cannot change; a request that changes
it is refused with `scimType: "mutability"`. A `POST` that sets `active` to
false is refused (`400`, `scimType: "invalidValue"`).

### Deprovisioning

Setting `active` to false, or deleting the user, removes the user's
Organization membership. In every workspace of the Organization, archived ones
included, it also removes their workspace membership and their access to the
boards, owner access included (a board they owned is left to the
Organization's org-admins), and revokes their API tokens for those boards and
their workspace tokens. Tasks they still hold under a claim, including ones
waiting in Review, go back to the board's Ready column; on a board with no
Ready column they stay where they are. They are unassigned from every other
task that is not archived, finished ones included, the webhook endpoints they
created on those boards are disabled (see
[When the person who added an endpoint leaves](webhooks.md#when-the-person-who-added-an-endpoint-leaves)),
and open invitations sent to them, or sent by them, in the Organization are
revoked. Their open pages are disconnected so they re-check their access.
This happens even when the account was already disabled, so the
Organization's access never outlives the identity provider's removal. Until
SCIM re-activates them, signing in through the Organization's
[single sign-on](single-sign-on.md) does not make them a member again, even
when the identity provider still lets them sign in.

When the Organization manages the account, it is also **disabled**: every
session is deleted, along with any password-reset or email-change link it has
not used, and every API token the person holds is revoked, on any board. A
linked account, which the person owns, keeps its personal boards and its other
access. A site admin is never disabled. Whether the person is
still the Organization's is checked again inside the deprovisioning
transaction, so one who joins another Organization at the same moment is
answered `404` and is never disabled from here.

The last enabled org-admin of an Organization that still has other members
cannot be deprovisioned (`409`).

A disabled managed account cannot sign in, so its owner cannot use
self-service deletion. Neither SCIM's deactivation nor its delete removes the
account. When the person asks for it to be deleted (`/terms` and `/privacy`
tell them to email us), a site admin deletes it from `/admin/users`. For a
disabled managed account that deletion runs the self-service cascade: boards
in its personal workspace that only the person uses are deleted, and the
rest are re-homed, instead of being refused because the account still has
boards. It is still refused while the account owns a board other people use;
transfer that board or remove its other members first.

Setting `active` back to true re-activates the user: a `member` membership is
restored and a managed account is enabled again, but only when SCIM's own
deprovisioning disabled it. An account a site admin disabled stays disabled,
and SCIM's request is refused (`409`); once a site admin disables or enables
the account, SCIM's earlier disable no longer counts as SCIM's. Revoked API
tokens and deleted sessions are not restored, and neither is anything else
deprovisioning removed: workspace memberships, board access, task assignments
and disabled webhook endpoints stay as they are. Add the person to workspaces
again, through the identity provider's groups or the org console.
Re-activation is refused once the person has joined another Organization, and
for an account the Organization does not manage whose email domain it no
longer verifies (`400`).

A request that is refused changes nothing: a PATCH that sets `externalId` and
`active: false` together on the last org-admin leaves the `externalId` as it
was.

### What is refused

| Case | Response |
|------|----------|
| The email's domain is not verified by the Organization | `400`, `scimType: "invalidValue"` |
| The person belongs to another Organization, the account is disabled and not managed by this Organization, or the account is a site admin | `409`, `scimType: "uniqueness"`, with a generic message that names neither the other Organization nor the reason |
| The user already exists in the Organization | `409`, `scimType: "uniqueness"` |
| A user outside the token's Organization | `404` |

## Groups

Groups are the Organization's workspaces (personal workspaces are never
shown, and archived ones are not listed). The identity provider can read them
and change their members with `PATCH /Groups/:id`:

- `add` adds Organization members with the `member` role; someone already in
  the workspace, such as a guest, keeps their role. Adding anyone who is not a
  member of the Organization is refused (`400`), and an archived workspace
  gains no members.
- `remove`, with a `members[value eq "<id>"]` path or a list of values,
  removes members the way an org-admin's removal does: they lose their access
  to that workspace's boards and their board and workspace API tokens there,
  their claimed tasks go back to Ready as in
  [Deprovisioning](#deprovisioning), they are unassigned from its tasks that
  are not archived, the webhook endpoints they created on its boards are disabled
  unless they can still open the board as an org-admin, and open invitations
  to that workspace addressed to them are revoked. Workspace owners are never
  removed.
- `replace` of `members` adds and removes to match the list it sends.

A change of members moves the Group's `meta.lastModified`. Two PATCHes to one
Group at the same moment are not merged: the later one wins, and the identity
provider's next sync sets the members again.

Workspaces are created, renamed and archived in the Stride org console, so
`POST`, `PUT` and `DELETE` on `/Groups` are refused with `403`, and a
`displayName` change with `scimType: "mutability"`.

## Discovery, filters and paging

`/ServiceProviderConfig`, `/ResourceTypes` and `/Schemas` describe what Stride
supports: PATCH and filtering yes; bulk, sorting, ETags and password changes
no. They need a token too.

The one supported filter is equality, `userName eq "ada@example.com"` on
Users and `displayName eq "Platform"` on Groups. Any other filter is refused
with `scimType: "invalidFilter"`. Lists take `startIndex` (from 1) and
`count` (default 100, at most 200). `excludedAttributes=members` leaves the
members out of Groups.

Responses use the `application/scim+json` content type, and requests may be
sent as `application/scim+json` or `application/json`. Errors use the SCIM
error schema, including the `401` for a missing, unknown or revoked token and
a malformed body's `400`.

## Rate limits and auditing

Failed authentications are rate limited by client address and by token: ten
failures with one token in a minute, or a hundred from one address, and
further requests get `429` with `retry-after` before the token is looked up.

Every token change and every change a token makes is recorded in the audit
log with the Organization and the token's id, never the token:
`scim_token_created`, `scim_token_revoked`, `scim_auth_failed`,
`scim_user_provisioned`, `scim_user_updated`, `scim_user_deprovisioned` and
`scim_group_updated`. The events are listed in the
[Telemetry](telemetry.md) reference.

## Where it lives

- `Kanban.SCIM` and the modules under `lib/kanban/scim/`: tokens, Users,
  Groups, request parsing and the deprovisioning lifecycle.
- `Kanban.Accounts.deprovision_from_organization/2` and
  `reactivate_in_organization/2`: the membership and account changes.
- `KanbanWeb.Plugs.AuthenticateScimToken` and the controllers under
  `lib/kanban_web/controllers/scim/`: the `/scim/v2` API.
- `KanbanWeb.OrgLive.SCIM`: the org-admin page.
