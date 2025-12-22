# Task 01B: Extend Task Schema with JSONB Collections

**Type**: Database Schema Extension
**Complexity**: Medium | Est. Files: 4-5 | Est. Time: 2-3 hours
**Dependencies**: 01A (scalar fields must be added first)
**Blocks**: 02 (task metadata), 03 (status field), 04 (AI workflow)

---

## Why

This is the second phase of extending the task schema to support AI-optimized task management. With scalar fields in place from task 01A, we now add JSONB collections for structured data that varies in size: key files to modify, verification steps, technology requirements, known pitfalls, and out-of-scope items.

Using JSONB instead of text fields provides:
- **Type safety** via Ecto embedded schemas
- **Efficient querying** with GIN indexes and PostgreSQL's JSONB operators
- **No parsing overhead** - data stored in native binary JSON format
- **Schema validation** at the application layer

AI agents will use these collections to understand which files to modify, how to verify their work, what technologies are required, and what to avoid.

## What

Add 5 JSONB collection fields to the tasks table:

1. **key_files**: Array of file paths the task will modify (with optional notes)
2. **verification_steps**: Ordered list of steps to verify task completion
3. **technology_requirements**: Technologies/tools required (e.g., ["ecto", "phoenix_live_view"])
4. **pitfalls**: Common mistakes to avoid
5. **out_of_scope**: Explicitly excluded items

Create 2 embedded schemas for structured JSONB data:
- `Kanban.Schemas.Task.KeyFile`
- `Kanban.Schemas.Task.VerificationStep`

Add GIN indexes on JSONB columns for fast querying.

## Where

### Files to Create

1. **Embedded Schema**: `lib/kanban/schemas/task/key_file.ex`
2. **Embedded Schema**: `lib/kanban/schemas/task/verification_step.ex`

### Files to Modify

3. **Migration**: `priv/repo/migrations/TIMESTAMP_extend_tasks_with_jsonb_collections.exs`
4. **Schema**: `lib/kanban/tasks/task.ex`
5. **Tests**: `test/kanban/tasks_test.exs`

---

## Embedded Schemas

### 1. KeyFile Schema

Create `lib/kanban/schemas/task/key_file.ex`:

```elixir
defmodule Kanban.Schemas.Task.KeyFile do
  @moduledoc """
  Embedded schema representing a key file that will be modified as part of a task.

  Each key file has:
  - file_path: Relative path from project root (e.g., "lib/kanban/tasks.ex")
  - note: Optional context about why this file is important (e.g., "Add claim_task/2 function")
  - position: Order in which files should be reviewed/modified
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :file_path, :string
    field :note, :string
    field :position, :integer
  end

  @doc false
  def changeset(key_file, attrs) do
    key_file
    |> cast(attrs, [:file_path, :note, :position])
    |> validate_required([:file_path, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_file_path()
  end

  defp validate_file_path(changeset) do
    if file_path = get_field(changeset, :file_path) do
      cond do
        String.starts_with?(file_path, "/") ->
          add_error(changeset, :file_path, "must be a relative path, not absolute")
        String.contains?(file_path, "..") ->
          add_error(changeset, :file_path, "must not contain .. path traversal")
        true ->
          changeset
      end
    else
      changeset
    end
  end
end
```

### 2. VerificationStep Schema

Create `lib/kanban/schemas/task/verification_step.ex`:

```elixir
defmodule Kanban.Schemas.Task.VerificationStep do
  @moduledoc """
  Embedded schema representing a verification step to confirm task completion.

  Each verification step has:
  - step_type: Either "command" (automated) or "manual" (human verification)
  - step_text: The command to run or manual instruction
  - expected_result: What should happen when the step succeeds
  - position: Order in which steps should be executed
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :step_type, :string
    field :step_text, :string
    field :expected_result, :string
    field :position, :integer
  end

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:step_type, :step_text, :expected_result, :position])
    |> validate_required([:step_type, :step_text, :position])
    |> validate_inclusion(:step_type, ["command", "manual"])
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
```

---

## Migration

