defmodule Kanban.Tasks.InterventionsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Targets
  alias Kanban.Tasks
  alias Kanban.Tasks.Interventions
  alias Kanban.Tasks.Task

  describe "can_intervene?/2" do
    setup do
      board_owner = user_fixture()
      board = board_fixture(board_owner)
      column = column_fixture(board)

      %{board_owner: board_owner, board: board, column: column}
    end

    test "returns true for the board owner of the goal's board", %{
      board_owner: board_owner,
      column: column
    } do
      goal = task_fixture(column, %{type: :goal})
      scope = Scope.for_user(board_owner)

      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns true for the goal's delivery-target owner who is a board member",
         %{board_owner: board_owner, board: board, column: column} do
      target_owner = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, target_owner, :read_only, board_owner)
      target = delivery_target_fixture(target_owner)
      goal = task_fixture(column, %{type: :goal, target_id: target.id})
      scope = Scope.for_user(target_owner)

      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns true for a user who is both target owner and board owner", %{
      board_owner: board_owner,
      column: column
    } do
      target = delivery_target_fixture(board_owner)
      goal = task_fixture(column, %{type: :goal, target_id: target.id})
      scope = Scope.for_user(board_owner)

      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns true for the board owner even when the goal has no delivery target",
         %{board_owner: board_owner, column: column} do
      goal = task_fixture(column, %{type: :goal})
      scope = Scope.for_user(board_owner)

      assert goal.target_id == nil
      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns false for a non-owner who can read the board", %{
      board_owner: board_owner,
      board: board,
      column: column
    } do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, board_owner)
      goal = task_fixture(column, %{type: :goal})
      scope = Scope.for_user(reader)

      refute Interventions.can_intervene?(scope, goal)
    end

    test "returns false when the goal is on a board the target owner cannot access",
         %{board: board, column: column} do
      # target_owner owns the target but is NOT a member of the goal's board.
      target_owner = user_fixture()
      target = delivery_target_fixture(target_owner)
      goal = task_fixture(column, %{type: :goal, target_id: target.id})
      scope = Scope.for_user(target_owner)

      # Sanity: without the board-access guard, target ownership alone would pass.
      assert Targets.owner?(target, target_owner)
      refute Boards.owner?(board, target_owner)

      refute Interventions.can_intervene?(scope, goal)
    end

    test "returns false for a nil scope", %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      refute Interventions.can_intervene?(nil, goal)
    end

    test "returns false for a scope with a nil user", %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      refute Interventions.can_intervene?(%Scope{user: nil}, goal)
    end
  end

  describe "reassign_goal_unstarted/3" do
    setup do
      owner = user_fixture()
      assignee = user_fixture()
      board = ai_optimized_board_fixture(owner)
      {:ok, _} = Boards.add_user_to_board(board, assignee, :modify, owner)
      columns = Columns.list_columns(board)

      cols = Map.new(columns, &{&1.name, &1})
      goal = task_fixture(cols["Ready"], %{type: :goal})

      %{
        owner: owner,
        assignee: assignee,
        board: board,
        cols: cols,
        goal: goal,
        scope: Scope.for_user(owner)
      }
    end

    test "reassigns the goal and every Backlog/Ready open child", ctx do
      %{cols: cols, goal: goal, assignee: assignee, scope: scope} = ctx
      backlog_child = task_fixture(cols["Backlog"], %{parent_id: goal.id})
      ready_child = task_fixture(cols["Ready"], %{parent_id: goal.id})

      assert {:ok, %{moved: moved, skipped: []}} =
               Interventions.reassign_goal_unstarted(scope, goal, assignee.id)

      moved_ids = Enum.map(moved, & &1.id)
      assert goal.id in moved_ids
      assert backlog_child.id in moved_ids
      assert ready_child.id in moved_ids

      for task <- moved, do: assert(task.assigned_to_id == assignee.id)
      assert reload(goal).assigned_to_id == assignee.id
      assert reload(backlog_child).assigned_to_id == assignee.id
      assert reload(ready_child).assigned_to_id == assignee.id
    end

    test "never touches Doing, Review, or Done children", ctx do
      %{cols: cols, goal: goal, assignee: assignee, scope: scope} = ctx
      doing = task_fixture(cols["Doing"], %{parent_id: goal.id, status: :in_progress})
      review = task_fixture(cols["Review"], %{parent_id: goal.id, status: :in_progress})

      done =
        task_fixture(cols["Done"], %{
          parent_id: goal.id,
          status: :completed,
          completed_at: DateTime.utc_now()
        })

      assert {:ok, %{moved: moved, skipped: skipped}} =
               Interventions.reassign_goal_unstarted(scope, goal, assignee.id)

      untouched = [doing.id, review.id, done.id]
      refute Enum.any?(moved, &(&1.id in untouched))
      refute Enum.any?(skipped, &(&1.id in untouched))

      assert reload(doing).assigned_to_id == nil
      assert reload(review).assigned_to_id == nil
      assert reload(done).assigned_to_id == nil
    end

    test "skips a Backlog/Ready child claimed after the goal was inspected", ctx do
      %{cols: cols, goal: goal, assignee: assignee, scope: scope} = ctx
      open_child = task_fixture(cols["Ready"], %{parent_id: goal.id})
      claimed_child = task_fixture(cols["Backlog"], %{parent_id: goal.id})

      # Simulate a concurrent agent claim landing between inspection and write.
      now = DateTime.utc_now()
      claim_expires = DateTime.add(now, 3600, :second)

      {1, _} =
        from(t in Task, where: t.id == ^claimed_child.id)
        |> Repo.update_all(set: [status: :in_progress, claim_expires_at: claim_expires])

      assert {:ok, %{moved: moved, skipped: skipped}} =
               Interventions.reassign_goal_unstarted(scope, goal, assignee.id)

      assert Enum.any?(moved, &(&1.id == open_child.id))
      refute Enum.any?(moved, &(&1.id == claimed_child.id))
      assert Enum.map(skipped, & &1.id) == [claimed_child.id]

      assert reload(open_child).assigned_to_id == assignee.id
      assert reload(claimed_child).assigned_to_id == nil
    end

    test "records assignment history for the goal and each moved child", ctx do
      %{cols: cols, goal: goal, assignee: assignee, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id})

      assert {:ok, _} = Interventions.reassign_goal_unstarted(scope, goal, assignee.id)

      assert assignment_to(goal.id) == [assignee.id]
      assert assignment_to(child.id) == [assignee.id]
    end

    test "returns {:ok, %{moved: ..., skipped: ...}} with only the goal when there are no children",
         ctx do
      %{goal: goal, assignee: assignee, scope: scope} = ctx

      assert {:ok, %{moved: [moved_goal], skipped: []}} =
               Interventions.reassign_goal_unstarted(scope, goal, assignee.id)

      assert moved_goal.id == goal.id
      assert moved_goal.assigned_to_id == assignee.id
    end

    test "unassigns when new_assigned_to_id is nil", ctx do
      %{cols: cols, goal: goal, assignee: assignee, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id})
      {:ok, _} = Interventions.reassign_goal_unstarted(scope, goal, assignee.id)

      assert {:ok, %{moved: moved}} =
               Interventions.reassign_goal_unstarted(scope, reload(goal), nil)

      for task <- moved, do: assert(task.assigned_to_id == nil)
      assert reload(child).assigned_to_id == nil
    end

    test "rejects a nonexistent assignee and reassigns nothing", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id})

      assert {:error, :assignee_not_on_board} =
               Interventions.reassign_goal_unstarted(scope, goal, -1)

      assert reload(goal).assigned_to_id == nil
      assert reload(child).assigned_to_id == nil
      assert assignment_to(goal.id) == []
    end

    test "rejects a real user who is not a member of the goal's board", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      off_board = user_fixture()
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id})

      assert {:error, :assignee_not_on_board} =
               Interventions.reassign_goal_unstarted(scope, goal, off_board.id)

      assert reload(goal).assigned_to_id == nil
      assert reload(child).assigned_to_id == nil
      assert assignment_to(goal.id) == []
    end

    test "returns {:error, :unauthorized} for a scope that cannot intervene", ctx do
      %{goal: goal, assignee: assignee, cols: cols} = ctx
      stranger_scope = Scope.for_user(user_fixture())
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id})

      assert {:error, :unauthorized} =
               Interventions.reassign_goal_unstarted(stranger_scope, goal, assignee.id)

      assert reload(goal).assigned_to_id == nil
      assert reload(child).assigned_to_id == nil
    end
  end

  describe "reprioritize_goal_unstarted/3" do
    setup do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)
      columns = Columns.list_columns(board)

      cols = Map.new(columns, &{&1.name, &1})
      goal = task_fixture(cols["Ready"], %{type: :goal, priority: :medium})

      %{owner: owner, board: board, cols: cols, goal: goal, scope: Scope.for_user(owner)}
    end

    test "sets the goal and every Backlog/Ready open child to the new priority", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      backlog_child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :low})
      ready_child = task_fixture(cols["Ready"], %{parent_id: goal.id, priority: :medium})

      assert {:ok, %{moved: moved, skipped: []}} =
               Interventions.reprioritize_goal_unstarted(scope, goal, :critical)

      for task <- moved, do: assert(task.priority == :critical)
      assert reload(goal).priority == :critical
      assert reload(backlog_child).priority == :critical
      assert reload(ready_child).priority == :critical
    end

    test "leaves Doing, Review, and Done children unchanged", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx

      doing =
        task_fixture(cols["Doing"], %{parent_id: goal.id, status: :in_progress, priority: :low})

      review =
        task_fixture(cols["Review"], %{parent_id: goal.id, status: :in_progress, priority: :low})

      done =
        task_fixture(cols["Done"], %{
          parent_id: goal.id,
          status: :completed,
          completed_at: DateTime.utc_now(),
          priority: :low
        })

      assert {:ok, _} = Interventions.reprioritize_goal_unstarted(scope, goal, :high)

      assert reload(doing).priority == :low
      assert reload(review).priority == :low
      assert reload(done).priority == :low
    end

    test "skips a Backlog/Ready child that has been claimed", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      open_child = task_fixture(cols["Ready"], %{parent_id: goal.id, priority: :low})
      claimed_child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :low})

      {1, _} =
        from(t in Task, where: t.id == ^claimed_child.id)
        |> Repo.update_all(set: [status: :in_progress])

      assert {:ok, %{moved: moved, skipped: skipped}} =
               Interventions.reprioritize_goal_unstarted(scope, goal, :high)

      assert Enum.any?(moved, &(&1.id == open_child.id))
      assert Enum.map(skipped, & &1.id) == [claimed_child.id]
      assert reload(open_child).priority == :high
      assert reload(claimed_child).priority == :low
    end

    test "records priority-change history for the goal and each moved child", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :medium})

      assert {:ok, _} = Interventions.reprioritize_goal_unstarted(scope, goal, :high)

      assert priority_changes_to(goal.id) == ["high"]
      assert priority_changes_to(child.id) == ["high"]
    end

    test "returns {:ok, %{moved: ..., skipped: ...}} with only the goal when there are no children",
         ctx do
      %{goal: goal, scope: scope} = ctx

      assert {:ok, %{moved: [moved_goal], skipped: []}} =
               Interventions.reprioritize_goal_unstarted(scope, goal, :high)

      assert moved_goal.id == goal.id
      assert moved_goal.priority == :high
    end

    test "accepts an allowed priority passed as a string", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :medium})

      assert {:ok, _} = Interventions.reprioritize_goal_unstarted(scope, goal, "critical")

      assert reload(goal).priority == :critical
      assert reload(child).priority == :critical
    end

    test "reprioritizing to the current priority is a no-op that still succeeds", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :medium})

      assert {:ok, %{moved: moved, skipped: []}} =
               Interventions.reprioritize_goal_unstarted(scope, goal, :medium)

      for task <- moved, do: assert(task.priority == :medium)
      assert reload(goal).priority == :medium
      assert reload(child).priority == :medium
      assert priority_changes_to(goal.id) == ["medium"]
    end

    test "lowering to low succeeds", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :high})

      assert {:ok, _} = Interventions.reprioritize_goal_unstarted(scope, goal, :low)

      assert reload(goal).priority == :low
      assert reload(child).priority == :low
    end

    test "rejects an invalid priority atom and mutates nothing", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :medium})

      assert {:error, :invalid_priority} =
               Interventions.reprioritize_goal_unstarted(scope, goal, :urgent)

      assert reload(goal).priority == :medium
      assert reload(child).priority == :medium
      assert priority_changes_to(goal.id) == []
    end

    test "rejects an invalid priority string and mutates nothing", ctx do
      %{cols: cols, goal: goal, scope: scope} = ctx
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :medium})

      assert {:error, :invalid_priority} =
               Interventions.reprioritize_goal_unstarted(scope, goal, "urgent")

      assert reload(goal).priority == :medium
      assert reload(child).priority == :medium
    end

    test "returns {:error, :unauthorized} for a scope that cannot intervene", ctx do
      %{goal: goal, cols: cols} = ctx
      stranger_scope = Scope.for_user(user_fixture())
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :medium})

      assert {:error, :unauthorized} =
               Interventions.reprioritize_goal_unstarted(stranger_scope, goal, :high)

      assert reload(goal).priority == :medium
      assert reload(child).priority == :medium
    end
  end

  defp reload(%Task{id: id}), do: Repo.get!(Task, id)

  defp assignment_to(task_id) do
    task_id
    |> Tasks.get_task_with_history!()
    |> Map.fetch!(:task_histories)
    |> Enum.filter(&(&1.type == :assignment))
    |> Enum.map(& &1.to_user_id)
  end

  defp priority_changes_to(task_id) do
    task_id
    |> Tasks.get_task_with_history!()
    |> Map.fetch!(:task_histories)
    |> Enum.filter(&(&1.type == :priority_change))
    |> Enum.map(& &1.to_priority)
  end
end
