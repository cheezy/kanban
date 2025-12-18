# Implement Hook Execution Engine

**Complexity:** Large | **Est. Files:** 5-6

## Description

**WHY:** Agents need to execute custom commands at workflow transition points (before/after claim, before/after column transitions, before/after completion).

**WHAT:** Build system to parse AGENTS.md file, substitute environment variables in hook commands, execute hooks with timeout enforcement, capture output, and handle errors. Integrate hook execution into task workflow (claim, move, complete, unclaim).

**WHERE:** New Hooks context module, Task workflow integration, AGENTS.md parser

## Acceptance Criteria

- [ ] Parser reads and parses AGENTS.md file format
- [ ] Hook commands extracted by agent name and hook point
- [ ] Environment variables substituted in hook commands
- [ ] Hook execution with timeout enforcement
- [ ] Stdout/stderr captured for logging
- [ ] Blocking hooks prevent action on failure
- [ ] Non-blocking hooks log errors but don't block
- [ ] Integration with claim/move/complete/unclaim workflows
- [ ] Telemetry events for hook execution
- [ ] Tests cover parsing, execution, and error cases

## Key Files to Read First

- `docs/WIP/UPDATE-TASKS/AGENTS-AND-HOOKS.md` - Complete hook design
- `lib/kanban/tasks.ex` - Task context (claim/complete functions)
- Task 08 implementation - Claim/unclaim endpoints
- Task 13 implementation - Hook configuration fields

## Technical Notes

**Patterns to Follow:**
- Use `System.cmd/3` for executing hook commands
- Use `Task.async/1` with timeout for hook execution
- Parse AGENTS.md using regex or markdown parser
- Substitute environment variables before execution
- Capture all output for debugging

**Architecture:**
```
Kanban.Hooks (new context)
├── Parser - Parse AGENTS.md file
├── Executor - Execute hook commands
├── Environment - Build environment variables
└── Reporter - Report hook execution results
```

**Database/Schema:**
No new tables needed. Hook execution is stateless but logged via telemetry.

**Integration Points:**
- [ ] Tasks.claim_task/2 - Execute before_claim and after_claim hooks
- [ ] Tasks.move_task/3 - Execute before/after column enter/exit hooks
- [ ] Tasks.complete_task/2 - Execute before_complete and after_complete hooks
- [ ] Tasks.unclaim_task/3 - Execute before_unclaim and after_unclaim hooks

## Verification

**Commands to Run:**
```bash
# Create AGENTS.md in project root
cat > AGENTS.md <<'EOF'
# Agent Configuration

## Agent: Claude Sonnet 4.5

### Capabilities
- code_generation
- testing

### Hook Implementations

#### after_claim
```bash
echo "Claimed task $TASK_ID: $TASK_TITLE"
git checkout -b "task-$TASK_ID"
```

#### before_complete
```bash
mix test
mix format --check-formatted
```

#### after_complete
```bash
git add .
git commit -m "Complete task $TASK_ID"
git push origin HEAD
```
EOF

# Test in console
iex -S mix
alias Kanban.{Hooks, Tasks}

# Parse AGENTS.md
{:ok, agents} = Hooks.Parser.parse_agents_md("AGENTS.md")

# Execute a hook
env = Hooks.Environment.build(task, board, column, agent_name: "Claude Sonnet 4.5")
{:ok, result} = Hooks.Executor.execute_hook(
  agents["Claude Sonnet 4.5"]["after_claim"],
  env,
  timeout: 30_000
)

# Test full workflow
{:ok, task} = Tasks.claim_task(task_id, api_token_id)
# Should execute before_claim and after_claim hooks

# Run tests
mix test test/kanban/hooks_test.exs
mix precommit
```

**Manual Testing:**
1. Create AGENTS.md with sample hooks
2. Enable hooks in board settings (from task 13)
3. Claim task and verify after_claim hook executes
4. Check logs for hook execution details
5. Move task to different column and verify column hooks execute
6. Complete task and verify completion hooks execute
7. Test hook failure scenarios (exit code != 0)
8. Test hook timeout scenarios (long-running command)
9. Verify blocking hooks prevent action on failure
10. Verify non-blocking hooks allow action despite failure

**Success Looks Like:**
- AGENTS.md parsed correctly
- Hooks execute with proper environment variables
- Output captured and logged
- Timeouts enforced
- Blocking vs non-blocking behavior works correctly
- All tests pass

## Data Examples

