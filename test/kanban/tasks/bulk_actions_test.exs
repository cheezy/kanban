defmodule Kanban.Tasks.BulkActionsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.BulkActions
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    todo = column_fixture(board, %{name: "Todo"})
    done = column_fixture(board, %{name: "Done"})

    %{owner: owner, scope: user_scope_fixture(owner), board: board, todo: todo, done: done}
  end

  defp reload(task), do: Repo.get!(Task, task.id)

  defp positions(column) do
    Task
    |> where([t], t.column_id == ^column.id and is_nil(t.archived_at))
    |> order_by([t], asc: t.position)
    |> select([t], {t.id, t.position})
    |> Repo.all()
  end

  defp other_board_task do
    other = user_fixture()
    other_board = board_fixture(other)
    other_column = column_fixture(other_board)
    {other_board, other_column, task_fixture(other_column)}
  end

  defp member_scope(board, owner, access) do
    member = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, member, access, owner)
    {member, user_scope_fixture(member)}
  end

  defp subscribe(board), do: Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

  describe "move/4" do
    test "appends the selected tasks to the target in board order and renumbers the source",
         %{scope: scope, board: board, todo: todo, done: done} do
      t1 = task_fixture(todo)
      t2 = task_fixture(todo)
      t3 = task_fixture(todo)
      existing = task_fixture(done)

      assert {:ok, %{count: 2, skipped_goals: 0}} =
               BulkActions.move(scope, board, [t3.id, t1.id], done.id)

      assert positions(done) == [{existing.id, 0}, {t1.id, 1}, {t3.id, 2}]
      assert positions(todo) == [{t2.id, 0}]
      assert reload(t1).status == :completed

      assert from(h in TaskHistory,
               where: h.task_id == ^t1.id and h.type == :move and h.to_column == "Done"
             )
             |> Repo.exists?()
    end

    test "renumbers several source columns correctly", %{
      scope: scope,
      board: board,
      todo: todo,
      done: done
    } do
      other = column_fixture(board, %{name: "Other"})
      a1 = task_fixture(todo)
      a2 = task_fixture(todo)
      a3 = task_fixture(todo)
      b1 = task_fixture(other)
      b2 = task_fixture(other)

      assert {:ok, %{count: 4}} =
               BulkActions.move(scope, board, [a1.id, a2.id, b1.id, b2.id], done.id)

      # a2 is moved after a1 has already shifted it to position 0, so the
      # gap it leaves must be closed from its current position, not its
      # stale one.
      assert positions(todo) == [{a3.id, 0}]
      assert positions(other) == []
      assert done |> positions() |> Enum.map(&elem(&1, 0)) == [a1.id, a2.id, b1.id, b2.id]
    end

    test "broadcasts exactly one board refresh and no per-task move", %{
      scope: scope,
      board: board,
      todo: todo,
      done: done
    } do
      t1 = task_fixture(todo)
      t2 = task_fixture(todo)
      subscribe(board)

      assert {:ok, %{count: 2}} = BulkActions.move(scope, board, [t1.id, t2.id], done.id)

      assert_receive {Kanban.Tasks, :task_updated, _}
      refute_receive {Kanban.Tasks, :task_updated, _}, 50
      refute_received {Kanban.Tasks, :task_moved, _}
    end

    test "changes nothing when the move would exceed the target's WIP limit", %{
      scope: scope,
      board: board,
      todo: todo
    } do
      limited = column_fixture(board, %{name: "Limited", wip_limit: 2})
      _already = task_fixture(limited)
      t1 = task_fixture(todo)
      t2 = task_fixture(todo)
      before = positions(todo)

      assert {:error, :wip_limit_reached} =
               BulkActions.move(scope, board, [t1.id, t2.id], limited.id)

      assert positions(todo) == before
      assert reload(t1).column_id == todo.id

      assert {:ok, %{count: 1}} = BulkActions.move(scope, board, [t1.id], limited.id)
    end

    test "skips goals and tasks already in the target", %{
      scope: scope,
      board: board,
      todo: todo,
      done: done
    } do
      goal = task_fixture(todo, %{type: :goal, title: "Goal"})
      work = task_fixture(todo)
      already = task_fixture(done)

      assert {:ok, %{count: 1, skipped_goals: 1}} =
               BulkActions.move(scope, board, [goal.id, work.id, already.id], done.id)

      assert reload(goal).column_id == todo.id
      assert reload(work).column_id == done.id
    end

    test "aborts with no changes when an id belongs to another board", %{
      scope: scope,
      board: board,
      todo: todo,
      done: done
    } do
      mine = task_fixture(todo)
      {_other_board, _other_column, foreign} = other_board_task()

      assert {:error, :not_found} = BulkActions.move(scope, board, [mine.id, foreign.id], done.id)
      assert reload(mine).column_id == todo.id
      assert reload(foreign).column_id != done.id
    end

    test "treats archived, missing and malformed ids as not found", %{
      scope: scope,
      board: board,
      todo: todo,
      done: done
    } do
      task = task_fixture(todo)
      {:ok, archived} = todo |> task_fixture() |> Tasks.archive_task()

      assert {:error, :not_found} = BulkActions.move(scope, board, [archived.id], done.id)
      assert {:error, :not_found} = BulkActions.move(scope, board, [task.id, -1], done.id)
      assert {:error, :not_found} = BulkActions.move(scope, board, [to_string(task.id)], done.id)
      assert {:error, :not_found} = BulkActions.move(scope, board, :all, done.id)
    end

    test "rejects a column from another board", %{scope: scope, board: board, todo: todo} do
      task = task_fixture(todo)
      {_other_board, other_column, _} = other_board_task()

      assert {:error, :invalid_column} =
               BulkActions.move(scope, board, [task.id], other_column.id)

      assert {:error, :invalid_column} = BulkActions.move(scope, board, [task.id], nil)
      assert reload(task).column_id == todo.id
    end

    test "refuses read-only members, non-members and a missing scope; allows modify members",
         %{owner: owner, board: board, todo: todo, done: done} do
      task = task_fixture(todo)
      {_reader, reader_scope} = member_scope(board, owner, :read_only)
      {_editor, editor_scope} = member_scope(board, owner, :modify)

      assert {:error, :unauthorized} = BulkActions.move(reader_scope, board, [task.id], done.id)

      stranger = user_fixture() |> user_scope_fixture()
      assert {:error, :unauthorized} = BulkActions.move(stranger, board, [task.id], done.id)

      assert {:error, :unauthorized} = BulkActions.move(nil, board, [task.id], done.id)
      assert reload(task).column_id == todo.id

      assert {:ok, %{count: 1}} = BulkActions.move(editor_scope, board, [task.id], done.id)
    end

    test "refuses an empty selection", %{scope: scope, board: board, done: done} do
      assert {:error, :empty_selection} = BulkActions.move(scope, board, [], done.id)
    end
  end

  describe "assign/4" do
    test "assigns the tasks to a member, recording history and broadcasting once",
         %{owner: owner, scope: scope, board: board, todo: todo} do
      {member, _} = member_scope(board, owner, :modify)
      t1 = task_fixture(todo)
      t2 = task_fixture(todo)
      subscribe(board)

      assert {:ok, %{count: 2, skipped_goals: 0}} =
               BulkActions.assign(scope, board, [t1.id, t2.id], member.id)

      assert reload(t1).assigned_to_id == member.id
      assert reload(t2).assigned_to_id == member.id

      assert from(h in TaskHistory,
               where: h.task_id in ^[t1.id, t2.id] and h.type == :assignment
             )
             |> Repo.aggregate(:count) == 2

      assert_receive {Kanban.Tasks, :task_updated, _}
      refute_receive {Kanban.Tasks, :task_updated, _}, 50
    end

    test "unassigns with nil and skips tasks that would not change", %{
      owner: owner,
      scope: scope,
      board: board,
      todo: todo
    } do
      t1 = task_fixture(todo, %{assigned_to_id: owner.id})
      t2 = task_fixture(todo)

      assert {:ok, %{count: 1}} = BulkActions.assign(scope, board, [t1.id, t2.id], nil)
      assert reload(t1).assigned_to_id == nil
    end

    test "allows read-only members as assignees", %{
      owner: owner,
      scope: scope,
      board: board,
      todo: todo
    } do
      {reader, _} = member_scope(board, owner, :read_only)
      task = task_fixture(todo)

      assert {:ok, %{count: 1}} = BulkActions.assign(scope, board, [task.id], reader.id)
    end

    test "rejects a non-member and malformed assignees", %{
      scope: scope,
      board: board,
      todo: todo
    } do
      task = task_fixture(todo)
      outsider = user_fixture()

      assert {:error, :invalid_assignee} =
               BulkActions.assign(scope, board, [task.id], outsider.id)

      assert {:error, :invalid_assignee} = BulkActions.assign(scope, board, [task.id], :invalid)
      assert reload(task).assigned_to_id == nil
    end

    test "skips goals and aborts on a foreign id", %{
      owner: owner,
      scope: scope,
      board: board,
      todo: todo
    } do
      goal = task_fixture(todo, %{type: :goal, title: "Goal"})
      task = task_fixture(todo)

      assert {:ok, %{count: 1, skipped_goals: 1}} =
               BulkActions.assign(scope, board, [goal.id, task.id], owner.id)

      assert reload(goal).assigned_to_id == nil

      {_other_board, _other_column, foreign} = other_board_task()
      other_task = task_fixture(todo)

      assert {:error, :not_found} =
               BulkActions.assign(scope, board, [other_task.id, foreign.id], owner.id)

      assert reload(other_task).assigned_to_id == nil
    end

    test "is refused for a read-only member", %{owner: owner, board: board, todo: todo} do
      task = task_fixture(todo)
      {_reader, reader_scope} = member_scope(board, owner, :read_only)

      assert {:error, :unauthorized} =
               BulkActions.assign(reader_scope, board, [task.id], owner.id)
    end
  end

  describe "add_label/4 and remove_label/4" do
    defp label_ids(task) do
      TaskLabel
      |> where([tl], tl.task_id == ^task.id)
      |> select([tl], tl.label_id)
      |> Repo.all()
      |> Enum.sort()
    end

    test "add keeps existing labels, is idempotent and labels goals", %{
      scope: scope,
      board: board,
      todo: todo
    } do
      bug = label_fixture(board, %{name: "bug"})
      ui = label_fixture(board, %{name: "ui"})
      task = task_fixture(todo)
      goal = task_fixture(todo, %{type: :goal, title: "Goal"})
      {:ok, _} = Kanban.Labels.set_task_labels(scope, task, [bug.id])

      assert {:ok, %{count: 2, skipped_goals: 0}} =
               BulkActions.add_label(scope, board, [task.id, goal.id], ui.id)

      assert label_ids(task) == Enum.sort([bug.id, ui.id])
      assert label_ids(goal) == [ui.id]

      assert {:ok, %{count: 0}} = BulkActions.add_label(scope, board, [task.id], ui.id)
    end

    test "add broadcasts once, and not at all when nothing changed", %{
      scope: scope,
      board: board,
      todo: todo
    } do
      label = label_fixture(board)
      t1 = task_fixture(todo)
      t2 = task_fixture(todo)
      subscribe(board)

      assert {:ok, %{count: 2}} = BulkActions.add_label(scope, board, [t1.id, t2.id], label.id)
      assert_receive {Kanban.Tasks, :task_updated, _}
      refute_receive {Kanban.Tasks, :task_updated, _}, 50

      assert {:ok, %{count: 0}} = BulkActions.add_label(scope, board, [t1.id], label.id)
      refute_receive {Kanban.Tasks, :task_updated, _}, 50
    end

    test "rejects another board's label", %{scope: scope, board: board, todo: todo} do
      task = task_fixture(todo)
      {other_board, _other_column, _} = other_board_task()
      foreign_label = label_fixture(other_board)

      assert {:error, :invalid_label} =
               BulkActions.add_label(scope, board, [task.id], foreign_label.id)

      assert {:error, :invalid_label} =
               BulkActions.remove_label(scope, board, [task.id], foreign_label.id)

      assert {:error, :invalid_label} = BulkActions.add_label(scope, board, [task.id], nil)
      assert label_ids(task) == []
    end

    test "remove takes only that label from only the selected tasks", %{
      scope: scope,
      board: board,
      todo: todo
    } do
      bug = label_fixture(board, %{name: "bug"})
      ui = label_fixture(board, %{name: "ui"})
      selected = task_fixture(todo)
      untouched = task_fixture(todo)
      {:ok, _} = Kanban.Labels.set_task_labels(scope, selected, [bug.id, ui.id])
      {:ok, _} = Kanban.Labels.set_task_labels(scope, untouched, [bug.id])

      assert {:ok, %{count: 1}} = BulkActions.remove_label(scope, board, [selected.id], bug.id)

      assert label_ids(selected) == [ui.id]
      assert label_ids(untouched) == [bug.id]
    end

    test "label actions are refused for a read-only member", %{
      owner: owner,
      board: board,
      todo: todo
    } do
      label = label_fixture(board)
      task = task_fixture(todo)
      {_reader, reader_scope} = member_scope(board, owner, :read_only)

      assert {:error, :unauthorized} =
               BulkActions.add_label(reader_scope, board, [task.id], label.id)

      assert {:error, :unauthorized} =
               BulkActions.remove_label(reader_scope, board, [task.id], label.id)
    end
  end

  describe "archive/3" do
    test "archives with the same fields as a single archive, with telemetry and one broadcast",
         %{scope: scope, board: board, todo: todo} do
      t1 = task_fixture(todo)
      t2 = task_fixture(todo)
      handler = "bulk-archive-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:kanban, :task, :archived],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:archived_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      subscribe(board)

      assert {:ok, %{count: 2, skipped_goals: 0}} =
               BulkActions.archive(scope, board, [t1.id, t2.id])

      archived = reload(t1)
      assert archived.archived_at
      assert archived.archive_reason == nil
      assert archived.archived_by_id == nil
      assert reload(t2).archived_at

      t1_id = t1.id
      assert_receive {:archived_event, %{task_id: ^t1_id}, %{via: :bulk}}
      assert_receive {:archived_event, %{task_id: _}, %{via: :bulk}}
      assert_receive {Kanban.Tasks, :task_updated, _}
      refute_receive {Kanban.Tasks, :task_updated, _}, 50
    end

    test "skips goals", %{scope: scope, board: board, todo: todo} do
      goal = task_fixture(todo, %{type: :goal, title: "Goal"})

      assert {:ok, %{count: 0, skipped_goals: 1}} = BulkActions.archive(scope, board, [goal.id])
      assert reload(goal).archived_at == nil
    end

    test "aborts with no changes on a foreign id", %{scope: scope, board: board, todo: todo} do
      task = task_fixture(todo)
      {_other_board, _other_column, foreign} = other_board_task()

      assert {:error, :not_found} = BulkActions.archive(scope, board, [task.id, foreign.id])
      assert reload(task).archived_at == nil
      assert reload(foreign).archived_at == nil
    end

    test "is refused for a read-only member", %{owner: owner, board: board, todo: todo} do
      task = task_fixture(todo)
      {_reader, reader_scope} = member_scope(board, owner, :read_only)

      assert {:error, :unauthorized} = BulkActions.archive(reader_scope, board, [task.id])
      assert reload(task).archived_at == nil
    end
  end

  describe "Kanban.Tasks facade" do
    test "delegates every bulk action", %{
      owner: owner,
      scope: scope,
      board: board,
      todo: todo,
      done: done
    } do
      label = label_fixture(board)
      task = task_fixture(todo)

      assert {:ok, %{count: 1}} = Tasks.bulk_add_label(scope, board, [task.id], label.id)
      assert label_ids(task) == [label.id]
      assert {:ok, %{count: 1}} = Tasks.bulk_remove_label(scope, board, [task.id], label.id)
      assert label_ids(task) == []
      assert {:ok, %{count: 1}} = Tasks.bulk_assign_tasks(scope, board, [task.id], owner.id)
      assert reload(task).assigned_to_id == owner.id
      assert {:ok, %{count: 1}} = Tasks.bulk_move_tasks(scope, board, [task.id], done.id)
      assert reload(task).column_id == done.id
      assert {:ok, %{count: 1}} = Tasks.bulk_archive_tasks(scope, board, [task.id])
      assert reload(task).archived_at
    end
  end
end
