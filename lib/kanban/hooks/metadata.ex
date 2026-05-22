defmodule Kanban.Hooks.Metadata do
  @moduledoc """
  Hook metadata builder for completion and mark_reviewed responses.

  Wraps `Kanban.Hooks.get_hook_info/4` to assemble the ordered list of
  hooks attached to a `/complete` or `/mark_reviewed` response. The
  builder is the single point at which `after_goal` is conditionally
  appended — when the caller signals that this completion finished the
  parent goal's final open child, the response carries an extra
  `after_goal` entry alongside the existing hooks; otherwise the
  response is byte-identical to the pre-`after_goal` shape.

  This module owns the response-shape contract for G113's after_goal
  protocol. Detection of "last child" is owned by
  `Kanban.Tasks.GoalCompletion` (W490); endpoint wiring is owned by
  W491 (completion) and W492 (mark_reviewed); the goal Done transition
  is gated on the agent's after_goal exit code by W493.

  ## Field shape

  Every hook entry has the same shape regardless of name —
  `name`, `timeout`, `blocking`, `env`, `execute_before`,
  `execute_after`, `description`. `after_goal` is no exception; older
  agents that parse the existing four hooks by name simply skip the
  unrecognized fifth entry.
  """

  alias Kanban.Boards.Board
  alias Kanban.Hooks
  alias Kanban.Tasks.Task

  @doc """
  Build the ordered hooks list for a `/complete` response.

  When `needs_review?: true`, the base list is
  `[after_doing, before_review]` — review-bound completions delay
  `after_review` until the human reviewer approves. Otherwise the base
  list is `[after_doing, before_review, after_review]` — auto-done
  completions ship all three transition hooks in one response.

  When `last_child?: true` an additional `after_goal` entry is appended
  to the base list. Otherwise the base list is returned unchanged.

  ## Options

    * `:needs_review?` (boolean, default `false`) — whether the
      completed child task is going to the Review column instead of
      directly to Done.
    * `:last_child?` (boolean, default `false`) — whether this
      completion finished the parent goal's final open child (per the
      transactional check in `Kanban.Tasks.finalize_child_and_check_goal_complete/2`).
  """
  @spec build_completion_hooks(Task.t(), Board.t(), String.t(), keyword()) :: [map()]
  def build_completion_hooks(%Task{} = task, %Board{} = board, agent_name, opts \\ []) do
    needs_review? = Keyword.get(opts, :needs_review?, false)
    last_child? = Keyword.get(opts, :last_child?, false)

    task
    |> base_completion_hooks(board, agent_name, needs_review?)
    |> maybe_append_after_goal(task, board, agent_name, last_child?)
  end

  @doc """
  Build the ordered hooks list for a `/mark_reviewed` response.

  Base shape is `[after_review]`. When `last_child?: true`, the
  `after_goal` entry is appended.
  """
  @spec build_mark_reviewed_hooks(Task.t(), Board.t(), String.t(), keyword()) :: [map()]
  def build_mark_reviewed_hooks(%Task{} = task, %Board{} = board, agent_name, opts \\ []) do
    last_child? = Keyword.get(opts, :last_child?, false)

    {:ok, after_review} = Hooks.get_hook_info(task, board, "after_review", agent_name)

    [after_review]
    |> maybe_append_after_goal(task, board, agent_name, last_child?)
  end

  defp base_completion_hooks(task, board, agent_name, needs_review?) do
    {:ok, after_doing} = Hooks.get_hook_info(task, board, "after_doing", agent_name)
    {:ok, before_review} = Hooks.get_hook_info(task, board, "before_review", agent_name)

    if needs_review? do
      [after_doing, before_review]
    else
      {:ok, after_review} = Hooks.get_hook_info(task, board, "after_review", agent_name)
      [after_doing, before_review, after_review]
    end
  end

  defp maybe_append_after_goal(hooks, _task, _board, _agent_name, false), do: hooks

  defp maybe_append_after_goal(hooks, task, board, agent_name, true) do
    {:ok, after_goal} = Hooks.get_hook_info(task, board, "after_goal", agent_name)

    # Telemetry: emitted only on real last-child deliveries through the
    # /complete and /mark_reviewed response paths. The grace-worker
    # back-compat promotion bypasses this module entirely (it calls
    # Goals.mark_after_goal_succeeded_and_promote/2 directly), so the
    # "do not count the empty no-op" pitfall is satisfied structurally.
    # `project_id` is aliased to `board.id` — the codebase has no separate
    # `project_id` field; `Board` is the project-equivalent schema. Both
    # keys are emitted so downstream consumers expecting either terminology
    # resolve to the same value.
    :telemetry.execute(
      [:kanban, :api, :after_goal_delivered],
      %{count: 1},
      %{goal_id: task.parent_id, board_id: board.id, project_id: board.id}
    )

    hooks ++ [after_goal]
  end
end
