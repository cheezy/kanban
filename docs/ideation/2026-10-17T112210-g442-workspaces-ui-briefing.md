# G442 Workspaces: UI and Technical Briefing

**Purpose:** what changes on screen when goal G442 is complete, how each change works, and which earlier open questions are now settled.

**Revised 2026-10-17 for the paying-Organizations program.** G442 was rewritten so that workspaces live **under Organizations**:
- Org-admins replace the workspace admin role.
- Personal workspaces are hidden.
- Workspaces are a paid-only feature.

The program's documents:
- Requirements: `docs/ideation/2026-10-17T154403-paying-organizations-and-free-tier-limits-for-stride-requirements.md`
- Detailed design: `docs/plans/PAYING-ORGANIZATIONS-DESIGN.md`
- Decomposition: `docs/ideation/2026-10-17T154403-paying-organizations-and-free-tier-limits-for-stride-stride-batch.json`

**Status (2026-10-17):** nothing in G442 has been built. Every task below was rewritten on the board, and W2216 now waits on the Organizations schema (W2390).

| Task | Status | Title (short) | Depends on |
|---|---|---|---|
| W2216 | blocked | Workspace schema with Organization ownership and single-owner personal workspaces | W2390 |
| W2217 | blocked | Hidden personal workspace for every user and existing board; wire creation | W2216 |
| W2218 | blocked | Org-admin board access, paid switcher, workspace settings, moving a board into an org workspace, removing org members | W2217, W2390, W2395, W2398, W2400, W2404 |
| W2219 | blocked | Email invitations: org workspaces, free boards, one Organization per user, member cap | W2218, W2391, W2400 |
| W2220 | blocked | Org-admin-created workspace API tokens, `GET /api/boards` | W2218, W2398 |
| W2221 | blocked | Self-service account deletion with board-ownership and last-org-admin guards | W2218, W2391 |
| W2222 | blocked | Org-admin workspace JSON export plus `mix kanban.import_workspace` | W2218 |
| W2223 | blocked | **[REMOVED — DELETE IN UI]** Stripe billing (still needs deleting on the board) | — |

The program's other goals:

| Goal | What it does | Tasks |
|---|---|---|
| G470 | Organizations, org-admins, the `/org` console, the Organization audit log | W2390–W2397 |
| G471 | `Kanban.Plans` plan check, the `:plans_enforced` flag, the 3-member cap on free boards | W2398–W2403 |
| G472 | Paid feature locks on free boards | W2404–W2411 |
| G473 | Public pages and launch | W2412–W2417 |
| G445 | SSO, SCIM and security policies, scoped to Organizations | W2244–W2247 |

Placeholders that appeared in drafts resolve as: lock component = W2404, plan check = W2398, member cap = W2400, Organizations schema = W2390, org membership rules = W2391, `/org` console = W2395.

---

## 1. One-paragraph summary

Stride gains two tiers.
- **Free users** keep every board in a **hidden personal workspace**: unlimited boards, at most 3 human members each, paid features locked.
- **Paying customers** belong to an **Organization**, created by a Stride admin. The Organization holds **org workspaces**, and its **org-admins** have owner-level control of every board in them.
- Organization members get a **workspace switcher** in the side nav, a **Workspace Settings** page and the org-admins' **`/org` console**.
- Org-admins can **move a board they own** into an org workspace, which lifts the cap and unlocks paid features on it.
- Invitations, workspace-scoped API tokens and full JSON export are org-admin features.
- **Self-service account deletion** is available to everyone.
- Every paid lock stays dormant until the `:plans_enforced` flag is switched on at launch.
- There is still no billing.

---

## 2. Today's UI baseline (what the session is changing)

This section describes the code as of commit `54641071`, before any of the program ships. It is unchanged from the first briefing apart from notes on what each item becomes.

### 2.1 Side nav (`lib/kanban_web/components/side_nav.ex`, 258 lines)

The side nav is 160 px wide on desktop (200 px as a mobile drawer), rendered by `Layouts.app/1` on every authenticated page. Top to bottom:
1. Logo and wordmark.
2. The primary nav (`<nav aria-label="Workspace">`): Boards, My Work, Agents, Review queue, Metrics.
3. A divider, then Resources and About.
4. A spacer.
5. The footer: avatar, name, settings cog, Log out.

There is no workspace or organization selector.

