# Create API Token Authentication for AI Agents

**Complexity:** Large | **Est. Files:** 6-8

## Description

**WHY:** AI agents need to authenticate to the API to create and manage tasks. Token-based auth is stateless and perfect for programmatic access.

**WHAT:** Implement Bearer token authentication system for API access, including token generation UI, validation plug, and scoped permissions.

**WHERE:** New API authentication system

## Acceptance Criteria

- [ ] API tokens table and schema created
- [ ] Token generation UI in user settings
- [ ] Bearer token validation plug created
- [ ] Tokens scoped with permissions (tasks:read, tasks:write)
- [ ] Tokens can be revoked
- [ ] Tokens are hashed in database
- [ ] API returns 401 for invalid/missing tokens
- [ ] Rate limiting per token
- [ ] Audit log for API usage

## Key Files to Read First

- `lib/kanban_web/user_auth.ex` - Current auth system (understand patterns)
- `lib/kanban/accounts.ex` - User context (add token functions here)
- `lib/kanban_web/router.ex` - Add /api pipeline
- `lib/kanban_web/controllers/user_settings_controller.ex` - Add token UI
- `docs/WIP/AI-AUTHENTICATION.md` - Token format and flow (full doc)

## Technical Notes

**Patterns to Follow:**
- Token format: `kan_{env}_{random}` (e.g., `kan_live_abc123...`)
- Store hashed tokens (like passwords)
- Use Guardian or custom plug for validation
- Follow existing auth patterns from user_auth.ex

**Database/Schema:**
- Tables: api_tokens (new table)
- Migrations needed: Yes - create api_tokens table
- Fields:
  - user_id (references users)
  - name (string) - User-friendly name
  - token_hash (string) - Hashed token
  - scopes (array of string) - ["tasks:read", "tasks:write", ...]
  - last_used_at (utc_datetime)
  - revoked_at (utc_datetime, nullable)
  - inserted_at, updated_at

**Integration Points:**
- [ ] PubSub broadcasts: Not needed
- [ ] Phoenix Channels: None
- [ ] External APIs: None

**Scopes to Implement:**
```
tasks:read       # Read tasks
tasks:write      # Create/update tasks
tasks:delete     # Delete tasks
boards:read      # Read board structure
```

## Verification

**Commands to Run:**
```bash
# Generate migration
mix ecto.gen.migration create_api_tokens
mix ecto.migrate

# Run tests
mix test test/kanban/accounts_test.exs
mix test test/kanban_web/plugs/api_auth_test.exs

# Test in browser
mix phx.server
# Navigate to /users/settings
# Create API token
# Copy token

# Test API with curl
export TOKEN="kan_live_abc123..."
curl -H "Authorization: Bearer $TOKEN" http://localhost:4000/api/tasks

# Run precommit
mix precommit
```

**Manual Testing:**
1. Create API token in user settings
2. Copy token (shown once)
3. Test API endpoint with valid token
4. Test API endpoint without token (should 401)
5. Test API endpoint with invalid token (should 401)
6. Revoke token
7. Test API with revoked token (should 401)
8. Verify token list shows created tokens

**Success Looks Like:**
- Can create tokens in UI
- Tokens work for API authentication
- Invalid tokens return 401
- Revoked tokens stop working
- Token usage tracked (last_used_at)
- Scopes enforced correctly

## Data Examples

**Token Generation:**
```elixir
defmodule Kanban.Accounts do
  def create_api_token(user, attrs) do
    # Generate random token
    token = "kan_#{Mix.env()}_" <> :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    # Hash for storage
    token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    %ApiToken{}
    |> ApiToken.changeset(Map.put(attrs, :token_hash, token_hash))
    |> Ecto.Changeset.put_assoc(:user, user)
    |> Repo.insert()
    |> case do
      {:ok, api_token} -> {:ok, api_token, token}  # Return plain token once
      error -> error
    end
  end
end
```

**API Auth Plug:**
```elixir
defmodule KanbanWeb.Plugs.ApiAuth do
  import Plug.Conn
  alias Kanban.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, api_token} <- Accounts.verify_api_token(token),
         {:ok, user} <- Accounts.get_user_by_api_token(api_token) do
      conn
      |> assign(:current_user, user)
      |> assign(:api_token, api_token)
      |> assign(:auth_method, :api_token)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Invalid or missing API token"})
        |> halt()
    end
  end
end
```

**Router API Pipeline:**
```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug KanbanWeb.Plugs.ApiAuth
end

scope "/api", KanbanWeb.API do
  pipe_through :api

  resources "/tasks", TaskController, only: [:index, :show, :create, :update]
  get "/tasks/ready", TaskController, :ready
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :api, :token_created]`
- [ ] Telemetry event: `[:kanban, :api, :token_used]`
- [ ] Telemetry event: `[:kanban, :api, :token_revoked]`
- [ ] Telemetry event: `[:kanban, :api, :auth_failed]`
- [ ] Metrics: Counter of API requests per token
- [ ] Logging: Log API authentication attempts (success/failure)

## Error Handling

- User sees: Clear error message if token creation fails
- On failure: API returns 401 with JSON error message
- Validation: Token must be at least 32 chars, scopes must be valid

## Common Pitfalls

- [ ] Don't store plain text tokens - hash them like passwords
- [ ] Remember to show token only once on creation
- [ ] Avoid logging tokens (security risk)
- [ ] Don't forget to update last_used_at on each API request
- [ ] Remember to validate scopes before allowing operations
- [ ] Avoid returning token in API responses
- [ ] Don't forget rate limiting (prevent abuse)

## Dependencies

**Requires:** 02-add-task-metadata-fields.md (to track created_by)
**Blocks:** 04-implement-task-crud-api.md

## Out of Scope

- Don't implement OAuth2 (too complex for this use case)
- Don't add token expiry initially (can add later)
- Don't implement fine-grained permissions beyond scopes
- Don't add multi-factor auth for API tokens
- Future: Add rate limiting with detailed quotas
