defmodule Kanban.Tasks.GoalPlacementTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.GoalPlacement
  alias Kanban.Tasks.Task

  @old ~N[2020-01-01 00:00:00]
  @now ~U[2026-01-02 03:04:05Z]

  defp age!(tasks) do
    ids = Enum.map(tasks, & &1.id)
    from(t in Task, where: t.id in ^ids) |> Repo.update_all(set: [updated_at: @old])
    Enum.map(tasks, &Repo.reload!/1)
  end

  describe "parent_goal_column_ids/1 (D368)" do
    test "lists the parent goal's column and every column its children sit in" do
      board = board_fixture(user_fixture())
      backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      goal = task_fixture(backlog, %{title: "Goal", type: :goal})
      mover = task_fixture(ready, %{title: "Mover", parent_id: goal.id})
      _sibling = task_fixture(doing, %{title: "Sibling", parent_id: goal.id})
      _same_column = task_fixture(ready, %{title: "Same column", parent_id: goal.id})
      # Creating children re-places the goal, so put it back where the test needs it.
      from(t in Task, where: t.id == ^goal.id) |> Repo.update_all(set: [column_id: backlog.id])

      assert mover.id |> GoalPlacement.parent_goal_column_ids() |> Enum.sort() ==
               Enum.sort([backlog.id, ready.id, doing.id])
    end

    test "is empty for a task with no parent goal" do
      board = board_fixture(user_fixture())
      column = column_fixture(board)
      task = task_fixture(column)
      goal = task_fixture(column, %{title: "Childless goal", type: :goal})

      assert GoalPlacement.parent_goal_column_ids(task.id) == []
      assert GoalPlacement.parent_goal_column_ids(goal.id) == []
    end
  end

  describe "goal_column_ids/1 (D373)" do
    test "lists the goal's column and its live children's, ignoring archived children" do
      board = board_fixture(user_fixture())
      backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})
      archived_in = column_fixture(board, %{name: "Archived in"})

      goal = task_fixture(backlog, %{title: "Goal", type: :goal})
      _child = task_fixture(ready, %{title: "Child", parent_id: goal.id})
      _same = task_fixture(ready, %{title: "Same column", parent_id: goal.id})
      _other = task_fixture(doing, %{title: "Other column", parent_id: goal.id})
      archived = task_fixture(archived_in, %{title: "Archived", parent_id: goal.id})

      from(t in Task, where: t.id == ^archived.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      from(t in Task, where: t.id == ^goal.id) |> Repo.update_all(set: [column_id: backlog.id])

      assert goal.id |> GoalPlacement.goal_column_ids() |> Enum.sort() ==
               Enum.sort([backlog.id, ready.id, doing.id])
    end

    test "is empty for a goal with no live children, and for a task that is not a goal" do
      board = board_fixture(user_fixture())
      column = column_fixture(board)
      goal = task_fixture(column, %{title: "Childless goal", type: :goal})
      task = task_fixture(column, %{title: "Not a goal"})
      _child_of_task = task_fixture(column, %{title: "Child of a task", parent_id: task.id})

      assert GoalPlacement.goal_column_ids(goal.id) == []
      assert GoalPlacement.goal_column_ids(task.id) == []
      assert GoalPlacement.goal_column_ids(-1) == []
    end
  end

  describe "close_up_column_left_by/2 (D372)" do
    test "moves the live tasks below a moved task up by one and stamps only them" do
      board = board_fixture(user_fixture())
      column = column_fixture(board)
      elsewhere = column_fixture(board, %{name: "Elsewhere"})

      above = task_fixture(column, %{title: "Above"})
      moved = task_fixture(column, %{title: "Moved"})
      archived = task_fixture(column, %{title: "Archived"})
      below = task_fixture(column, %{title: "Below"})

      from(t in Task, where: t.id == ^archived.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      [above, moved, archived, below] = age!([above, moved, archived, below])
      from(t in Task, where: t.id == ^moved.id) |> Repo.update_all(set: [column_id: elsewhere.id])

      assert :ok = GoalPlacement.close_up_column_left_by(moved, @now)

      assert live_positions(column) == [{above.id, 0}, {below.id, 2}]
      assert Repo.reload!(below).updated_at == ~N[2026-01-02 03:04:05]
      assert Repo.reload!(above).updated_at == @old
      assert Repo.reload!(archived).position == 2
      assert Repo.reload!(archived).updated_at == @old
    end

    test "renumbers nothing for an archived task" do
      board = board_fixture(user_fixture())
      column = column_fixture(board)
      archived = task_fixture(column, %{title: "Archived"})
      below = task_fixture(column, %{title: "Below"})

      from(t in Task, where: t.id == ^archived.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      [archived, below] = age!([archived, below])

      assert :ok = GoalPlacement.close_up_column_left_by(archived, @now)

      assert Repo.reload!(below).position == 1
      assert Repo.reload!(below).updated_at == @old
    end
  end

  describe "move_goal_to_top_with_other_goals/3" do
    test "places the goal after the other goals and stamps it and the shifted tasks" do
      user = user_fixture()
      board = board_fixture(user)
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      other_goal = task_fixture(doing, %{title: "Other Goal", type: :goal})
      shifted = task_fixture(doing, %{title: "Shifted"})

      archived =
        doing
        |> task_fixture(%{title: "Archived"})
        |> tap(fn t ->
          from(x in Task, where: x.id == ^t.id)
          |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])
        end)

      [goal, other_goal, shifted, archived] = age!([goal, other_goal, shifted, archived])

      assert {:ok, :moved} = GoalPlacement.move_goal_to_top_with_other_goals(goal, doing, @now)

      placed = Repo.reload!(goal)
      assert placed.column_id == doing.id
      assert placed.position == 1
      assert placed.status == :open
      assert placed.updated_at == ~N[2026-01-02 03:04:05]

      assert Repo.reload!(shifted).position == 2
      assert Repo.reload!(shifted).updated_at == ~N[2026-01-02 03:04:05]

      assert Repo.reload!(other_goal).updated_at == @old
      assert Repo.reload!(archived).updated_at == @old
      assert Repo.reload!(archived).position == archived.position
    end

    test "re-placing a goal from the last position leaves its old column contiguous" do
      board = board_fixture(user_fixture())
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})
      lone = column_fixture(board, %{name: "Lone"})
      done = column_fixture(board, %{name: "Done"})

      first = task_fixture(ready, %{title: "First"})
      second = task_fixture(ready, %{title: "Second"})
      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      # A goal that is the only live task in its column leaves nothing to
      # renumber, including when it is promoted to Done.
      lone_goal = task_fixture(lone, %{title: "Lone goal", type: :goal})
      [first, second, goal, lone_goal] = age!([first, second, goal, lone_goal])
      assert live_positions(ready) == [{first.id, 0}, {second.id, 1}, {goal.id, 2}]

      assert {:ok, :moved} = GoalPlacement.move_goal_to_top_with_other_goals(goal, doing, @now)

      assert live_positions(ready) == [{first.id, 0}, {second.id, 1}]
      assert Repo.reload!(first).updated_at == @old
      assert Repo.reload!(second).updated_at == @old

      assert {:ok, :moved} =
               GoalPlacement.move_goal_to_top_with_other_goals(lone_goal, done, @now)

      assert live_positions(lone) == []
      assert Repo.reload!(lone_goal).column_id == done.id
      assert Repo.reload!(lone_goal).status == :completed
    end

    test "re-placing a goal from a mid-column position renumbers the tasks below it and bumps their updated_at" do
      board = board_fixture(user_fixture())
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      above = task_fixture(ready, %{title: "Above"})
      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      below = task_fixture(ready, %{title: "Below"})
      archived = task_fixture(ready, %{title: "Archived"})
      last = task_fixture(ready, %{title: "Last"})

      from(t in Task, where: t.id == ^archived.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      [above, goal, below, archived, last] = age!([above, goal, below, archived, last])
      assert live_positions(ready) == [{above.id, 0}, {goal.id, 1}, {below.id, 2}, {last.id, 4}]

      assert {:ok, :moved} = GoalPlacement.move_goal_to_top_with_other_goals(goal, doing, @now)

      # The archived gap at 3 predates the move and is not this close-up's to fill.
      assert live_positions(ready) == [{above.id, 0}, {below.id, 1}, {last.id, 3}]
      assert Repo.reload!(above).updated_at == @old
      assert Repo.reload!(below).updated_at == ~N[2026-01-02 03:04:05]
      assert Repo.reload!(last).updated_at == ~N[2026-01-02 03:04:05]

      assert Repo.reload!(archived).position == 3
      assert Repo.reload!(archived).updated_at == @old
    end

    test "an archived goal's stale position renumbers nothing in the column it leaves" do
      board = board_fixture(user_fixture())
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      below = task_fixture(ready, %{title: "Below"})

      from(t in Task, where: t.id == ^goal.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      [goal, below] = age!([goal, below])

      assert {:ok, :moved} = GoalPlacement.move_goal_to_top_with_other_goals(goal, doing, @now)

      assert live_positions(ready) == [{below.id, 1}]
      assert Repo.reload!(below).updated_at == @old
    end
  end

  # D372 made the re-placement one transaction for the callers that run it
  # after their own transaction has committed. This proves a failure part-way
  # undoes every write, with no caller transaction around the call (W2362).
  describe "a failed re-placement with no caller transaction (W2362)" do
    setup do
      original = Application.get_env(:kanban, GoalPlacement)
      on_exit(fn -> restore_env(original) end)
    end

    defp restore_env(nil), do: Application.delete_env(:kanban, GoalPlacement)
    defp restore_env(original), do: Application.put_env(:kanban, GoalPlacement, original)

    test "a failure after parking rolls the goal and both columns back" do
      board = board_fixture(user_fixture())
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      # Tasks below the goal make the close-up write rows before the failure;
      # tasks in the target column sit where the shifts would have run.
      above = task_fixture(ready, %{title: "Above"})
      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      below = task_fixture(ready, %{title: "Below"})
      last = task_fixture(ready, %{title: "Last"})
      first_doing = task_fixture(doing, %{title: "First doing"})
      second_doing = task_fixture(doing, %{title: "Second doing"})

      [goal | _] = age!([goal, above, below, last, first_doing, second_doing])
      before = snapshot([ready, doing])

      test_pid = self()

      Application.put_env(:kanban, GoalPlacement,
        after_park: fn goal_id ->
          send(test_pid, {:parked, goal_id, live_positions(ready)})
          raise "re-placement failed after parking"
        end
      )

      assert_raise RuntimeError, "re-placement failed after parking", fn ->
        GoalPlacement.move_goal_to_top_with_other_goals(goal, doing, @now)
      end

      # The close-up had renumbered the old column before the failure.
      goal_id = goal.id
      assert_received {:parked, ^goal_id, closed_up}
      assert closed_up == [{above.id, 0}, {below.id, 1}, {last.id, 2}]

      assert snapshot([ready, doing]) == before

      restored = Repo.reload!(goal)
      assert {restored.column_id, restored.position} == {ready.id, 1}
      assert restored.updated_at == @old
    end
  end

  defp live_positions(column) do
    from(t in Task,
      where: t.column_id == ^column.id and is_nil(t.archived_at),
      order_by: [asc: t.position],
      select: {t.id, t.position}
    )
    |> Repo.all()
  end

  # Every row in the columns, archived or not, with what a rollback restores.
  defp snapshot(columns) do
    column_ids = Enum.map(columns, & &1.id)

    from(t in Task,
      where: t.column_id in ^column_ids,
      order_by: [asc: t.id],
      select: {t.id, t.column_id, t.position, t.updated_at}
    )
    |> Repo.all()
  end
end