**Becomes:**
- a workspace switcher (W2218) for Organization members;
- a locked switcher slot for free users once plans are enforced;
- an **Organization** link shown only to org-admins (W2395).

### 2.2 The word "Workspace" is already in use

The nav landmark, the `/boards` breadcrumb ("Workspace › Boards") and `/metrics` (`MetricsLive.Workspace`) all use "Workspace" to mean *everything I can see*. **Still open:** see §9.1.

### 2.3 Boards list (`/boards`, `BoardLive.Index`)

Today it is a flat list of every board with a `board_users` row.

**Becomes (W2218):**
- Users with a current org workspace see that workspace's boards, then **Personal boards**, then any other shared boards.
- Users without an Organization see today's flat list unchanged.

### 2.4 Board membership (`/boards/:id/members`, `BoardLive.Membership`, 167 lines)

Today only the board owner manages members, and an unknown email is a dead end.

**Becomes:**
- On free boards, the member cap applies, and the screen shows it (W2400, W2401).
- **Invite by email** is offered when no user is found (W2219):
  - on personal-workspace boards, only to the board owner;
  - on org boards, only to org-admins.

### 2.5 Board API tokens (`/boards/:id/api_tokens`)

These stay unchanged and free. Workspace-scoped tokens are added for org-admins (W2220).

### 2.6 User settings (`/users/settings`, `UserLive.Settings`, 337 lines)

Today it has three sections: Profile, Password and Two-factor. **Becomes:** a fourth section, the Danger zone, for every user (W2221). Free users also see a locked SSO entry there (W2245).

### 2.7 Account deletion today

Today only site admins can delete accounts, through `/admin/users`. **Becomes:** self-service for every user (W2221).

### 2.8 Exports today

Today there is the archived-tasks CSV and metrics PDF and Excel. **Becomes:** org-admins can also run a full restorable JSON export of an org workspace (W2222). Metrics exports stay free.

### 2.9 Public pages that already promise G442 features

`/pricing` (Team at $12, a trial, "Up to 25 users", agents "scoped to a board and a user") and `/privacy` (self-service deletion) are rewritten for the free plan and the sales-led Organization plan in G473: W2412 for `/pricing`, W2413 for `/terms`, W2414 for `/privacy`.

---

## 3. Core concepts introduced

### 3.1 Workspace

The `workspaces` table (W2216) holds name, a unique slug, `personal`, a nullable `organization_id`, a nullable `archived_at` and timestamps. A check constraint makes a workspace personal exactly when it has no Organization.

- **Personal workspace:**
  - one per user, created at registration and by the W2217 backfill;
  - exactly one owner row (the user);
  - **never shown in any UI**;
  - its boards use `board_users` access only and are **free boards**: capped and locked.
- **Org workspace:**
  - belongs to an Organization and has **no owner row**, because the Organization owns it;
  - created, renamed and archived by org-admins in the `/org` console (W2396);
  - archiving only hides it.
- **Every board belongs to exactly one workspace.** `boards.workspace_id` becomes NOT NULL after W2217.
- **No more "Unassigned boards" workspace.** A board with no owner goes to its earliest remaining member's personal workspace. If it has no members, it goes to the earliest enabled site admin's, and the migration fails loudly if neither exists.

### 3.2 Workspace roles

`workspace_members.role` is now `owner | member | guest`, and **the `admin` role is gone**.
- `owner` exists only on personal workspaces.
- `member` and `guest` exist only on org workspaces.
- Partial unique indexes and a trigger enforce this.

Organization-level roles live on `organization_members` (G470: W2390, W2391) as `org_admin | member`, with one Organization per user. Neither of these is the site-admin flag `User.type`.

| Role | Where it lives | What it grants |
|---|---|---|
| site admin | `User.type == :admin` | Creates Organizations and appoints org-admins (`/admin/organizations`, W2393–W2394). It gets no workspace or board access by itself. |
| org-admin | `organization_members.role` | Owner-equivalent access to every board in their Organization's workspaces. Manages workspaces, members, invitations, workspace tokens, exports, SSO, SCIM, policies and the Organization audit log. Cannot appoint org-admins. |
| org member | `organization_members.role` | Belongs to the Organization. Board access comes only from explicit `board_users` rows. |
| workspace owner | `workspace_members.role` | Only the user's own hidden personal workspace. |
| workspace member / guest | `workspace_members.role` | Membership in an org workspace. Board access still comes from explicit `board_users` rows. In G442 the two behave the same (see §9.3). |

