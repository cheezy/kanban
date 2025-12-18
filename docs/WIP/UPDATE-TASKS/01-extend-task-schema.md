# Extend Task Schema with Proper Database Columns

**Complexity:** Large | **Est. Files:** 5-7

## Description

**WHY:** Current task schema only has title, description, and position. Need to store the rich task information from TASKS.md format using proper database columns for better querying and data integrity.

**WHAT:** Add database columns to tasks table for complexity, key files, verification steps, observability requirements, and other TASKS.md fields. Store collections (key files, verification steps, pitfalls, out of scope) as text fields with simple formatting.

**WHERE:** Task schema, migrations, and context module

## Acceptance Criteria

- [ ] Migration adds new columns to tasks table
- [ ] Text fields store collections (key_files, verification_steps, pitfalls, out_of_scope)
- [ ] Task schema updated with new fields
- [ ] Changeset validates new fields
- [ ] Default values set appropriately
- [ ] Existing tasks compatible (nullable fields)
- [ ] All tests pass after migration
- [ ] Helper functions parse text fields into structured data for API/UI

## Key Files to Read First

- `lib/kanban/schemas/task.ex` - Current task schema (all fields)
- `lib/kanban/tasks.ex` - Task context module
- `priv/repo/migrations/` - Check latest migration number
- `test/kanban/tasks_test.exs` - Task tests to update
- `docs/WIP/TASKS.md` - Reference format (understand 18 categories)

## Technical Notes

**Patterns to Follow:**
- Use proper database columns for scalar values (complexity, estimated_files, etc.)
- Store collections as text fields with simple line-based formatting
- Use virtual fields in Ecto schema for structured access
- Follow existing naming conventions in the project
- Nullable columns for backward compatibility

**Database/Schema:**
- Tables: tasks (extend only - keep flat structure)
- Migrations needed: Yes - single migration adding columns to tasks table

**New columns on tasks table:**
- `complexity` (string) - "small", "medium", "large"
- `estimated_files` (string) - "1-2", "3-5", "5+"
- `why` (text) - Problem being solved
- `what` (text) - Specific feature/change
- `where_context` (text) - UI location or code area
- `patterns_to_follow` (text) - Existing patterns to use
- `database_changes` (text) - Migration/schema notes
- `technology_requirements` (text) - Required technologies/integrations (one per line)
- `telemetry_event` (string) - Event name like "[:kanban, :task, :action]"
- `metrics_to_track` (text) - What to measure
- `logging_requirements` (text) - What to log
- `error_user_message` (text) - What user sees on error
- `error_on_failure` (text) - What happens on failure
- `validation_rules` (text) - Input validation needed
- `key_files` (text) - One file per line, format: "path | note"
- `verification_steps` (text) - One step per line, format: "type | text | expected_result"
- `pitfalls` (text) - One pitfall per line
- `out_of_scope` (text) - One item per line

**Text Field Formats:**
- **key_files**: Each line is "file_path | note" (e.g., "lib/kanban/tasks.ex | Task context module")
- **verification_steps**: Each line is "command|text|expected" or "manual|text|expected"
- **pitfalls**: Each line is a single pitfall description
- **out_of_scope**: Each line is a single out-of-scope item
- **technology_requirements**: Each line is a technology/integration name (e.g., "Phoenix PubSub", "Database migration", "Phoenix Channels", "External API integration")

**Integration Points:**
- [ ] PubSub broadcasts: Broadcast task schema changes to all clients
- [ ] Phoenix Channels: Update board channel to include new fields
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Create migration
mix ecto.gen.migration extend_tasks_with_ai_fields

# Edit migration, then run
mix ecto.migrate

# Run tests
mix test test/kanban/tasks_test.exs
mix test test/kanban/schemas/task_test.exs

# Verify in console
iex -S mix
alias Kanban.{Repo, Schemas.Task, Tasks}

