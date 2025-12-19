# Create API Token Authentication for AI Agents

**Complexity:** Large | **Est. Files:** 8-10 | **Est. Time:** 5-7 hours

## Description

**WHY:** AI agents need to authenticate to the API to create and manage tasks. Token-based auth is stateless, revocable, and perfect for programmatic access without exposing user credentials.

**WHAT:** Implement Bearer token authentication system for API access, including token generation/management UI in user settings, validation plug, scoped permissions, capability matching, and usage tracking.

**WHERE:** New API authentication system integrated with existing user auth patterns

## Acceptance Criteria

- [ ] `api_tokens` table and schema created
- [ ] Token generation UI in user settings page
- [ ] Bearer token validation plug created and tested
- [ ] Tokens scoped with permissions (tasks:read, tasks:write, etc.)
- [ ] Tokens include agent capabilities array for intelligent task matching
- [ ] Tokens include metadata for agent identity (model, version, purpose)
- [ ] Tokens can be revoked via UI
- [ ] Tokens are hashed in database (never stored in plain text)
- [ ] API returns 401 Unauthorized for invalid/missing tokens
- [ ] Token usage tracking (last_used_at timestamp)
- [ ] Audit log for token creation and usage
- [ ] Token list UI showing active/revoked tokens
- [ ] Rate limiting foundation (per-token request counting)
- [ ] Tests for all authentication scenarios

## Key Files to Read First

- `lib/kanban_web/user_auth.ex` - Current auth system (lines 1-310, understand session token patterns)
- `lib/kanban/accounts.ex` - User context (add token functions here)
- `lib/kanban/accounts/user_token.ex` - Existing token schema (reference for pattern)
- `lib/kanban_web/router.ex` - Add /api pipeline with auth
- `lib/kanban_web/controllers/user_settings_controller.ex` - Add token management UI
- `priv/repo/migrations/` - Check latest migration number
- `docs/WIP/AI-AUTHENTICATION.md` - Token format and auth flow specification

## Technical Notes

**Patterns to Follow:**
- Follow existing `UserToken` pattern from lib/kanban/accounts/user_token.ex
- Token format: `kan_{env}_{random}` (e.g., `kan_dev_vX7kL...`, `kan_prod_mN2pQ...`)
- Store hashed tokens (SHA-256) like passwords - NEVER plain text
- Use custom plug for validation (similar to `UserAuth` patterns)
- Follow telemetry patterns from existing auth (see user_auth.ex:121)
- Use existing `current_scope` pattern for API requests

**Database/Schema:**
- Tables: `api_tokens` (new table)
- Migrations needed: Yes - create api_tokens table with indexes
- Reference: `UserToken` schema in lib/kanban/accounts/user_token.ex

**Schema Fields:**
```elixir
defmodule Kanban.Accounts.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_tokens" do
    field :name, :string                        # User-friendly name
    field :token_hash, :string                  # SHA-256 hash of token
    field :scopes, {:array, :string}            # ["tasks:read", "tasks:write", ...]
    field :capabilities, {:array, :string}      # Agent capabilities
    field :metadata, :map                       # JSONB: {model, version, purpose}
    field :last_used_at, :utc_datetime          # Track usage
    field :revoked_at, :utc_datetime            # Soft delete

    belongs_to :user, Kanban.Accounts.User

    timestamps()
  end
end
```

**Integration Points:**
- [ ] PubSub broadcasts: Not needed (stateless auth)
- [ ] Phoenix Channels: None
- [ ] External APIs: None
- [ ] Telemetry: Track token creation, usage, revocation, auth failures

**Scopes to Implement:**

```elixir
# Scope definitions
@valid_scopes [
  "tasks:read",       # GET /api/tasks, /api/tasks/:id
  "tasks:write",      # POST /api/tasks, PATCH /api/tasks/:id
  "tasks:delete",     # DELETE /api/tasks/:id
  "tasks:claim",      # POST /api/tasks/claim (atomic claiming)
  "boards:read"       # GET /api/boards (for task context)
]
```

