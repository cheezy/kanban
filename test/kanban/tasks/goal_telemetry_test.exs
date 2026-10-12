defmodule Kanban.Tasks.GoalTelemetryTest do
  use Kanban.DataCase, async: true

  import Kanban.TelemetryHelpers

  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.GoalTelemetry
  alias Kanban.Tasks.Task

  @goal %Task{id: 9, type: :goal, column: %Column{board_id: 4}, assigned_to_id: 12}
  @moved {:ok, %{moved: [@goal, %Task{id: 10}, %Task{id: 11}], skipped: [%Task{id: 13}]}}

  describe "completed/2" do
    test "emits goal_id and board_id outside a transaction" do
      attach_telemetry([:kanban, :goal, :completed])

      assert :ok = GoalTelemetry.completed(9, 4)

      assert_receive {:telemetry_event, [:kanban, :goal, :completed], %{count: 1},
                      %{goal_id: 9, board_id: 4}}
    end

    test "emits nothing for a nil goal id" do
      attach_telemetry([:kanban, :goal, :completed])

      assert :ok = GoalTelemetry.completed(nil, 4)
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end

    test "emits nothing inside a transaction, which has not committed yet" do
      attach_telemetry([:kanban, :goal, :completed])

      assert {:ok, :ok} = Repo.transaction(fn -> GoalTelemetry.completed(9, 4) end)
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end
  end

  describe "after_commit/1" do
    test "holds goal events back until the transaction returns {:ok, _}" do
      attach_telemetry([[:kanban, :goal, :completed], [:kanban, :task, :unblocked]])
      test_pid = self()

      result =
        GoalTelemetry.after_commit(fn ->
          Repo.transaction(fn ->
            GoalTelemetry.completed(9, 4)
            GoalTelemetry.unblocked({:ok, %Task{id: 3, status: :open}}, 4)
            send(test_pid, :inside_done)
            :done
          end)
        end)

      assert result == {:ok, :done}
      assert_received :inside_done

      assert_receive {:telemetry_event, [:kanban, :goal, :completed], _, %{goal_id: 9}}
      assert_receive {:telemetry_event, [:kanban, :task, :unblocked], _, %{task_id: 3}}
    end

    test "drops the held events when the transaction does not commit" do
      attach_telemetry([[:kanban, :goal, :completed], [:kanban, :task, :unblocked]])

      result =
        GoalTelemetry.after_commit(fn ->
          Repo.transaction(fn ->
            GoalTelemetry.completed(9, 4)
            GoalTelemetry.unblocked({:ok, %Task{id: 3, status: :open}}, 4)
            Repo.rollback(:nope)
          end)
        end)

      assert result == {:error, :nope}
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end

    test "drops the held events and stops holding when the function raises" do
      attach_telemetry([:kanban, :task, :unblocked])

      assert_raise RuntimeError, fn ->
        GoalTelemetry.after_commit(fn ->
          GoalTelemetry.unblocked({:ok, %Task{id: 3, status: :open}}, 4)
          raise "boom"
        end)
      end

      refute_receive {:telemetry_event, _event, _measurements, _metadata}

      # Nothing is held any more, so a later event is emitted straight away.
      GoalTelemetry.unblocked({:ok, %Task{id: 5, status: :open}}, 4)
      assert_receive {:telemetry_event, [:kanban, :task, :unblocked], _, %{task_id: 5}}
    end
  end

  describe "unblocked/2" do
    test "emits for a dependent that is no longer blocked and returns the result" do
      attach_telemetry([:kanban, :task, :unblocked])
      result = {:ok, %Task{id: 3, status: :open}}

      assert GoalTelemetry.unblocked(result, 4) == result

      assert_receive {:telemetry_event, [:kanban, :task, :unblocked], %{count: 1},
                      %{task_id: 3, board_id: 4}}
    end

    test "passes a still-blocked dependent or an error through without emitting" do
      attach_telemetry([:kanban, :task, :unblocked])
      blocked = {:ok, %Task{id: 3, status: :blocked}}

      assert GoalTelemetry.unblocked(blocked, 4) == blocked
      assert GoalTelemetry.unblocked({:error, :boom}, 4) == {:error, :boom}
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end
  end

  describe "after_goal_failed/2" do
    test "drops a non-integer exit code and duration rather than sending them" do
      attach_telemetry([:kanban, :goal, :after_goal_failed])
      attempt = %{"exit_code" => "1", "duration_ms" => "slow", "output" => "hook printed this"}

      assert GoalTelemetry.after_goal_failed({:ok, @goal}, attempt) == {:ok, @goal}

      assert_receive {:telemetry_event, [:kanban, :goal, :after_goal_failed], measurements,
                      metadata}

      assert measurements == %{count: 1}
      assert metadata == %{goal_id: 9, board_id: 4, exit_code: nil}
      refute inspect(metadata) =~ "hook printed"
    end

    test "passes an error through without emitting" do
      attach_telemetry([:kanban, :goal, :after_goal_failed])

      assert GoalTelemetry.after_goal_failed({:error, :boom}, %{}) == {:error, :boom}
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end
  end

  describe "promoted_to_ready/3 and grace_window_scheduled/3" do
    test "pass errors and empty promotions through without emitting" do
      attach_telemetry([
        [:kanban, :goal, :promoted_to_ready],
        [:kanban, :goal, :grace_window_scheduled]
      ])

      assert GoalTelemetry.promoted_to_ready({:ok, 0}, @goal, 4) == {:ok, 0}
      assert GoalTelemetry.promoted_to_ready({:error, :nope}, @goal, 4) == {:error, :nope}
      assert GoalTelemetry.grace_window_scheduled({:error, :cs}, @goal, 500) == {:error, :cs}
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end
  end

  describe "interventions" do
    test "count the moved children without the goal, and the skipped ones" do
      attach_telemetry([:kanban, :goal, :reassigned])

      assert GoalTelemetry.reassigned(@moved, %{user: %{id: 7}}) == @moved

      assert_receive {:telemetry_event, [:kanban, :goal, :reassigned], measurements, metadata}
      assert measurements == %{count: 1, moved_count: 2, skipped_count: 1}

      assert metadata == %{
               goal_id: 9,
               board_id: 4,
               actor_user_id: 7,
               assigned_to_id: 12
             }
    end

    test "send a nil actor without a scoped user" do
      attach_telemetry([:kanban, :goal, :reprioritization_undone])

      assert GoalTelemetry.undone(@moved, :priority, nil) == @moved

      assert_receive {:telemetry_event, [:kanban, :goal, :reprioritization_undone], _,
                      %{actor_user_id: nil}}
    end

    test "pass errors through without emitting" do
      attach_telemetry([
        [:kanban, :goal, :reassigned],
        [:kanban, :goal, :reprioritized],
        [:kanban, :goal, :reassignment_undone]
      ])

      assert GoalTelemetry.reassigned({:error, :unauthorized}, nil) == {:error, :unauthorized}

      assert GoalTelemetry.reprioritized({:error, :invalid_priority}, nil, :high) ==
               {:error, :invalid_priority}

      assert GoalTelemetry.undone({:error, :unauthorized}, :assigned_to_id, nil) ==
               {:error, :unauthorized}

      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end
  end
end