Create `priv/repo/migrations/TIMESTAMP_extend_tasks_with_jsonb_collections.exs`:

```elixir
defmodule Kanban.Repo.Migrations.ExtendTasksWithJsonbCollections do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :key_files, :jsonb
      add :verification_steps, :jsonb
      add :technology_requirements, :jsonb
      add :pitfalls, :jsonb
      add :out_of_scope, :jsonb
    end

    # GIN indexes for fast JSONB querying
    # These enable O(log n) lookups instead of O(n) sequential scans
    create index(:tasks, [:key_files], using: :gin)
    create index(:tasks, [:verification_steps], using: :gin)
    create index(:tasks, [:technology_requirements], using: :gin)
  end
end
```

**Why GIN Indexes?**
- `key_files`: Query tasks that modify a specific file (e.g., "show all tasks touching lib/kanban/tasks.ex")
- `verification_steps`: Find tasks with specific verification commands (e.g., "show tasks that run mix test")
- `technology_requirements`: Find tasks requiring specific tech (e.g., "show tasks needing ecto knowledge")

We skip indexes on `pitfalls` and `out_of_scope` since they're rarely queried.

---

## Schema Updates

Update `lib/kanban/tasks/task.ex`:

```elixir
defmodule Kanban.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Schemas.Task.{KeyFile, VerificationStep}

  schema "tasks" do
    # Existing fields from 01A
    field :title, :string
    field :description, :string
    field :acceptance_criteria, :string
    field :position, :integer
    field :type, Ecto.Enum, values: [:work, :defect], default: :work
    field :priority, Ecto.Enum, values: [:low, :medium, :high, :critical], default: :medium
    field :identifier, :string

    # Scalar AI fields (01A)
    field :complexity, :string
    field :estimated_files, :string
    field :why, :string
    field :what, :string
    field :where_context, :string
    field :patterns_to_follow, :string
    field :database_changes, :string
    field :validation_rules, :string
    field :telemetry_event, :string
    field :metrics_to_track, :string
    field :logging_requirements, :string
    field :error_user_message, :string
    field :error_on_failure, :string

    # JSONB collections (01B)
    embeds_many :key_files, KeyFile, on_replace: :delete
    embeds_many :verification_steps, VerificationStep, on_replace: :delete
    field :technology_requirements, {:array, :string}
    field :pitfalls, {:array, :string}
    field :out_of_scope, {:array, :string}

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
      # Scalar AI fields (01A)
      :complexity,
      :estimated_files,
      :why,
      :what,
      :where_context,
      :patterns_to_follow,
      :database_changes,
      :validation_rules,
      :telemetry_event,
      :metrics_to_track,
      :logging_requirements,
      :error_user_message,
      :error_on_failure,
      # Simple JSONB arrays (01B)
      :technology_requirements,
      :pitfalls,
      :out_of_scope
    ])
    |> cast_embed(:key_files)
    |> cast_embed(:verification_steps)
    |> validate_required([:title, :position, :type, :priority])
    |> validate_inclusion(:type, [:work, :defect])
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical])
    |> validate_complexity()
    |> validate_technology_requirements()
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

  defp validate_technology_requirements(changeset) do
    case get_field(changeset, :technology_requirements) do
      nil -> changeset
      [] -> changeset
      techs when is_list(techs) ->
        if Enum.all?(techs, &is_binary/1) do
          changeset
        else
          add_error(changeset, :technology_requirements, "must be a list of strings")
        end
      _ ->
        add_error(changeset, :technology_requirements, "must be a list")
    end
  end
end
```

**Key Changes**:
1. Import embedded schemas at the top
2. Use `embeds_many` for key_files and verification_steps (structured data)
3. Use `{:array, :string}` for simple string arrays (technology_requirements, pitfalls, out_of_scope)
4. Add `on_replace: :delete` to embedded schemas to allow full replacement on updates
5. Use `cast_embed` for embedded schemas (not regular `cast`)

---

## JSONB Querying Examples

Add query helpers to `lib/kanban/tasks.ex`:

```elixir
@doc """
Returns all tasks that modify a specific file.

Uses PostgreSQL's @> (contains) operator with GIN index for fast lookups.
"""
def get_tasks_modifying_file(file_path) do
  from(t in Task,
    where: fragment("? @> ?", t.key_files, ^[%{file_path: file_path}])
  )
  |> Repo.all()
end

@doc """
Returns all tasks that require a specific technology.

Uses PostgreSQL's array contains operator.
"""
def get_tasks_requiring_technology(tech) do
  from(t in Task,
    where: ^tech in t.technology_requirements
  )
  |> Repo.all()
end

@doc """
Returns all tasks with command-based verification steps.
"""
def get_tasks_with_automated_verification do
  from(t in Task,
    where: fragment("? @> ?", t.verification_steps, ^[%{step_type: "command"}])
  )
  |> Repo.all()
end
```

---

## Testing

Add to `test/kanban/tasks_test.exs`:

### 1. Test Embedded Schema - KeyFile

```elixir
describe "key_files embedded schema" do
  test "stores and retrieves key files with ordering" do
    column = column_fixture()

    attrs = %{
      title: "Refactor authentication",
      position: 1,
      column_id: column.id,
      key_files: [
        %{file_path: "lib/kanban/accounts.ex", note: "Update create_user/1", position: 0},
        %{file_path: "lib/kanban_web/user_auth.ex", note: "Add token validation", position: 1},
        %{file_path: "test/kanban/accounts_test.exs", note: "Add tests", position: 2}
      ]
    }

    {:ok, task} = Tasks.create_task(attrs)
    task = Repo.preload(task, :key_files)

    assert length(task.key_files) == 3
    assert Enum.at(task.key_files, 0).file_path == "lib/kanban/accounts.ex"
    assert Enum.at(task.key_files, 1).note == "Add token validation"
    assert Enum.at(task.key_files, 2).position == 2
  end

  test "validates key file paths" do
    column = column_fixture()

    attrs = %{
      title: "Test task",
      position: 1,
      column_id: column.id,
      key_files: [
        %{file_path: "/absolute/path/bad.ex", position: 0}
      ]
    }

    {:error, changeset} = Tasks.create_task(attrs)
    assert %{key_files: [%{file_path: ["must be a relative path, not absolute"]}]} =
      errors_on(changeset)
  end

  test "rejects path traversal in key files" do
    column = column_fixture()

    attrs = %{
      title: "Test task",
      position: 1,
      column_id: column.id,
      key_files: [
        %{file_path: "../../../etc/passwd", position: 0}
      ]
    }

    {:error, changeset} = Tasks.create_task(attrs)
    assert %{key_files: [%{file_path: ["must not contain .. path traversal"]}]} =
      errors_on(changeset)
  end
end
```

### 2. Test Embedded Schema - VerificationStep

```elixir
describe "verification_steps embedded schema" do
  test "stores and retrieves verification steps with ordering" do
    column = column_fixture()

    attrs = %{
      title: "Add feature",
      position: 1,
      column_id: column.id,
      verification_steps: [
        %{
          step_type: "command",
          step_text: "mix test",
          expected_result: "All tests pass",
          position: 0
        },
        %{
          step_type: "manual",
          step_text: "Check UI in browser",
          expected_result: "Button appears and is clickable",
          position: 1
        }
      ]
    }

    {:ok, task} = Tasks.create_task(attrs)
    task = Repo.preload(task, :verification_steps)

    assert length(task.verification_steps) == 2
    assert Enum.at(task.verification_steps, 0).step_type == "command"
    assert Enum.at(task.verification_steps, 1).step_text == "Check UI in browser"
  end

  test "validates step_type enum" do
    column = column_fixture()

    attrs = %{
      title: "Test task",
      position: 1,
      column_id: column.id,
      verification_steps: [
        %{
          step_type: "invalid_type",
          step_text: "Do something",
          position: 0
        }
      ]
    }

    {:error, changeset} = Tasks.create_task(attrs)
    assert %{verification_steps: [%{step_type: ["is invalid"]}]} = errors_on(changeset)
  end
end
```

