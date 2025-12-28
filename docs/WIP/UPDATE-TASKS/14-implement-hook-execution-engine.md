# Implement Hook Execution Engine

**Complexity:** Medium | **Est. Files:** 4-5

## Description

**WHY:** Agents need to execute custom commands at fixed workflow transition points (before_doing, after_doing, before_review, after_review).

**WHAT:** Build system to parse `.stride.md` file, substitute environment variables in hook commands, execute hooks with timeout enforcement, capture output, and handle errors. Integrate hook execution into claim and complete workflows at fixed points tied to Doing and Review columns.

**WHERE:** New Hooks context module, integration with Tasks.claim_task and Tasks.complete_task

## Acceptance Criteria

- [ ] Parser reads and parses `.stride.md` file format
- [ ] Hook commands extracted by agent name and hook point
- [ ] Environment variables substituted in hook commands
- [ ] Hook execution with timeout enforcement
- [ ] Stdout/stderr captured for logging
- [ ] Blocking hooks (before_doing, after_doing) prevent action on failure
- [ ] Non-blocking hooks (before_review, after_review) log errors but don't block
- [ ] Integration with claim workflow (before_doing)
- [ ] Integration with complete workflow (after_doing, before_review)
- [ ] Integration with mark_reviewed workflow (after_review)
- [ ] Telemetry events for hook execution
- [ ] Tests cover parsing, execution, and error cases

## Hook Execution Points

**Fixed execution points (NOT configurable):**

### 1. before_doing
- **Triggers**: During `Tasks.claim_task/3`
- **When**: After validation, before moving task to Doing column
- **Blocking**: YES - failure prevents claim
- **Timeout**: 60 seconds

### 2. after_doing
- **Triggers**: During `Tasks.complete_task/3`
- **When**: After validation, before moving task to Review column
- **Blocking**: YES - failure prevents completion
- **Timeout**: 120 seconds (for running tests)

### 3. before_review
- **Triggers**: During `Tasks.complete_task/3`
- **When**: After task moves to Review column
- **Blocking**: NO - failure logged but doesn't prevent review
- **Timeout**: 60 seconds

### 4. after_review
- **Triggers**: During `Tasks.mark_reviewed/2` OR immediately after before_review if needs_review=false
- **When**: After review approved, before moving to Done
- **Blocking**: NO - failure logged but doesn't prevent completion
- **Timeout**: 60 seconds

## Key Files to Read First

- `docs/WIP/UPDATE-TASKS/13-add-workflow-hooks-configuration.md` - Hook configuration
- `lib/kanban/tasks.ex` - Tasks context (claim_task, complete_task functions)
- `.stride.md` - Agent hook configuration file (version-controlled)

## Technical Notes

**Patterns to Follow:**
- Use `System.cmd/3` for executing hook commands
- Use `Task.async/1` with timeout for hook execution
- Parse `.stride.md` using regex for markdown code blocks
- Substitute environment variables before execution
- Capture all output for debugging

**Architecture:**
```
Kanban.Hooks (new context)
├── Parser - Parse .stride.md file
├── Executor - Execute hook commands
├── Environment - Build environment variables
└── Reporter - Report hook execution results
```

**Integration Points:**
- [ ] `Tasks.claim_task/3` - Execute before_doing hook (blocking)
- [ ] `Tasks.complete_task/3` - Execute after_doing (blocking), then before_review (non-blocking)
- [ ] `Tasks.mark_reviewed/2` - Execute after_review hook (non-blocking) if needs_review=false, execute immediately in complete_task
- [ ] Auto-execute after_review if needs_review=false

## Verification

**Commands to Run:**
```bash
# Create .stride.md in project root (version-controlled)
cat > .stride.md <<'EOF'
# Stride Agent Configuration

## Agent: Claude Sonnet 4.5

### Capabilities
- code_generation
- testing

### Hook Implementations

#### before_doing
```bash
echo "Starting work on task $TASK_IDENTIFIER"
git checkout -b "task/$TASK_IDENTIFIER"
```

#### after_doing
```bash
# Run your project's tests (customize for your tech stack)
# Examples:
#   npm test                    # JavaScript/Node
#   pytest                      # Python
#   mvn test                    # Java/Maven
#   cargo test                  # Rust
#   mix test                    # Elixir
echo "Running tests..."
# Add your test command here
git add .
git commit -m "Complete task $TASK_IDENTIFIER: $TASK_TITLE"
```

#### before_review
```bash
git push origin HEAD
# Optional: Create PR using GitHub CLI
# gh pr create --title "$TASK_TITLE" --body "Closes #$TASK_IDENTIFIER"
```

#### after_review
```bash
echo "Task $TASK_IDENTIFIER completed and reviewed"
git checkout main
git pull origin main
```
EOF

# Test in console
iex -S mix
alias Kanban.{Hooks, Tasks}

# Parse .stride.md
{:ok, agents} = Hooks.Parser.parse_stride_md(".stride.md")

# Execute a hook
env = Hooks.Environment.build(task, board, agent_name: "Claude Sonnet 4.5")
{:ok, result} = Hooks.Executor.execute_hook(
  agents["Claude Sonnet 4.5"]["hooks"]["before_doing"],
  env,
  timeout: 60_000
)

# Test full workflow
{:ok, task} = Tasks.claim_task(task_id, api_token, "Claude Sonnet 4.5")
# Should execute before_doing hook

# Run tests
mix test test/kanban/hooks_test.exs
mix precommit
```

