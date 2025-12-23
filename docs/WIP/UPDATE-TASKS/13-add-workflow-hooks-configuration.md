# Add Workflow Hooks Configuration to Boards and Columns

**Complexity:** Medium | **Est. Files:** 3-4

## Description

**WHY:** Enable boards to configure when workflow hooks run and with what settings (enabled/disabled, timeouts).

**WHAT:** Add workflow_hooks JSONB field to boards table and enter_hooks/exit_hooks JSONB fields to columns table. These fields store hook configuration including enabled status and timeout values.

**WHERE:** Database schema (boards and columns tables), Board settings context, Column schema

## Acceptance Criteria

- [ ] Migration adds workflow_hooks to boards table
- [ ] Migration adds enter_hooks and exit_hooks to columns table
- [ ] Schema updated with hook configuration fields
- [ ] Default values set for common hooks
- [ ] Board context functions for managing hook settings
- [ ] Validation for hook configuration structure
- [ ] Tests cover hook configuration CRUD

## Key Files to Read First

- `lib/kanban/schemas/board.ex` - Board schema
- `lib/kanban/schemas/column.ex` - Column schema
- `lib/kanban/boards.ex` - Board context
- `lib/kanban/columns.ex` - Column context
- `docs/WIP/UPDATE-TASKS/AGENTS-AND-HOOKS.md` - Hook design specification
- `.stride.md` - Agent hook configuration file (version-controlled)

## Technical Notes

**Patterns to Follow:**
- Use JSONB for flexible hook configuration storage
- Set sensible defaults for common hooks
- Validate hook configuration structure on update
- Index JSONB fields for query performance

**Database/Schema:**
- Tables: boards, columns
- Migrations needed: Yes - add hook configuration fields
- Fields to add:

**boards table:**
```elixir
add :workflow_hooks, :jsonb, default: %{
  "before_claim" => %{"enabled" => true, "timeout" => 60},
  "after_claim" => %{"enabled" => true, "timeout" => 30},
  "before_complete" => %{"enabled" => true, "timeout" => 120},
  "after_complete" => %{"enabled" => true, "timeout" => 60},
  "before_unclaim" => %{"enabled" => false, "timeout" => 30},
  "after_unclaim" => %{"enabled" => false, "timeout" => 30}
}
```

**columns table:**
```elixir
add :enter_hooks, :jsonb, default: %{
  "before" => %{"enabled" => true, "timeout" => 60},
  "after" => %{"enabled" => false, "timeout" => 30}
}
add :exit_hooks, :jsonb, default: %{
  "before" => %{"enabled" => true, "timeout" => 60},
  "after" => %{"enabled" => false, "timeout" => 30}
}
```

**Integration Points:**
- [ ] Board settings UI: Display and edit hook configuration
- [ ] Column settings UI: Display and edit column-specific hooks
- [ ] API endpoints: GET/PATCH board and column hook settings

## Verification

**Commands to Run:**
```bash
# Create and run migration
mix ecto.gen.migration add_workflow_hooks_configuration
mix ecto.migrate

# Test in console
iex -S mix
alias Kanban.{Repo, Schemas.Board, Schemas.Column, Boards}

# Create board with custom hook settings
{:ok, board} = Boards.create_board(%{
  name: "Development",
  workflow_hooks: %{
    "before_claim" => %{"enabled" => true, "timeout" => 90},
    "after_claim" => %{"enabled" => false, "timeout" => 30}
  }
})

# Update column hook settings
{:ok, column} = Columns.update_column(column, %{
  enter_hooks: %{
    "before" => %{"enabled" => true, "timeout" => 120},
    "after" => %{"enabled" => true, "timeout" => 30}
  }
})

# Query boards with hooks enabled
from(b in Board, where: fragment("?->>'enabled' = 'true'", b.workflow_hooks["before_claim"]))
|> Repo.all()

# Run tests
mix test test/kanban/boards_test.exs
mix test test/kanban/columns_test.exs
mix precommit
```

**Manual Testing:**
1. Create board with default hook configuration
2. Update board workflow_hooks via context function
3. Create column with default hook configuration
4. Update column enter_hooks and exit_hooks
5. Query boards by hook configuration
6. Verify defaults applied correctly
7. Test validation rejects invalid hook configuration

**Success Looks Like:**
- Boards have workflow_hooks JSONB field with defaults
- Columns have enter_hooks and exit_hooks JSONB fields with defaults
- Can query and update hook configuration
- Validation ensures hook config structure is valid
- All tests pass

## Data Examples

**Migration:**
```elixir
defmodule Kanban.Repo.Migrations.AddWorkflowHooksConfiguration do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :workflow_hooks, :jsonb, default: fragment("""
        '{
          "before_claim": {"enabled": true, "timeout": 60},
          "after_claim": {"enabled": true, "timeout": 30},
          "before_complete": {"enabled": true, "timeout": 120},
          "after_complete": {"enabled": true, "timeout": 60},
          "before_unclaim": {"enabled": false, "timeout": 30},
          "after_unclaim": {"enabled": false, "timeout": 30}
        }'::jsonb
      """)
    end

    alter table(:columns) do
      add :enter_hooks, :jsonb, default: fragment("""
        '{
          "before": {"enabled": true, "timeout": 60},
          "after": {"enabled": false, "timeout": 30}
        }'::jsonb
      """)

      add :exit_hooks, :jsonb, default: fragment("""
        '{
          "before": {"enabled": true, "timeout": 60},
          "after": {"enabled": false, "timeout": 30}
        }'::jsonb
      """)
    end

    # Indexes for querying hook configuration
    create index(:boards, [:workflow_hooks], using: :gin)
    create index(:columns, [:enter_hooks], using: :gin)
    create index(:columns, [:exit_hooks], using: :gin)
  end
end
```