**Standard Agent Capabilities:**

The capabilities array enables intelligent task-agent matching. When an agent claims a task, the system verifies the agent has ALL required capabilities for that task.

```elixir
@standard_capabilities [
  # Core Development
  "code_generation",              # Can write code (most programming tasks)
  "code_review",                  # Can review code quality and suggest improvements
  "testing",                      # Can write automated tests
  "debugging",                    # Can diagnose and fix bugs
  "refactoring",                  # Can improve code structure

  # Specialized Skills
  "database_design",              # Can design schemas and write migrations
  "api_design",                   # Can design REST/GraphQL APIs
  "ui_implementation",            # Can implement user interfaces
  "documentation",                # Can write docs, comments, READMEs

  # Advanced
  "performance_optimization",     # Can optimize slow code
  "security_analysis",            # Can identify security vulnerabilities
  "devops",                       # Can write CI/CD, Docker, deployment configs
  "algorithm_design"              # Can design algorithms and data structures
]
```

**Capability Matching Logic:**

```elixir
# Task definition (in task schema)
field :required_capabilities, {:array, :string}

# Example task requiring specific skills
%Task{
  title: "Add database migration for AI fields",
  required_capabilities: ["database_design", "code_generation"]
}

# API token for specialized agent
%ApiToken{
  name: "Backend Agent",
  capabilities: ["code_generation", "database_design", "testing", "code_review"]
}

# Matching logic in Tasks.get_next_available_task/2
def get_next_available_task(agent_capabilities, board_id) do
  from(t in Task,
    where: t.status == "ready",
    where: t.board_id == ^board_id,
    where: is_nil(t.claimed_by),
    # Task with empty required_capabilities matches any agent
    # Otherwise, agent must have ALL required capabilities
    where: fragment(
      "? <@ ?",
      t.required_capabilities,
      ^agent_capabilities
    )
  )
  |> order_by([t], [asc: t.priority, desc: t.inserted_at])
  |> limit(1)
  |> Repo.one()
end
```

**Token Metadata Structure:**

```elixir
%{
  model: "claude-3.5-sonnet",        # AI model name
  version: "20241022",                # Model version
  purpose: "Backend development",     # Human description
  created_by: "John Doe",             # Who created this token
  environment: "production"           # dev/staging/production
}
```

## Verification

**Commands to Run:**
```bash
# Generate migration
mix ecto.gen.migration create_api_tokens
# Edit migration file, then run
mix ecto.migrate

# Run tests
mix test test/kanban/accounts_test.exs
mix test test/kanban/accounts/api_token_test.exs
mix test test/kanban_web/plugs/api_auth_test.exs
mix test test/kanban_web/controllers/api/auth_test.exs

# Test in browser
mix phx.server
# Navigate to http://localhost:4000/users/settings
# Click "API Tokens" tab
# Create new token with name "Test Agent"
# Copy token (shown once in green alert)

# Test API with curl
export TOKEN="kan_dev_abc123..."

# Test valid token
curl -H "Authorization: Bearer $TOKEN" \
     http://localhost:4000/api/tasks

# Test missing token (should 401)
curl http://localhost:4000/api/tasks

# Test invalid token (should 401)
curl -H "Authorization: Bearer invalid" \
     http://localhost:4000/api/tasks

# Test revoked token
# Revoke in UI, then:
curl -H "Authorization: Bearer $TOKEN" \
     http://localhost:4000/api/tasks
# Should return 401

# Run all precommit checks
mix precommit
```