### 3.3 Effective board access (`Kanban.Workspaces.Policy`, new in W2218)

Effective access is the **stronger** of the explicit `board_users` access and access derived from the Organization.

| Board location ↓ / user → | org-admin of the board's Organization | other user |
|---|---|---|
| Org workspace | owner-equivalent (derived, never written as a row) | explicit `board_users` access only (none, read_only, modify, owner) |
| Personal workspace | explicit `board_users` access only | explicit `board_users` access only |

- Legacy `board_users` rows are always honoured.
- When someone stops being an org-admin, their derived access, including through workspace tokens, ends on the very next request.
- Lists use one joined query, never one query per board.

### 3.4 Current workspace

- It is stored in the session under `current_workspace_id` and put into `current_scope.workspace` by `UserAuth`, in both the plug and `on_mount`, then checked on every mount.
- Only **org workspaces** can be current. A stale or foreign id falls back to the first reachable org workspace, or to none. Users without an Organization never have a current workspace.
- New boards go into the current org workspace when the caller is an org-admin or a member there. Otherwise they go into the caller's personal workspace. A `workspace_id` in submitted attributes is always ignored.

### 3.5 Paid boards, free boards and the plan check

These live in G471 rather than G442, but every G442 screen depends on them:
- `Kanban.Plans.paid_board?(board)` is true when the board's workspace has an Organization. **Paid status follows the board.**
- `Kanban.Plans.user_has_paid_access?(user)` is true when the user belongs to an Organization. It decides whether user-level UI such as the switcher shows unlocked.
- Every workspace gate calls `Kanban.Plans` (W2398, W2399).
- **The cap (W2400):** a board in a personal workspace accepts a new human member only while it has fewer than 3. Boards already over the cap keep everyone. Agents never count.
- **Locked UI** uses one component, W2404: the feature shows with a lock and an "Available to organizations" prompt, and each click is recorded.
- **Nothing locks until `:plans_enforced` is true** (`STRIDE_PLANS_ENFORCED`). It defaults to false and is switched on at launch.

---

## 4. UI changes by task

### 4.1 W2216: schema and context (no UI)

This task builds the data layer:
- **Migration:** creates `workspaces` and `workspace_members` with the constraints in §3.1–3.2, plus a nullable `boards.workspace_id`.
- **Schemas:** `Workspace` (`belongs_to :organization`) and `WorkspaceMember`.
- **Context, `Kanban.Workspaces`:**
  - `create_personal_workspace/1`, `get_personal_workspace/1`;
  - `create_org_workspace/2`: org-admin only; the organization comes from the caller's membership and never from attributes; it creates no owner row;
  - `get_workspace/2`, scoped to what the caller can reach;
  - `list_workspaces_for_user/1`, which never returns a personal workspace;
  - `get_member_role/2`;
  - `add_member/4`, which refuses non-members of the Organization and the owner role;
  - `update_member_role/4` and `remove_member/3`.
- **Scope** gains `:workspace` and `put_workspace/2`.
- There is no plan, seat or billing column.

### 4.2 W2217: grandfathering (no new UI; the invariant is "nothing changes")

- **Migration 1:**
  - creates a hidden personal workspace with a single owner row for every user;
  - moves each board into its owner's personal workspace, with ownerless boards following the rule in §3.1;
  - writes **no** member or guest rows;
  - is set-based, idempotent and one-way.
- **Migration 2** asserts that every board has a workspace, then sets NOT NULL.
- Registration creates the personal workspace in the same transaction.
- `create_board/2` and `create_ai_optimized_board/2` place new boards in the caller's personal workspace.
- **Visible result:** none. `/boards` and every access value are exactly as before, boards above 3 members keep everyone, and no personal workspace appears anywhere.

### 4.3 W2218: switcher, role-aware access and Workspace Settings (members and boards)

**Workspace switcher (side nav):**
- Organization members see their Organization's reachable, unarchived org workspaces, never a personal one.
- Choosing one POSTs to `/workspace/switch` (`WorkspaceSessionController`).
- Free users see the switcher slot as a W2404 lock while plans are enforced, and no slot while they are not.

**`/boards` grouping:** see §2.3.

