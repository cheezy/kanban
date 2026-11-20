defmodule Kanban.Tasks.MoveToBacklogTest do
  @moduledoc """
  Tests for `Kanban.Tasks.MoveToBacklog` (W2760): the app's move of a released
  task in Ready, or an expired claim in Doing, to Backlog.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  setup do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

    %{user: user, scope: user_scope_fixture(user), board: board, cols: cols}
  end

  test "moves a Ready task to the end of Backlog, broadcasts it and emits :moved", ctx do
    first = task_fixture(ctx.cols["Backlog"])
    task = task_fixture(ctx.cols["Ready"])
    Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")
    attach_telemetry([[:kanban, :task, :moved]])

    assert {:ok, %{moved: true, task: moved}} = Tasks.move_to_backlog(ctx.scope, ctx.board, task)

    assert moved.column_id == ctx.cols["Backlog"].id
    assert moved.status == :open
    assert moved.labels == []
    assert moved.position > Repo.reload!(first).position

    assert Repo.get_by(TaskHistory, task_id: task.id, type: :move, to_column: "Backlog")
    assert_receive {Kanban.Tasks, :task_moved, %Task{id: id}}
    assert id == task.id
    assert_receive {:telemetry_event, [:kanban, :task, :moved], _measurements, %{task_id: ^id}}
  end

  test "a task already in Backlog is left where it is, with nothing broadcast", ctx do
    task = task_fixture(ctx.cols["Backlog"])
    Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

    assert {:ok, %{moved: false, task: same}} = Tasks.move_to_backlog(ctx.scope, ctx.board, task)
    assert same.id == task.id
    assert Repo.reload!(task).position == task.position
    refute_receive {Kanban.Tasks, :task_moved, _}
  end

  test "re-reads the task under the locks: a task moved on since the app read it stays", ctx do
    task = task_fixture(ctx.cols["Ready"])
    # An agent claims it after the app read it in Ready.
    {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.user, ctx.board.id, task.identifier)
    assert claimed.column_id == ctx.cols["Doing"].id

    assert Tasks.move_to_backlog(ctx.scope, ctx.board, task) == {:error, :not_movable}
    assert Repo.reload!(task).column_id == ctx.cols["Doing"].id
  end

  describe "an expired claim in Doing" do
    setup ctx do
      task = task_fixture(ctx.cols["Ready"])
      {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.user, ctx.board.id, task.identifier)
      %{task: claimed}
    end

    defp expire!(task, seconds_ago) do
      task
      |> Ecto.Changeset.change(
        claim_expires_at: DateTime.utc_now(:second) |> DateTime.add(-seconds_ago)
      )
      |> Repo.update!()
    end

    test "moves to Backlog and clears the claim, as a release does", ctx do
      task = expire!(ctx.task, 60)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      assert {:ok, %{moved: true, task: moved}} =
               Tasks.move_to_backlog(ctx.scope, ctx.board, task)

      assert %Task{
               status: :open,
               claimed_at: nil,
               claim_expires_at: nil,
               assigned_to_id: nil,
               assigned_to: nil
             } = moved

      assert moved.column_id == ctx.cols["Backlog"].id

      assert %Task{claimed_at: nil, claim_expires_at: nil, assigned_to_id: nil, status: :open} =
               Repo.reload!(task)

      assert Repo.get_by(TaskHistory,
               task_id: task.id,
               type: :move,
               from_column: "Doing",
               to_column: "Backlog"
             )

      assert_receive {Kanban.Tasks, :task_moved, %Task{id: id}}
      assert id == task.id

      # Promoted again, another agent may claim it: a stale assignee would refuse that.
      other = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, other, :modify, ctx.user)

      task
      |> Repo.reload!()
      |> Ecto.Changeset.change(column_id: ctx.cols["Ready"].id)
      |> Repo.update!()

      assert {:ok, %Task{assigned_to_id: assignee}, _hook} =
               Tasks.claim_next_task([], other, ctx.board.id, task.identifier)

      assert assignee == other.id
    end

    test "a live claim, or a blocked task with an expired claim, stays in Doing", ctx do
      assert Tasks.move_to_backlog(ctx.scope, ctx.board, ctx.task) == {:error, :not_movable}

      blocked =
        ctx.task |> expire!(60) |> Ecto.Changeset.change(status: :blocked) |> Repo.update!()

      assert Tasks.move_to_backlog(ctx.scope, ctx.board, blocked) == {:error, :not_movable}

      assert %Task{column_id: doing_id, assigned_to_id: assigned} = Repo.reload!(ctx.task)
      assert doing_id == ctx.cols["Doing"].id
      assert assigned == ctx.user.id
    end

    test "an expired claim in a column other than Doing is not movable", ctx do
      review = ctx.task |> expire!(60) |> Ecto.Changeset.change(column_id: ctx.cols["Review"].id)
      review = Repo.update!(review)

      assert Tasks.move_to_backlog(ctx.scope, ctx.board, review) == {:error, :not_movable}
      assert Repo.reload!(review).column_id == ctx.cols["Review"].id
    end

    test "Backlog's WIP limit refuses it and leaves the claim in place", ctx do
      task = expire!(ctx.task, 60)
      task_fixture(ctx.cols["Backlog"])
      ctx.cols["Backlog"] |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()

      assert Tasks.move_to_backlog(ctx.scope, ctx.board, task) ==
               {:error, :backlog_wip_limit_reached}

      assert %Task{assigned_to_id: assigned, claim_expires_at: %DateTime{}} = Repo.reload!(task)
      assert assigned == ctx.user.id
    end
  end

  test "an archived or deleted task, or one on another board, is :not_found", ctx do
    {:ok, archived} = ctx.cols["Ready"] |> task_fixture() |> Tasks.archive_task()
    assert Tasks.move_to_backlog(ctx.scope, ctx.board, archived) == {:error, :not_found}

    deleted = task_fixture(ctx.cols["Ready"])
    {:ok, _} = Tasks.delete_task(deleted)
    assert Tasks.move_to_backlog(ctx.scope, ctx.board, deleted) == {:error, :not_found}

    other_board = ai_optimized_board_fixture(ctx.user)
    elsewhere = other_board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))
    foreign = task_fixture(elsewhere)
    assert Tasks.move_to_backlog(ctx.scope, ctx.board, foreign) == {:error, :not_found}
  end

  test "a goal, or a task in any column but Ready and Backlog, is :not_movable", ctx do
    goal = task_fixture(ctx.cols["Ready"], %{type: :goal})
    review = task_fixture(ctx.cols["Review"])

    assert Tasks.move_to_backlog(ctx.scope, ctx.board, goal) == {:error, :not_movable}
    assert Tasks.move_to_backlog(ctx.scope, ctx.board, review) == {:error, :not_movable}
  end

  test "re-reads write access: a read-only member and no scope are :forbidden", ctx do
    task = task_fixture(ctx.cols["Ready"])
    reader = user_fixture()
    {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.user)

    reader_scope = user_scope_fixture(reader)
    assert Tasks.move_to_backlog(reader_scope, ctx.board, task) == {:error, :forbidden}

    assert Tasks.move_to_backlog(nil, ctx.board, task) == {:error, :forbidden}
    assert Repo.reload!(task).column_id == ctx.cols["Ready"].id
  end

  test "Backlog's WIP limit and a missing Backlog column refuse the move", ctx do
    task = task_fixture(ctx.cols["Ready"])
    task_fixture(ctx.cols["Backlog"])
    backlog = ctx.cols["Backlog"] |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()

    assert Tasks.move_to_backlog(ctx.scope, ctx.board, task) ==
             {:error, :backlog_wip_limit_reached}

    # A goal in Backlog does not count towards the limit.
    backlog |> Ecto.Changeset.change(wip_limit: 2) |> Repo.update!()
    task_fixture(ctx.cols["Backlog"], %{type: :goal})
    assert {:ok, %{moved: true}} = Tasks.move_to_backlog(ctx.scope, ctx.board, task)

    other = task_fixture(ctx.cols["Ready"])
    backlog |> Ecto.Changeset.change(name: "Ideas") |> Repo.update!()
    assert Tasks.move_to_backlog(ctx.scope, ctx.board, other) == {:error, :no_backlog_column}
  end
end
