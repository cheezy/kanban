# Task 01A: Extend Task Schema with Scalar Fields

**Type**: Database Schema Extension
**Complexity**: Medium | Est. Files: 3-4 | Est. Time: 2-3 hours
**Dependencies**: None
**Blocks**: 01B (JSONB collections), 02 (task metadata), 03 (status field), 04 (AI workflow)

---

## Why

This is the first phase of extending the task schema to support AI-optimized task management. By adding scalar fields first, we establish the foundation for more complex JSONB collections in task 01B. This incremental approach reduces risk and allows for easier testing and validation of each layer.

The scalar fields capture essential task metadata like complexity estimates, context, implementation guidance, and observability requirements. These fields will be used by AI agents to understand what needs to be done, where to do it, and how to verify success.

## What

Add 13 new scalar fields to the tasks table:

**Planning & Context** (5 fields):
- `complexity`: Complexity estimate (e.g., "small", "medium", "large")
- `estimated_files`: File count estimate (e.g., "2-3", "5-7")
- `why`: Why this task exists (business/technical rationale)
- `what`: What needs to be implemented (high-level description)
- `where_context`: Where in the codebase this work happens

**Implementation Guidance** (3 fields):
- `patterns_to_follow`: Code patterns and conventions to follow
- `database_changes`: Database migration requirements
- `validation_rules`: Validation requirements for inputs/data

**Observability** (3 fields):
- `telemetry_event`: Telemetry event name to emit
- `metrics_to_track`: Metrics to track for this feature
- `logging_requirements`: What to log and at what levels

**Error Handling** (2 fields):
- `error_user_message`: User-facing error message template
- `error_on_failure`: What to do if task implementation fails

All fields are optional (nullable) to support backward compatibility with existing tasks.

## Where

### Files to Modify

1. **Migration**: `priv/repo/migrations/TIMESTAMP_extend_tasks_with_scalar_fields.exs`
2. **Schema**: `lib/kanban/tasks/task.ex`
3. **Context**: `lib/kanban/tasks.ex` (update create/update functions)
4. **Tests**: `test/kanban/tasks_test.exs`

---

## Migration

```elixir
defmodule Kanban.Repo.Migrations.ExtendTasksWithScalarFields do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Planning & Context
      add :complexity, :string
      add :estimated_files, :string
      add :why, :text
      add :what, :text
      add :where_context, :text

      # Implementation Guidance
      add :patterns_to_follow, :text
      add :database_changes, :text
      add :validation_rules, :text

      # Observability
      add :telemetry_event, :string
      add :metrics_to_track, :text
      add :logging_requirements, :text

      # Error Handling
      add :error_user_message, :text
      add :error_on_failure, :text
    end

    # Add index for common query patterns
    create index(:tasks, [:complexity])
  end
end
```

---

## Schema Updates

Update `lib/kanban/tasks/task.ex`:

```elixir
defmodule Kanban.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    # Existing fields
    field :title, :string
    field :description, :string
    field :acceptance_criteria, :string
    field :position, :integer
    field :type, Ecto.Enum, values: [:work, :defect], default: :work
    field :priority, Ecto.Enum, values: [:low, :medium, :high, :critical], default: :medium
    field :identifier, :string

    # Planning & Context (01A)
    field :complexity, :string
    field :estimated_files, :string
    field :why, :string
    field :what, :string
    field :where_context, :string

    # Implementation Guidance (01A)
    field :patterns_to_follow, :string
    field :database_changes, :string
    field :validation_rules, :string

    # Observability (01A)
    field :telemetry_event, :string
    field :metrics_to_track, :string
    field :logging_requirements, :string

    # Error Handling (01A)
    field :error_user_message, :string
    field :error_on_failure, :string

    # Associations
    belongs_to :column, Kanban.Columns.Column
    belongs_to :assigned_to, Kanban.Accounts.User
    has_many :task_histories, Kanban.Tasks.TaskHistory
    has_many :comments, Kanban.Tasks.TaskComment

    timestamps()
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      # Existing
      :title,
      :description,
      :acceptance_criteria,
      :position,
      :column_id,
      :type,
      :priority,
      :identifier,
      :assigned_to_id,
      # Planning & Context
      :complexity,
      :estimated_files,
      :why,
      :what,
      :where_context,
      # Implementation Guidance
      :patterns_to_follow,
      :database_changes,
      :validation_rules,
      # Observability
      :telemetry_event,
      :metrics_to_track,
      :logging_requirements,
      # Error Handling
      :error_user_message,
      :error_on_failure
    ])
    |> validate_required([:title, :position, :type, :priority])
    |> validate_inclusion(:type, [:work, :defect])
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical])
    |> validate_complexity()
    |> foreign_key_constraint(:column_id)
    |> foreign_key_constraint(:assigned_to_id)
    |> unique_constraint([:column_id, :position])
    |> unique_constraint(:identifier)
  end

  defp validate_complexity(changeset) do
    if complexity = get_field(changeset, :complexity) do
      if complexity in ["small", "medium", "large"] do
        changeset
      else
        add_error(changeset, :complexity, "must be one of: small, medium, large")
      end
    else
      changeset
    end
  end
end
```