**New page: `/workspace/settings`, `KanbanWeb.WorkspaceLive.Settings`** (`live_session :require_authenticated_user`)
- **Members:** org-admins change member and guest roles and remove members. Removal deletes the member's board memberships in that workspace and revokes their board tokens there. Members and guests see a read-only list, or a denied flash if they try a management action.
- **Boards:** the workspace's boards, plus **Move a board here** (decision D8).
  - An org-admin can move a board they own from their personal workspace into this workspace.
  - The board's `board_users` rows are kept, and nobody is added to the Organization.
  - The board becomes paid: the cap is lifted, paid features unlock, and paused webhooks resume.
  - The move is refused for boards the caller doesn't own, boards outside their personal workspace, and workspaces of another Organization.

**The `/org` console** (built by W2395 and W2396 in G470) gains a **remove member from the Organization** action in its Members section, with the same board-membership and token cascade across every workspace of the Organization. Nobody here can grant or remove org-admin; only site admins can.

**Access:** see §3.3. Every management event re-checks the caller server-side, and a stale or foreign workspace id never grants access.

### 4.4 W2219: email invitations

**Data:** `workspace_invitations` holds `workspace_id`, `email`, a nullable role, a nullable board grant (`board_id` and `board_access`), a hashed token, `invited_by_id`, a 7-day expiry, `accepted_at` and `revoked_at`.

**Who can invite:**
- **Workspace invitations** (role member or guest): only org-admins of the workspace's Organization, from Workspace Settings.
- **Board invitations** from the board members form:
  - the board owner on a personal-workspace board;
  - an org-admin on an org board, where it becomes a workspace invitation.

  A board invitation never grants owner.

**Accepting** at `/invitations/:token` (`live_session :current_user`, login optional) happens in one transaction:
- the email must match, ignoring case;
- **one Organization per user:** an invitee from another Organization gets the same generic message as an invalid token, and nothing is written;
- an organization membership with role member is created when the invitee has none, and an existing org-admin role is never changed;
- a workspace member row is added, never downgrading an existing role;
- the optional board grant is applied;
- **the cap** applies to boards still in a personal workspace (W2400). Boards that have since moved into an Organization aren't capped.

**Also:**
- New users register from the link and join after confirming their email.
- Pending invites can be resent and revoked.
- Sends are rate-limited per inviter (`:invite` surface).
- Expired, revoked, used and unknown tokens all show one generic message.

### 4.5 W2220: workspace-scoped API tokens

**Data:** `api_tokens` gains a nullable `workspace_id`, `board_id` becomes nullable, and a check constraint requires exactly one of the two.

**Who:** only org-admins of the Organization can create, list or revoke workspace tokens. There are none for personal workspaces.

**How a request works:**
- The board is chosen with an `X-Stride-Board` header or `board_id` param.
- A missing selector, or a header and param that disagree, gets **400**.
- A board outside the workspace, or one the user can't access, gets the same body as a nonexistent board.
- Derived access ends the moment the user stops being an org-admin, and the token is revoked when the user leaves the Organization.

**Also:**
- `GET /api/boards` lists the boards a token can use.
- Board tokens are unchanged and stay free.
- The endpoint is documented in `priv/openapi/stride-api.json` and `docs/api/get_boards.md`.

### 4.6 W2221: self-service account deletion

**A Danger zone in `/users/settings`** (`:require_sudo_mode`) for **every** user, free or paid, with password re-entry and a confirmation phrase.

**Blockers:**
- being the sole owner of a board other people use;
- being the last org-admin of an Organization with other members. A Stride admin must appoint another org-admin first.

**Board ownership transfer** (`Boards.transfer_board_ownership/3`):
- It is available to the explicit owner, or to an org-admin for their Organization's boards, toward an existing board member. The old owner becomes modify.
- A personal-workspace board moves into the new owner's personal workspace.

**Deletion:**
- removes tokens, sessions, the organization membership, workspace and board memberships, the personal workspace and boards only that user used;
- moves any shared board left in the personal workspace to its earliest remaining member's personal workspace;
- keeps the tasks the user created, with attribution cleared, and revokes invitations they sent;
- records an `:account_self_deleted` audit event with no email.

### 4.7 W2222: full export and self-host import

**Org-admins only:**
- They request, view and download exports of an org workspace. Others, former org-admins and expired exports get 404.
- An Oban job (`:workspace_exports` queue, one per workspace at a time) writes a zip with `manifest.json` (`format_version` 1) plus JSON for boards, columns, tasks, comments, history and memberships.
- An explicit allow-list keeps out secrets **and the Organization's address and contact details**.
- Status shows in the app only; there is no email.
- Files expire after 7 days.

