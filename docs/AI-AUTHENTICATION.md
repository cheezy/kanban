# AI Authentication

How would AI authenticate to the API?

## Recommended: API Token (Bearer Token)

Why This Works Best for AI

Simple, stateless, and secure - perfect for programmatic access.

```text
Authorization: Bearer kan_live_abc123def456...
```

### ✅ Pros from AI Perspective

1. Easy to use: Just one header on every request
2. No session management: Stateless, no cookies to manage
3. Scoped permissions: Token can limit what AI can do
4. Revocable: User can revoke without changing password
5. Multiple tokens: Different tokens for different AI agents/projects
6. Works everywhere: CLI, MCP servers, any HTTP client

### Implementation Approach

```text
# User generates token in UI
POST /settings/api-tokens
{
  "name": "Claude Code - Kanban Project",
  "scopes": ["tasks:read", "tasks:write"]
}

Response:
{
  "token": "kan_live_abc123...",  # Show once, user copies it
  "name": "Claude Code - Kanban Project",
  "scopes": ["tasks:read", "tasks:write"],
  "created_at": "2025-12-13T..."
}

# AI uses token
GET /api/tasks/ready
Authorization: Bearer kan_live_abc123...
```

### Token Format I'd Prefer

```text
kan_{env}_{random}

kan_live_abc123...     # Production
kan_test_xyz789...     # Testing
```

- Prefix `(kan_)` makes it recognizable if leaked
- Environment helps prevent using test tokens in prod
- Random is the actual credential

### Scopes for AI Workflow

```text
tasks:read       # Read tasks
tasks:write      # Create/update tasks
tasks:delete     # Delete tasks (maybe restrict?)
boards:read      # Read board structure
```

## Alternative Options (Less Ideal for AI)

### ❌ OAuth2

- Too complex for AI agents
- Requires browser flow
- Overkill for single-user scenarios

### ⚠️ Username/Password

- Security risk: AI might log credentials
- Can't scope permissions
- Can't revoke without changing password

### ⚠️ JWT with Expiry

- Annoying for AI: Have to refresh tokens
- Adds complexity
- Better for human sessions

### ✅ mTLS (Mutual TLS)

- Very secure
- But overkill and complex for this use case

## My Ideal Flow as an AI

1. User creates token in Kanban UI

    - Names it "Claude - Dec 2025"
    - Selects scopes
    - Copies token

2. User configures me (via env var or config)

    ```text
    export KANBAN_API_TOKEN="kan_live_abc123..."
    export KANBAN_API_URL="http://localhost:4000"
    ```

3. I make requests

    ```elixir
    Req.get!(
    "#{System.get_env("KANBAN_API_URL")}/api/tasks/ready",
    auth: {:bearer, System.get_env("KANBAN_API_TOKEN")}
    )
    ```

4. User can revoke anytime without disrupting their login

## Security Considerations

- Store tokens hashed in DB (like passwords)
- Rate limit by token
- Log API usage per token
- Allow token expiry (optional)
- Validate token on every request (plug)

**Bottom line: Simple Bearer token is the sweet spot** - secure enough, simple enough, and exactly what AI tools expect. Does this match your thinking on auth?
