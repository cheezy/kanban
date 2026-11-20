defmodule Kanban.Tasks.AfterGoalAttempt do
  @moduledoc """
  Reads a goal's last `after_goal` attempt for the Stride app (W2761,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.10, §7.10, decision 9).

  The last attempt is the goal's `after_goal_result`, the latest report an
  agent made (`Kanban.Tasks.report_after_goal/2`); every earlier one stays in
  `after_goal_attempts` and is not read here.

  Only the exit code, the duration and the time of the report are read. The
  hook's output is never read: decision 9 shows it on the phone only where the
  web goal page shows it, and no web page shows it, because it can hold
  secrets or internal paths. A value of the wrong type reads as `nil` rather
  than reaching the app.

  A goal's hook has failed when the goal still waits on `after_goal`
  (`after_goal_status: :pending`) and its last attempt has an exit code other
  than `0`, a missing or non-integer one included. That is the rule
  `Kanban.Tasks.report_after_goal/2` uses to decide an attempt failed, and the
  rule the decision list's `hook_failed` items use
  (`Kanban.Decisions.Sources.hook_failed/1`).
  """

  alias Kanban.Tasks.Task

  @type t :: %{
          status: :pending | :succeeded | nil,
          exit_code: integer() | nil,
          duration_ms: integer() | nil,
          reported_at: DateTime.t() | nil,
          failed: boolean()
        }

  @doc """
  The goal's last `after_goal` attempt as `t:t/0`. A goal no agent has
  reported an attempt for has `nil` for the exit code, the duration and the
  report time, and `failed: false`.
  """
  @spec last(Task.t()) :: t()
  def last(%Task{after_goal_status: status, after_goal_result: result} = goal) do
    attempt = attempt_map(result)

    %{
      status: status,
      exit_code: integer_or_nil(attempt["exit_code"]),
      duration_ms: integer_or_nil(attempt["duration_ms"]),
      reported_at: reported_at(attempt["reported_at"]),
      failed: failed?(goal)
    }
  end

  @doc """
  Whether the goal's hook has failed: it still waits on `after_goal` and its
  last attempt's exit code is not `0`.
  """
  @spec failed?(Task.t()) :: boolean()
  def failed?(%Task{after_goal_status: :pending, after_goal_result: %{} = result}),
    do: Map.get(result, "exit_code") !== 0

  def failed?(%Task{}), do: false

  defp attempt_map(%{} = result), do: result
  defp attempt_map(_result), do: %{}

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp reported_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp reported_at(_at), do: nil
end