---

## Context Updates

Update `lib/kanban/tasks.ex` to handle new fields in create/update operations:

```elixir
def create_task(attrs \\ %{}) do
  %Task{}
  |> Task.changeset(attrs)
  |> Repo.insert()
  |> case do
    {:ok, task} ->
      broadcast_task_change(task, :task_created)
      {:ok, task}
    error -> error
  end
end

def update_task(%Task{} = task, attrs) do
  task
  |> Task.changeset(attrs)
  |> Repo.update()
  |> case do
    {:ok, updated_task} ->
      broadcast_task_change(updated_task, :task_updated)
      {:ok, updated_task}
    error -> error
  end
end
```

No changes needed to broadcast logic - existing functions handle all fields automatically.

---

## Testing

Add tests to `test/kanban/tasks_test.exs`:

### 1. Test Scalar Field Storage and Retrieval

```elixir
describe "scalar AI fields" do
  test "stores and retrieves planning context fields" do
    column = column_fixture()

    attrs = %{
      title: "Implement user authentication",
      position: 1,
      column_id: column.id,
      complexity: "medium",
      estimated_files: "5-7",
      why: "Users need secure login functionality",
      what: "Add JWT-based authentication with refresh tokens",
      where_context: "lib/kanban_web/controllers/auth and lib/kanban/accounts"
    }

    {:ok, task} = Tasks.create_task(attrs)

    assert task.complexity == "medium"
    assert task.estimated_files == "5-7"
    assert task.why == "Users need secure login functionality"
    assert task.what == "Add JWT-based authentication with refresh tokens"
    assert task.where_context =~ "lib/kanban_web/controllers/auth"
  end

  test "stores and retrieves implementation guidance fields" do
    column = column_fixture()

    attrs = %{
      title: "Add user settings page",
      position: 1,
      column_id: column.id,
      patterns_to_follow: "Use LiveView components, follow Phoenix naming conventions",
      database_changes: "Add settings table with user_id foreign key",
      validation_rules: "Email must be unique, password min 12 chars"
    }

    {:ok, task} = Tasks.create_task(attrs)

    assert task.patterns_to_follow =~ "LiveView"
    assert task.database_changes =~ "settings table"
    assert task.validation_rules =~ "Email must be unique"
  end

  test "stores and retrieves observability fields" do
    column = column_fixture()

    attrs = %{
      title: "Add metrics endpoint",
      position: 1,
      column_id: column.id,
      telemetry_event: "kanban.tasks.metrics_exported",
      metrics_to_track: "Export count, export duration, error rate",
      logging_requirements: "Log exports at info level, errors at error level"
    }

    {:ok, task} = Tasks.create_task(attrs)

    assert task.telemetry_event == "kanban.tasks.metrics_exported"
    assert task.metrics_to_track =~ "Export count"
    assert task.logging_requirements =~ "info level"
  end

  test "stores and retrieves error handling fields" do
    column = column_fixture()

    attrs = %{
      title: "Add file upload",
      position: 1,
      column_id: column.id,
      error_user_message: "File upload failed. Please try again or contact support.",
      error_on_failure: "Send alert to ops team, log full stack trace"
    }

    {:ok, task} = Tasks.create_task(attrs)

    assert task.error_user_message =~ "File upload failed"
    assert task.error_on_failure =~ "Send alert to ops team"
  end
end
```

### 2. Test Complexity Validation

