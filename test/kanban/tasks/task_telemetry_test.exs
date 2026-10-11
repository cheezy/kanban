defmodule Kanban.Tasks.TaskTelemetryTest do
  use ExUnit.Case, async: true

  import Kanban.TelemetryHelpers

  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry

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
end
