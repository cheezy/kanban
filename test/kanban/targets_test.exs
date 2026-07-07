defmodule Kanban.TargetsTest do
  @moduledoc """
  Tests for `Kanban.Targets` — board-scoped CRUD and goal membership for
  delivery targets. Visibility flows through accessible member goals, so the
  scoping assertions build a second user/board and assert cross-board denial.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    scope = Scope.for_user(user)

    # A second, unrelated user + board the first user cannot access.
    other_user = user_fixture()
    other_board = board_fixture(other_user)
    other_column = column_fixture(other_board)
    other_scope = Scope.for_user(other_user)

    %{
      user: user,
      board: board,
      column: column,
      scope: scope,
      other_user: other_user,
      other_board: other_board,
      other_column: other_column,
      other_scope: other_scope
    }
  end

  defp goal_fixture(column, attrs \\ %{}) do
    task_fixture(column, Map.merge(%{type: :goal}, attrs))
  end

  describe "create_target/2" do
    test "creates a target and stamps owner_id from the scope", %{scope: scope, user: user} do
      assert {:ok, %DeliveryTarget{} = target} =
               Targets.create_target(scope, %{name: "Q3 Launch", target_date: ~D[2026-09-30]})

      assert target.owner_id == user.id
      assert target.name == "Q3 Launch"
    end

    test "ignores a client-supplied owner_id (not castable)", %{
      scope: scope,
      user: user,
      other_user: other
    } do
      assert {:ok, target} =
               Targets.create_target(scope, %{
                 name: "Forged",
                 target_date: ~D[2026-09-30],
                 owner_id: other.id
               })

      assert target.owner_id == user.id
    end

    test "returns a changeset error when required fields are missing", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = cs} = Targets.create_target(scope, %{name: "No date"})
      assert %{target_date: ["can't be blank"]} = errors_on(cs)
    end

    test "returns {:error, :not_authorized} for a nil scope" do
      assert {:error, :not_authorized} =
               Targets.create_target(nil, %{name: "X", target_date: ~D[2026-09-30]})
    end
  end

  describe "update_target/3" do
    test "updates editable fields", %{scope: scope, user: user} do
      target = delivery_target_fixture(user)

      assert {:ok, updated} =
               Targets.update_target(scope, target, %{name: "Renamed", description: "why"})

      assert updated.name == "Renamed"
      assert updated.description == "why"
    end

    test "returns a changeset error on invalid data", %{scope: scope, user: user} do
      target = delivery_target_fixture(user)
      assert {:error, %Ecto.Changeset{}} = Targets.update_target(scope, target, %{name: nil})
    end

    test "returns {:error, :not_authorized} for a nil scope", %{user: user} do
      target = delivery_target_fixture(user)
      assert {:error, :not_authorized} = Targets.update_target(nil, target, %{name: "Nope"})
    end
  end

  describe "list_targets/1" do
    test "returns targets with a member goal on an accessible board", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [listed] = Targets.list_targets(scope)
      assert listed.id == target.id
    end

    test "excludes targets whose only goals are on an inaccessible board", %{
      user: user,
      other_scope: other_scope,
      column: column,
      scope: scope
    } do
      # Target's single member goal lives on `user`'s board.
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      # The second user cannot see it — its goal is on an inaccessible board.
      assert Targets.list_targets(other_scope) == []
    end

    test "excludes targets that have no member goals", %{scope: scope, user: user} do
      _target = delivery_target_fixture(user)
      assert Targets.list_targets(scope) == []
    end
  end

  describe "get_target/2" do
    test "returns {:ok, target} when reachable via an accessible member goal", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert {:ok, fetched} = Targets.get_target(scope, target.id)
      assert fetched.id == target.id
    end

    test "returns {:error, :not_found} when the only member goal is on an inaccessible board", %{
      user: user,
      column: column,
      scope: scope,
      other_scope: other_scope
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert {:error, :not_found} = Targets.get_target(other_scope, target.id)
    end

    test "returns {:error, :not_found} for a target with no member goals", %{
      scope: scope,
      user: user
    } do
      target = delivery_target_fixture(user)
      assert {:error, :not_found} = Targets.get_target(scope, target.id)
    end
  end

  describe "assign_goal/3" do
    test "sets target_id on a goal on an accessible board", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)

      assert {:ok, assigned} = Targets.assign_goal(scope, goal, target)
      assert assigned.target_id == target.id
    end

    test "rejects a non-goal (work) task with a changeset error", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      work = task_fixture(column, %{type: :work})

      assert {:error, %Ecto.Changeset{} = cs} = Targets.assign_goal(scope, work, target)
      assert %{target_id: ["may only be set on goal-type tasks"]} = errors_on(cs)
    end

    test "rejects a goal on an inaccessible board with {:error, :not_found}", %{
      scope: scope,
      user: user,
      other_column: other_column
    } do
      target = delivery_target_fixture(user)
      foreign_goal = goal_fixture(other_column)

      assert {:error, :not_found} = Targets.assign_goal(scope, foreign_goal, target)

      # And nothing was written.
      assert Repo.get!(Task, foreign_goal.id).target_id == nil
    end
  end

  describe "unassign_goal/2" do
    test "clears the target reference on an accessible goal", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert {:ok, unassigned} = Targets.unassign_goal(scope, goal)
      assert unassigned.target_id == nil
      assert Repo.get!(Task, goal.id).target_id == nil
    end

    test "returns {:error, :not_found} for a goal on an inaccessible board", %{
      other_column: other_column,
      scope: scope
    } do
      foreign_goal = goal_fixture(other_column)
      assert {:error, :not_found} = Targets.unassign_goal(scope, foreign_goal)
    end
  end

  describe "list_member_goals/2" do
    test "returns only member goals on accessible boards", %{
      scope: scope,
      user: user,
      column: column,
      other_scope: other_scope,
      other_column: other_column
    } do
      target = delivery_target_fixture(user)

      accessible_goal = goal_fixture(column)
      foreign_goal = goal_fixture(other_column)

      assert {:ok, _} = Targets.assign_goal(scope, accessible_goal, target)
      assert {:ok, _} = Targets.assign_goal(other_scope, foreign_goal, target)

      ids = scope |> Targets.list_member_goals(target) |> Enum.map(& &1.id)
      assert ids == [accessible_goal.id]

      other_ids = other_scope |> Targets.list_member_goals(target) |> Enum.map(& &1.id)
      assert other_ids == [foreign_goal.id]
    end
  end

  describe "full create -> assign -> list-members -> unassign cycle" do
    test "walks the target lifecycle end to end", %{scope: scope, column: column} do
      assert {:ok, target} =
               Targets.create_target(scope, %{name: "Cycle", target_date: ~D[2026-11-01]})

      # Not visible until it has a member goal.
      assert Targets.list_targets(scope) == []
      assert {:error, :not_found} = Targets.get_target(scope, target.id)

      goal = goal_fixture(column)
      assert {:ok, assigned} = Targets.assign_goal(scope, goal, target)
      assert assigned.target_id == target.id

      # Now visible.
      assert [listed] = Targets.list_targets(scope)
      assert listed.id == target.id
      assert {:ok, _} = Targets.get_target(scope, target.id)

      assert [member] = Targets.list_member_goals(scope, target)
      assert member.id == goal.id

      assert {:ok, unassigned} = Targets.unassign_goal(scope, goal)
      assert unassigned.target_id == nil

      # Back to invisible with no member goals.
      assert Targets.list_member_goals(scope, target) == []
      assert Targets.list_targets(scope) == []
    end
  end

  describe "list_targets_with_status/2" do
    test "summarizes a target with aggregate child progress and a derived status",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      _incomplete = task_fixture(column, %{parent_id: goal.id})
      complete_task(task_fixture(column, %{parent_id: goal.id}))

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      # today early in the target's window (created ~now, target_date 2026-12-31)
      # with work at 1/2 = 0.5 => work leads elapsed => :on_track.
      assert [summary] = Targets.list_targets_with_status(scope, ~D[2026-07-07])

      assert summary.target.id == target.id
      assert summary.completed == 1
      assert summary.total == 2
      assert summary.percentage == 50
      assert summary.status == :on_track
    end

    test "reports 0/0 (0%) progress when a member goal has no children",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, ~D[2026-07-07])
      assert summary.completed == 0
      assert summary.total == 0
      assert summary.percentage == 0
    end

    test "excludes targets whose goals are all on inaccessible boards",
         %{scope: scope, user: user, column: column, other_scope: other_scope} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert Targets.list_targets_with_status(other_scope, ~D[2026-07-07]) == []
    end
  end

  describe "owner?/2" do
    test "true for the owner, false for a non-owner", %{user: user, other_user: other} do
      target = delivery_target_fixture(user)
      assert Targets.owner?(target, user)
      refute Targets.owner?(target, other)
    end
  end

  describe "change_target/2" do
    test "returns a changeset for the target", %{user: user} do
      target = delivery_target_fixture(user)
      assert %Ecto.Changeset{} = Targets.change_target(target)
    end

    test "does not cast owner_id (never mass-assignable)", %{user: user, other_user: other} do
      target = delivery_target_fixture(user)
      cs = Targets.change_target(target, %{owner_id: other.id})
      refute Map.has_key?(cs.changes, :owner_id)
    end
  end

  describe "get_owned_target/2" do
    test "returns {:ok, target} with :owner preloaded for the owner (no goals needed)",
         %{scope: scope, user: user} do
      target = delivery_target_fixture(user)

      assert {:ok, fetched} = Targets.get_owned_target(scope, target.id)
      assert fetched.id == target.id
      assert fetched.owner.id == user.id
    end

    test "returns {:error, :not_found} for a target owned by another user",
         %{other_scope: other_scope, user: user} do
      target = delivery_target_fixture(user)
      assert {:error, :not_found} = Targets.get_owned_target(other_scope, target.id)
    end

    test "returns {:error, :not_found} for a missing id", %{scope: scope} do
      assert {:error, :not_found} = Targets.get_owned_target(scope, 999_999_999)
    end

    test "returns {:error, :not_found} for a nil scope", %{user: user} do
      target = delivery_target_fixture(user)
      assert {:error, :not_found} = Targets.get_owned_target(nil, target.id)
    end
  end

  describe "update_target/3 authorization" do
    test "the owner may update", %{scope: scope, user: user} do
      target = delivery_target_fixture(user)
      assert {:ok, updated} = Targets.update_target(scope, target, %{name: "Owner Renamed"})
      assert updated.name == "Owner Renamed"
    end

    test "a non-owner is rejected with {:error, :not_authorized}",
         %{other_scope: other_scope, user: user} do
      target = delivery_target_fixture(user)

      assert {:error, :not_authorized} =
               Targets.update_target(other_scope, target, %{name: "Nope"})

      assert Repo.get!(DeliveryTarget, target.id).name == target.name
    end
  end

  describe "list_assignable_goals/2" do
    test "returns goals not on this target, on accessible boards",
         %{scope: scope, user: user, column: column, other_column: other_column} do
      target = delivery_target_fixture(user)

      unassigned = goal_fixture(column)
      already_here = goal_fixture(column)
      foreign = goal_fixture(other_column)
      assert {:ok, _} = Targets.assign_goal(scope, already_here, target)

      ids = scope |> Targets.list_assignable_goals(target) |> Enum.map(& &1.id)

      assert unassigned.id in ids
      refute already_here.id in ids
      refute foreign.id in ids
    end

    test "excludes goals already assigned to a different target (no silent stealing)",
         %{scope: scope, user: user, column: column} do
      target = delivery_target_fixture(user)
      other_target = delivery_target_fixture(user)

      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, other_target)

      ids = scope |> Targets.list_assignable_goals(target) |> Enum.map(& &1.id)
      refute goal.id in ids
    end

    test "excludes non-goal (work) tasks", %{scope: scope, user: user, column: column} do
      target = delivery_target_fixture(user)
      work = task_fixture(column, %{type: :work})

      ids = scope |> Targets.list_assignable_goals(target) |> Enum.map(& &1.id)
      refute work.id in ids
    end
  end

  defp complete_task(task) do
    {:ok, done} =
      task
      |> Task.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
      |> Repo.update()

    done
  end
end
