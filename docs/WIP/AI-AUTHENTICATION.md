# AI Authentication

## API Token (Bearer Token)

Simple, stateless, and secure - perfect for programmatic access.

```text
Authorization: Bearer stride_live_abc123def456...
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
  "name": "Claude Code - Stride Project",
  "scopes": ["tasks:read", "tasks:write"]
}

Response:
{
  "token": "stride_live_abc123...",  # Show once, user copies it
  "name": "Claude Code - Stride Project",
  "scopes": ["tasks:read", "tasks:write"],
  "created_at": "2025-12-13T..."
}

# AI uses token
GET /api/tasks/ready
Authorization: Bearer stride_live_abc123...
```

### Token Format I'd Prefer

```text
stride_{env}_{random}

stride_live_abc123...     # Production
stride_test_xyz789...     # Testing
```

- Prefix `(stride_)` makes it recognizable if leaked
- Environment helps prevent using test tokens in prod
- Random is the actual credential

### Scopes for AI Workflow

```text
tasks:read       # Read tasks
tasks:write      # Create/update tasks
tasks:delete     # Delete tasks (maybe restrict?)
boards:read      # Read board structure
```

## My Ideal Flow as an AI

1. User creates token in Stride UI

    - Names it "Claude - Dec 2025"
    - Selects scopes
    - Copies token

2. User configures me via `.stride_auth.md` file (NOT version-controlled)

    **Create `.stride_auth.md` in project root:**
    ```markdown
    # Stride API Authentication

    **DO NOT commit this file to version control!**

    ## API Configuration

    - **API URL:** `http://localhost:4000`
    - **API Token:** `stride_live_abc123...`

    ## Environment Variables

    ```bash
    export STRIDE_API_TOKEN="stride_live_abc123..."
    export STRIDE_API_URL="http://localhost:4000"
    ```
    ```

    **Add to `.gitignore`:**
    ```
    .stride_auth.md
    ```

3. I read `.stride_auth.md` and make requests

    ```elixir
    # Agent reads auth from .stride_auth.md
    Req.get!(
      "http://localhost:4000/api/tasks/ready",
      auth: {:bearer, "stride_live_abc123..."}
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