### 3. Test Simple JSONB Arrays

```elixir
describe "simple JSONB arrays" do
  test "stores and retrieves technology requirements" do
    column = column_fixture()

    attrs = %{
      title: "Build API",
      position: 1,
      column_id: column.id,
      technology_requirements: ["ecto", "phoenix", "jose"]
    }

    {:ok, task} = Tasks.create_task(attrs)

    assert "ecto" in task.technology_requirements
    assert "phoenix" in task.technology_requirements
    assert length(task.technology_requirements) == 3
  end

  test "stores and retrieves pitfalls" do
    column = column_fixture()

    attrs = %{
      title: "Optimize queries",
      position: 1,
      column_id: column.id,
      pitfalls: [
        "Don't use Repo.all without limit",
        "Remember to preload associations",
        "Add indexes for foreign keys"
      ]
    }

    {:ok, task} = Tasks.create_task(attrs)

    assert length(task.pitfalls) == 3
    assert Enum.any?(task.pitfalls, &String.contains?(&1, "preload"))
  end

  test "stores and retrieves out_of_scope items" do
    column = column_fixture()

    attrs = %{
      title: "Add user profile",
      position: 1,
      column_id: column.id,
      out_of_scope: [
        "Profile photo upload (defer to next sprint)",
        "Social media integration",
        "Email notifications"
      ]
    }

    {:ok, task} = Tasks.create_task(attrs)

    assert length(task.out_of_scope) == 3
    assert Enum.any?(task.out_of_scope, &String.contains?(&1, "Photo"))
  end
end
```

### 4. Test JSONB Querying

```elixir
describe "JSONB querying" do
  test "finds tasks modifying specific file" do
    column = column_fixture()

    task1 = task_fixture(%{
      title: "Task 1",
      column_id: column.id,
      key_files: [
        %{file_path: "lib/kanban/tasks.ex", position: 0}
      ]
    })

    task2 = task_fixture(%{
      title: "Task 2",
      column_id: column.id,
      key_files: [
        %{file_path: "lib/kanban/boards.ex", position: 0}
      ]
    })

    results = Tasks.get_tasks_modifying_file("lib/kanban/tasks.ex")

    assert length(results) == 1
    assert hd(results).id == task1.id
  end

  test "finds tasks requiring specific technology" do
    column = column_fixture()

    task1 = task_fixture(%{
      title: "Task 1",
      column_id: column.id,
      technology_requirements: ["ecto", "phoenix"]
    })

    task2 = task_fixture(%{
      title: "Task 2",
      column_id: column.id,
      technology_requirements: ["react", "typescript"]
    })

    results = Tasks.get_tasks_requiring_technology("ecto")

    assert length(results) == 1
    assert hd(results).id == task1.id
  end
end
```

### 5. Test Updates and Replacements

```elixir
describe "updating JSONB collections" do
  test "replaces key_files on update" do
    task = task_fixture(%{
      key_files: [
        %{file_path: "lib/old.ex", position: 0}
      ]
    })

    {:ok, updated_task} = Tasks.update_task(task, %{
      key_files: [
        %{file_path: "lib/new.ex", position: 0}
      ]
    })

    updated_task = Repo.preload(updated_task, :key_files, force: true)

    assert length(updated_task.key_files) == 1
    assert hd(updated_task.key_files).file_path == "lib/new.ex"
  end

  test "appends to technology_requirements" do
    task = task_fixture(%{
      technology_requirements: ["ecto"]
    })

    {:ok, updated_task} = Tasks.update_task(task, %{
      technology_requirements: ["ecto", "phoenix", "jose"]
    })

    assert length(updated_task.technology_requirements) == 3
  end
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
   SELECT * FROM pg_indexes WHERE tablename = 'tasks' AND indexdef LIKE '%gin%';
   ```

3. **Run tests**:
   ```bash
   mix test test/kanban/tasks_test.exs
   ```