# Create task with new fields
{:ok, task} = Tasks.create_task(%{
  title: "Add priority filter",
  complexity: "medium",
  estimated_files: "2-3",
  why: "Users need to focus on high-priority tasks",
  what: "Add dropdown filter for task priority (0-4)",
  where_context: "Board list view header",
  telemetry_event: "[:kanban, :filter, :used]",
  key_files: "lib/kanban_web/live/board_live.ex | Main LiveView\nlib/kanban_web/live/board_live.html.heex | Board template",
  verification_steps: "command | mix test test/kanban/boards_test.exs | All tests pass",
  pitfalls: "Don't forget to handle nil priority values\nRemember to broadcast filter changes",
  out_of_scope: "Priority editing in this task\nSorting by priority",
  technology_requirements: "Phoenix PubSub\nPhoenix LiveView"
})

# Verify data stored correctly
IO.inspect(task.key_files, label: "Key files (text)")

# Run all checks
mix precommit
```

**Manual Testing:**
1. Run migration successfully
2. Create new task with rich fields via iex
3. Verify text fields store data correctly
4. Query tasks and verify new fields returned
5. Update existing task - verify backward compatibility
6. Check board UI still displays tasks
7. Parse text fields into structured format for API

**Success Looks Like:**
- Migration runs without errors
- New columns in tasks table
- Can create/update tasks with rich data
- Text fields store collections properly
- Existing tasks still work (nulls handled)
- No breaking changes to existing UI
- All 510 tests still pass

## Data Examples

**Migration:**
```elixir
defmodule Kanban.Repo.Migrations.ExtendTasksWithAiFields do
  use Ecto.Migration

  def change do
    # Extend tasks table with all AI-optimized fields
    alter table(:tasks) do
      # Complexity and scope
      add :complexity, :string
      add :estimated_files, :string

      # Context fields
      add :why, :text
      add :what, :text
      add :where_context, :text

      # Technical notes
      add :patterns_to_follow, :text
      add :database_changes, :text
      add :technology_requirements, :text

      # Observability
      add :telemetry_event, :string
      add :metrics_to_track, :text
      add :logging_requirements, :text

      # Error handling
      add :error_user_message, :text
      add :error_on_failure, :text
      add :validation_rules, :text

      # Collections stored as text (one item per line)
      add :key_files, :text           # Format: "path | note" per line
      add :verification_steps, :text  # Format: "type | text | expected" per line
      add :pitfalls, :text            # One pitfall per line
      add :out_of_scope, :text        # One item per line
    end
  end
end
```

**Schema Update:**
```elixir
defmodule Kanban.Schemas.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    # Existing fields
    field :title, :string
    field :description, :string
    field :position, :integer
    belongs_to :column, Kanban.Schemas.Column

    # New AI-optimized fields
    field :complexity, :string
    field :estimated_files, :string
    field :why, :string
    field :what, :string
    field :where_context, :string
    field :patterns_to_follow, :string
    field :database_changes, :string
    field :technology_requirements, :string
    field :telemetry_event, :string
    field :metrics_to_track, :string
    field :logging_requirements, :string
    field :error_user_message, :string
    field :error_on_failure, :string
    field :validation_rules, :string

    # Collections stored as text fields
    field :key_files, :string
    field :verification_steps, :string
    field :pitfalls, :string
    field :out_of_scope, :string

    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title, :description, :position, :complexity,
      :estimated_files, :why, :what, :where_context,
      :patterns_to_follow, :database_changes, :technology_requirements,
      :telemetry_event, :metrics_to_track,
      :logging_requirements, :error_user_message,
      :error_on_failure, :validation_rules,
      :key_files, :verification_steps, :pitfalls, :out_of_scope
    ])
    |> validate_required([:title])
    |> validate_inclusion(:complexity, ["small", "medium", "large"], allow_nil: true)
    |> validate_inclusion(:estimated_files, ["1-2", "2-3", "3-5", "5+"], allow_nil: true)
  end
