defmodule Kanban.AfterGoalTest do
  use Kanban.DataCase, async: false

  alias Kanban.AfterGoal
  alias Kanban.AfterGoal.GraceWorker
  alias Kanban.Tasks.Task

  describe "grace_window_ms/0" do
    setup do
      original = Application.get_env(:kanban, :after_goal_grace_window_ms)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:kanban, :after_goal_grace_window_ms)
        else
          Application.put_env(:kanban, :after_goal_grace_window_ms, original)
        end
      end)

      :ok
    end

    test "returns the configured value when set" do
      Application.put_env(:kanban, :after_goal_grace_window_ms, 1234)
      assert AfterGoal.grace_window_ms() == 1234
    end

    test "defaults to 500ms when no value is configured" do
      Application.delete_env(:kanban, :after_goal_grace_window_ms)
      assert AfterGoal.grace_window_ms() == 500
    end
  end

  describe "schedule_grace_window/1" do
    test "schedules a GraceWorker job at now + grace_window_ms with millisecond precision" do
      goal = %Task{id: 42, type: :goal}
      before = DateTime.utc_now()

      assert {:ok, %Oban.Job{} = job} = AfterGoal.schedule_grace_window(goal)

      after_call = DateTime.utc_now()

      assert job.worker == inspect(GraceWorker)
      assert job.args == %{goal_id: 42}
      assert job.queue == "after_goal_grace"

      window_ms = AfterGoal.grace_window_ms()
      expected_min = DateTime.add(before, window_ms, :millisecond)
      expected_max = DateTime.add(after_call, window_ms + 50, :millisecond)

      assert DateTime.compare(job.scheduled_at, expected_min) in [:eq, :gt]
      assert DateTime.compare(job.scheduled_at, expected_max) in [:eq, :lt]
    end
  end
end