**Manual Testing:**
1. Create `.stride.md` with sample hooks
2. Claim task via API - verify before_doing hook executes
3. Check logs for hook execution details
4. Complete task - verify after_doing hook executes (blocking)
5. Verify before_review hook executes (non-blocking)
6. If needs_review=false, verify after_review executes immediately
7. If needs_review=true, mark reviewed and verify after_review executes
8. Test hook failure scenarios (exit code != 0)
9. Test hook timeout scenarios (long-running command)
10. Verify blocking hooks prevent action on failure

**Success Looks Like:**
- `.stride.md` parsed correctly
- Hooks execute with proper environment variables
- Output captured and logged
- Timeouts enforced
- before_doing and after_doing block on failure
- before_review and after_review log but don't block
- Continuous workflow works: claim → work → complete → review in one flow

## Data Examples

**Hooks Context Module:**
```elixir
defmodule Kanban.Hooks do
  @moduledoc """
  Context for managing and executing workflow hooks.
  Fixed hooks: before_doing, after_doing, before_review, after_review
  """

  alias Kanban.Hooks.{Parser, Executor, Environment, Reporter}
  alias Kanban.Schemas.{Task, Board}

  @hook_config %{
    "before_doing" => %{blocking: true, timeout: 60_000},
    "after_doing" => %{blocking: true, timeout: 120_000},
    "before_review" => %{blocking: false, timeout: 60_000},
    "after_review" => %{blocking: false, timeout: 60_000}
  }

  @doc """
  Execute a workflow hook for a task.
  Hook name must be one of: before_doing, after_doing, before_review, after_review
  """
  def execute_hook(%Task{} = task, %Board{} = board, hook_name, agent_name) do
    config = Map.get(@hook_config, hook_name)

    unless config do
      raise ArgumentError, "Invalid hook name: #{hook_name}. Must be one of: #{Map.keys(@hook_config) |> Enum.join(", ")}"
    end

    with {:ok, agents} <- Parser.parse_stride_md(".stride.md"),
         {:ok, hook_command} <- get_hook_command(agents, agent_name, hook_name),
         env <- Environment.build(task, board, hook_name: hook_name, agent_name: agent_name),
         {:ok, result} <- Executor.execute_hook(hook_command, env, timeout: config.timeout) do
      Reporter.report_success(task, hook_name, result)
      {:ok, result}
    else
      {:error, :hook_not_found} ->
        # Hook not implemented for this agent - this is OK
        {:ok, :skipped}

      {:error, reason} = error ->
        Reporter.report_failure(task, hook_name, reason)

        if config.blocking do
          error
        else
          # Non-blocking hook - log error but don't fail
          {:ok, :failed_non_blocking}
        end
    end
  end

  defp get_hook_command(agents, agent_name, hook_name) do
    case get_in(agents, [agent_name, "hooks", hook_name]) do
      nil -> {:error, :hook_not_found}
      command -> {:ok, command}
    end
  end
end
```

**Parser Module:**
```elixir
defmodule Kanban.Hooks.Parser do
  @moduledoc """
  Parses .stride.md file to extract hook configurations.
  """

  def parse_stride_md(filepath) do
    case File.read(filepath) do
      {:ok, content} ->
        {:ok, parse_content(content)}

      {:error, :enoent} ->
        # No .stride.md file - hooks disabled
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp parse_content(content) do
    # Split by agent sections (## Agent: ...)
    agent_pattern = ~r/^## Agent: (.+)$/m

    agent_sections = Regex.split(agent_pattern, content, include_captures: true, trim: true)

    agent_sections
    |> Enum.chunk_every(2)
    |> Enum.reject(fn chunk -> length(chunk) != 2 end)
    |> Enum.reduce(%{}, fn [name, section], acc ->
      agent_name = String.trim(name)
      capabilities = parse_capabilities(section)
      hooks = parse_hooks(section)

      Map.put(acc, agent_name, %{
        "capabilities" => capabilities,
        "hooks" => hooks
      })
    end)
  end

  defp parse_capabilities(section) do
    case Regex.run(~r/### Capabilities\s*\n((?:- .+\n?)+)/m, section) do
      [_, caps_text] ->
        caps_text
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "- "))
        |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  defp parse_hooks(section) do
    # Match hook sections: #### hook_name followed by ```bash or ``` code block
    hook_pattern = ~r/####\s+(\w+)\s*\n```(?:bash)?\n(.+?)\n```/ms

    Regex.scan(hook_pattern, section)
    |> Enum.reduce(%{}, fn [_, hook_name, command], acc ->
      Map.put(acc, String.trim(hook_name), String.trim(command))
    end)
  end
end
```

