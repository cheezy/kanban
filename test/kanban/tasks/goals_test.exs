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

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

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
end