**Hooks Context Module:**
```elixir
defmodule Kanban.Hooks do
  @moduledoc """
  Context for managing and executing workflow hooks.
  """

  alias Kanban.Hooks.{Parser, Executor, Environment, Reporter}
  alias Kanban.Schemas.{Task, Board, Column}

  @doc """
  Execute a workflow hook for a task.

  ## Options
  - `:agent_name` - Name of the agent executing the hook
  - `:hook_name` - Name of the hook to execute (e.g., "after_claim")
  - `:blocking` - Whether hook failure should block the action (default: true for before_*, false for after_*)
  - `:timeout` - Maximum execution time in milliseconds

  ## Returns
  - `{:ok, result}` - Hook executed successfully
  - `{:error, reason}` - Hook execution failed
  """
  def execute_workflow_hook(%Task{} = task, %Board{} = board, opts \\ []) do
    agent_name = Keyword.fetch!(opts, :agent_name)
    hook_name = Keyword.fetch!(opts, :hook_name)
    blocking = Keyword.get(opts, :blocking, String.starts_with?(hook_name, "before_"))
    timeout = Keyword.get(opts, :timeout, 60_000)

    with {:ok, agents} <- Parser.parse_agents_md("AGENTS.md"),
         {:ok, hook_command} <- get_hook_command(agents, agent_name, hook_name),
         env <- Environment.build(task, board, hook_name: hook_name, agent_name: agent_name),
         {:ok, result} <- Executor.execute_hook(hook_command, env, timeout: timeout) do
      Reporter.report_success(task, hook_name, result)
      {:ok, result}
    else
      {:error, :hook_not_found} ->
        # Hook not implemented for this agent - this is OK
        {:ok, :skipped}

      {:error, reason} = error ->
        Reporter.report_failure(task, hook_name, reason)

        if blocking do
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
  Parses AGENTS.md file to extract hook configurations.
  """

  @doc """
  Parse AGENTS.md file and return agent configurations.

  ## Returns
  Map of agent name to configuration:
  ```
  %{
    "Claude Sonnet 4.5" => %{
      "capabilities" => ["code_generation", "testing"],
      "hooks" => %{
        "after_claim" => "git checkout -b task-$TASK_ID",
        "before_complete" => "mix test",
        ...
      }
    }
  }
  ```
  """
  def parse_agents_md(filepath) do
    case File.read(filepath) do
      {:ok, content} ->
        {:ok, parse_content(content)}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp parse_content(content) do
    # Split by agent sections (## Agent: ...)
    agent_sections = Regex.split(~r/^## Agent: (.+)$/m, content, include_captures: true, trim: true)

    agent_sections
    |> Enum.chunk_every(2)
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
        |> Enum.map(fn line -> String.trim_leading(line, "- ") end)

      _ ->
        []
    end
  end

  defp parse_hooks(section) do
    # Match hook sections like:
    # #### after_claim
    # ```bash
    # command here
    # ```
    hook_pattern = ~r/####\s+(\w+(?:\[.+\])?)\s*\n```(?:bash)?\n(.+?)\n```/ms

    Regex.scan(hook_pattern, section)
    |> Enum.reduce(%{}, fn [_, hook_name, command], acc ->
      # Clean up hook name (remove column specifier if present)
      clean_name = String.replace(hook_name, ~r/\[.+\]/, "")
      Map.put(acc, String.trim(clean_name), String.trim(command))
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

  @doc """
  Execute a hook command with environment variables and timeout.

  ## Options
  - `:timeout` - Maximum execution time in milliseconds (default: 60_000)

  ## Returns
  - `{:ok, %{exit_code: 0, output: string, duration_ms: integer}}` - Success
  - `{:error, reason}` - Failure (timeout, non-zero exit, etc.)
  """
  def execute_hook(command, env, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    start_time = System.monotonic_time(:millisecond)

    # Substitute environment variables in command
    command_with_env = substitute_env_vars(command, env)

    Logger.debug("Executing hook command: #{inspect(command_with_env)}")

    task =
      Task.async(fn ->
        # Execute command in shell
        case System.cmd("sh", ["-c", command_with_env], env: env, stderr_to_stdout: true) do
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
    # Replace $VAR and ${VAR} with values from env
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

  alias Kanban.Schemas.{Task, Board, Column}

  @doc """
  Build environment variable map for hook execution.

  ## Options
  - `:agent_name` - Name of the agent
  - `:hook_name` - Name of the hook being executed
  - `:unclaim_reason` - Reason for unclaim (for unclaim hooks)
  """
  def build(%Task{} = task, %Board{} = board, opts \\ []) do
    column = task.column || %Column{}
    agent_name = Keyword.get(opts, :agent_name, "Unknown")
    hook_name = Keyword.get(opts, :hook_name, "unknown")

    base_env = %{
      # Task information
      "TASK_ID" => to_string(task.id),
      "TASK_TITLE" => task.title || "",
      "TASK_DESCRIPTION" => task.description || "",
      "TASK_STATUS" => task.status || "open",
      "TASK_COMPLEXITY" => task.complexity || "medium",
      "TASK_PRIORITY" => to_string(task.priority || 0),
      "TASK_NEEDS_REVIEW" => to_string(task.needs_review || false),

      # Board information
      "BOARD_ID" => to_string(board.id),
      "BOARD_NAME" => board.name || "",

      # Column information
      "COLUMN_ID" => to_string(column.id || ""),
      "COLUMN_NAME" => column.name || "",

      # Agent information
      "AGENT_NAME" => agent_name,

      # Hook context
      "HOOK_NAME" => hook_name,
      "HOOK_TIMEOUT" => to_string(Keyword.get(opts, :timeout, 60))
    }

    # Add optional fields
    base_env
    |> maybe_add_unclaim_reason(Keyword.get(opts, :unclaim_reason))
    |> maybe_add_capabilities(task)
  end

  defp maybe_add_unclaim_reason(env, nil), do: env
  defp maybe_add_unclaim_reason(env, reason) do
    Map.put(env, "UNCLAIM_REASON", reason)
  end

  defp maybe_add_capabilities(env, %Task{required_capabilities: caps}) when is_list(caps) do
    Map.put(env, "AGENT_CAPABILITIES", Enum.join(caps, ","))
  end
  defp maybe_add_capabilities(env, _), do: env
end
```

**Reporter Module:**
```elixir
defmodule Kanban.Hooks.Reporter do
  @moduledoc """
  Reports hook execution results via telemetry and logging.
  """

  require Logger

  def report_success(task, hook_name, result) do
    :telemetry.execute(
      [:kanban, :hook, :executed],
      %{duration_ms: result.duration_ms, exit_code: 0},
      %{
        hook_name: hook_name,
        task_id: task.id,
        success: true
      }
    )

    Logger.info("Hook execution completed: task_id=#{task.id} hook=#{hook_name} duration=#{result.duration_ms}ms exit_code=0")
  end

  def report_failure(task, hook_name, reason) do
    :telemetry.execute(
      [:kanban, :hook, :executed],
      %{duration_ms: 0, exit_code: -1},
      %{
        hook_name: hook_name,
        task_id: task.id,
        success: false,
        reason: inspect(reason)
      }
    )

    Logger.warn("Hook execution failed: task_id=#{task.id} hook=#{hook_name} reason=#{inspect(reason)}")
  end
end
```

**Integration with Tasks Context:**
```elixir
defmodule Kanban.Tasks do
  alias Kanban.Hooks

  def claim_task(task_id, api_token_id, agent_name \\ nil) do
    task = get_task!(task_id) |> Repo.preload([:column])
    board = Repo.preload(task.column, :board).board

    # Execute before_claim hook (blocking)
    with {:ok, _} <- execute_hook_if_enabled(task, board, "before_claim", agent_name, blocking: true),
         {:ok, claimed_task} <- do_claim_task(task, api_token_id) do
      # Execute after_claim hook (non-blocking)
      execute_hook_if_enabled(claimed_task, board, "after_claim", agent_name, blocking: false)

      {:ok, claimed_task}
    end
  end

  def complete_task(%Task{} = task, attrs, agent_name \\ nil) do
    board = Repo.preload(task.column, :board).board

    # Execute before_complete hook (blocking)
    with {:ok, _} <- execute_hook_if_enabled(task, board, "before_complete", agent_name, blocking: true),
         {:ok, completed_task} <- do_complete_task(task, attrs) do
      # Execute after_complete hook (non-blocking)
      execute_hook_if_enabled(completed_task, board, "after_complete", agent_name, blocking: false)

      {:ok, completed_task}
    end
  end

  defp execute_hook_if_enabled(task, board, hook_name, agent_name, opts) do
    if hook_enabled?(board, hook_name) do
      timeout = hook_timeout(board, hook_name)

      Hooks.execute_workflow_hook(task, board,
        agent_name: agent_name,
        hook_name: hook_name,
        blocking: Keyword.get(opts, :blocking, true),
        timeout: timeout
      )
    else
      {:ok, :disabled}
    end
  end

  defp hook_enabled?(board, hook_name) do
    get_in(board.workflow_hooks, [hook_name, "enabled"]) == true
  end

  defp hook_timeout(board, hook_name) do
    get_in(board.workflow_hooks, [hook_name, "timeout"]) || 60
  end

  # ... existing claim and complete implementations ...
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :hook, :executed]` with duration, exit code, success
- [ ] Telemetry event: `[:kanban, :hook, :timeout]` when hook times out
- [ ] Telemetry event: `[:kanban, :hook, :failed]` when hook fails
- [ ] Metrics: Counter of hook executions by name and status
- [ ] Metrics: Histogram of hook execution duration
- [ ] Logging: Info level for successful hooks, warn for failures, error for timeouts

## Error Handling

- User sees: Error message from failed blocking hook
- On failure: Blocking hooks prevent action, non-blocking hooks log error
- Validation: Timeout must be positive, command must be non-empty
- Timeout: Hook process killed after timeout, treated as failure

## Common Pitfalls

- [ ] Don't forget to handle AGENTS.md file not found
- [ ] Remember to substitute environment variables before execution
- [ ] Don't forget to capture both stdout and stderr
- [ ] Remember blocking vs non-blocking behavior differs
- [ ] Don't forget to enforce timeouts on hook execution
- [ ] Remember to sanitize environment variables for security
- [ ] Don't forget to handle hook command with exit code != 0
- [ ] Remember to preload board and column associations

## Dependencies

**Requires:** Task 13 (Hook Configuration)
**Blocks:** None (this completes the hooks feature)

## Out of Scope

- Don't implement UI for editing AGENTS.md (manual editing only)
- Don't add hook marketplace or templates
- Don't implement conditional hooks
- Don't add remote hook execution
- Don't implement hook versioning