**Executor Module:**
```elixir
defmodule Kanban.Hooks.Executor do
  @moduledoc """
  Executes hook commands with timeout and output capture.
  """

  require Logger

  def execute_hook(command, env, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    start_time = System.monotonic_time(:millisecond)

    # Substitute environment variables in command
    command_with_env = substitute_env_vars(command, env)

    Logger.debug("Executing hook command: #{inspect(command_with_env)}")

    task =
      Task.async(fn ->
        case System.cmd("sh", ["-c", command_with_env], stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, exit_code} ->
            {:error, {:exit_code, exit_code, output}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, output}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        {:ok, %{exit_code: 0, output: output, duration_ms: duration_ms}}

      {:ok, {:error, {:exit_code, code, output}}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        {:error, {:exit_code, code, output, duration_ms}}

      nil ->
        {:error, :timeout}
    end
  end

  defp substitute_env_vars(command, env) do
    Enum.reduce(env, command, fn {key, value}, acc ->
      acc
      |> String.replace("$#{key}", to_string(value))
      |> String.replace("${#{key}}", to_string(value))
    end)
  end
end
```

**Environment Module:**
```elixir
defmodule Kanban.Hooks.Environment do
  @moduledoc """
  Builds environment variables for hook execution.
  """

  alias Kanban.Schemas.{Task, Board}

  def build(%Task{} = task, %Board{} = board, opts \\ []) do
    task = Repo.preload(task, :column)
    agent_name = Keyword.get(opts, :agent_name, "Unknown")
    hook_name = Keyword.get(opts, :hook_name, "unknown")

    %{
      "TASK_ID" => to_string(task.id),
      "TASK_IDENTIFIER" => task.identifier || "",
      "TASK_TITLE" => task.title || "",
      "TASK_DESCRIPTION" => task.description || "",
      "TASK_STATUS" => to_string(task.status || "open"),
      "TASK_COMPLEXITY" => to_string(task.complexity || "medium"),
      "TASK_PRIORITY" => to_string(task.priority || 0),
      "TASK_NEEDS_REVIEW" => to_string(task.needs_review || false),
      "BOARD_ID" => to_string(board.id),
      "BOARD_NAME" => board.name || "",
      "COLUMN_ID" => to_string(task.column.id),
      "COLUMN_NAME" => task.column.name || "",
      "AGENT_NAME" => agent_name,
      "HOOK_NAME" => hook_name
    }
  end
end
```

**Integration with Tasks Context:**
```elixir
defmodule Kanban.Tasks do
  alias Kanban.Hooks

  def claim_task(task_id, api_token, agent_name \\ "Unknown") do
    task = get_task!(task_id) |> Repo.preload([:column])
    board = Repo.preload(task.column, :board).board

    # Execute before_doing hook (blocking)
    with {:ok, _} <- Hooks.execute_hook(task, board, "before_doing", agent_name),
         {:ok, claimed_task} <- do_claim_task(task, api_token) do
      {:ok, claimed_task}
    end
  end

  def complete_task(task, attrs, agent_name \\ "Unknown") do
    board = get_board_for_task(task)

    # Execute after_doing hook (blocking)
    with {:ok, _} <- Hooks.execute_hook(task, board, "after_doing", agent_name),
         {:ok, completed_task} <- do_complete_task(task, attrs) do

      # Execute before_review hook (non-blocking)
      Hooks.execute_hook(completed_task, board, "before_review", agent_name)

      # If doesn't need review, execute after_review immediately
      if not completed_task.needs_review do
        Hooks.execute_hook(completed_task, board, "after_review", agent_name)
      end

      {:ok, completed_task}
    end
  end

  def mark_reviewed(task, review_result) do
    board = get_board_for_task(task)

    with {:ok, reviewed_task} <- do_mark_reviewed(task, review_result) do
      # Execute after_review hook (non-blocking)
      Hooks.execute_hook(reviewed_task, board, "after_review", get_agent_name(task))

      {:ok, reviewed_task}
    end
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :hook, :executed]` with duration, exit code, success
- [ ] Telemetry event: `[:kanban, :hook, :timeout]` when hook times out
- [ ] Logging: Info level for successful hooks, warn for failures, error for timeouts

## Error Handling

- User sees: Error message from failed blocking hook (before_doing, after_doing)
- On failure: Blocking hooks prevent action, non-blocking hooks log error
- Timeout: Hook process killed after timeout, treated as failure

## Common Pitfalls

- [ ] Don't forget to handle `.stride.md` file not found (return empty map)
- [ ] Remember to substitute environment variables before execution
- [ ] Don't forget to capture both stdout and stderr
- [ ] Remember blocking vs non-blocking behavior differs by hook
- [ ] Don't forget to execute after_review immediately if needs_review=false
- [ ] Remember to preload board and column associations

## Dependencies

**Requires:** Task 13 (Hook configuration documentation)
**Blocks:** None (this completes the hooks feature)

## Out of Scope

- Don't make hooks configurable per-column
- Don't add database fields for hook configuration
- Don't implement UI for editing `.stride.md`
- Don't add hook marketplace or templates
- Hooks are FIXED to Doing and Review columns only