**Manual Testing:**
1. Navigate to `/users/settings` and find "API Tokens" section
2. Click "Generate New Token"
3. Enter name: "Development Agent"
4. Select scopes: tasks:read, tasks:write
5. Select capabilities: code_generation, testing
6. Add metadata: model="claude-3.5-sonnet"
7. Click "Generate Token"
8. Copy token (shown once with warning it won't be shown again)
9. Use token in curl to test API endpoint
10. Verify token appears in "Active Tokens" list
11. Test API endpoint with valid token (should work)
12. Test API endpoint without token (should 401)
13. Test API endpoint with invalid token (should 401)
14. Click "Revoke" on token
15. Test API with revoked token (should 401)
16. Verify token moved to "Revoked Tokens" section
17. Check last_used_at timestamp updates after API calls

**Success Looks Like:**
- Can create tokens via UI with name, scopes, capabilities
- Token displayed once with security warning
- Tokens work for API authentication
- Invalid/missing tokens return 401 with JSON error
- Revoked tokens immediately stop working
- Token list shows active and revoked tokens separately
- last_used_at updates after each API call
- Scopes enforced (can't access endpoints without scope)
- Audit trail exists for security review

## Data Examples

**Migration:**

```elixir
defmodule Kanban.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :scopes, {:array, :string}, default: [], null: false
      add :capabilities, {:array, :string}, default: [], null: false
      add :metadata, :map, default: %{}, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    # Hash must be unique (one token can't be used twice)
    create unique_index(:api_tokens, [:token_hash])

    # Fast lookup by user
    create index(:api_tokens, [:user_id])

    # Fast filtering of active tokens
    create index(:api_tokens, [:user_id, :revoked_at])

    # Fast lookup during auth (most common query)
    create index(:api_tokens, [:token_hash, :revoked_at])
  end
end
```

**Schema:**

```elixir
defmodule Kanban.Accounts.ApiToken do
  @moduledoc """
  API token for programmatic access to the Kanban API.

  Tokens are scoped with permissions and capabilities for intelligent
  task-agent matching. Tokens are hashed before storage and never
  stored in plain text.

  ## Scopes

  - tasks:read - Can read tasks
  - tasks:write - Can create and update tasks
  - tasks:delete - Can delete tasks
  - tasks:claim - Can atomically claim tasks
  - boards:read - Can read board structure

  ## Capabilities

  Agent capabilities for intelligent task matching. Tasks can specify
  required_capabilities, and only agents with ALL those capabilities
  can claim the task.

  Standard capabilities: code_generation, testing, debugging, etc.
  See @standard_capabilities in Kanban.Tasks for full list.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(
    tasks:read
    tasks:write
    tasks:delete
    tasks:claim
    boards:read
  )

  @standard_capabilities ~w(
    code_generation
    code_review
    testing
    debugging
    refactoring
    database_design
    api_design
    ui_implementation
    documentation
    performance_optimization
    security_analysis
    devops
    algorithm_design
  )

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string
    field :scopes, {:array, :string}, default: []
    field :capabilities, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Kanban.Accounts.User

    timestamps()
  end

  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name, :token_hash, :scopes, :capabilities, :metadata, :user_id])
    |> validate_required([:name, :token_hash, :user_id])
    |> validate_length(:name, min: 3, max: 100)
    |> validate_scopes()
    |> validate_capabilities()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
  end

  defp validate_scopes(changeset) do
    case get_change(changeset, :scopes) do
      nil ->
        changeset
      scopes ->
        invalid = Enum.reject(scopes, &(&1 in @valid_scopes))
        if Enum.empty?(invalid) do
          changeset
        else
          add_error(changeset, :scopes, "contains invalid scopes: #{Enum.join(invalid, ", ")}")
        end
    end
  end

  defp validate_capabilities(changeset) do
    case get_change(changeset, :capabilities) do
      nil ->
        changeset
      capabilities ->
        # Allow custom capabilities, but warn if not standard
        non_standard = Enum.reject(capabilities, &(&1 in @standard_capabilities))
        if length(non_standard) > length(capabilities) / 2 do
          # More than half are non-standard - likely a mistake
          add_error(changeset, :capabilities,
            "mostly non-standard capabilities: #{Enum.join(non_standard, ", ")}")
        else
          changeset
        end
    end
  end

  def valid_scopes, do: @valid_scopes
  def standard_capabilities, do: @standard_capabilities
end
```

**Token Generation (in Accounts context):**

```elixir
defmodule Kanban.Accounts do
  @moduledoc """
  The Accounts context.
  """

  alias Kanban.Accounts.ApiToken
  alias Kanban.Repo

  @doc """
  Creates an API token for a user.

  Generates a random token, hashes it, and stores only the hash.
  Returns the plain text token ONCE - it cannot be retrieved later.

  ## Examples

      iex> create_api_token(user, %{
      ...>   name: "Backend Agent",
      ...>   scopes: ["tasks:read", "tasks:write"],
      ...>   capabilities: ["code_generation", "testing"],
      ...>   metadata: %{model: "claude-3.5-sonnet"}
      ...> })
      {:ok, %ApiToken{}, "kan_dev_vX7kL2m..."}

  """
  def create_api_token(user, attrs) do
    # Generate cryptographically secure random token
    # Format: kan_{env}_{32_bytes_base64}
    env = Atom.to_string(Mix.env())
    random_part = :crypto.strong_rand_bytes(32)
                  |> Base.url_encode64(padding: false)

    token = "kan_#{env}_#{random_part}"

    # Hash for storage (SHA-256)
    token_hash = :crypto.hash(:sha256, token)
                 |> Base.encode16(case: :lower)

    # Create token record
    attrs = Map.put(attrs, :token_hash, token_hash)

    %ApiToken{}
    |> ApiToken.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:user, user)
    |> Repo.insert()
    |> case do
      {:ok, api_token} ->
        # Emit telemetry
        :telemetry.execute(
          [:kanban, :api, :token_created],
          %{count: 1},
          %{user_id: user.id, token_id: api_token.id}
        )

        # Return plain token ONCE
        {:ok, api_token, token}

      error ->
        error
    end
  end

  @doc """
  Verifies an API token and returns the associated token record.

  Returns {:ok, token} if valid and not revoked.
  Returns {:error, :invalid} if token not found or revoked.

  Updates last_used_at timestamp on successful verification.
  """
  def verify_api_token(token_string) when is_binary(token_string) do
    # Hash the provided token
    token_hash = :crypto.hash(:sha256, token_string)
                 |> Base.encode16(case: :lower)

    # Look up by hash
    query = from t in ApiToken,
            where: t.token_hash == ^token_hash,
            where: is_nil(t.revoked_at),
            preload: [:user]

    case Repo.one(query) do
      nil ->
        # Emit telemetry for failed auth
        :telemetry.execute(
          [:kanban, :api, :auth_failed],
          %{count: 1},
          %{reason: :invalid_token}
        )
        {:error, :invalid}

      token ->
        # Update last_used_at
        token
        |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
        |> Repo.update()

        # Emit telemetry for successful auth
        :telemetry.execute(
          [:kanban, :api, :token_used],
          %{count: 1},
          %{user_id: token.user_id, token_id: token.id}
        )

        {:ok, token}
    end
  end

  def verify_api_token(_), do: {:error, :invalid}

  @doc """
  Lists all API tokens for a user.

  Returns active and revoked tokens separately.
  """
  def list_api_tokens(user) do
    from(t in ApiToken,
      where: t.user_id == ^user.id,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists only active (non-revoked) API tokens for a user.
  """
  def list_active_api_tokens(user) do
    from(t in ApiToken,
      where: t.user_id == ^user.id,
      where: is_nil(t.revoked_at),
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Revokes an API token.

  Soft-deletes by setting revoked_at timestamp.
  Token becomes immediately invalid for authentication.
  """
  def revoke_api_token(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update()
    |> case do
      {:ok, token} ->
        :telemetry.execute(
          [:kanban, :api, :token_revoked],
          %{count: 1},
          %{user_id: token.user_id, token_id: token.id}
        )
        {:ok, token}

      error ->
        error
    end
  end

  @doc """
  Checks if a token has a specific scope.
  """
  def has_scope?(%ApiToken{scopes: scopes}, required_scope) do
    required_scope in scopes
  end

  @doc """
  Checks if a token has all required capabilities.
  """
  def has_capabilities?(%ApiToken{capabilities: caps}, required_capabilities)
      when is_list(required_capabilities) do
    Enum.all?(required_capabilities, &(&1 in caps))
  end

  def has_capabilities?(_, _), do: false
end
```

**API Auth Plug:**

```elixir
defmodule KanbanWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug for authenticating API requests via Bearer token.

  Extracts token from Authorization header, validates it,
  and assigns current_user and api_token to conn.

  Halts with 401 if token is missing, invalid, or revoked.

  ## Usage

      # In router.ex
      pipeline :api do
        plug :accepts, ["json"]
        plug KanbanWeb.Plugs.ApiAuth
      end

  ## Response on failure

      {
        "error": "Unauthorized",
        "message": "Invalid or missing API token"
      }

  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, api_token} <- Accounts.verify_api_token(token) do
      # Success - assign user and token info
      conn
      |> assign(:current_user, api_token.user)
      |> assign(:current_scope, Scope.for_user(api_token.user))
      |> assign(:api_token, api_token)
      |> assign(:auth_method, :api_token)
    else
      [] ->
        # Missing Authorization header
        unauthorized(conn, "Missing API token")

      ["Bearer"] ->
        # Empty token
        unauthorized(conn, "Missing API token")

      [_other] ->
        # Wrong auth scheme (not Bearer)
        unauthorized(conn, "Invalid authorization header format. Expected: Bearer <token>")

      {:error, :invalid} ->
        # Invalid or revoked token
        unauthorized(conn, "Invalid or revoked API token")
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      error: "Unauthorized",
      message: message
    })
    |> halt()
  end
end
```

**Scope Enforcement Plug:**

```elixir
defmodule KanbanWeb.Plugs.RequireApiScope do
  @moduledoc """
  Plug for enforcing API token scopes.

  ## Usage

      # Require specific scope for endpoint
      plug KanbanWeb.Plugs.RequireApiScope, "tasks:write"

      # Require one of multiple scopes
      plug KanbanWeb.Plugs.RequireApiScope, ["tasks:write", "tasks:delete"]

  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.Accounts

  def init(required_scope), do: required_scope

  def call(conn, required_scope) when is_binary(required_scope) do
    call(conn, [required_scope])
  end

  def call(conn, required_scopes) when is_list(required_scopes) do
    api_token = conn.assigns[:api_token]

    if api_token && has_any_scope?(api_token, required_scopes) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "Forbidden",
        message: "Insufficient permissions. Required scopes: #{Enum.join(required_scopes, " or ")}",
        required_scopes: required_scopes,
        token_scopes: (api_token && api_token.scopes) || []
      })
      |> halt()
    end
  end

  defp has_any_scope?(token, required_scopes) do
    Enum.any?(required_scopes, &Accounts.has_scope?(token, &1))
  end
end
```

**Router API Pipeline:**

```elixir
# In lib/kanban_web/router.ex

pipeline :api do
  plug :accepts, ["json"]
  plug KanbanWeb.Plugs.ApiAuth
end

scope "/api", KanbanWeb.API, as: :api do
  pipe_through :api

  # Tasks endpoints
  get "/tasks", TaskController, :index
  get "/tasks/:id", TaskController, :show
  post "/tasks", TaskController, :create
  patch "/tasks/:id", TaskController, :update
  delete "/tasks/:id", TaskController, :delete

  # Task claiming (requires separate scope)
  get "/tasks/next", TaskController, :next
  post "/tasks/claim", TaskController, :claim
  post "/tasks/:id/unclaim", TaskController, :unclaim
  post "/tasks/:id/complete", TaskController, :complete

  # Board structure (read-only)
  get "/boards", BoardController, :index
  get "/boards/:id", BoardController, :show
  get "/boards/:id/tree", BoardController, :tree

  # Agent info
  get "/agent/info", AgentController, :info
end
```

**Token Management UI (User Settings):**

```heex
<%# In lib/kanban_web/controllers/user_settings_html/edit.html.heex %>

<div class="space-y-8">
  <%# ... existing settings sections ... %>

  <section class="bg-white shadow rounded-lg p-6">
    <h2 class="text-lg font-semibold text-gray-900 mb-4">API Tokens</h2>
    <p class="text-sm text-gray-600 mb-6">
      Generate tokens for programmatic access to the Kanban API.
      Use these tokens with AI agents or automation scripts.
    </p>

    <.simple_form
      for={@token_form}
      action={~p"/users/settings/api-tokens"}
      method="post"
      class="space-y-4 mb-6"
    >
      <.input
        field={@token_form[:name]}
        type="text"
        label="Token Name"
        placeholder="e.g., Backend Agent"
        required
      />

      <div>
        <label class="block text-sm font-medium text-gray-700 mb-2">
          Scopes (Permissions)
        </label>
        <div class="space-y-2">
          <%= for scope <- ApiToken.valid_scopes() do %>
            <label class="flex items-center">
              <input
                type="checkbox"
                name="api_token[scopes][]"
                value={scope}
                class="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              />
              <span class="ml-2 text-sm text-gray-700"><%= scope %></span>
            </label>
          <% end %>
        </div>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-700 mb-2">
          Capabilities (for task matching)
        </label>
        <div class="grid grid-cols-2 gap-2">
          <%= for capability <- ApiToken.standard_capabilities() do %>
            <label class="flex items-center">
              <input
                type="checkbox"
                name="api_token[capabilities][]"
                value={capability}
                class="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              />
              <span class="ml-2 text-sm text-gray-700">
                <%= capability |> String.replace("_", " ") |> String.capitalize() %>
              </span>
            </label>
          <% end %>
        </div>
      </div>

      <.input
        field={@token_form[:metadata][:model]}
        type="text"
        label="AI Model (optional)"
        placeholder="e.g., claude-3.5-sonnet"
      />

      <.button type="submit" class="w-full">
        Generate API Token
      </.button>
    </.simple_form>

    <%# Show newly created token ONCE %>
    <%= if @new_token do %>
      <div class="bg-green-50 border border-green-200 rounded-md p-4 mb-6">
        <p class="text-sm font-medium text-green-800 mb-2">
          Token created successfully! Copy it now - it won't be shown again.
        </p>
        <div class="flex items-center gap-2">
          <code class="flex-1 px-3 py-2 bg-white border border-green-300 rounded font-mono text-sm">
            <%= @new_token %>
          </code>
          <button
            onclick="navigator.clipboard.writeText('<%= @new_token %>')"
            class="px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700"
          >
            Copy
          </button>
        </div>
      </div>
    <% end %>

    <%# Active tokens list %>
    <div>
      <h3 class="text-md font-medium text-gray-900 mb-3">Active Tokens</h3>
      <%= if Enum.empty?(@active_tokens) do %>
        <p class="text-sm text-gray-500">No active tokens</p>
      <% else %>
        <div class="space-y-2">
          <%= for token <- @active_tokens do %>
            <div class="flex items-center justify-between p-3 border border-gray-200 rounded">
              <div class="flex-1">
                <p class="font-medium text-gray-900"><%= token.name %></p>
                <p class="text-xs text-gray-500">
                  Created <%= Calendar.strftime(token.inserted_at, "%b %d, %Y") %>
                  <%= if token.last_used_at do %>
                    • Last used <%= Timex.from_now(token.last_used_at) %>
                  <% else %>
                    • Never used
                  <% end %>
                </p>
                <div class="flex gap-1 mt-1">
                  <%= for scope <- token.scopes do %>
                    <span class="px-2 py-0.5 bg-blue-100 text-blue-700 text-xs rounded">
                      <%= scope %>
                    </span>
                  <% end %>
                </div>
              </div>
              <.link
                href={~p"/users/settings/api-tokens/#{token.id}/revoke"}
                method="delete"
                data-confirm="Are you sure? This will immediately invalidate the token."
                class="px-3 py-1 text-sm text-red-600 hover:text-red-800"
              >
                Revoke
              </.link>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
  </section>
</div>
```

## Testing

### Test Files to Create

**1. API Token Schema Tests (test/kanban/accounts/api_token_test.exs):**

```elixir
defmodule Kanban.Accounts.ApiTokenTest do
  use Kanban.DataCase
  alias Kanban.Accounts.ApiToken

  describe "changeset/2" do
    test "valid with all required fields" do
      user = insert(:user)

      attrs = %{
        name: "Test Token",
        token_hash: "abc123",
        scopes: ["tasks:read"],
        user_id: user.id
      }

      changeset = ApiToken.changeset(%ApiToken{}, attrs)
      assert changeset.valid?
    end

    test "validates scopes are from valid list" do
      attrs = %{
        name: "Test",
        token_hash: "abc",
        scopes: ["invalid:scope"]
      }

      changeset = ApiToken.changeset(%ApiToken{}, attrs)
      refute changeset.valid?
      assert "contains invalid scopes" in errors_on(changeset).scopes
    end

    test "allows standard capabilities" do
      attrs = %{
        name: "Test",
        token_hash: "abc",
        capabilities: ["code_generation", "testing"]
      }

      changeset = ApiToken.changeset(%ApiToken{}, attrs)
      assert changeset.valid?
    end
  end
end
```

**2. Accounts Context Tests (test/kanban/accounts_test.exs):**

```elixir
describe "api_tokens" do
  test "create_api_token/2 generates unique token" do
    user = insert(:user)

    {:ok, token1, plain1} = Accounts.create_api_token(user, %{
      name: "Token 1",
      scopes: ["tasks:read"]
    })

    {:ok, token2, plain2} = Accounts.create_api_token(user, %{
      name: "Token 2",
      scopes: ["tasks:write"]
    })

    assert plain1 != plain2
    assert token1.token_hash != token2.token_hash
    assert String.starts_with?(plain1, "kan_test_")
  end

  test "verify_api_token/1 validates token" do
    user = insert(:user)
    {:ok, _token, plain} = Accounts.create_api_token(user, %{
      name: "Test",
      scopes: ["tasks:read"]
    })

    assert {:ok, verified} = Accounts.verify_api_token(plain)
    assert verified.user_id == user.id
  end

  test "verify_api_token/1 rejects revoked token" do
    user = insert(:user)
    {:ok, token, plain} = Accounts.create_api_token(user, %{
      name: "Test",
      scopes: ["tasks:read"]
    })

    {:ok, _} = Accounts.revoke_api_token(token)

    assert {:error, :invalid} = Accounts.verify_api_token(plain)
  end

  test "verify_api_token/1 updates last_used_at" do
    user = insert(:user)
    {:ok, token, plain} = Accounts.create_api_token(user, %{
      name: "Test",
      scopes: ["tasks:read"]
    })

    assert is_nil(token.last_used_at)

    {:ok, verified} = Accounts.verify_api_token(plain)
    assert verified.last_used_at != nil
  end
end
```

**3. API Auth Plug Tests (test/kanban_web/plugs/api_auth_test.exs):**

```elixir
defmodule KanbanWeb.Plugs.ApiAuthTest do
  use KanbanWeb.ConnCase
  alias KanbanWeb.Plugs.ApiAuth

  test "assigns current_user with valid token", %{conn: conn} do
    user = insert(:user)
    {:ok, _token, plain} = create_api_token(user, %{
      name: "Test",
      scopes: ["tasks:read"]
    })

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plain}")
      |> ApiAuth.call([])

    refute conn.halted
    assert conn.assigns.current_user.id == user.id
    assert conn.assigns.auth_method == :api_token
  end

  test "halts with 401 when token missing", %{conn: conn} do
    conn = ApiAuth.call(conn, [])

    assert conn.halted
    assert conn.status == 401
    assert json_response(conn, 401)["error"] == "Unauthorized"
  end

  test "halts with 401 for invalid token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer invalid_token")
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 for revoked token", %{conn: conn} do
    user = insert(:user)
    {:ok, token, plain} = create_api_token(user, %{
      name: "Test",
      scopes: ["tasks:read"]
    })

    revoke_api_token(token)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plain}")
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :api, :token_created]` - metrics: count, metadata: user_id, token_id
- [ ] Telemetry event: `[:kanban, :api, :token_used]` - metrics: count, metadata: user_id, token_id
- [ ] Telemetry event: `[:kanban, :api, :token_revoked]` - metrics: count, metadata: user_id, token_id
- [ ] Telemetry event: `[:kanban, :api, :auth_failed]` - metrics: count, metadata: reason
- [ ] Metrics: Counter of API requests per token (for rate limiting foundation)
- [ ] Logging: Log token creation at info level
- [ ] Logging: Log authentication failures at warning level
- [ ] Logging: Log token revocation at info level

## Error Handling

- User sees: Clear error message in UI if token creation fails
- On API failure: Returns 401 Unauthorized with JSON error message
- On scope failure: Returns 403 Forbidden with required vs actual scopes
- Validation: Token name 3-100 chars, scopes must be valid, capabilities validated
- Security: Never log plain text tokens, only log token IDs
- Database: Foreign key constraint prevents orphaned tokens

## Common Pitfalls

- [ ] **CRITICAL**: Don't store plain text tokens - always hash with SHA-256
- [ ] Remember to show token only once on creation (can't be retrieved later)
- [ ] **SECURITY**: Never log tokens in telemetry or error messages
- [ ] Don't forget to update last_used_at on each API request
- [ ] Remember to check token is not revoked in verify function
- [ ] Validate scopes before allowing operations (use RequireApiScope plug)
- [ ] Don't return token in API responses (security risk)
- [ ] Remember to preload :user when fetching tokens for auth
- [ ] Use unique index on token_hash to prevent duplicates
- [ ] Add index on (user_id, revoked_at) for fast active token queries
- [ ] Don't forget to emit telemetry events for monitoring
- [ ] Test both valid and invalid token scenarios
- [ ] Handle missing Authorization header gracefully
- [ ] Validate token format (should start with "kan_{env}_")

## Security Considerations

**Token Format:**
- Prefix with `kan_{env}_` for easy identification and environment separation
- Use 32 bytes of cryptographically secure random data
- Base64 URL-safe encoding (no padding) for clean tokens
- Total length ~50-60 characters

**Storage:**
- Store only SHA-256 hash, never plain text
- Unique constraint on hash prevents duplicates
- Soft delete with revoked_at (audit trail)

**Validation:**
- Hash incoming token and compare with database
- Check revoked_at is null
- Update last_used_at atomically
- Verify scopes before allowing operations

**Rate Limiting Foundation:**
- Track request count per token in last_used_at updates
- Future: Add request_count field for detailed tracking
- Future: Add rate_limit field for per-token limits

**Audit Trail:**
- Keep revoked tokens in database (don't hard delete)
- Track creation, usage, and revocation via telemetry
- Log authentication failures for security monitoring

## Dependencies

**Requires:**
- 01-extend-task-schema.md (for task metadata)
- 02-add-task-metadata-fields.md (for created_by tracking)

**Blocks:**
- 07-implement-task-crud-api.md (API needs auth)
- 08-add-task-ready-endpoint.md (claiming needs capabilities)

## Out of Scope

- Don't implement OAuth2/OAuth (too complex for AI agent use case)
- Don't add token expiry initially (can add expiry_at field later)
- Don't implement fine-grained per-resource permissions (scopes sufficient)
- Don't add multi-factor auth for API tokens (tokens are already secret)
- Don't implement token refresh mechanism (just generate new token)
- Don't add IP allowlisting (complicates agent deployment)
- Future: Add detailed rate limiting with quotas and sliding windows
- Future: Add token usage analytics dashboard
- Future: Add token rotation/renewal notifications
- Future: Add webhook notifications for suspicious token usage

## Migration Rollback Strategy

If issues arise during deployment:

1. **Before migration:** Backup database
2. **After migration:** Test token creation in staging
3. **Rollback plan:**
   ```bash
   # Rollback migration
   mix ecto.rollback

   # Redeploy previous version
   git revert <commit>
   ```
4. **Data safety:** Revoked tokens preserved (soft delete)
5. **No breaking changes:** API endpoints added, no existing changes
