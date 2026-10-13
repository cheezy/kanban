defmodule Kanban.Tasks.TaskTelemetryTest do
  use ExUnit.Case, async: true

  import Kanban.TelemetryHelpers

  alias Kanban.Columns.Column
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskTelemetry
  alias Kanban.Telemetry.AfterCommit

  @task %Task{id: 7, identifier: "W7", time_spent_minutes: 20}

  test "archived carries the task id in metadata and merges via and goal_id" do
    attach_telemetry([:kanban, :task, :archived])

    :ok = TaskTelemetry.archived(@task)
    :ok = TaskTelemetry.archived(@task, %{via: :goal_cascade, goal_id: 3})

    assert_receive {:telemetry_event, _event, %{count: 1}, %{task_id: 7, identifier: "W7"} = md}
    refute Map.has_key?(md, :via)

    assert_receive {:telemetry_event, _event, %{count: 1},
                    %{task_id: 7, identifier: "W7", via: :goal_cascade, goal_id: 3}}
  end

  test "unarchived carries the task id in metadata" do
    attach_telemetry([:kanban, :task, :unarchived])

    :ok = TaskTelemetry.unarchived(@task)

    assert_receive {:telemetry_event, _event, %{count: 1}, %{task_id: 7, identifier: "W7"}}
  end

  test "completed carries the task id and user in metadata" do
    attach_telemetry([:kanban, :task, :completed])

    :ok = TaskTelemetry.completed(@task, 2)

    assert_receive {:telemetry_event, _event, measurements, %{task_id: 7, completed_by: 2}}
    assert measurements == %{count: 1}
  end

  describe "completed under AfterCommit.after_commit/1" do
    test "is held until the function returns {:ok, _}, then emitted once unchanged" do
      attach_telemetry([:kanban, :task, :completed])
      test_pid = self()

      result =
        AfterCommit.after_commit(fn ->
          :ok = TaskTelemetry.completed(@task, 2)
          send(test_pid, :inside_done)
          {:ok, :committed}
        end)

      assert result == {:ok, :committed}

      assert {:messages, [:inside_done, {:telemetry_event, [:kanban, :task, :completed], _, _}]} =
               Process.info(self(), :messages)

      assert_received {:telemetry_event, [:kanban, :task, :completed], measurements, metadata}

      assert measurements == %{count: 1}
      assert metadata == %{task_id: 7, completed_by: 2}
      refute_received {:telemetry_event, _, _, _}
    end

    test "is dropped when the function does not commit" do
      attach_telemetry([:kanban, :task, :completed])

      assert {:error, :rolled_back} =
               AfterCommit.after_commit(fn ->
                 TaskTelemetry.completed(@task, 2)
                 {:error, :rolled_back}
               end)

      refute_received {:telemetry_event, _, _, _}
    end
  end

  test "moved_to_review measures an integer time_spent_minutes" do
    attach_telemetry([:kanban, :task, :moved_to_review])

    :ok = TaskTelemetry.moved_to_review(@task, 2)
    :ok = TaskTelemetry.moved_to_review(%{@task | time_spent_minutes: "20"}, 2)

    assert_receive {:telemetry_event, _event, %{count: 1, time_spent_minutes: 20}, _md}
    assert_receive {:telemetry_event, _event, measurements, %{task_id: 7, completed_by_id: 2}}
    assert measurements == %{count: 1}
  end

  test "returned_to_doing carries the task id, reviewer and review status" do
    attach_telemetry([:kanban, :task, :returned_to_doing])

    :ok = TaskTelemetry.returned_to_doing(@task, 2, :rejected)

    assert_receive {:telemetry_event, _event, %{count: 1},
                    %{task_id: 7, reviewed_by: 2, review_status: :rejected}}
  end

  describe "task activity emitters" do
    @task_events [
      [:kanban, :task, :updated],
      [:kanban, :task, :reordered],
      [:kanban, :task, :claimed],
      [:kanban, :task, :review_approved],
      [:kanban, :task, :review_changes_requested],
      [:kanban, :task, :comment_created]
    ]

    @placed %Task{id: 7, column_id: 3, column: %Column{id: 3, board_id: 9}}

    test "functions that take a result return an error unchanged and emit nothing" do
      attach_telemetry(@task_events)
      error = {:error, :boom}
      changeset = Ecto.Changeset.change(@placed, %{priority: :high})

      assert TaskTelemetry.updated(error, changeset, :ui, nil) == error
      assert TaskTelemetry.column_reordered(error, %Column{id: 3, board_id: 9}, [1]) == error
      assert TaskTelemetry.claimed(error, 1, 9) == error
      assert TaskTelemetry.reviewed(error, :approved, %{id: 1}) == error
      assert TaskTelemetry.reviewed(error, :changes_requested, %{id: 1}) == error
      assert TaskTelemetry.comment_created(error, 9) == error

      refute_receive {:telemetry_event, _, _, _}
    end

    test "updated returns a saved result unchanged and skips an empty change" do
      attach_telemetry([:kanban, :task, :updated])
      result = {:ok, @placed}

      assert TaskTelemetry.updated(result, Ecto.Changeset.change(@placed), :api, nil) == result
      refute_receive {:telemetry_event, _, _, _}

      changeset = Ecto.Changeset.change(@placed, %{priority: :high})
      assert TaskTelemetry.updated(result, changeset, :api, nil) == result

      assert_receive {:telemetry_event, _, %{count: 1},
                      %{task_id: 7, board_id: 9, fields: [:priority], source: :api}}
    end

    test "a task with no column sends a nil board id" do
      attach_telemetry([:kanban, :task, :deleted])

      :ok = TaskTelemetry.deleted(%Task{id: 7, column_id: nil})

      assert_receive {:telemetry_event, _, %{count: 1}, %{task_id: 7, board_id: nil}}
    end

    test "comment_created reports a human comment as by_agent false" do
      attach_telemetry([:kanban, :task, :comment_created])
      comment = %TaskComment{id: 5, task_id: 7, author_user_id: 2, author_agent_name: nil}

      assert TaskTelemetry.comment_created({:ok, comment}, 9) == {:ok, comment}

      assert_receive {:telemetry_event, _, %{count: 1},
                      %{task_id: 7, board_id: 9, comment_id: 5, user_id: 2, by_agent: false}}
    end
  end
end