4. **Test in IEx**:
   ```elixir
   iex -S mix
   alias Kanban.{Tasks, Repo}

   column = Repo.get_by!(Kanban.Columns.Column, name: "Backlog")

   {:ok, task} = Tasks.create_task(%{
     title: "Test JSONB task",
     position: 1,
     column_id: column.id,
     key_files: [
       %{file_path: "lib/test.ex", note: "Main implementation", position: 0}
     ],
     verification_steps: [
       %{step_type: "command", step_text: "mix test", expected_result: "Pass", position: 0}
     ],
     technology_requirements: ["ecto", "phoenix"],
     pitfalls: ["Don't forget to preload"],
     out_of_scope: ["UI updates"]
   })

   task |> Repo.preload([:key_files, :verification_steps]) |> IO.inspect()
   ```

5. **Test JSONB queries**:
   ```elixir
   Tasks.get_tasks_modifying_file("lib/test.ex")
   Tasks.get_tasks_requiring_technology("ecto")
   ```

6. **Check GIN index usage**:
   ```sql
   EXPLAIN ANALYZE
   SELECT * FROM tasks
   WHERE key_files @> '[{"file_path": "lib/test.ex"}]';
   ```
   Should show "Bitmap Index Scan on tasks_key_files_index" (not Seq Scan).

---

## Patterns to Follow

1. **Use embeds_many for structured data** - KeyFile and VerificationStep have multiple fields
2. **Use {:array, :string} for simple lists** - technology_requirements, pitfalls, out_of_scope
3. **Add on_replace: :delete** - Allows full replacement of embedded collections on update
4. **Validate in embedded schema changesets** - Keep validation close to the data structure
5. **Use GIN indexes strategically** - Only for fields that will be queried
6. **Query with fragment/2** - Use PostgreSQL's native JSONB operators (@>, ?, etc.)

---

## Database Changes

Single migration adding 5 JSONB columns:
- `key_files` (with GIN index)
- `verification_steps` (with GIN index)
- `technology_requirements` (with GIN index)
- `pitfalls` (no index)
- `out_of_scope` (no index)

All columns nullable for backward compatibility.

---

## Out of Scope

- Full-text search on JSONB content (defer to future enhancement)
- UI for editing these fields (defer to task 07 - AI Task Form)
- API endpoints (defer to task 06 - API Authentication)
- Advanced JSONB querying (contains key, nested path queries) - implement as needed
- Data migration/backfill (handled in task 02)

---

## Pitfalls

1. **Don't use cast for embedded schemas** - Use `cast_embed` instead
2. **Don't forget on_replace: :delete** - Without this, updates append instead of replace
3. **Don't over-index** - GIN indexes are expensive to maintain; only add for queried fields
4. **Don't use embeds_one for arrays** - Use `embeds_many`, not `embeds_one`
5. **Don't forget to preload** - Embedded schemas must be preloaded to access data
6. **Validate file paths** - Prevent path traversal and absolute paths in key_files

---

## Technology Requirements

- **Ecto 3.10+**: For `embeds_many` and `cast_embed`
- **PostgreSQL 9.4+**: For JSONB support and GIN indexes
- **Phoenix 1.7+**: (already in use)

---

## Testing Summary

**Total New Tests**: ~15 tests

**Coverage Areas**:
1. KeyFile embedded schema (3 tests: storage, validation, security)
2. VerificationStep embedded schema (2 tests: storage, validation)
3. Simple JSONB arrays (3 tests: one for each field)
4. JSONB querying (2 tests: file lookup, tech lookup)
5. Updates and replacements (2 tests: embedded vs array updates)
6. Backward compatibility (implicit in other tests)

**Test Execution Time**: < 2 seconds (JSONB operations are fast with GIN indexes)

---

## Rollback Plan

If issues arise:

```bash
mix ecto.rollback
```

This removes all 5 JSONB columns and their GIN indexes. No data loss since fields are new.

---

## Next Steps

After completing 01B, proceed to:

**Task 02**: Add task metadata fields (status, claimed_at, completed_at, dependencies, etc.)

At this point, the core task schema is complete and ready for AI agent workflow implementation.
