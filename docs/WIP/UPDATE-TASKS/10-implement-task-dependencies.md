# Implement Task Dependencies and Blocking Logic

**Complexity:** Large | **Est. Files:** 5-7

## Description

**WHY:** Tasks often depend on other tasks being completed first. Need robust dependency management to prevent AI agents from starting blocked tasks and to automatically unblock tasks when their dependencies complete.

**WHAT:** Implement dependency graph validation, circular dependency detection, automatic task unblocking on completion, and dependency visualization helpers.

**WHERE:** Tasks context, database constraints, API

## Acceptance Criteria

- [ ] Can add dependencies when creating/updating tasks
- [ ] Circular dependency detection prevents invalid relationships
- [ ] Task status auto-updates to "blocked" if dependencies incomplete
- [ ] Task auto-unblocks when all dependencies complete
- [ ] GET /api/tasks/:id/dependencies returns dependency tree
- [ ] GET /api/tasks/:id/dependents returns tasks blocked by this task
- [ ] Validation prevents deleting tasks with dependents
- [ ] Database constraints ensure referential integrity
- [ ] Tests cover circular deps, auto-unblocking, and edge cases

## Key Files to Read First

- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - Dependencies and blocks arrays
- [lib/kanban/tasks.ex](lib/kanban/tasks.ex) - Add dependency management functions
- [lib/kanban_web/controllers/api/task_controller.ex](lib/kanban_web/controllers/api/task_controller.ex) - Add dependency endpoints
- [docs/WIP/AI-WORKFLOW.md](docs/WIP/AI-WORKFLOW.md) - Dependency handling (lines 172-209)
- [priv/repo/migrations/XXXXXX_add_task_metadata.exs](priv/repo/migrations) - Check dependencies array field

## Technical Notes

**Patterns to Follow:**
- Use PostgreSQL array field for dependencies (already exists from task 02)
- Implement graph traversal for circular dependency detection
- Use database triggers or Ecto callbacks for auto-blocking
- Broadcast PubSub events when tasks unblock

**Database/Schema:**
- Tables: tasks (use existing dependencies and blocks arrays)
- Migrations needed: Maybe - add check constraint for no self-dependencies
- Constraint to add:
  ```sql
  ALTER TABLE tasks
  ADD CONSTRAINT no_self_dependency
  CHECK (NOT (id = ANY(dependencies)));
  ```

**Dependency Logic:**
- When task created/updated with dependencies:
  1. Validate all dependency IDs exist
  2. Check for circular dependencies
  3. Set status to "blocked" if any dependency incomplete
- When task completed:
  1. Find all tasks that depend on this task
  2. For each dependent, check if all ITS dependencies now complete
  3. If yes, update status from "blocked" to "open"
  4. Broadcast unblock event

**Integration Points:**
- [ ] PubSub broadcasts: Broadcast when tasks blocked/unblocked
- [ ] Phoenix Channels: Update UI in real-time
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Run tests
mix test test/kanban/tasks_test.exs
mix test test/kanban/tasks/dependency_test.exs

# Test in console
iex -S mix
alias Kanban.{Repo, Tasks}

# Create dependency chain: A -> B -> C
{:ok, task_a} = Tasks.create_task(%{title: "Task A", status: "open"})
{:ok, task_b} = Tasks.create_task(%{title: "Task B", dependencies: [task_a.id]})
{:ok, task_c} = Tasks.create_task(%{title: "Task C", dependencies: [task_b.id]})

# Verify B and C are blocked
task_b = Repo.reload(task_b)
IO.inspect(task_b.status, label: "Task B status (should be blocked)")

# Complete A
Tasks.complete_task(task_a, %{
  completed_by: "user:1",
  completion_summary: %{files_changed: [], verification_results: %{status: "passed"}}
})

# Verify B unblocked, C still blocked
task_b = Repo.reload(task_b)
task_c = Repo.reload(task_c)
IO.inspect(task_b.status, label: "Task B after A completed (should be open)")
IO.inspect(task_c.status, label: "Task C status (should still be blocked)")

# Test circular dependency detection
{:error, changeset} = Tasks.create_task(%{
  title: "Task D",
  dependencies: [task_b.id]
})
# Then try to add D to B's dependencies - should fail

# Test API
export TOKEN="kan_dev_your_token_here"

# Get dependencies
curl http://localhost:4000/api/tasks/2/dependencies \
  -H "Authorization: Bearer $TOKEN"

# Get dependents
curl http://localhost:4000/api/tasks/1/dependents \
  -H "Authorization: Bearer $TOKEN"

