# Authentication Guide for Agents

This guide explains how to authenticate with the Stride API using API tokens.

## Quick Start

1. **Human creates your API token** on the board's **Tokens** tab (`/boards/{board_id}/api_tokens`)
2. **Human provides you with a `.stride_auth.md` file** containing your credentials
3. **You read `.stride_auth.md`** to get your token and configuration
4. **You include the token** in every API request as a Bearer token
5. **With a workspace token**, which an org-admin creates for many boards of an Organization at once, you also name the board on every request. See [Board Tokens and Workspace Tokens](#board-tokens-and-workspace-tokens).

## User Accounts: Email Confirmation Gate

Before any API token can exist, the human needs a confirmed Stride account.
Registration is gated on email confirmation:

1. **Register** at `/users/register`. The account is created and a confirmation
   email is sent, but **no session is established** — registration does not log
   the user in.
2. **Confirmation-pending page**. The browser lands on
   `/users/confirmation-pending`, which shows the destination email address and
   offers a throttled resend button. Until the emailed link is clicked, the
   account cannot sign in, and any existing session for an unconfirmed account
   is redirected away from authenticated pages.
3. **Click the emailed link** (`/users/confirm/{token}`). The account is
   confirmed and the page becomes a getting-started guide: a copy-paste prompt
   that points an agent at `/api/agent/onboarding` to scaffold `.stride_auth.md`
   and `.stride.md`, followed by steps for signing in, creating a first board,
   generating an API token (the **Tokens** tab on an AI-optimized board), and
   inviting team members.
4. **Sign in** at `/users/log-in`. Only confirmed accounts can authenticate;
   an unconfirmed login attempt (with the correct password) is redirected to
   `/users/confirmation-pending` with an explanatory message, and no session or
   remember-me cookie is issued. Wrong-password and unknown-email attempts stay
   on the login page with the generic "Invalid email or password" error.

Invalid or already-used confirmation links redirect to the login page with an
explanatory message. Accounts created before the confirmation gate shipped were
grandfathered in as confirmed.

### Recovering a Lost Confirmation Email

A user who never received (or deleted) the confirmation email has three ways
back to a working resend button — no support intervention needed:

1. **Try to sign in.** A login attempt with the correct password on an
   unconfirmed account redirects straight to
   `/users/confirmation-pending?email={email}`, which shows the resend button.
   This is the natural path for a returning user who forgot the account was
   never confirmed.
2. **Use the login-page link.** The login page has a **Resend confirmation
   email** link below the sign-in button that navigates to
   `/users/confirmation-pending` without requiring a failed sign-in.
3. **Enter the email directly.** Visiting `/users/confirmation-pending` without
   an `email` query parameter shows an email-entry form. Submitting an address
   sends a fresh confirmation link when the account exists and is unconfirmed.

All three paths converge on the same resend mechanism: the response is neutral
("If your email is in our system and the account isn't confirmed yet…") whether
or not the address is registered or already confirmed, so the endpoint cannot
be used to enumerate accounts, and resends are throttled to one per minute.

## User Accounts: Two-Factor Authentication

A person can add an authenticator-app code to their password under
**Settings → Two-factor**. Once it is on, signing in asks for a code from the
app (or a recovery code) after the password, at `/users/two-factor`, before
any session is created. It protects the human's account only: API tokens,
and so agents, are not affected. See
[Two-Factor Authentication](TWO-FACTOR-AUTHENTICATION.md) for how it works.
An Organization's org-admins can require it for every member, after a grace
period; see [Organization Security Policies](organization-security-policies.md).

## User Accounts: Single Sign-On

An Organization can connect its own OpenID Connect or SAML 2.0 identity
provider. People
with an email on a domain the Organization verified sign in with **Sign in
with SSO** on the login page; their first sign-in creates a confirmed account
without a password and makes them a member of the Organization. Like
two-factor, it covers the browser only: API tokens, and so agents, are not
affected. See [Single Sign-On](single-sign-on.md).

## Authentication Method: Bearer Token

All API requests require authentication using a Bearer token in the Authorization header:

```http
Authorization: Bearer stride_dev_abc123def456...
```

### Why Bearer Tokens?

- **Simple**: Just one header on every request
- **Stateless**: No session management or cookies
- **Scoped**: A board token grants access to one specific board only; a
  workspace token grants access to the boards of one Organization workspace
  (see [Workspace tokens](#workspace-tokens))
- **Revocable**: Human can revoke your token without affecting their login
- **Trackable**: Your usage is tracked via `last_used_at` timestamps

## The `.stride_auth.md` File

**CRITICAL**: Before making any API calls, look for a `.stride_auth.md` file in your project root. This file contains your authentication credentials.

### Expected Format

This is the template the [onboarding endpoint](api/get_agent_onboarding.md) serves, with `{{YOUR_TOKEN_HERE}}` and `{{YOUR_EMAIL}}` replaced by the human's token and email:

````markdown
# Stride API Authentication

**DO NOT commit this file to version control!**

## API Configuration

- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `{{YOUR_TOKEN_HERE}}`
- **User Email:** `{{YOUR_EMAIL}}`
- **Token Name:** Development Agent

## Usage

**Unix/Linux/macOS:**

```bash
export STRIDE_API_TOKEN="{{YOUR_TOKEN_HERE}}"
export STRIDE_API_URL="https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  $STRIDE_API_URL/api/tasks/next
```

**Windows PowerShell:**

```powershell
$env:STRIDE_API_TOKEN = "{{YOUR_TOKEN_HERE}}"
$env:STRIDE_API_URL = "https://www.stridelikeaboss.com"

curl.exe -H "Authorization: Bearer $env:STRIDE_API_TOKEN" `
  "$env:STRIDE_API_URL/api/tasks/next"
```

Type `curl.exe`, not `curl`: in Windows PowerShell 5.1, `curl` is an alias for `Invoke-WebRequest`, which takes different arguments and fails on this command.

**Windows Users:** For complete setup instructions including WSL2, PowerShell, and Git Bash options, see https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/WINDOWS-SETUP.md
````

The file has no board field. An agent holding a workspace token names its board on each request instead; see [Naming the Board on Each Request](#naming-the-board-on-each-request). Windows setup is in [WINDOWS-SETUP.md](WINDOWS-SETUP.md).

### What To Do

1. **Read the file** to extract:
   - `STRIDE_API_TOKEN` - Your Bearer token for authentication
   - `STRIDE_API_URL` - The base URL for API requests (e.g., `https://www.stridelikeaboss.com`)

2. **Use these values** in all API requests

3. **Never commit this file** - It should already be in `.gitignore`, but verify

**Note**: Agent capabilities are set on the token when the human creates it in the Stride UI, not in this file. See [Capability Scopes](#capability-scopes).

### If `.stride_auth.md` Doesn't Exist

If you don't find this file, **stop and ask the human** to:
1. Create an API token on the board's **Tokens** tab (`/boards/{board_id}/api_tokens`), or a workspace token under **Workspace settings → Tokens**
2. Create the `.stride_auth.md` file with the token
3. Add `.stride_auth.md` to `.gitignore`

**Do not proceed without valid credentials.**

## Token Format

Tokens follow this format:

```text
stride_{env}_{random}

Example:
stride_dev_xxxxxxxxxxxx...
```

- `stride_` marks it as a Stride token, so a leaked token is easy to recognise.
- `{env}` is `test` for tokens the test suite creates and `dev` everywhere else, including the hosted service at `https://www.stridelikeaboss.com`. It does not tell you which server a token belongs to.
- `{random}` is 32 random bytes in standard Base64 without padding (43 characters), so it can contain `+` and `/`. Quote the token in shell commands and never split it.

Treat the token as an opaque string.

Every token, board or workspace, **expires 90 days after it is created**. An expired token gets `401`, like a revoked one; the human must create a new one. Tokens created before expiry was introduced do not expire.

## Board Tokens and Workspace Tokens

There are two kinds of token. Both are sent the same way, as `Authorization: Bearer <token>`.

### Which Token to Use

| | Board token | Workspace token |
|---|---|---|
| Reaches | One AI Optimized board | Every AI Optimized board in one Organization workspace that its creator can modify |
| Who creates it | Anyone with owner or modify access to the board | An org-admin of the Organization |
| Where | The board's **Tokens** tab | **Workspace settings → Tokens** |
| Names the board on each request | No | Yes, with `X-Stride-Board` or `board_id` |
| Agent model and purpose fields | Yes | No |

Use a **board token** when an agent works on one board; it is the simplest setup and needs nothing beyond `.stride_auth.md`. Use a **workspace token** when an agent fleet works across many boards of one Organization, so you manage one token instead of one per board. Personal workspaces and archived workspaces cannot have workspace tokens.

Either kind acts as the human who created it, and only while that human can still use the board; see [Token Scope](#token-scope).

### Creating a Board Token

1. Open the AI Optimized board and click its **Tokens** tab (`/boards/{board_id}/api_tokens`). The tab is shown only on AI Optimized boards, and only to people with owner or modify access.
2. Under **Create new token**, fill in **Token name**, optionally **Agent model (optional)** and **Purpose (optional)**, and **Agent capabilities** (see [Capability Scopes](#capability-scopes)).
3. Click **Generate token** and copy the token shown under **Token created**. It is shown once.

The token is listed under **Active tokens** with a **Revoke** button; once revoked, the button becomes **Delete**.

### Creating a Workspace Token

1. Open the workspace switcher in the side navigation, which members of an Organization see, pick the workspace, and click **Workspace settings** (`/workspace/settings`).
2. Open the **Tokens** section (`/workspace/settings?section=tokens`). Only people who manage the workspace see it.
3. In **Create a workspace token**, fill in **Token name** and, optionally, **Agent capabilities (comma-separated, optional)**.
4. Click **Create token** and copy the token shown under **Your new workspace token**. It is shown once.

The token is listed under **Workspace tokens** with its status (**Active**, **Revoked** or **Expired**) and a **Revoke** button.

### Naming the Board on Each Request

A workspace token does not know which board you mean, so every request names it by id, in the `X-Stride-Board` header or the `board_id` parameter. `GET /api/boards` lists the board ids the token can use, and needs no board named. `.stride_auth.md` has no board field, so send the header on every call:

```bash
curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \
     -H "X-Stride-Board: 42" \
     https://www.stridelikeaboss.com/api/tasks/next
```

MCP clients send the header too; see the [MCP endpoint's authentication](MCP.md#authentication). The error rules (`400` for no board or two different boards, `404` for a board the token cannot use) are in [Workspace tokens](#workspace-tokens). A board token needs no selector.

## Capability Scopes

Capabilities limit which tasks a token can claim. They are entered as a comma-separated list when the token is created, and the valid names are:

`api_design`, `code_generation`, `code_review`, `database_design`, `debugging`, `devops`, `documentation`, `file_operations`, `git`, `performance_optimization`, `refactoring`, `security_analysis`, `testing`, `ui_design`, `ui_implementation`, `web_browsing`

- A token with **no capabilities** can claim any task.
- A token **with capabilities** can claim a task only when it has **all** of the task's `required_capabilities`.
- A task with **no required capabilities** can be claimed by any token.
- Stride does **not** check the names when the token is created. A misspelled name is saved and matches no task, so an agent holding it sees fewer tasks than expected.
- Capabilities cannot be changed on an existing token. To change them, create a new token and revoke the old one.

Capabilities decide which tasks are offered, not which endpoints a token may call. What each capability means is in [AGENT-CAPABILITIES.md](AGENT-CAPABILITIES.md).

## Making Authenticated Requests

### Example: Claim a Task

```bash
curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer stride_dev_xxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"before_doing_result": {"exit_code": 0, "output": "", "duration_ms": 0}}'
```

The `before_doing_result` is required; see [POST /api/tasks/claim](api/post_tasks_claim.md).

### Example: Get Onboarding Info

```bash
curl https://www.stridelikeaboss.com/api/agent/onboarding
```

The onboarding endpoint is public, so it needs no token.

### Example: Complete a Task

```bash
curl -X PATCH https://www.stridelikeaboss.com/api/tasks/42/complete \
  -H "Authorization: Bearer stride_dev_xxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d @completion.json
```

The completion body also needs the hook results and a summary of the work; every required field is in [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md).

## Security Considerations

### Token Security

1. **Never log tokens** - Don't include tokens in console output or logs
2. **Never commit tokens** - Tokens belong in `.stride_auth.md`, which must be gitignored
3. **Token is secret** - Treat it like a password; anyone with the token has full board access
4. **Use HTTPS in production** - Tokens in production should only be sent over HTTPS

### Token Scope

A board token grants access to (a workspace token reaches several boards; see [Workspace tokens](#workspace-tokens)):
- ✓ **One specific board** - The board it was created for
- ✓ **All tasks on that board** - Reading, claiming, completing, unclaiming
- ✓ **All API endpoints** - Task operations, hook configuration, onboarding info
- ✗ **Other boards** - Your token cannot access other boards
- ✗ **User authentication** - Your token doesn't grant UI access

A token acts as the human who created it, and only while that human can still
use the board. Every request checks their access to the board again:

- **Reads** (every `GET` endpoint that takes a token: `GET /api/tasks`,
  `GET /api/tasks/:id`, `GET /api/tasks/next`, the dependency, tree,
  after_goal status and comment endpoints and `GET /api/boards`, plus the MCP
  read tools `stride_next_task`, `stride_get_task` and `stride_list_tasks`) need any access to the board,
  read-only included. Without it they get `403` with the body
  `{"error": "Not authorized — board membership required", ...}` (`error_code`
  `not_authorized` over MCP).
- **Writes** (create, update, claim, complete and the rest) need owner or
  modify access and keep their own `403` bodies, documented on each endpoint.

The human loses access when they are removed from the board, or, when their
access came from being an org-admin of the Organization that owns the board,
when they stop being an org-admin or leave the Organization. A token whose
human was disabled gets `401` instead.

### Workspace tokens

An org-admin of an Organization can create a **workspace token** in the Tokens
section of the workspace settings page (`/workspace/settings?section=tokens`);
the steps are in [Creating a Workspace Token](#creating-a-workspace-token).
One workspace token reaches every board of that workspace that is AI Optimized
and that the org-admin can modify, so an agent fleet working across many boards
needs one token instead of one per board. The token acts as the org-admin who
created it.

With a workspace token, every request except `GET /api/boards` and the
[MCP endpoint's](MCP.md#authentication) discovery calls (`initialize`, `ping`,
`tools/list`) names the board it acts on, by id, in the `X-Stride-Board` header
or the `board_id` parameter:

```bash
curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \
     -H "X-Stride-Board: 42" \
     https://www.stridelikeaboss.com/api/tasks/next
```

- A request that names no board, names two different ones (in the header, the
  query string or the body), or repeats the header or the query-string
  `board_id`, gets `400`.
- A board outside the workspace, or one the token's user can no longer modify,
  gets `404` with the same body as a board that does not exist.
- [GET /api/boards](api/get_boards.md) lists the board ids the token can use.
- The token is revoked when its user stops being an org-admin of the
  Organization, when they are removed from the workspace, or when the
  workspace is archived. Like every token, it expires after 90 days.

A board token needs no selector. If a request sends one anyway, it must name
the token's own board: a header or `board_id` naming another board gets `400`
(`Board selector does not match token`), and so does an ambiguous selector, so
an agent configured for one board while holding another board's token notices
instead of writing to the token's board. `GET /api/boards` ignores the
selector for both kinds of token.

### Token Revocation

The human who created your token can revoke it at any time:

1. Open the board's **Tokens** tab (`/boards/{board_id}/api_tokens`), or, for a workspace token, **Workspace settings → Tokens**
2. Click **Revoke** next to your token
3. Your token immediately stops working

A token also stops working when it expires, 90 days after it was created, with the same `401`.

**What happens when revoked:**
- All your API requests return `401 Unauthorized`
- You cannot complete in-progress work
- The human must create a new token for you to continue

**If you get 401 errors**, ask the human if they revoked your token.

## Token Metadata

When your token was created, the human may have provided metadata about you:

```json
{
  "name": "Claude Sonnet 4.5 Agent",
  "agent_model": "claude-sonnet-4-5",
  "agent_purpose": "Task automation"
}
```

This metadata:
- Helps humans track which agent is which
- Appears in the token management UI
- Does not affect your capabilities or access
- Is purely for human reference

## Troubleshooting

### 401 Unauthorized

**Possible causes:**
1. Token is invalid or malformed
2. Token has been revoked
3. Token has expired (90 days after creation)
4. You're using the wrong token for this server
5. Authorization header is missing or incorrect

**Solutions:**
- Verify token matches what's in `.stride_auth.md`
- Check Authorization header format: `Bearer {token}`
- Ask human if token was revoked
- Ask human to create a new token

### 403 Forbidden

**Possible causes:**
- You're trying to access a board your token doesn't have access to
- The human who created your token no longer has access to its board
  (`"Not authorized — board membership required"`), or no longer has write
  access to it (`"Not authorized — board write access (owner or modify) required"`).
  Every write checks this before it looks up the task, so the same `403`
  comes back whether the task exists and whatever state it is in.
  See [Token Scope](#token-scope).

**Solutions:**
- With a board token, check you are calling the board the token was created for
- With a workspace token, check the `X-Stride-Board` header names a board that `GET /api/boards` lists
- Ask the human whether they still have access to the board; if not, someone
  with access must create a new token

### 404 Not Found

**Possible causes:**
1. API endpoint doesn't exist
2. Wrong base URL (check `STRIDE_API_URL`)
3. Task/resource ID doesn't exist on your board (a numeric ID outside the signed 64-bit range also gets a 404)

**Solutions:**
- Verify base URL is correct
- Check API documentation for correct endpoints
- Verify resource IDs exist on your board

## Best Practices

1. **Read `.stride_auth.md` first** - Before making any API calls
2. **Validate credentials** - Test with an authenticated endpoint first, such as `GET /api/tasks/next` (or `GET /api/boards` for a workspace token); a `401` means the token is invalid, revoked or expired. The onboarding endpoint is public, so it cannot validate a token
3. **Use environment values** - Don't hardcode URLs or tokens
4. **Handle 401 gracefully** - If token is revoked, notify human and stop work
5. **Never expose tokens** - Don't include in error messages, logs, or output

## Example: Reading and Using Credentials

```python
# Python example
import os
import re

def read_stride_auth():
    """Read authentication from .stride_auth.md file."""
    try:
        with open('.stride_auth.md', 'r') as f:
            content = f.read()

        # Extract values from markdown
        token_match = re.search(r'STRIDE_API_TOKEN="([^"]+)"', content)
        url_match = re.search(r'STRIDE_API_URL="([^"]+)"', content)

        return {
            'token': token_match.group(1) if token_match else None,
            'url': url_match.group(1) if url_match else None
        }
    except FileNotFoundError:
        print("ERROR: .stride_auth.md not found!")
        print("Please ask human to create API token and .stride_auth.md file")
        return None

# Use credentials
auth = read_stride_auth()
if auth and auth['token']:
    headers = {
        'Authorization': f"Bearer {auth['token']}",
        'Content-Type': 'application/json'
    }
    # Make API request...
```

## See Also

- [AI-WORKFLOW.md](AI-WORKFLOW.md) - Complete workflow guide
- [POST /api/tasks/claim](api/post_tasks_claim.md) - Claiming tasks
- [GET /api/agent/onboarding](api/get_agent_onboarding.md) - Getting started
