# AI Authentication

## API Token (Bearer Token)

Simple, stateless, and secure - perfect for programmatic access.

```text
Authorization: Bearer stride_dev_abc123def456...
```

### ✅ Pros from AI Perspective

1. Easy to use: Just one header on every request
2. No session management: Stateless, no cookies to manage
3. Board-scoped access: Each token is tied to a specific board
4. Revocable: User can revoke without changing password
5. Multiple tokens: Different tokens for different AI agents/projects
6. Works everywhere: CLI, MCP servers, any HTTP client
7. Agent tracking: Optional metadata for AI model, version, and purpose

### Final Implementation

#### Token Generation

Tokens are generated per-board from the board's API Tokens page:

```text
Path: /boards/{board_id}/api_tokens

Form Fields:
- name: "Claude Code - Stride Project" (required)
- agent_model: "claude-sonnet-4-5" (optional)
- agent_purpose: "Task automation" (optional)
- agent_version: "1.0" (optional)
- agent_capabilities: [] (optional, for future use)

Response (shown once):
{
  "token": "stride_dev_abc123...",  # Show once, user must copy it
  "name": "Claude Code - Stride Project",
  "board_id": 14,
  "created_at": "2025-12-24T..."
}
```

**Note:** Scopes were removed from the final implementation in favor of board-level access. Each token grants full access to its associated board only.

#### Token Format

```text
stride_{env}_{random_base64url}

stride_dev_abc123...      # Development
stride_test_xyz789...     # Testing
stride_prod_abc123...     # Production (when deployed)
```

- Prefix `stride_` makes it recognizable if leaked
- Environment (`dev`, `test`, `prod`) helps prevent using wrong tokens
- Random portion is 256-bit cryptographically secure value
- Tokens are hashed with SHA-256 before storage (never stored in plaintext)

#### Database Schema

```elixir
schema "api_tokens" do
  field :name, :string
  field :token_hash, :string  # SHA-256 hash, not the token itself
  field :agent_model, :string
  field :agent_version, :string
  field :agent_purpose, :string
  field :agent_capabilities, {:array, :string}
  field :last_used_at, :utc_datetime
  field :revoked_at, :utc_datetime

  belongs_to :user, User
  belongs_to :board, Board

  timestamps()
end
```

#### Security Features

1. **Hashed storage**: Tokens are SHA-256 hashed before database storage
2. **One-time display**: Token is only shown once after creation
3. **Revocable**: Tokens can be revoked without affecting user login
4. **Board-scoped**: Each token only accesses its specific board
5. **Usage tracking**: `last_used_at` timestamp updated on each use
6. **Revocation checking**: Revoked tokens are rejected immediately

## Actual Flow for AI Agents

1. **User creates token in Kanban UI**

    - Navigate to `/boards/{board_id}/api_tokens`
    - Fill in token name (required): "Claude - Dec 2025"
    - Optionally add agent model: "claude-sonnet-4-5"
    - Optionally add purpose: "Task automation"
    - Click "Generate Token"
    - Copy the token immediately (it's only shown once!)

2. **User configures AI via `.stride_auth.md` file** (NOT version-controlled)

    **Create `.stride_auth.md` in project root:**
    ```markdown
    # Stride API Authentication

    **DO NOT commit this file to version control!**

    ## API Configuration

    - **API URL:** `http://localhost:4000`
    - **API Token:** `stride_dev_abc123...`
    - **Board ID:** `14`

    ## Environment Variables

    ```bash
    export STRIDE_API_TOKEN="stride_dev_abc123..."
    export STRIDE_API_URL="http://localhost:4000"
    export STRIDE_BOARD_ID="14"
    ```
    ```

    **Add to `.gitignore`:**
    ```
    .stride_auth.md
    ```

3. **AI reads `.stride_auth.md` and makes requests**

    ```elixir
    # Agent reads auth from .stride_auth.md
    Req.get!(
      "http://localhost:4000/api/v1/boards/14/tasks",
      auth: {:bearer, "stride_dev_abc123..."}
    )
    ```

4. **User can revoke anytime** without disrupting their login session
    - Navigate back to `/boards/{board_id}/api_tokens`
    - Click "Revoke" next to the token
    - Token immediately stops working

## Token Management UI

### Token Creation Success Display

After creating a token, users see:

```text
✓ Token created successfully! Copy it now - you won't see it again.

┌─────────────────────────────────────────────────────────────────────┐
│ stride_dev_abc123def456ghi789jkl012mno345pqr678stu901vwx234yz567ABC │
│ [Copy]                                                        [×]   │
└─────────────────────────────────────────────────────────────────────┘
```

**Key UX Features:**
- Token displays immediately after creation
- Clear warning that it won't be shown again
- Copy button for easy copying
- Dismiss button (×) to manually hide the alert
- Token persists until user dismisses it (fixed issue where it disappeared too quickly)

### Active Tokens List

Shows all tokens for the board with:
- Token name
- Agent model (if provided)
- Purpose (if provided)
- Created date
- Last used date
- Revoke button

## Implementation Files

### Core Files

1. **Migration**: `priv/repo/migrations/*_create_api_tokens.exs`
   - Creates `api_tokens` table with all fields

2. **Schema**: `lib/kanban/api_tokens/api_token.ex`
   - Defines `ApiToken` schema
   - Handles token generation and hashing
   - Validates token format

3. **Context**: `lib/kanban/api_tokens.ex`
   - `create_api_token/3` - Creates token and returns plaintext
   - `get_api_token_by_token/1` - Authenticates token
   - `revoke_api_token/1` - Revokes token
   - `list_api_tokens/1` - Lists board tokens

4. **LiveView**: `lib/kanban_web/live/board_live/show.ex`
   - `handle_params` for `:api_tokens` action (line 97-112)
   - `handle_event("create_token", ...)` (line 295-315)
   - `handle_event("revoke_token", ...)` (line 324-342)
   - `handle_event("dismiss_token", ...)` (line 318-320)
   - `assign_api_tokens_state/3` helper (line 475-497)

5. **Template**: `lib/kanban_web/live/board_live/show.html.heex`
   - Token creation form (line 416-444)
   - Token success display (line 383-414)
   - Active tokens list (line 446-518)

### Security Implementation

All security features are implemented:

✅ **Hashed storage**: Tokens hashed with SHA-256 before DB insert
✅ **One-time display**: Token only returned from `create_api_token/3` once
✅ **Revocable**: `revoke_api_token/1` sets `revoked_at` timestamp
✅ **Board-scoped**: Foreign key constraint ensures board access only
✅ **Usage tracking**: `last_used_at` updated via `update_last_used/1`
✅ **Revocation checking**: `get_api_token_by_token/1` returns `{:error, :revoked}` for revoked tokens

### Bug Fixes Applied

**Token Persistence Issue** (Fixed 2025-12-24):
- **Problem**: Flash message triggered `handle_params` re-render, clearing `:new_token`
- **Solution**: Removed `put_flash(:info, ...)` from token creation handler
- **File**: `lib/kanban_web/live/board_live/show.ex:311`
- **Result**: Token now persists until manually dismissed

## Future Enhancements

- [ ] Token expiration dates (optional)
- [ ] Rate limiting per token
- [ ] Detailed usage logs per token
- [ ] Token rotation mechanism
- [ ] Webhook notifications for token usage

**Bottom line: Simple Bearer token with board-level access** - secure, simple, and exactly what AI tools expect.
