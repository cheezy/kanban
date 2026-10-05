defmodule Kanban.Tasks.GoalsTest do
  @moduledoc """
  Unit tests for `Kanban.Tasks.Goals` archived-child exclusion (D60).

  `fetch_scoped_children/3` is the single base query behind
  `get_task_children/2` and `get_task_tree/2`; archived children must not
  appear in either result, otherwise goal-progress badges report inflated
  denominators (e.g. "5/8 · 62%" when every active child is done).
  `promote_goal_to_ready/2` filters archived tasks in its own query
  (`collect_backlog_tasks/2`) and is covered here as a regression guard.

  The W397 cross-board scoping tests live in `test/kanban/tasks_test.exs`
  and continue to cover the `board_id` half of the where-clause.
  """

  use Kanban.DataCase
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Notifications.GoalCompletedWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    goal = task_fixture(column, %{title: "Goal", type: :goal})

    %{user: user, board: board, column: column, goal: goal}
  end

  defp archive!(task) do
    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    task
  end

  defp complete!(task) do
    {:ok, task} =
      Tasks.update_task(task, %{
        "status" => "completed",
        "completed_at" => DateTime.utc_now()
      })

    task
  end

  describe "get_task_children/2 (archived-child exclusion)" do
    test "returns only non-archived children when archived children exist",
         %{board: board, column: column, goal: goal} do
      active1 = task_fixture(column, %{title: "Active 1", parent_id: goal.id})
      active2 = task_fixture(column, %{title: "Active 2", parent_id: goal.id})

      column
      |> task_fixture(%{title: "Archived", parent_id: goal.id})
      |> archive!()

      children = Tasks.get_task_children(goal.id, board.id)

      assert Enum.map(children, & &1.id) |> Enum.sort() ==
               Enum.sort([active1.id, active2.id])
    end

    test "returns [] when every child is archived", %{board: board, column: column, goal: goal} do
      column
      |> task_fixture(%{title: "Archived only", parent_id: goal.id})
      |> archive!()

      assert Tasks.get_task_children(goal.id, board.id) == []
    end
  end

  describe "get_task_children_including_archived/2 (target-progress path — D124)" do
    test "includes archived children (unlike get_task_children/2), still board-scoped",
         %{board: board, column: column, goal: goal} do
      active = task_fixture(column, %{title: "Active", parent_id: goal.id})

      archived =
        column
        |> task_fixture(%{title: "Archived", parent_id: goal.id})
        |> archive!()

      including = Tasks.get_task_children_including_archived(goal.id, board.id)

      assert Enum.map(including, & &1.id) |> Enum.sort() ==
               Enum.sort([active.id, archived.id])

      # The board/flow path still excludes the archived child — the change is
      # scoped to the progress fetch only.
      live_only = Tasks.get_task_children(goal.id, board.id)
      assert Enum.map(live_only, & &1.id) == [active.id]
    end

    test "returns [] for children on another board (cross-board IDOR closed)",
         %{column: column, goal: goal} do
      task_fixture(column, %{title: "Child", parent_id: goal.id})

      other_board = board_fixture(user_fixture())
      assert Tasks.get_task_children_including_archived(goal.id, other_board.id) == []
    end
  end

  describe "get_children_including_archived_by_parent/1 (batched target-progress path — D125)" do
    test "groups each goal's children (archived included) by parent id",
         %{board: board, column: column, goal: goal1} do
      goal2 = task_fixture(column, %{title: "Goal 2", type: :goal})

      g1_active = task_fixture(column, %{title: "G1 active", parent_id: goal1.id})

      g1_archived =
        column |> task_fixture(%{title: "G1 archived", parent_id: goal1.id}) |> archive!()

      g2_active = task_fixture(column, %{title: "G2 active", parent_id: goal2.id})

      by_parent =
        Tasks.get_children_including_archived_by_parent([
          {goal1.id, board.id},
          {goal2.id, board.id}
        ])

      assert Enum.map(by_parent[goal1.id], & &1.id) |> Enum.sort() ==
               Enum.sort([g1_active.id, g1_archived.id])

      assert Enum.map(by_parent[goal2.id], & &1.id) == [g2_active.id]
    end

    test "a goal with no children is absent from the map (Map.get default applies)",
         %{board: board, goal: goal} do
      by_parent = Tasks.get_children_including_archived_by_parent([{goal.id, board.id}])

      refute Map.has_key?(by_parent, goal.id)
      assert Map.get(by_parent, goal.id, []) == []
    end

    test "children on another board are excluded per goal (cross-board IDOR closed)",
         %{column: column, goal: goal} do
      task_fixture(column, %{title: "Child", parent_id: goal.id})

      other_board = board_fixture(user_fixture())
      # Scoping the goal to a board it does not live on yields no children.
      assert Tasks.get_children_including_archived_by_parent([{goal.id, other_board.id}]) == %{}
    end
  end

  describe "get_task_tree/2 (archived-child exclusion)" do
    # counts.total is 1 (the goal itself) + the number of ACTIVE children;
    # this is the denominator consumed by compute_goal_progress/2 in
    # KanbanWeb.BoardLive.Show (lib/kanban_web/live/board_live/show.ex:939).
    test "children and counts.total reflect only non-archived children",
         %{board: board, column: column, goal: goal} do
      active = task_fixture(column, %{title: "Active", parent_id: goal.id})

      column
      |> task_fixture(%{title: "Archived", parent_id: goal.id})
      |> archive!()

      tree = Tasks.get_task_tree(goal.id, board.id)

      assert Enum.map(tree.children, & &1.id) == [active.id]
      assert tree.counts.total == 2
    end

    test "counts.completed excludes archived completed children",
         %{board: board, column: column, goal: goal} do
      column
      |> task_fixture(%{title: "Active done", parent_id: goal.id})
      |> complete!()

      column
      |> task_fixture(%{title: "Archived done", parent_id: goal.id})
      |> complete!()
      |> archive!()

      tree = Tasks.get_task_tree(goal.id, board.id)

      assert tree.counts.completed == 1
      assert tree.counts.total == 2
    end

    test "counts.blocked excludes archived blocked children",
         %{board: board, column: column, goal: goal} do
      task_fixture(column, %{title: "Active blocked", parent_id: goal.id, status: :blocked})

      column
      |> task_fixture(%{title: "Archived blocked", parent_id: goal.id, status: :blocked})
      |> archive!()

      tree = Tasks.get_task_tree(goal.id, board.id)

      assert tree.counts.blocked == 1
      assert tree.counts.total == 2
    end
  end

  describe "promote_goal_to_ready/2 (archived-child exclusion)" do
    test "does not move archived backlog children into Ready", %{user: user} do
      board = board_fixture(user)
      backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "Ready"})

      goal = task_fixture(backlog, %{title: "Backlog Goal", type: :goal})
      active_child = task_fixture(backlog, %{title: "Active child", parent_id: goal.id})

      archived_child =
        backlog
        |> task_fixture(%{title: "Archived child", parent_id: goal.id})
        |> archive!()

      # Goal + active child move; the archived child stays put.
      assert {:ok, 2} = Tasks.promote_goal_to_ready(goal, board.id)

      assert Tasks.get_task!(goal.id).column_id == ready.id
      assert Tasks.get_task!(active_child.id).column_id == ready.id
      assert Tasks.get_task!(archived_child.id).column_id == backlog.id
    end
  end

  # D357: promotion and goal-follows-children moves write with update_all,
  # so updated_at must be stamped explicitly for updated_since to see them.
  describe "promote_goal_to_ready and goal follow move bump updated_at (D357)" do
    @old ~N[2020-01-01 00:00:00]

    defp age!(tasks) do
      ids = Enum.map(tasks, & &1.id)
      from(t in Task, where: t.id in ^ids) |> Repo.update_all(set: [updated_at: @old])
      Enum.map(tasks, &Repo.reload!/1)
    end

    defp stamp(task), do: Repo.reload!(task).updated_at
    defp bumped?(task), do: task |> stamp() |> NaiveDateTime.compare(@old) == :gt

    test "promote_goal_to_ready bumps updated_at on each promoted task", %{user: user} do
      board = board_fixture(user)
      backlog = column_fixture(board, %{name: "Backlog"})
      _ready = column_fixture(board, %{name: "Ready"})

      goal = task_fixture(backlog, %{title: "Backlog Goal", type: :goal})
      child_a = task_fixture(backlog, %{title: "Child A", parent_id: goal.id})
      child_b = task_fixture(backlog, %{title: "Child B", parent_id: goal.id})
      bystander = task_fixture(backlog, %{title: "Not in the goal"})
      [goal, child_a, child_b, bystander] = age!([goal, child_a, child_b, bystander])

      assert {:ok, 3} = Tasks.promote_goal_to_ready(goal, board.id)

      assert Enum.all?([goal, child_a, child_b], &bumped?/1)
      refute bumped?(bystander)

      # One value per promotion, shared by every promoted row.
      assert [_single] = [goal, child_a, child_b] |> Enum.map(&stamp/1) |> Enum.uniq()
    end

    test "a goal following its child bumps the goal and the siblings shifted for it", %{
      user: user
    } do
      board = board_fixture(user)
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      goal = task_fixture(ready, %{title: "Following Goal", type: :goal})
      child = task_fixture(ready, %{title: "Child", parent_id: goal.id})
      sibling = task_fixture(doing, %{title: "Already in Doing"})
      [goal, child, sibling] = age!([goal, child, sibling])

      assert {:ok, _} = Tasks.move_task(child, doing, 0)

      goal_after = Repo.reload!(goal)
      assert goal_after.column_id == doing.id
      assert Enum.all?([goal, child, sibling], &bumped?/1)

      # The goal follow is part of the same move, so it shares the move's stamp.
      assert stamp(goal) == stamp(child)
    end

    test "the goal follow bumps a sibling that only the goal placement shifts", %{user: user} do
      board = board_fixture(user)
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      goal = task_fixture(ready, %{title: "Following Goal", type: :goal})
      child = task_fixture(ready, %{title: "Child", parent_id: goal.id})
      # Doing holds another goal (0) and a task (1). The child lands at the end
      # (2), so the move itself shifts nothing in Doing; the goal is then placed
      # after the other goal (1) and only the goal placement shifts the task.
      other_goal = task_fixture(doing, %{title: "Other Goal", type: :goal})
      placement_only = task_fixture(doing, %{title: "Shifted by the goal only"})
      [goal, child, other_goal, placement_only] = age!([goal, child, other_goal, placement_only])

      assert {:ok, _} = Tasks.move_task(child, doing, 2)

      assert Repo.reload!(goal).position == 1
      assert Repo.reload!(placement_only).position == 2
      assert bumped?(placement_only)
      assert stamp(placement_only) == stamp(goal)
      refute bumped?(other_goal)
    end
  end

  describe "mark_after_goal_succeeded_and_promote/2 — Done column resolution" do
    @attempt %{
      "exit_code" => 0,
      "output" => "after_goal hook succeeded",
      "source" => "test"
    }

    test "flips to succeeded but stays put when the board has no Done column",
         %{column: column, goal: goal} do
      # The default board has a single non-Done column, so find_done_column/1
      # returns nil and promotion becomes a no-op move.
      assert {:ok, updated} = Goals.mark_after_goal_succeeded_and_promote(goal, @attempt)

      assert updated.after_goal_status == :succeeded
      assert Tasks.get_task!(goal.id).column_id == column.id
    end

    test "is a no-op move when the goal already sits in the Done column",
         %{board: board} do
      done = column_fixture(board, %{name: "Done"})
      goal = task_fixture(done, %{title: "Done goal", type: :goal})

      assert {:ok, updated} = Goals.mark_after_goal_succeeded_and_promote(goal, @attempt)

      assert updated.after_goal_status == :succeeded
      assert Tasks.get_task!(goal.id).column_id == done.id
    end

    test "moves the goal into the Done column when one exists elsewhere",
         %{board: board, column: column, goal: goal} do
      done = column_fixture(board, %{name: "Done"})

      assert {:ok, updated} = Goals.mark_after_goal_succeeded_and_promote(goal, @attempt)

      assert updated.after_goal_status == :succeeded
      refute Tasks.get_task!(goal.id).column_id == column.id
      assert Tasks.get_task!(goal.id).column_id == done.id
    end
  end

  describe "goal_completed notifications (W2204)" do
    @success %{"exit_code" => 0, "output" => "ok", "source" => "test"}
    @failure %{"exit_code" => 1, "output" => "boom", "duration_ms" => 50}

    setup %{user: user, board: board, column: column} do
      done = column_fixture(board, %{name: "Done"})
      assignee = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, assignee, :modify, user)

      goal =
        task_fixture(column, %{
          title: "Notify goal",
          type: :goal,
          created_by_id: user.id,
          assigned_to_id: assignee.id
        })

      %{done: done, assignee: assignee, notify_goal: goal}
    end

    defp goal_rows(event_type) do
      Notification
      |> where(event_type: ^event_type)
      |> Repo.all()
    end

    test "promotion via after_goal success notifies creator and assignee once; a re-report adds nothing",
         ctx do
      assert {:ok, _} = Goals.mark_after_goal_succeeded_and_promote(ctx.notify_goal, @success)

      users = :goal_completed |> goal_rows() |> Enum.map(& &1.user_id) |> Enum.sort()
      assert users == Enum.sort([ctx.user.id, ctx.assignee.id])

      # Idempotent branch: already succeeded.
      assert {:ok, _} = Goals.mark_after_goal_succeeded_and_promote(ctx.notify_goal, @success)
      assert length(goal_rows(:goal_completed)) == 2
    end

    test "a promotion that cannot reach Done notifies nobody" do
      # This describe's setup adds a Done column, so use a fresh board
      # without one: promotion becomes a no-op move.
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      lonely = task_fixture(column, %{type: :goal, created_by_id: user.id})

      assert {:ok, _} = Goals.mark_after_goal_succeeded_and_promote(lonely, @success)
      assert goal_rows(:goal_completed) == []
    end

    test "a human moving the last child into Done notifies once, after the move commits",
         ctx do
      child = task_fixture(ctx.column, %{title: "Last child", parent_id: ctx.notify_goal.id})

      assert {:ok, _} = Tasks.move_task(child, ctx.done, 0)

      assert Tasks.get_task!(ctx.notify_goal.id).column_id == ctx.done.id
      assert_enqueued(worker: GoalCompletedWorker, args: %{goal_id: ctx.notify_goal.id})
      assert goal_rows(:goal_completed) == []

      assert :ok = perform_job(GoalCompletedWorker, %{goal_id: ctx.notify_goal.id})
      assert :ok = perform_job(GoalCompletedWorker, %{goal_id: ctx.notify_goal.id})
      assert length(goal_rows(:goal_completed)) == 2
    end

    test "record_after_goal_failure/2 notifies creator and assignee", ctx do
      assert {:ok, updated} = Goals.record_after_goal_failure(ctx.notify_goal, @failure)
      assert [@failure] == updated.after_goal_attempts

      users = :after_goal_failed |> goal_rows() |> Enum.map(& &1.user_id) |> Enum.sort()
      assert users == Enum.sort([ctx.user.id, ctx.assignee.id])
    end
  end
end
