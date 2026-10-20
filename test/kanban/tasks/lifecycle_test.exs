defmodule Kanban.Tasks.LifecycleTest do
  @moduledoc """
  Tests for `Kanban.Tasks.Lifecycle`: `update_changed_files/2` (D36 nil
  rejection), the `update_task/3` task_assigned notifications (W2203), and the
  refusal of dependencies that name no task on the board.
  The archive tests moved to `Kanban.Tasks.ArchivingTest` in W2350.
  """
  use Kanban.DataCase
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.ColumnLockHelpers
  alias Kanban.Notifications
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Lifecycle
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  describe "update_changed_files/2 — D36 nil rejection" do
    test "raises FunctionClauseError when given nil", %{column: column} do
      task = task_fixture(column)

      assert_raise FunctionClauseError, fn ->
        # apply/3 keeps the deliberately-invalid nil opaque to the Elixir 1.20
        # type checker while still raising at runtime.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Lifecycle, :update_changed_files, [task, nil])
      end
    end

    test "accepts an empty list (explicit clear)", %{column: column} do
      task = task_fixture(column)
      assert {:ok, %Task{changed_files: []}} = Lifecycle.update_changed_files(task, [])
    end

    test "accepts a populated list", %{column: column} do
      task = task_fixture(column)
      entry = %{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"}
      assert {:ok, %Task{changed_files: [^entry]}} = Lifecycle.update_changed_files(task, [entry])
    end
  end

  describe "update_task/3 and api_update_task/2 — dependencies on the board" do
    test "refuse an identifier with no task on the board and save nothing", %{column: column} do
      task = task_fixture(column)

      for update <- [
            &Tasks.update_task(&1, %{dependencies: ["W900"]}),
            &Lifecycle.api_update_task(&1, %{"dependencies" => ["W900"]})
          ] do
        assert {:error, changeset} = update.(task)

        assert errors_on(changeset).dependencies == [
                 "lists tasks that are not on this board: W900"
               ]
      end

      assert Repo.get!(Task, task.id).dependencies == []
    end

    test "still save other edits to a task that already holds a dangling dependency", %{
      column: column
    } do
      task =
        column
        |> task_fixture()
        |> Ecto.Changeset.change(dependencies: ["W900"])
        |> Repo.update!()

      assert {:ok, %Task{title: "Renamed"}} = Tasks.update_task(task, %{title: "Renamed"})
    end
  end

  describe "update_task/3 — task_assigned notifications (W2203)" do
    setup %{user: user, board: board} do
      assignee = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, assignee, :modify, user)
      %{assignee: assignee}
    end

    defp assignments do
      Notification
      |> where(event_type: :task_assigned)
      |> Repo.all()
    end

    test "notifies the new assignee once, live and by email", ctx do
      task = task_fixture(ctx.column)
      :ok = Notifications.subscribe(ctx.assignee)

      assert {:ok, _} =
               Tasks.update_task(task, %{assigned_to_id: ctx.assignee.id}, actor: ctx.user)

      assert [%Notification{user_id: user_id} = n] = assignments()
      assert user_id == ctx.assignee.id
      assert n.url_path == "/boards/#{ctx.board.id}/tasks/#{task.id}/edit"
      assert n.task_id == task.id
      assert_receive {:notification_created, %Notification{event_type: :task_assigned}}
      assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "assigning a task to yourself notifies nobody", ctx do
      task = task_fixture(ctx.column)

      assert {:ok, _} = Tasks.update_task(task, %{assigned_to_id: ctx.user.id}, actor: ctx.user)
      assert assignments() == []
    end

    test "clearing the assignee notifies nobody", ctx do
      task = task_fixture(ctx.column, %{assigned_to_id: ctx.assignee.id})

      assert {:ok, _} = Tasks.update_task(task, %{assigned_to_id: nil}, actor: ctx.user)
      assert assignments() == []
    end

    test "update_task/2 without an actor still notifies the assignee", ctx do
      task = task_fixture(ctx.column)

      assert {:ok, _} = Tasks.update_task(task, %{assigned_to_id: ctx.assignee.id})
      assert [%Notification{}] = assignments()
    end

    test "a change that leaves the assignee alone notifies nobody", ctx do
      task = task_fixture(ctx.column, %{assigned_to_id: ctx.assignee.id})

      assert {:ok, _} = Tasks.update_task(task, %{title: "Renamed"}, actor: ctx.user)
      assert assignments() == []
    end

    test "a goal reassignment that cascades to children notifies once, for the goal", ctx do
      goal = task_fixture(ctx.column, %{type: :goal})
      for _ <- 1..3, do: task_fixture(ctx.column, %{parent_id: goal.id})

      assert {:ok, _} =
               Tasks.update_task(goal, %{assigned_to_id: ctx.assignee.id}, actor: ctx.user)

      assert [%Notification{task_id: task_id}] = assignments()
      assert task_id == goal.id
    end

    test "a goal whose children already have the assignee still notifies once", ctx do
      goal = task_fixture(ctx.column, %{type: :goal})

      for _ <- 1..2,
          do: task_fixture(ctx.column, %{parent_id: goal.id, assigned_to_id: ctx.assignee.id})

      assert {:ok, _} =
               Tasks.update_task(goal, %{assigned_to_id: ctx.assignee.id}, actor: ctx.user)

      assert [%Notification{}] = assignments()
    end

    test "an assignee who is not on the board is not notified", ctx do
      task = task_fixture(ctx.column)
      outsider = user_fixture()

      assert {:ok, _} = Tasks.update_task(task, %{assigned_to_id: outsider.id}, actor: ctx.user)
      assert assignments() == []
    end

    test "a failed update notifies nobody", ctx do
      task = task_fixture(ctx.column)

      assert {:error, _} =
               Tasks.update_task(task, %{assigned_to_id: ctx.assignee.id, title: ""},
                 actor: ctx.user
               )

      assert assignments() == []
    end
  end

  describe "moving a task between goals re-places both under column locks (D373)" do
    test "moving a task between goals via update_task re-places both goals under locks",
         %{column: created_in, board: board} do
      old_goal_column = column_fixture(board, %{name: "Old goal column"})
      new_goal_column = column_fixture(board, %{name: "New goal column"})
      old_goal = task_fixture(created_in, %{title: "Old goal", type: :goal})
      new_goal = task_fixture(created_in, %{title: "New goal", type: :goal})
      task = task_fixture(created_in, %{title: "Mover", parent_id: old_goal.id})
      _stays = task_fixture(created_in, %{title: "Stays", parent_id: old_goal.id})

      # Both goals sit in columns only the second session locks; each is
      # re-placed into its children's column, so each must wait for it.
      ColumnLockHelpers.relocate!(old_goal.id, old_goal_column.id, 0)
      ColumnLockHelpers.relocate!(new_goal.id, new_goal_column.id, 0)
      holder = ColumnLockHelpers.hold_columns([old_goal_column.id, new_goal_column.id], 400)

      {waited, result} =
        ColumnLockHelpers.timed(fn -> Tasks.update_task(task, %{parent_id: new_goal.id}) end)

      assert {:ok, :held} = Elixir.Task.await(holder, 10_000)
      assert {:ok, %Task{parent_id: parent_id}} = result
      assert parent_id == new_goal.id
      assert waited >= 300
      assert Repo.get!(Task, old_goal.id).column_id == created_in.id
      assert Repo.get!(Task, new_goal.id).column_id == created_in.id
    end
  end
end