**Import:** `mix kanban.import_workspace --file … --org-admin-email … [--dry-run]` restores into a workspace of that org-admin's Organization. It refuses when the email isn't an org-admin's, and fails atomically on an unknown format version.

### 4.8 W2223: billing (removed)

The task is still out of scope. Payments are handled outside Stride: a Stride admin creates the Organization after a deal is signed. The task still needs deleting on the board, since the API can't delete tasks.

---

## 5. New and changed routes

| Route | Kind | Scope / live_session | Task |
|---|---|---|---|
| `/workspace/settings` | LiveView | `:require_authenticated_user` | W2218 (sections from W2219, W2220, W2222) |
| `POST /workspace/switch` | controller | browser + `:require_authenticated_user` | W2218 |
| `/org` | LiveView | `:require_authenticated_user` + `on_mount :require_org_admin` | W2395 (workspaces W2396; remove-member W2218) |
| `/org/audit` (+ export) | LiveView / controller | org-admin only | W2397 |
| `/admin/organizations` | LiveView | `/admin` live_session (`:require_admin_user`) | W2393, W2394 |
| `/invitations/:token` | LiveView | `:current_user` (login optional) | W2219 |
| `/users/register` | existing LiveView | gains invitation-token handling | W2219 |
| `/users/settings` | existing LiveView | `:require_sudo_mode`, gains Danger zone and an SSO entry | W2221, W2245 |
| `/boards/:id/members` | existing | cap display; invite by email; open to org-admins on org boards | W2218, W2219, W2401 |
| `GET /workspace/exports/:id/download` | controller | browser + `:require_authenticated_user` | W2222 |
| `GET /api/boards` | JSON API | `:api` pipeline | W2220 |

## 6. New tables and columns

| Change | Task |
|---|---|
| `organizations` (name, structured address, contact name, phone, email) | W2390 |
| `organization_members` (unique per user, role org_admin/member) | W2390 |
| `workspaces` (personal, nullable organization_id, archived_at; personal exactly when no organization) | W2216 |
| `workspace_members` (role owner/member/guest; owner only on personal, member/guest only on org workspaces) | W2216 |
| `boards.workspace_id`: nullable in W2216, NOT NULL in W2217 | W2216, W2217 |
| `workspace_invitations` (hashed token, 7-day expiry, optional board grant) | W2219 |
| `api_tokens.workspace_id`, nullable `board_id`, exactly-one check constraint | W2220 |
| `workspace_exports` | W2222 |
| `audit_events.organization_id` | W2397 |
| Organization SSO, domain, SCIM and policy tables | W2244–W2247 |

Migration timestamps in the task specs are placeholders. Real ones come from `mix ecto.gen.migration`.

## 7. New modules

- **G442:**
  - contexts: `Kanban.Workspaces`, `Kanban.Workspaces.Policy`, `Kanban.Workspaces.Invitations`, `Kanban.Workspaces.Export` (with `.Serializer` and `.Worker`), `Kanban.Accounts.AccountDeletion`;
  - schemas: `Workspace`, `WorkspaceMember`, `Invitation`;
  - web: `KanbanWeb.WorkspaceLive.Settings`, `KanbanWeb.WorkspaceLive.InvitationAccept`, `KanbanWeb.WorkspaceSessionController`, `KanbanWeb.WorkspaceExportController`, `KanbanWeb.API.BoardController`;
  - mix task: `Mix.Tasks.Kanban.ImportWorkspace`.
- **Other goals that G442 relies on:** `Kanban.Organizations` (G470), `KanbanWeb.OrgLive.Console` (G470), `Kanban.Plans` (G471), and the lock component (G472).

---

## 8. Cross-cutting requirements

These apply to every task with UI:
- **Translations.** Every new string uses gettext, and `mix gettext.extract --merge` runs with all seven locales (de, en, es, fr, ja, pt, zh) translated and no fuzzy entries.
- **Dark mode.** Pages use theme tokens per `docs/dark-mode-contract.md`, are checked in both themes, and pass `mix dark_mode.scan`.
- **Phoenix conventions.** `<Layouts.app flash={@flash} current_scope={@current_scope}>`, plus `<.button>`, `<.input>` and `<.icon>`. No Ecto queries in LiveViews, and modules stay under about 500 lines.
- **Plans.** Every paid gate calls `Kanban.Plans` and respects `:plans_enforced`. Locks are enforced on the server, not only hidden in the UI.
- **Goal acceptance.** The full test suite, `credo --strict` and sobelow pass.

