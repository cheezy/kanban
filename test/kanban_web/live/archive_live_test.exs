defmodule KanbanWeb.ArchiveLiveTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Archive Index" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays archived tasks page with board name", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Archived Tasks"
      assert html =~ board.name
    end

    test "displays back to board link", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Back to Board"
      assert html =~ ~p"/boards/#{board}"
    end

    test "displays empty state when no archived tasks exist", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "No archived tasks"
      assert html =~ "Tasks that are archived will appear here"
    end

    test "displays archived tasks in a table", %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task", type: :work})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      refute html =~ "No archived tasks"
      assert html =~ "Test Task"
      assert html =~ archived_task.identifier
      assert html =~ "Work"
    end

    test "displays task type badges correctly", %{conn: conn, board: board, column: column} do
      work_task = task_fixture(column, %{title: "Work Task", type: :work})
      defect_task = task_fixture(column, %{title: "Defect Task", type: :defect})
      goal_task = task_fixture(column, %{title: "Goal Task", type: :goal})

      Tasks.archive_task(work_task)
      Tasks.archive_task(defect_task)
      Tasks.archive_task(goal_task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Work"
      assert html =~ "Defect"
      assert html =~ "Goal"
    end

    test "displays task description when present", %{conn: conn, board: board, column: column} do
      task =
        task_fixture(column, %{
          title: "Task with description",
          description: "This is a detailed description"
        })

      Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Task with description"
      assert html =~ "This is a detailed description"
    end

    test "displays archived date", %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, _archived_task} = Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      # Check that the page contains a time element
      assert html =~ "<time"
    end

    test "displays unarchive and delete buttons when user can modify", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Unarchive"
      assert html =~ "Delete"
    end

    test "unarchive button restores task to board", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Test Task"

      # Click unarchive button
      index_live |> render_click("unarchive", %{"id" => archived_task.id})

      html = render(index_live)
      assert html =~ "Task unarchived successfully"

      # Verify task is no longer in archived list
      refute html =~ "Test Task"
    end

    test "unarchive event reloads archived tasks list", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      {:ok, archived_task1} = Tasks.archive_task(task1)
      {:ok, _archived_task2} = Tasks.archive_task(task2)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Task 1"
      assert html =~ "Task 2"

      # Unarchive task 1
      index_live |> render_click("unarchive", %{"id" => archived_task1.id})

      html = render(index_live)
      refute html =~ "Task 1"
      assert html =~ "Task 2"
    end

    test "delete button removes task permanently", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Test Task"

      # Click delete button
      index_live |> render_click("delete", %{"id" => archived_task.id})

      html = render(index_live)
      assert html =~ "Task deleted successfully"
      refute html =~ "Test Task"

      # Verify task no longer exists in database
      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(archived_task.id)
      end
    end

    test "displays multiple archived tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "First Task"})
      task2 = task_fixture(column, %{title: "Second Task"})
      task3 = task_fixture(column, %{title: "Third Task"})

      Tasks.archive_task(task1)
      Tasks.archive_task(task2)
      Tasks.archive_task(task3)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      # All tasks should be displayed
      assert html =~ "First Task"
      assert html =~ "Second Task"
      assert html =~ "Third Task"
    end

    test "only displays archived tasks, not active tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      archived_task = task_fixture(column, %{title: "Archived Task"})
      _active_task = task_fixture(column, %{title: "Active Task"})

      Tasks.archive_task(archived_task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Archived Task"
      refute html =~ "Active Task"
    end

    test "cannot access archive page for other users' boards", %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{other_board}/archive")
      end
    end

    test "handles task_updated PubSub event", %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Original Title"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Update the task
      {:ok, _updated_task} = Tasks.update_task(archived_task, %{title: "Updated Title"})

      html = render(index_live)
      assert html =~ "Updated Title"
    end

    test "handles task_deleted PubSub event", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      {:ok, archived_task1} = Tasks.archive_task(task1)
      {:ok, _archived_task2} = Tasks.archive_task(task2)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Task 1"
      assert html =~ "Task 2"

      # Delete task 1
      {:ok, _} = Tasks.delete_task(archived_task1)

      html = render(index_live)
      refute html =~ "Task 1"
      assert html =~ "Task 2"
    end

    test "user with read-only access sees archived tasks but no action buttons", %{
      conn: conn,
      user: user
    } do
      # Create a board owned by another user
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board, %{name: "Test Column"})

      # Grant read-only access to the current user
      Kanban.Boards.add_user_to_board(board, user, :read_only)

      task = task_fixture(column, %{title: "Test Task"})
      Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Test Task"
      refute html =~ "Unarchive"
      refute html =~ "Delete"
    end

    test "shows error message when unarchive fails", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, _archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Try to unarchive with invalid ID
      index_live |> render_click("unarchive", %{"id" => 999_999})

      html = render(index_live)
      assert html =~ "Failed to unarchive task"
    end

    test "shows error message when delete fails", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, _archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Try to delete with invalid ID
      index_live |> render_click("delete", %{"id" => 999_999})

      html = render(index_live)
      assert html =~ "Failed to delete task"
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = board_fixture(user)
    column = column_fixture(board, %{name: "Test Column"})
    %{board: board, column: column}
  end
end
