defmodule Kanban.Tasks do
  @moduledoc """
  The Tasks context.

  Thin facade that delegates to focused submodules:
  - `Tasks.Queries` - Read-only task queries
  - `Tasks.Creation` - Task and goal creation
  - `Tasks.Lifecycle` - Update, delete, archive, unarchive
  - `Tasks.Positioning` - Movement, reordering, WIP limits
  - `Tasks.Dependencies` - Blocking, circular deps, dependency tree
  - `Tasks.Goals` - Goal hierarchy, promotion, parent tracking
  - `Tasks.AgentQueries` - Agent task discovery queries
  - `Tasks.AgentWorkflow` - Agent claim, complete, review, unclaim
  - `Tasks.Broadcaster` - PubSub broadcasting
  - `Tasks.Identifiers` - Identifier generation
  - `Tasks.History` - Move/priority/assignment history
  """

  alias Kanban.Tasks.AgentQueries
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Creation
  alias Kanban.Tasks.Dependencies
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.Lifecycle
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries

  # ── Query delegations ──────────────────────────────────────────────

  def list_tasks(column, opts \\ []), do: Queries.list_tasks(column, opts)

  defdelegate list_archived_tasks(column), to: Queries
  defdelegate list_archived_tasks_for_board(board_id), to: Queries
  defdelegate get_task!(id), to: Queries
  defdelegate get_task_with_history!(id), to: Queries
  defdelegate get_task_for_view!(id), to: Queries
  defdelegate get_task_for_view(id), to: Queries
  defdelegate get_task_by_identifier_for_view!(identifier, column_ids), to: Queries

  # ── Creation delegations ───────────────────────────────────────────

  def create_task(column, attrs \\ %{}), do: Creation.create_task(column, attrs)

  def create_goal_with_tasks(column, goal_attrs, child_tasks_attrs \\ []),
    do: Creation.create_goal_with_tasks(column, goal_attrs, child_tasks_attrs)

  # ── Lifecycle delegations ──────────────────────────────────────────

  defdelegate update_task(task, attrs), to: Lifecycle
  defdelegate delete_task(task), to: Lifecycle
  defdelegate archive_task(task), to: Lifecycle
  defdelegate unarchive_task(task), to: Lifecycle

  # ── Positioning delegations ────────────────────────────────────────

  defdelegate move_task(task, new_column, new_position), to: Positioning
  defdelegate reorder_tasks(column, task_ids), to: Positioning
  defdelegate can_add_task?(column), to: Positioning

  # ── Dependency delegations ─────────────────────────────────────────

  defdelegate update_task_blocking_status(task), to: Dependencies
  defdelegate unblock_dependent_tasks(completed_task_identifier, board_id), to: Dependencies
  defdelegate validate_circular_dependencies(changeset), to: Dependencies
  defdelegate get_dependency_tree(task), to: Dependencies
  defdelegate get_dependent_tasks(task), to: Dependencies

  # ── Goal delegations ───────────────────────────────────────────────

  defdelegate get_task_tree(task_id), to: Goals
  defdelegate get_task_children(parent_task_id), to: Goals
  defdelegate promote_goal_to_ready(goal, board_id), to: Goals
  defdelegate update_parent_goal_position(moving_task, old_column_id, new_column_id), to: Goals

  # ── Agent query delegations ────────────────────────────────────────

  defdelegate get_tasks_modifying_file(file_path), to: AgentQueries
  defdelegate get_tasks_requiring_technology(tech), to: AgentQueries
  defdelegate get_tasks_with_automated_verification(), to: AgentQueries

  def get_next_task(agent_capabilities \\ [], board_id),
    do: AgentQueries.get_next_task(agent_capabilities, board_id)

  # ── Agent workflow delegations ─────────────────────────────────────

  def claim_next_task(
        agent_capabilities \\ [],
        user,
        board_id,
        task_identifier \\ nil,
        agent_name \\ "Unknown"
      ),
      do:
        AgentWorkflow.claim_next_task(
          agent_capabilities,
          user,
          board_id,
          task_identifier,
          agent_name
        )

  def unclaim_task(task, user, reason \\ nil),
    do: AgentWorkflow.unclaim_task(task, user, reason)

  def complete_task(task, user, params, agent_name \\ "Unknown"),
    do: AgentWorkflow.complete_task(task, user, params, agent_name)

  defdelegate mark_reviewed(task, user), to: AgentWorkflow
  defdelegate mark_done(task, user), to: AgentWorkflow
end