```elixir
test "validates complexity values" do
  column = column_fixture()

  attrs = %{
    title: "Test task",
    position: 1,
    column_id: column.id,
    complexity: "invalid_value"
  }

  {:error, changeset} = Tasks.create_task(attrs)
  assert "must be one of: small, medium, large" in errors_on(changeset).complexity
end

test "allows valid complexity values" do
  column = column_fixture()

  for complexity <- ["small", "medium", "large"] do
    attrs = %{
      title: "Test task #{complexity}",
      position: 1,
      column_id: column.id,
      complexity: complexity
    }

    {:ok, task} = Tasks.create_task(attrs)
    assert task.complexity == complexity
  end
end
```

### 3. Test Backward Compatibility

```elixir
test "creates task without scalar fields (backward compatibility)" do
  column = column_fixture()

  attrs = %{
    title: "Simple task",
    position: 1,
    column_id: column.id
  }

  {:ok, task} = Tasks.create_task(attrs)

  assert task.title == "Simple task"
  assert task.complexity == nil
  assert task.why == nil
  assert task.telemetry_event == nil
end
```

### 4. Test Updates to Scalar Fields

```elixir
test "updates scalar fields" do
  task = task_fixture()

  update_attrs = %{
    complexity: "large",
    why: "Updated rationale",
    telemetry_event: "updated.event"
  }

  {:ok, updated_task} = Tasks.update_task(task, update_attrs)

  assert updated_task.complexity == "large"
  assert updated_task.why == "Updated rationale"
  assert updated_task.telemetry_event == "updated.event"
end
```

---

## Verification Steps

After implementing this task:

1. **Run migration**:
   ```bash
   mix ecto.migrate
   ```

2. **Verify schema in database**:
   ```sql
   \d tasks
   ```
   Should show 13 new columns.

3. **Run tests**:
   ```bash
   mix test test/kanban/tasks_test.exs
   ```

4. **Test in IEx**:
   ```elixir
   iex -S mix
   alias Kanban.{Tasks, Repo}
   alias Kanban.Tasks.Task

   column = Repo.get_by!(Kanban.Columns.Column, name: "Backlog")

   {:ok, task} = Tasks.create_task(%{
     title: "Test AI task",
     position: 1,
     column_id: column.id,
     complexity: "medium",
     estimated_files: "3-5",
     why: "Testing new scalar fields"
   })

   task |> Repo.reload() |> IO.inspect()
   ```

5. **Check for nil values on existing tasks**:
   ```elixir
   existing_task = Repo.get!(Task, 1)
   existing_task.complexity  # Should be nil
   existing_task.why  # Should be nil
   ```

---

## Patterns to Follow

1. **All new fields are optional** - Use `field :name, :type` without defaults to allow nil
2. **Validation is lenient** - Only validate complexity enum; other fields accept any text
3. **Text vs String** - Use `:text` for potentially long content (why, what, patterns_to_follow), `:string` for short values (complexity, telemetry_event)
4. **No UI changes yet** - This is pure backend work; UI will be added in later tasks
5. **Preserve existing behavior** - All existing tests should continue to pass

---

## Database Changes

Single migration adding 13 columns to `tasks` table. All columns nullable for backward compatibility.

Index on `complexity` for common filtering queries (e.g., "show all medium complexity tasks").

---

## Out of Scope

- UI for editing these fields (defer to task 07 - AI Task Form)
- JSONB collections (defer to task 01B)
- Embedded schemas (defer to task 01B)
- API endpoints for these fields (defer to task 06 - API Authentication)
- Data migration/backfill (handled in task 02)
- LiveView updates (handled in task 07)

---

## Pitfalls

1. **Don't add non-null constraints** - This breaks existing tasks
2. **Don't add defaults** - Let nil mean "not specified" vs "empty string"
3. **Don't over-validate** - AI agents will provide structured data; validation happens at API layer
4. **Don't index text fields** - PostgreSQL full-text search comes later if needed
5. **Don't forget to update changeset cast/2** - New fields must be in the cast list

---

## Testing Summary

**Total New Tests**: ~12 tests

**Coverage Areas**:
1. Scalar field storage and retrieval (4 tests for 4 categories)
2. Complexity validation (2 tests)
3. Backward compatibility (1 test)
4. Field updates (1 test)
5. Nil handling (implicit in other tests)

**Test Execution Time**: < 1 second (no complex queries or JSONB operations)

---

## Rollback Plan

If issues arise:

```bash
mix ecto.rollback
```

This removes all 13 columns. No data loss since fields are new.

---

## Next Steps

After completing 01A, proceed to:

**Task 01B**: Add JSONB collections (key_files, verification_steps, technology_requirements, pitfalls, out_of_scope) and embedded schemas.
