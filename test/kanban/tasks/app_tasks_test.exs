defmodule Kanban.Tasks.AppTasksTest do
  @moduledoc "Tests for `Kanban.Tasks.AppTasks` (W2760): the app's task lookup and capture."
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    {:ok, board} = Boards.get_board(board.id, user)

    %{user: user, scope: user_scope_fixture(user), board: board, cols: cols}
  end

  describe "get_task_for_app/2" do
    test "returns the task with its column and labels and the board with access", ctx do
      task = task_fixture(ctx.cols["Ready"])

      assert {:ok, %Task{id: id} = found, board} = Tasks.get_task_for_app(ctx.scope, task.id)
      assert id == task.id
      assert found.column.id == ctx.cols["Ready"].id
      assert found.labels == []
      assert board.id == ctx.board.id
      assert board.user_access == :owner
    end

    test "a read-only member finds it, with read_only access", ctx do
      task = task_fixture(ctx.cols["Ready"])
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.user)

      reader_scope = user_scope_fixture(reader)

      assert {:ok, _task, %{user_access: :read_only}} =
               Tasks.get_task_for_app(reader_scope, task.id)
    end

    test "an archived task is found", ctx do
      {:ok, archived} = ctx.cols["Ready"] |> task_fixture() |> Tasks.archive_task()

      assert {:ok, %Task{archived_at: %DateTime{}}, _} =
               Tasks.get_task_for_app(ctx.scope, archived.id)
    end

    test "a stranger, a public board's non-member, a missing id or no scope is :not_found",
         ctx do
      task = task_fixture(ctx.cols["Ready"])
      stranger = user_scope_fixture(user_fixture())

      assert Tasks.get_task_for_app(stranger, task.id) == {:error, :not_found}

      ctx.board |> Ecto.Changeset.change(read_only: true) |> Repo.update!()
      assert Tasks.get_task_for_app(stranger, task.id) == {:error, :not_found}

      assert Tasks.get_task_for_app(ctx.scope, task.id + 1_000_000) == {:error, :not_found}
      assert Tasks.get_task_for_app(nil, task.id) == {:error, :not_found}
      assert Tasks.get_task_for_app(ctx.scope, "1") == {:error, :not_found}
    end
  end

  describe "get_goal_for_app/2 (W2761)" do
    test "returns a goal with its board", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})

      assert {:ok, %Task{id: id, type: :goal}, board} = Tasks.get_goal_for_app(ctx.scope, goal.id)
      assert id == goal.id
      assert board.id == ctx.board.id
    end

    test "a work or defect task, a stranger's goal or no scope is :not_found", ctx do
      work = task_fixture(ctx.cols["Ready"])
      defect = task_fixture(ctx.cols["Ready"], %{type: :defect})
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      stranger = user_scope_fixture(user_fixture())

      assert Tasks.get_goal_for_app(ctx.scope, work.id) == {:error, :not_found}
      assert Tasks.get_goal_for_app(ctx.scope, defect.id) == {:error, :not_found}
      assert Tasks.get_goal_for_app(stranger, goal.id) == {:error, :not_found}
      assert Tasks.get_goal_for_app(nil, goal.id) == {:error, :not_found}
    end
  end

  describe "capture_task/3" do
    test "creates the task at the end of Backlog with created_via mobile", ctx do
      task_fixture(ctx.cols["Backlog"])

      assert {:ok, task} =
               Tasks.capture_task(ctx.scope, ctx.board, %{
                 type: "defect",
                 title: "Captured",
                 description: "One sentence."
               })

      assert %Task{
               type: :defect,
               title: "Captured",
               description: "One sentence.",
               created_via: :mobile,
               position: 1,
               status: :open
             } = task

      assert task.column.id == ctx.cols["Backlog"].id
      assert task.created_by_id == ctx.user.id
      assert task.labels == []
    end

    test "reads only type, title and description", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})

      assert {:ok, task} =
               Tasks.capture_task(ctx.scope, ctx.board, %{
                 type: "work",
                 title: "Only these",
                 parent_id: goal.id,
                 column_id: ctx.cols["Ready"].id,
                 status: "completed"
               })

      assert task.parent_id == nil
      assert task.column_id == ctx.cols["Backlog"].id
      assert task.status == :open
    end

    test "refuses a goal or an unknown type with a changeset", ctx do
      for type <- ["goal", "epic", nil] do
        assert {:error, changeset} =
                 Tasks.capture_task(ctx.scope, ctx.board, %{type: type, title: "No"})

        assert %{type: ["is invalid"]} = errors_on(changeset)
      end

      refute Repo.get_by(Task, title: "No")
    end

    test "re-reads write access: a read-only member and no scope are :forbidden", ctx do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.user)
      attrs = %{type: "work", title: "No"}

      reader_scope = user_scope_fixture(reader)
      assert Tasks.capture_task(reader_scope, ctx.board, attrs) == {:error, :forbidden}

      assert Tasks.capture_task(nil, ctx.board, attrs) == {:error, :forbidden}

      # A board struct claiming owner access is not trusted.
      stranger = user_scope_fixture(user_fixture())

      assert Tasks.capture_task(stranger, %{ctx.board | user_access: :owner}, attrs) ==
               {:error, :forbidden}
    end

    test "Backlog's WIP limit, a missing Backlog and an invalid title refuse it", ctx do
      task_fixture(ctx.cols["Backlog"])
      backlog = ctx.cols["Backlog"] |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()
      attrs = %{type: "work", title: "No"}

      assert Tasks.capture_task(ctx.scope, ctx.board, attrs) ==
               {:error, :backlog_wip_limit_reached}

      backlog |> Ecto.Changeset.change(wip_limit: 0) |> Repo.update!()

      assert {:error, changeset} =
               Tasks.capture_task(ctx.scope, ctx.board, %{
                 attrs
                 | title: String.duplicate("t", 256)
               })

      assert %{title: [_too_long]} = errors_on(changeset)

      backlog |> Ecto.Changeset.change(name: "Ideas") |> Repo.update!()
      assert Tasks.capture_task(ctx.scope, ctx.board, attrs) == {:error, :no_backlog_column}
      refute Repo.get_by(Task, title: "No")
    end
  end
end