---

## 9. Gaps, inconsistencies and open questions (ideation fodder)

These are the questions from the first briefing, each marked **Resolved** or **Open**.

### 9.1 Naming and information architecture
1. **"Workspace" is already taken.** **Open.** The nav landmark, the `/boards` breadcrumb and `/metrics` still say "Workspace". `/metrics` stays free and cross-board.
2. **What the current workspace scopes.** **Partly resolved:** `/boards` follows it, and users without an Organization keep the flat list. **Open:** whether My Work, Agents, Review queue, Metrics and targets should follow the switcher.
3. **Where the switcher goes.** **Partly resolved:** it goes in the side nav, with a locked slot for free users. **Open:** its exact visual form and how it behaves in the mobile drawer.
4. **How people reach Workspace Settings.** **Open.** Org-admins reach `/org` through the Organization side-nav link (W2395), but the entry point to `/workspace/settings` isn't specified.
5. **Personal workspace naming.** **Resolved:** personal workspaces are never shown, so their name doesn't matter to users. Whether the slug is needed stays an implementation detail.

### 9.2 Missing UI capabilities
6. **No "create workspace" UI.** **Resolved:** org-admins create, rename and archive workspaces in `/org` (W2396).
7. **No moving a board between workspaces.** **Resolved** for personal workspace to org workspace (W2218). Moving between two org workspaces is **open**.
8. **No workspace picker when creating a board.** **Resolved by rule:** new boards go to the current org workspace when the caller can use it, otherwise the personal one. A visible picker is **open**.
9. **No rename, delete or leave.** **Partly resolved:** rename and archive are in W2396, and org-admins remove members (W2218). Deleting a workspace and a member leaving on their own are **open**.
10. **Export notification.** **Resolved:** in-app status only. The email promise was dropped.
11. **Import is CLI-only.** **Resolved as a non-goal** for now. The rewritten `/pricing` (W2412) must not promise web import.

### 9.3 Role model
12. **Member and guest behave the same.** **Open**, and still true in G442.
13. **Who can invite at which role.** **Resolved:** org-admins invite as member or guest. Nobody can invite or grant org-admin; only site admins appoint org-admins.
14. **Admins can delete any board.** **Open, now about org-admins:** owner-equivalent access includes deleting boards in their Organization.

### 9.4 Spec inconsistencies to fix before work starts
15. **The W2216 `plan` field.** **Resolved:** removed. There is no plan column.
16. **W2223 is still on the board.** **Open:** delete it in the UI.
17. **`/pricing` sells a Team plan.** **Resolved by W2412**, which rewrites it for the Free plan and the sales-led Organization plan.
18. **`/pricing` says tokens are board-scoped.** **Resolved by W2412.**

### 9.5 Edge cases worth a design decision
19. **Removed while a workspace is current in another tab.** **Resolved:** falls back to the first reachable org workspace, or none. The exact message is open.
20. **Invitation for a workspace you already belong to with a higher role.** **Resolved:** an existing role is never downgraded.
21. **An agent mid-claim when its user is removed or deleted.** **Open.** It remains a manual exploration in W2221.
22. **Ownerless boards with no site admin.** **Resolved:** the migration fails loudly.
23. **Invitation rate-limit thresholds.** **Open.**

---

## 10. What does not change

- Board, column and task screens look the same.
- Legacy `board_users` access is honoured unchanged, and boards over the cap at launch keep every member.
- Board API tokens keep working and stay free, and the REST API stays free. Only `/api/mcp` is paid-only (G472).
- Metrics pages and exports stay free.
- Site admin (`User.type == :admin`) and `/admin/*` are unchanged apart from the new `/admin/organizations`.
- There is no billing, seat counting, trial or self-serve upgrade.
- Before launch, with `:plans_enforced` false, free users see no locks and no cap.

## 11. Downstream

- G445 (W2244–W2247) puts SSO, SCIM and security policies on the Organization.
- The org audit log is W2397.
- Suggested build order for the whole program:
  1. G470, starting with W2390;
  2. G442's W2216 and W2217;
  3. G471;
  4. G472;
  5. the rest of G442;
  6. G445;
  7. G473. Its page rewrites can happen any time; the runbook, W2417, comes last.
