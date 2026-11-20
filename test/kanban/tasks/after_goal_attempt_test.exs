defmodule Kanban.Tasks.AfterGoalAttemptTest do
  @moduledoc "Tests for `Kanban.Tasks.AfterGoalAttempt` (W2761): a goal's last after_goal attempt."
  use ExUnit.Case, async: true

  alias Kanban.Tasks.AfterGoalAttempt
  alias Kanban.Tasks.Task

  defp goal(status, result),
    do: %Task{type: :goal, after_goal_status: status, after_goal_result: result}

  describe "last/1" do
    test "reads the exit code, duration and report time, never the output" do
      result = %{
        "exit_code" => 1,
        "output" => "secret output",
        "duration_ms" => 4000,
        "reported_at" => "2026-11-18T10:00:00Z"
      }

      last = :pending |> goal(result) |> AfterGoalAttempt.last()

      assert last == %{
               status: :pending,
               exit_code: 1,
               duration_ms: 4000,
               reported_at: ~U[2026-11-18 10:00:00Z],
               failed: true
             }

      refute last |> Map.values() |> Enum.any?(&(&1 == "secret output"))
    end

    test "a goal with no attempt has nil fields and has not failed" do
      assert nil |> goal(nil) |> AfterGoalAttempt.last() == %{
               status: nil,
               exit_code: nil,
               duration_ms: nil,
               reported_at: nil,
               failed: false
             }

      assert %{status: :pending, exit_code: nil, failed: false} =
               :pending |> goal(nil) |> AfterGoalAttempt.last()
    end

    test "a value of the wrong type reads as nil" do
      result = %{"exit_code" => "1", "duration_ms" => 1.5, "reported_at" => "yesterday"}

      assert %{exit_code: nil, duration_ms: nil, reported_at: nil, failed: true} =
               :pending |> goal(result) |> AfterGoalAttempt.last()

      assert %{reported_at: nil} =
               :pending |> goal(%{"reported_at" => 5}) |> AfterGoalAttempt.last()
    end
  end

  describe "failed?/1" do
    test "a pending goal whose last exit code is not 0 has failed" do
      assert :pending |> goal(%{"exit_code" => 2}) |> AfterGoalAttempt.failed?()
      assert :pending |> goal(%{"output" => "no exit code"}) |> AfterGoalAttempt.failed?()
    end

    test "an exit code of 0, a succeeded goal or no attempt has not failed" do
      refute :pending |> goal(%{"exit_code" => 0}) |> AfterGoalAttempt.failed?()
      refute :succeeded |> goal(%{"exit_code" => 1}) |> AfterGoalAttempt.failed?()
      refute :pending |> goal(nil) |> AfterGoalAttempt.failed?()
      refute nil |> goal(nil) |> AfterGoalAttempt.failed?()
    end
  end
end
