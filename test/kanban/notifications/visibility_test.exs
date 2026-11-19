defmodule Kanban.Notifications.VisibilityTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Notifications
  alias Kanban.Notifications.Visibility

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board, %{name: "Ready"})
    %{user: user, board: board, column: column, scope: Scope.for_user(user)}
  end

  defp task_notification!(user, board, task, event_type \\ :task_unclaimed) do
    notification_fixture(user, %{event_type: event_type, board_id: board.id, task_id: task.id})
  end

  describe "query/1" do
    test "selects only the scoped user's own in-app rows on their boards", ctx do
      task = task_fixture(ctx.column)
      mine = task_notification!(ctx.user, ctx.board, task)

      other = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, other, :modify, ctx.user)
      task_notification!(other, ctx.board, task)

      assert ctx.scope |> Visibility.query() |> Repo.all() |> Enum.map(& &1.id) == [mine.id]
    end
  end

  describe "list_task_notifications/4" do
    test "returns the given event types on the given boards, newest first, with task and column",
         ctx do
      task = task_fixture(ctx.column)
      older = task_notification!(ctx.user, ctx.board, task, :task_unclaimed)
      newer = task_notification!(ctx.user, ctx.board, task, :claim_expired)
      task_notification!(ctx.user, ctx.board, task, :task_assigned)

      rows =
        Notifications.list_task_notifications(
          ctx.scope,
          [:task_unclaimed, :claim_expired],
          [ctx.board.id]
        )

      assert Enum.map(rows, & &1.id) == [newer.id, older.id]
      assert [%{task: %{id: task_id, column: %{board_id: board_id}}} | _] = rows
      assert task_id == task.id
      assert board_id == ctx.board.id
    end

    test "leaves out other boards, archived tasks and other task statuses", ctx do
      task = task_fixture(ctx.column)
      task_notification!(ctx.user, ctx.board, task)

      assert Notifications.list_task_notifications(ctx.scope, [:task_unclaimed], [-1]) == []

      assert Notifications.list_task_notifications(ctx.scope, [:task_unclaimed], [ctx.board.id],
               task_statuses: [:in_progress]
             ) == []

      assert [_] =
               Notifications.list_task_notifications(ctx.scope, [:task_unclaimed], [ctx.board.id],
                 task_statuses: [:open]
               )

      task |> Ecto.Changeset.change(%{archived_at: DateTime.utc_now(:second)}) |> Repo.update!()

      assert Notifications.list_task_notifications(ctx.scope, [:task_unclaimed], [ctx.board.id]) ==
               []
    end

    test "an empty board or event type list returns [] without querying", ctx do
      assert Visibility.list_task_notifications(ctx.scope, [:task_unclaimed], []) == []
      assert Visibility.list_task_notifications(ctx.scope, [], [ctx.board.id]) == []
    end
  end
end