**Schema Updates:**
```elixir
defmodule Kanban.Schemas.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    # ... existing fields ...
    field :workflow_hooks, :map

    timestamps()
  end

  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :workflow_hooks])
    |> validate_required([:name])
    |> validate_workflow_hooks()
  end

  defp validate_workflow_hooks(changeset) do
    case get_change(changeset, :workflow_hooks) do
      nil ->
        changeset

      hooks when is_map(hooks) ->
        valid_hook_names = [
          "before_claim", "after_claim",
          "before_complete", "after_complete",
          "before_unclaim", "after_unclaim"
        ]

        # Validate each hook has enabled and timeout keys
        valid? =
          Enum.all?(hooks, fn {hook_name, config} ->
            hook_name in valid_hook_names and
              is_map(config) and
              Map.has_key?(config, "enabled") and
              Map.has_key?(config, "timeout") and
              is_boolean(config["enabled"]) and
              is_integer(config["timeout"]) and
              config["timeout"] > 0
          end)

        if valid? do
          changeset
        else
          add_error(changeset, :workflow_hooks, "invalid hook configuration")
        end

      _ ->
        add_error(changeset, :workflow_hooks, "must be a map")
    end
  end
end

defmodule Kanban.Schemas.Column do
  use Ecto.Schema
  import Ecto.Changeset

  schema "columns" do
    # ... existing fields ...
    field :enter_hooks, :map
    field :exit_hooks, :map

    timestamps()
  end

  def changeset(column, attrs) do
    column
    |> cast(attrs, [:name, :position, :enter_hooks, :exit_hooks])
    |> validate_required([:name, :position])
    |> validate_column_hooks(:enter_hooks)
    |> validate_column_hooks(:exit_hooks)
  end

  defp validate_column_hooks(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      hooks when is_map(hooks) ->
        valid_hook_types = ["before", "after"]

        # Validate each hook type has enabled and timeout keys
        valid? =
          Enum.all?(hooks, fn {hook_type, config} ->
            hook_type in valid_hook_types and
              is_map(config) and
              Map.has_key?(config, "enabled") and
              Map.has_key?(config, "timeout") and
              is_boolean(config["enabled"]) and
              is_integer(config["timeout"]) and
              config["timeout"] > 0
          end)

        if valid? do
          changeset
        else
          add_error(changeset, field, "invalid hook configuration")
        end

      _ ->
        add_error(changeset, field, "must be a map")
    end
  end
end
```

**Context Functions:**
```elixir
defmodule Kanban.Boards do
  # Update board workflow hooks
  def update_workflow_hooks(%Board{} = board, hook_name, enabled, timeout) do
    workflow_hooks =
      board.workflow_hooks
      |> Map.put(hook_name, %{
        "enabled" => enabled,
        "timeout" => timeout
      })

    board
    |> Board.changeset(%{workflow_hooks: workflow_hooks})
    |> Repo.update()
  end

  # Check if a specific hook is enabled for a board
  def hook_enabled?(%Board{} = board, hook_name) do
    case get_in(board.workflow_hooks, [hook_name, "enabled"]) do
      true -> true
      _ -> false
    end
  end

  # Get timeout for a specific hook
  def hook_timeout(%Board{} = board, hook_name) do
    get_in(board.workflow_hooks, [hook_name, "timeout"]) || 60
  end
end

defmodule Kanban.Columns do
  # Update column enter hooks
  def update_enter_hooks(%Column{} = column, hook_type, enabled, timeout) do
    enter_hooks =
      column.enter_hooks
      |> Map.put(hook_type, %{
        "enabled" => enabled,
        "timeout" => timeout
      })

    column
    |> Column.changeset(%{enter_hooks: enter_hooks})
    |> Repo.update()
  end

  # Update column exit hooks
  def update_exit_hooks(%Column{} = column, hook_type, enabled, timeout) do
    exit_hooks =
      column.exit_hooks
      |> Map.put(hook_type, %{
        "enabled" => enabled,
        "timeout" => timeout
      })

    column
    |> Column.changeset(%{exit_hooks: exit_hooks})
    |> Repo.update()
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :board, :workflow_hooks_updated]`
- [ ] Telemetry event: `[:kanban, :column, :hooks_updated]`
- [ ] Logging: Log hook configuration changes at info level

## Error Handling

- User sees: Validation errors if hook configuration invalid
- On failure: Hook configuration remains unchanged
- Validation: Ensure enabled is boolean, timeout is positive integer

## Common Pitfalls

- [ ] Don't forget to use fragment() for JSONB default in migration
- [ ] Remember to create GIN indexes for JSONB fields
- [ ] Don't forget to validate hook configuration structure
- [ ] Remember timeout must be positive integer
- [ ] Don't forget to handle nil hook configuration gracefully

## Dependencies

**Requires:** Task 08 (claim/unclaim endpoints)
**Blocks:** Task 14 (Hook Execution Engine)

## Out of Scope

- Don't implement hook execution logic (that's task 14)
- Don't create UI for hook configuration yet
- Don't implement AGENTS.md parsing
- Don't add hook reporting endpoints