# Run all checks
mix precommit
```

**Manual Testing:**
1. Create task A with no dependencies
2. Create task B depending on A
3. Verify B status is "blocked"
4. Complete task A
5. Verify B status auto-updates to "open"
6. Try to create circular dependency A->B->A
7. Verify validation error
8. Try to delete task A (has dependent B)
9. Verify prevented or warning shown
10. Check dependency tree endpoint returns correct graph

**Success Looks Like:**
- Dependencies create blocked status automatically
- Completing task unblocks dependents
- Circular dependencies detected and prevented
- Cannot delete tasks with dependents
- Dependency graph queryable via API
- All tests pass
- PubSub broadcasts work

## Data Examples

**Dependency Management Functions:**
```elixir
defmodule Kanban.Tasks do
  import Ecto.Query
  alias Kanban.Repo
  alias Kanban.Schemas.Task

  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> validate_dependencies()
    |> maybe_set_blocked_status()
    |> Repo.insert()
  end

  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> validate_dependencies()
    |> maybe_set_blocked_status()
    |> Repo.update()
  end

  defp validate_dependencies(changeset) do
    case get_change(changeset, :dependencies) do
      nil ->
        changeset

      deps when is_list(deps) ->
        changeset
        |> validate_dependencies_exist(deps)
        |> validate_no_circular_dependencies(deps)

      _ ->
        add_error(changeset, :dependencies, "must be a list of task IDs")
    end
  end

  defp validate_dependencies_exist(changeset, dep_ids) do
    existing_count =
      from(t in Task, where: t.id in ^dep_ids, select: count(t.id))
      |> Repo.one()

    if existing_count == length(dep_ids) do
      changeset
    else
      add_error(changeset, :dependencies, "some dependency IDs do not exist")
    end
  end

  defp validate_no_circular_dependencies(changeset, new_deps) do
    task_id = get_field(changeset, :id)

    if task_id && has_circular_dependency?(task_id, new_deps) do
      add_error(changeset, :dependencies, "circular dependency detected")
    else
      changeset
    end
  end

  defp has_circular_dependency?(task_id, dep_ids, visited \\ MapSet.new()) do
    if task_id in dep_ids do
      true
    else
      visited = MapSet.put(visited, task_id)

      Enum.any?(dep_ids, fn dep_id ->
        if MapSet.member?(visited, dep_id) do
          false
        else
          task = Repo.get(Task, dep_id)

          if task && task.dependencies do
            has_circular_dependency?(task_id, task.dependencies, visited)
          else
            false
          end
        end
      end)
    end
  end

  defp maybe_set_blocked_status(changeset) do
    deps = get_field(changeset, :dependencies) || []

    if Enum.empty?(deps) do
      changeset
    else
      # Check if all dependencies are completed
      completed_count =
        from(t in Task,
          where: t.id in ^deps and t.status == "completed",
          select: count(t.id)
        )
        |> Repo.one()

      if completed_count == length(deps) do
        # All deps complete, don't block
        changeset
      else
        # Some deps incomplete, set to blocked
        put_change(changeset, :status, "blocked")
      end
    end
  end

  def complete_task(%Task{} = task, attrs) do
    # ... existing completion logic ...

    case Repo.update(changeset) do
      {:ok, completed_task} = result ->
        # Unblock dependent tasks
        unblock_dependent_tasks(completed_task.id)

        # ... existing broadcast logic ...
        result

      error ->
        error
    end
  end

  defp unblock_dependent_tasks(completed_task_id) do
    # Find all tasks that depend on this one
    dependent_tasks =
      from(t in Task,
        where: ^completed_task_id in t.dependencies,
        where: t.status == "blocked"
      )
      |> Repo.all()

    Enum.each(dependent_tasks, fn task ->
      # Check if ALL dependencies are now complete
      all_deps_complete? =
        from(t in Task,
          where: t.id in ^task.dependencies,
          where: t.status != "completed"
        )
        |> Repo.aggregate(:count) == 0

      if all_deps_complete? do
        {:ok, unblocked_task} =
          task
          |> Ecto.Changeset.change(status: "open")
          |> Repo.update()

        :telemetry.execute(
          [:kanban, :task, :unblocked],
          %{task_id: unblocked_task.id},
          %{unblocked_by: completed_task_id}
        )

        Phoenix.PubSub.broadcast(
          Kanban.PubSub,
          "board:#{unblocked_task.column.board_id}",
          {:task_unblocked, unblocked_task}
        )
      end
    end)
  end

  def get_task_dependencies(task_id) do
    task = Repo.get!(Task, task_id)

    if task.dependencies && length(task.dependencies) > 0 do
      from(t in Task, where: t.id in ^task.dependencies)
      |> Repo.all()
      |> Repo.preload([:key_files, :verification_steps])
    else
      []
    end
  end

  def get_task_dependents(task_id) do
    from(t in Task, where: ^task_id in t.dependencies)
    |> Repo.all()
    |> Repo.preload([:key_files, :verification_steps])
  end

  def delete_task(%Task{} = task) do
    # Check for dependents
    dependents_count =
      from(t in Task, where: ^task.id in t.dependencies)
      |> Repo.aggregate(:count)

    if dependents_count > 0 do
      {:error, :has_dependents}
    else
      Repo.delete(task)
    end
  end
