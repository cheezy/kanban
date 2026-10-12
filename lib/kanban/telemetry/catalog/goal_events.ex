defmodule Kanban.Telemetry.Catalog.GoalEvents do
  @moduledoc """
  The goal, dependency and after_goal events in `Kanban.Telemetry.Catalog`.

  These events are emitted by `Kanban.Tasks.GoalTelemetry` once the change
  they report has been committed, so a refused, invalid or rolled-back change
  emits nothing. `[:kanban, :goal, :completed]` is emitted once per goal: when
  the last child's completion first flips the goal's `after_goal_status` from
  `nil` to `:pending`.

  Metadata carries ids, enum-like atoms and counts only. Task titles and
  descriptions, and the output of a project's after_goal hook, are never sent:
  a hook can print anything, including secrets, so a failed after_goal carries
  only its exit code and duration. `Kanban.Telemetry.Catalog` appends these
  entries to its own list; nothing else should call this module.
  """

  @intervention_measurements [:count, :moved_count, :skipped_count]

  @events [
    %{
      name: [:kanban, :task, :unblocked],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id],
      description:
        "A blocked task became unblocked because the last of its dependencies was completed.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :completed],
      kind: :event,
      domain: :goal,
      measurements: [:count],
      metadata: [:goal_id, :board_id],
      description:
        "The last child of a goal was completed. Emitted once per goal, after the completion commits.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :promoted_to_ready],
      kind: :event,
      domain: :goal,
      measurements: [:count, :task_count],
      metadata: [:goal_id, :board_id],
      description:
        "A goal and its Backlog children were moved to Ready. task_count is the number of tasks moved.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :after_goal_succeeded],
      kind: :event,
      domain: :goal,
      measurements: [:count, :duration_ms],
      metadata: [:goal_id, :board_id, :source],
      description:
        "A goal's after_goal hook succeeded and the goal moved to Done. source is :agent for an agent report or :grace_worker when the grace window expired; duration_ms is the agent's reported run time.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :after_goal_failed],
      kind: :event,
      domain: :goal,
      measurements: [:count, :duration_ms],
      metadata: [:goal_id, :board_id, :exit_code],
      description:
        "An agent reported a failed after_goal hook. Only the exit code and duration are sent, never the hook's output.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :grace_window_scheduled],
      kind: :event,
      domain: :goal,
      measurements: [:count, :grace_window_ms],
      metadata: [:goal_id, :board_id],
      description:
        "The after_goal grace window was scheduled for a goal whose last child completed.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :grace_window_expired],
      kind: :event,
      domain: :goal,
      measurements: [:count],
      metadata: [:goal_id, :board_id],
      description:
        "The after_goal grace window expired with no agent report, and the grace worker moved the goal to Done.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :reassigned],
      kind: :event,
      domain: :goal,
      measurements: @intervention_measurements,
      metadata: [:goal_id, :board_id, :actor_user_id, :assigned_to_id],
      description:
        "A goal and its unstarted children were reassigned. moved_count counts the children moved and skipped_count the claimed children left alone.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :reprioritized],
      kind: :event,
      domain: :goal,
      measurements: @intervention_measurements,
      metadata: [:goal_id, :board_id, :actor_user_id, :priority],
      description:
        "A goal and its unstarted children were given a new priority. moved_count counts the children changed and skipped_count the claimed children left alone.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :reassignment_undone],
      kind: :event,
      domain: :goal,
      measurements: @intervention_measurements,
      metadata: [:goal_id, :board_id, :actor_user_id],
      description:
        "A goal reassignment was undone. moved_count counts the children restored and skipped_count those that could no longer be restored.",
      legacy: false
    },
    %{
      name: [:kanban, :goal, :reprioritization_undone],
      kind: :event,
      domain: :goal,
      measurements: @intervention_measurements,
      metadata: [:goal_id, :board_id, :actor_user_id],
      description:
        "A goal reprioritization was undone. moved_count counts the children restored and skipped_count those that could no longer be restored.",
      legacy: false
    }
  ]

  @doc """
  Returns the goal, dependency and after_goal entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