end
```

**Helper Module for Parsing Text Fields:**
```elixir
defmodule Kanban.Tasks.TextFieldParser do
  @moduledoc """
  Parses text fields from tasks table into structured data for API/UI.
  """

  def parse_key_files(nil), do: []
  def parse_key_files(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, position} ->
      case String.split(line, "|", parts: 2) do
        [file_path, note] ->
          %{
            file_path: String.trim(file_path),
            note: String.trim(note),
            position: position
          }

        [file_path] ->
          %{
            file_path: String.trim(file_path),
            note: nil,
            position: position
          }
      end
    end)
  end

  def parse_verification_steps(nil), do: []
  def parse_verification_steps(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, position} ->
      case String.split(line, "|", parts: 3) do
        [step_type, step_text, expected_result] ->
          %{
            step_type: String.trim(step_type),
            step_text: String.trim(step_text),
            expected_result: String.trim(expected_result),
            position: position
          }

        [step_type, step_text] ->
          %{
            step_type: String.trim(step_type),
            step_text: String.trim(step_text),
            expected_result: nil,
            position: position
          }
      end
    end)
  end

  def parse_pitfalls(nil), do: []
  def parse_pitfalls(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {pitfall, position} ->
      %{
        pitfall_text: String.trim(pitfall),
        position: position
      }
    end)
  end

  def parse_out_of_scope(nil), do: []
  def parse_out_of_scope(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {item, position} ->
      %{
        item_text: String.trim(item),
        position: position
      }
    end)
  end

  # Format helpers for going the other direction (structured -> text)
  def format_key_files([]), do: nil
  def format_key_files(key_files) when is_list(key_files) do
    key_files
    |> Enum.map(fn
      %{file_path: path, note: nil} -> path
      %{file_path: path, note: note} -> "#{path} | #{note}"
      # Also handle map with string keys
      %{"file_path" => path, "note" => nil} -> path
      %{"file_path" => path, "note" => note} -> "#{path} | #{note}"
    end)
    |> Enum.join("\n")
  end

  def format_verification_steps([]), do: nil
  def format_verification_steps(steps) when is_list(steps) do
    steps
    |> Enum.map(fn
      %{step_type: type, step_text: text, expected_result: nil} ->
        "#{type} | #{text}"
      %{step_type: type, step_text: text, expected_result: expected} ->
        "#{type} | #{text} | #{expected}"
      # Handle string keys
      %{"step_type" => type, "step_text" => text, "expected_result" => nil} ->
        "#{type} | #{text}"
      %{"step_type" => type, "step_text" => text, "expected_result" => expected} ->
        "#{type} | #{text} | #{expected}"
    end)
    |> Enum.join("\n")
  end

  def format_pitfalls([]), do: nil
  def format_pitfalls(pitfalls) when is_list(pitfalls) do
    pitfalls
    |> Enum.map(fn
      %{pitfall_text: text} -> text
      %{"pitfall_text" => text} -> text
      text when is_binary(text) -> text
    end)
    |> Enum.join("\n")
  end

  def format_out_of_scope([]), do: nil
  def format_out_of_scope(items) when is_list(items) do
    items
    |> Enum.map(fn
      %{item_text: text} -> text
      %{"item_text" => text} -> text
      text when is_binary(text) -> text
    end)
    |> Enum.join("\n")
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :task, :schema_extended]`
- [ ] Metrics: Count of tasks with AI fields populated
- [ ] Logging: Log migration completion at info level

## Error Handling

- User sees: Migration errors if database constraints violated
- On failure: Rollback migration automatically (Ecto handles)
- Validation: Changeset validates complexity values, required fields

## Common Pitfalls

- [ ] Don't make new columns NOT NULL (backward compatibility with existing tasks)
- [ ] Remember to escape pipe characters in text data if needed
- [ ] Avoid storing structured data in text fields that changes frequently
- [ ] Don't forget to trim whitespace when parsing text fields
- [ ] Remember to handle nil/empty text fields gracefully in parsers
- [ ] Avoid complex parsing logic - keep format simple
- [ ] Don't forget to validate complexity and estimated_files values
- [ ] Remember text fields are nullable for backward compatibility

## Dependencies

**Requires:** None (foundational change)
**Blocks:** 02-add-task-metadata-fields.md, 04-implement-task-crud-api.md, 09-add-task-creation-form.md

## Out of Scope

- Don't implement UI forms yet (separate task #09)
- Don't add API endpoints yet (separate task #04)
- Don't migrate existing task descriptions to new format
- Don't implement rich text editing for text fields
- Don't add complex validation for text field formats (keep it simple)
- Don't create separate tables for collections (keep tasks table flat)