end
```

**API Controller Actions:**
```elixir
defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller
  alias Kanban.Tasks

  def dependencies(conn, %{"id" => id}) do
    if has_scope?(conn, "tasks:read") do
      dependencies = Tasks.get_task_dependencies(id)
      render(conn, "index.json", tasks: dependencies)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end

  def dependents(conn, %{"id" => id}) do
    if has_scope?(conn, "tasks:read") do
      dependents = Tasks.get_task_dependents(id)
      render(conn, "index.json", tasks: dependents)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end

  def delete(conn, %{"id" => id}) do
    if has_scope?(conn, "tasks:delete") do
      task = Tasks.get_task!(id)

      case Tasks.delete_task(task) do
        {:ok, _task} ->
          send_resp(conn, :no_content, "")

        {:error, :has_dependents} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Cannot delete task with dependent tasks"})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render("error.json", changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Insufficient permissions"})
    end
  end

  defp has_scope?(conn, required_scope) do
    api_token = conn.assigns[:api_token]
    required_scope in api_token.scopes
  end
end
```

**Router Update:**
```elixir
scope "/api", KanbanWeb.API do
  pipe_through :api

  resources "/tasks", TaskController, only: [:index, :show, :create, :update, :delete]
  get "/tasks/ready", TaskController, :ready
  patch "/tasks/:id/complete", TaskController, :complete
  get "/tasks/:id/dependencies", TaskController, :dependencies
  get "/tasks/:id/dependents", TaskController, :dependents
end
```

**Migration for Constraint:**
```elixir
defmodule Kanban.Repo.Migrations.AddDependencyConstraints do
  use Ecto.Migration

  def change do
    # Prevent self-dependencies
    execute(
      "ALTER TABLE tasks ADD CONSTRAINT no_self_dependency CHECK (NOT (id = ANY(dependencies)))",
      "ALTER TABLE tasks DROP CONSTRAINT no_self_dependency"
    )

    # Optionally add index for performance
    create index(:tasks, [:dependencies], using: :gin)
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :task, :blocked]`
- [ ] Telemetry event: `[:kanban, :task, :unblocked]`
- [ ] Telemetry event: `[:kanban, :task, :circular_dependency_detected]`
- [ ] Metrics: Gauge of currently blocked tasks
- [ ] Metrics: Counter of dependency validation failures
- [ ] Logging: Log task blocking/unblocking at info level

## Error Handling

- User sees: Clear error if circular dependency detected
- User sees: Error if trying to delete task with dependents
- On failure: Task creation/update fails, no partial state
- Validation:
  - All dependency IDs must exist
  - No circular dependencies
  - No self-dependencies

## Common Pitfalls

- [ ] Don't forget to check ALL dependencies complete before unblocking
- [ ] Remember to broadcast PubSub when tasks unblock
- [ ] Avoid infinite loops in circular dependency detection (use visited set)
- [ ] Don't forget to handle empty dependencies array vs nil
- [ ] Remember to preload associations in dependency queries
- [ ] Avoid N+1 queries when checking multiple dependencies
- [ ] Don't forget database constraint for no self-dependencies
- [ ] Remember to update blocks array when dependencies added (denormalization)

## Dependencies

**Requires:** 02-add-task-metadata-fields.md, 04-implement-task-crud-api.md, 06-add-task-completion-tracking.md
**Blocks:** 08-display-rich-task-details.md

## Out of Scope

- Don't implement dependency visualization graph UI yet
- Don't add "soft" vs "hard" dependencies
- Don't implement dependency priority ordering
- Don't add automatic dependency suggestion
- Future enhancement: Add dependency graph visualization with D3.js
- Future enhancement: Add "blocker" field to track WHY a task is blocked
