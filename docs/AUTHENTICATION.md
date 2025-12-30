# Authentication Guide for Agents

This guide explains how to authenticate with the Stride API using API tokens.

## Quick Start

1. **Human creates your API token** in the Stride UI at `/boards/{board_id}/api_tokens`
2. **Human provides you with a `.stride_auth.md` file** containing your credentials
3. **You read `.stride_auth.md`** to get your token and configuration
4. **You include the token** in every API request as a Bearer token

## Authentication Method: Bearer Token

All API requests require authentication using a Bearer token in the Authorization header:

```http
Authorization: Bearer stride_dev_abc123def456...
```

### Why Bearer Tokens?

- **Simple**: Just one header on every request
- **Stateless**: No session management or cookies
- **Board-scoped**: Each token grants access to one specific board only
- **Revocable**: Human can revoke your token without affecting their login
- **Trackable**: Your usage is tracked via `last_used_at` timestamps

## The `.stride_auth.md` File

**CRITICAL**: Before making any API calls, look for a `.stride_auth.md` file in your project root. This file contains your authentication credentials.

### Expected Format

```markdown
# Stride API Authentication

**DO NOT commit this file to version control!**

## API Configuration

- **API URL:** `http://www.stridelikeaboss.com`
- **API Token:** `stride_dev_abc123...
- **User Email:** `user@example.com`
- **Token Name:** Development Agent
- **Capabilities:** code_generation, testing

## Environment Variables

```bash
export STRIDE_API_TOKEN="stride_dev_abc123..."
export STRIDE_API_URL="https://www.stridelikeaboss.com"

curl -H "Authorization: Bearer $STRIDE_API_TOKEN" \\
  $STRIDE_API_URL/api/tasks/next
```

### What To Do

1. **Read the file** to extract:
   - `STRIDE_API_TOKEN` - Your Bearer token for authentication
   - `STRIDE_API_URL` - The base URL for API requests (e.g., `https://www.stridelikeaboss.com`)

2. **Use these values** in all API requests

3. **Never commit this file** - It should already be in `.gitignore`, but verify

### If `.stride_auth.md` Doesn't Exist

If you don't find this file, **stop and ask the human** to:
1. Create an API token at `/boards/{board_id}/api_tokens`
2. Create the `.stride_auth.md` file with the token
3. Add `.stride_auth.md` to `.gitignore`

**Do not proceed without valid credentials.**

## Token Format

Tokens follow this format:

```text
stride_{env}_{random_base64url}

Examples:
stride_dev_abc123...      # Development environment
stride_test_xyz789...     # Testing environment
stride_prod_abc123...     # Production environment
```

The prefix and environment help you identify:
- That it's a Stride token (if you see it leaked somewhere)
- Which environment it's for (dev/test/prod)

## Making Authenticated Requests

### Example: Claim a Task

```bash
curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json"
```

### Example: Get Onboarding Info

```bash
curl https://www.stridelikeaboss.com/api/agent/onboarding \
  -H "Authorization: Bearer stride_dev_abc123..."
```

### Example: Complete a Task

```bash
curl -X PATCH https://www.stridelikeaboss.com/api/tasks/42/complete \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "actual_complexity": "medium",
    "actual_files_changed": 3,
    "time_spent_minutes": 45
  }'
```

## Security Considerations

### Token Security

1. **Never log tokens** - Don't include tokens in console output or logs
2. **Never commit tokens** - Tokens belong in `.stride_auth.md`, which must be gitignored
3. **Token is secret** - Treat it like a password; anyone with the token has full board access
4. **Use HTTPS in production** - Tokens in production should only be sent over HTTPS

### Token Scope

Your token grants access to:
- ✓ **One specific board** - The board it was created for
- ✓ **All tasks on that board** - Reading, claiming, completing, unclaiming
- ✓ **All API endpoints** - Task operations, hook configuration, onboarding info
- ✗ **Other boards** - Your token cannot access other boards
- ✗ **User authentication** - Your token doesn't grant UI access

### Token Revocation

The human who created your token can revoke it at any time:

1. Navigate to `/boards/{board_id}/api_tokens`
2. Click "Revoke" next to your token
3. Your token immediately stops working

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
  "agent_version": "20251229",
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
3. You're using the wrong token for this environment
4. Authorization header is missing or incorrect

**Solutions:**
- Verify token matches what's in `.stride_auth.md`
- Check Authorization header format: `Bearer {token}`
- Ask human if token was revoked
- Ask human to create a new token

### 403 Forbidden

**Possible cause:**
- You're trying to access a board your token doesn't have access to

**Solution:**
- Verify `STRIDE_BOARD_ID` matches the board in your API calls
- Each token is scoped to one board only

### 404 Not Found

**Possible causes:**
1. API endpoint doesn't exist
2. Wrong base URL (check `STRIDE_API_URL`)
3. Task/resource ID doesn't exist

**Solutions:**
- Verify base URL is correct
- Check API documentation for correct endpoints
- Verify resource IDs exist on your board

## Best Practices

1. **Read `.stride_auth.md` first** - Before making any API calls
2. **Validate credentials** - Test with `/api/agent/onboarding` endpoint first
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
        board_match = re.search(r'STRIDE_BOARD_ID="([^"]+)"', content)

        return {
            'token': token_match.group(1) if token_match else None,
            'url': url_match.group(1) if url_match else None,
            'board_id': board_match.group(1) if board_match else None
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
