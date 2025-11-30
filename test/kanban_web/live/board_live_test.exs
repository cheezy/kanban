defmodule KanbanWeb.BoardLiveTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import ExUnit.CaptureLog

  @create_attrs %{name: "some name", description: "some description"}
  @update_attrs %{name: "some updated name", description: "some updated description"}
  @invalid_attrs %{name: nil, description: nil}

  describe "Index" do
    setup [:register_and_log_in_user]

    test "lists all boards", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _index_live, html} = live(conn, ~p"/boards")

      assert html =~ "Listing Boards"
      assert html =~ board.name
    end

    test "saves new board", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/boards/new")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _index_live, html} =
        form_live
        |> form("#board-form", board: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards")

      assert html =~ "some name"
    end

    test "updates board in listing", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _index_live, html} =
        form_live
        |> form("#board-form", board: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards")

      assert html =~ "some updated name"
    end

    test "deletes board in listing", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, index_live, _html} = live(conn, ~p"/boards")

      assert index_live |> element("#boards-#{board.id} a[href*='#']", "") |> render_click()
      refute has_element?(index_live, "#boards-#{board.id}")
    end

    test "cannot see other users' boards", %{conn: conn} do
      other_user = user_fixture()
      _other_board = board_fixture(other_user)

      {:ok, _index_live, html} = live(conn, ~p"/boards")

      refute html =~ "other user board"
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user]

    test "displays board", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Show Board"
      assert html =~ board.name
    end

    test "cannot access other users' boards", %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{other_board}")
      end
    end

    test "displays empty state when board has no columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "No columns yet"
      assert html =~ "Create your first column"
    end

    test "displays columns in order", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress"})
      column3 = column_fixture(board, %{name: "Done"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ column1.name
      assert html =~ column2.name
      assert html =~ column3.name

      # Check order by position in HTML
      assert html =~ ~r/To Do.*In Progress.*Done/s
    end

    test "displays WIP limit indicator when column has WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "In Progress", wip_limit: 5})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "WIP"
      assert html =~ "5"
    end

    test "does not display WIP limit indicator when limit is 0", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "Done", wip_limit: 0})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # WIP limit label should not appear when limit is 0
      refute html =~ "WIP: 0"
    end
  end

  describe "Column Management" do
    setup [:register_and_log_in_user]

    test "creates new column", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Click "New Column" button which patches to the form
      show_live |> element("a", "New Column") |> render_click()

      # Validate form shows error for missing name
      assert show_live
             |> form("#column-form", column: %{name: nil})
             |> render_change() =~ "can&#39;t be blank"

      # Submit form
      show_live
      |> form("#column-form", column: %{name: "To Do", wip_limit: 5})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column created successfully"
      assert html =~ "To Do"
      assert html =~ "WIP"
      assert html =~ "5"
    end

    test "creates column with default WIP limit of 0", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live |> element("a", "New Column") |> render_click()

      show_live
      |> form("#column-form", column: %{name: "Done"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column created successfully"
      assert html =~ "Done"
      # Should not show WIP limit indicator when it's 0
      refute html =~ "WIP: 0"
    end

    test "rejects negative WIP limit when creating column", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live |> element("a", "New Column") |> render_click()

      html =
        show_live
        |> form("#column-form", column: %{name: "Test", wip_limit: -1})
        |> render_change()

      assert html =~ "must be greater than or equal to 0"
    end

    test "edits existing column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do", wip_limit: 3})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("#columns-#{column.id} a[href*='edit']")
      |> render_click()

      show_live
      |> form("#column-form", column: %{name: "In Progress", wip_limit: 5})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column updated successfully"
      assert html =~ "In Progress"
      assert html =~ "5"
      refute html =~ "To Do"
    end

    test "rejects negative WIP limit when editing column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("#columns-#{column.id} a[href*='edit']")
      |> render_click()

      html =
        show_live
        |> form("#column-form", column: %{wip_limit: -5})
        |> render_change()

      assert html =~ "must be greater than or equal to 0"
    end

    test "deletes column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "To Do"

      # Trigger the delete_column event directly
      show_live |> render_click("delete_column", %{"id" => column.id})

      html = render(show_live)
      assert html =~ "Column deleted successfully"
      refute html =~ "To Do"
    end

    test "displays New Column button", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "New Column"
    end
  end

  describe "Task Management" do
    setup [:register_and_log_in_user]

    test "displays tasks in column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "First task", description: "Description 1"})
      task2 = task_fixture(column, %{title: "Second task"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ task1.title
      assert html =~ task1.description
      assert html =~ task2.title
    end

    test "displays empty state when column has no tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "No tasks yet"
    end

    test "displays task count in column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Tasks"
      assert html =~ ">2<"
    end

    test "creates new task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Click "Add task" button
      show_live
      |> element("a[href='/boards/#{board.id}/columns/#{column.id}/tasks/new']")
      |> render_click()

      # Validate form shows error for missing title
      assert show_live
             |> form("#task-form", task: %{title: nil})
             |> render_change() =~ "can&#39;t be blank"

      # Submit form
      show_live
      |> form("#task-form", task: %{title: "New Task", description: "Task description"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Task created successfully"
      assert html =~ "New Task"
      assert html =~ "Task description"
    end

    test "edits existing task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Original Title"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Click edit button for task
      show_live
      |> element("a[href='/boards/#{board.id}/tasks/#{task.id}/edit']")
      |> render_click()

      # Update task
      show_live
      |> form("#task-form", task: %{title: "Updated Title", description: "Updated description"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Task updated successfully"
      assert html =~ "Updated Title"
      assert html =~ "Updated description"
      refute html =~ "Original Title"
    end

    test "deletes task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task to delete"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Task to delete"

      # Trigger the delete_task event directly
      show_live |> render_click("delete_task", %{"id" => task.id})

      html = render(show_live)
      assert html =~ "Task deleted successfully"
      refute html =~ "Task to delete"
    end

    test "shows Add task button when WIP limit not reached", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      _task1 = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Add task"
    end

    test "hides Add task button when WIP limit reached", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "WIP limit reached"
      refute html =~ "Add task"
    end

    test "shows warning indicator when column exceeds WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      # Create column with higher limit initially
      column = column_fixture(board, %{name: "In Progress", wip_limit: 5})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})
      _task3 = task_fixture(column, %{title: "Task 3"})

      # Lower the WIP limit below current task count to simulate exceeding
      {:ok, _column} = Kanban.Columns.update_column(column, %{wip_limit: 2})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for red warning badge indicating limit exceeded
      assert html =~ "from-red-50 to-red-100 text-red-700"
    end

    test "displays blue indicator when column under WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      _task1 = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for blue badge when under limit
      assert html =~ "from-blue-50 to-blue-100 text-blue-700"
    end

    test "displays blue indicator when column at WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for blue badge when at limit (not exceeding)
      assert html =~ "from-blue-50 to-blue-100 text-blue-700"
      refute html =~ "from-red-50 to-red-100 text-red-700"
    end

    test "cannot create task when WIP limit reached", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 1})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Try to navigate to new task form - should show WIP limit message instead
      html = render(show_live)
      assert html =~ "WIP limit reached"
    end
  end

  describe "Drag and Drop" do
    setup [:register_and_log_in_user]

    test "moves task within same column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task3 (position 2) to position 0
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task3.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 0
      })

      # Verify task was moved by checking the order
      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task3.id, task1.id, task2.id]
    end

    test "moves task to different column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress"})
      task = task_fixture(column1, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task from column1 to column2
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task.id}",
        "old_column_id" => "#{column1.id}",
        "new_column_id" => "#{column2.id}",
        "new_position" => 0
      })

      # Verify task was moved
      column1
      |> Kanban.Tasks.list_tasks()
      |> Enum.empty?()
      |> assert()

      tasks = Kanban.Tasks.list_tasks(column2)
      assert length(tasks) == 1
      assert hd(tasks).id == task.id
    end

    test "respects WIP limit when moving task to different column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Task 1"})
      _task2 = task_fixture(column2, %{title: "Task 2"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Try to move task from column1 to column2 (already at limit)
      # Suppress warning log by using @tag :capture_log
      capture_log(fn ->
        html =
          show_live
          |> render_click("move_task", %{
            "task_id" => "#{task.id}",
            "old_column_id" => "#{column1.id}",
            "new_column_id" => "#{column2.id}",
            "new_position" => 0
          })

        # Should show error message
        assert html =~ "Cannot move task: column has reached its WIP limit"

        # Verify task was NOT moved
        tasks1 = Kanban.Tasks.list_tasks(column1)
        assert length(tasks1) == 1
        assert hd(tasks1).id == task.id

        tasks2 = Kanban.Tasks.list_tasks(column2)
        assert length(tasks2) == 2
      end)
    end

    test "moves task to different column with room", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task from column1 to column2 (has room)
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task.id}",
        "old_column_id" => "#{column1.id}",
        "new_column_id" => "#{column2.id}",
        "new_position" => 1
      })

      # Verify task was moved
      column1
      |> Kanban.Tasks.list_tasks()
      |> Enum.empty?()
      |> assert()

      tasks2 = Kanban.Tasks.list_tasks(column2)
      assert length(tasks2) == 2
      task_ids = Enum.map(tasks2, & &1.id)
      assert task.id in task_ids
    end

    test "updates position correctly when moving task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task1 (position 0) to position 2 (end)
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task1.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 2
      })

      # Verify new order
      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task2.id, task3.id, task1.id]
    end

    test "displays drag handle on tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for drag handle class
      assert html =~ "drag-handle"
    end

    test "shows sortable hook on task list", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for sortable hook
      assert html =~ ~s(phx-hook="Sortable")
      assert html =~ ~s(data-column-id="#{column.id}")
      assert html =~ ~s(data-group="tasks")
    end

    test "highlights column when at WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check that WIP limit data attributes are present for JS to use
      assert html =~ ~s(data-wip-limit="2")
      assert html =~ ~s(data-task-count="2")
    end
  end

  describe "Permissions - Owner" do
    setup [:register_and_log_in_user]

    test "owner can see add task buttons", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Add task"
      assert html =~ ~s(phx-hook="Sortable")
    end

    test "owner can see edit and delete buttons for columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, ~s([href="/boards/#{board.id}/columns/#{column.id}/edit"]))
      # Check that delete link with confirmation exists
      assert html =~ ~s(phx-click)
      assert html =~ ~s(delete_column)
      assert html =~ ~s(Are you sure you want to delete this column?)
    end

    test "owner can see edit and delete buttons for tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, ~s([href="/boards/#{board.id}/tasks/#{task.id}/edit"]))
      # Check that delete link with confirmation exists
      assert html =~ ~s(delete_task)
      assert html =~ ~s(Are you sure you want to delete this task?)
    end
  end

  describe "Permissions - Modify Access" do
    setup [:register_and_log_in_user]

    test "user with modify access can see add task buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Add task"
    end

    test "user with modify access can see task edit/delete buttons but not column buttons", %{
      conn: conn,
      user: user
    } do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, ~s([href="/boards/#{board.id}/columns/#{column.id}/edit"]))
      assert has_element?(show_live, ~s([href="/boards/#{board.id}/tasks/#{task.id}/edit"]))
    end

    test "user with modify access can delete tasks", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task to delete"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Task to delete"

      show_live |> render_click("delete_task", %{"id" => task.id})

      html = render(show_live)
      assert html =~ "Task deleted successfully"
      refute html =~ "Task to delete"
    end

    test "user with modify access cannot delete columns", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify)
      column = column_fixture(board, %{name: "To Delete"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "To Delete"

      show_live |> render_click("delete_column", %{"id" => column.id})

      html = render(show_live)
      assert html =~ "Only the board owner can delete columns"
      assert html =~ "To Delete"
    end
  end

  describe "Permissions - Read Only Access" do
    setup [:register_and_log_in_user]

    test "user with read only access cannot see add task buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "Add task"
      refute html =~ "hero-plus-circle-solid"
    end

    test "user with read only access cannot see edit buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, ~s([href="/boards/#{board.id}/columns/#{column.id}/edit"]))
      refute has_element?(show_live, ~s([href="/boards/#{board.id}/tasks/#{task.id}/edit"]))
    end

    test "user with read only access cannot see delete buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, ~s([phx-click="delete_column"]))
      refute has_element?(show_live, ~s([phx-click="delete_task"]))
    end

    test "user with read only access can view board and tasks", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user, %{name: "Shared Board"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Visible Task"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Shared Board"
      assert html =~ "To Do"
      assert html =~ "Visible Task"
    end
  end

  describe "Task Assignment Display" do
    setup [:register_and_log_in_user]

    test "displays person icon for assigned tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      other_user = user_fixture(%{email: "assigned@example.com", name: "Assigned User"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, other_user, :modify)

      _task = task_fixture(column, %{title: "Assigned Task", assigned_to_id: other_user.id})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Assigned Task"
      assert html =~ "hero-user-solid"
      assert html =~ "Assigned User"
    end

    test "does not display person icon for unassigned tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Unassigned Task"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Unassigned Task"
      # Count hero-user-solid occurrences - should be 0 for unassigned tasks
      user_icon_count = html |> String.split("hero-user-solid") |> length() |> Kernel.-(1)
      assert user_icon_count == 0
    end
  end

  describe "Column Reordering" do
    setup [:register_and_log_in_user]

    test "handles move_column event successfully", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Reorder columns: swap first and third
      new_order = [column3.id, column2.id, column1.id]

      show_live
      |> render_click("move_column", %{
        "column_id" => "#{column3.id}",
        "column_ids" => Enum.map(new_order, &to_string/1)
      })

      # Verify columns are in new order
      columns = Kanban.Columns.list_columns(board)
      column_ids = Enum.map(columns, & &1.id)

      assert column_ids == new_order
    end
  end

  describe "Board Display" do
    setup [:register_and_log_in_user]

    test "displays board name and description", %{conn: conn, user: user} do
      board = board_fixture(user, %{name: "My Project Board", description: "Project description"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "My Project Board"
      assert html =~ "Project description"
    end

    test "displays New Column button", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "New Column"
      assert has_element?(show_live, ~s([href="/boards/#{board.id}/columns/new"]))
    end

    test "displays Edit board button", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Edit board"
      assert has_element?(show_live, ~s([href="/boards/#{board.id}/edit"]))
    end

    test "displays Back to boards button", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Back to boards"
      assert has_element?(show_live, ~s([href="/boards"]))
    end
  end

  describe "Navigation with Modals" do
    setup [:register_and_log_in_user]

    test "can navigate to new column modal", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/columns/new")

      assert true
    end

    test "can navigate to edit column modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Edit"})

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/edit")

      assert true
    end

    test "can navigate to new task modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      assert true
    end

    test "can navigate to edit task modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task to Edit"})

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      assert true
    end
  end

  describe "Task Reordering Within Column" do
    setup [:register_and_log_in_user]

    test "reorders tasks within the same column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task3.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 0
      })

      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task3.id, task1.id, task2.id]
    end

    test "handles moving task to end of column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task1.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 2
      })

      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task2.id, task3.id, task1.id]
    end
  end

  describe "WIP Limit Enforcement" do
    setup [:register_and_log_in_user]

    test "prevents moving task to column at WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Existing 1"})
      _task2 = task_fixture(column2, %{title: "Existing 2"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      capture_log(fn ->
        html =
          show_live
          |> render_click("move_task", %{
            "task_id" => "#{task.id}",
            "old_column_id" => "#{column1.id}",
            "new_column_id" => "#{column2.id}",
            "new_position" => 0
          })

        assert html =~ "Cannot move task: column has reached its WIP limit"

        tasks1 = Kanban.Tasks.list_tasks(column1)
        assert length(tasks1) == 1
        assert hd(tasks1).id == task.id
      end)
    end

    test "allows moving task to column with available space", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Existing 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task.id}",
        "old_column_id" => "#{column1.id}",
        "new_column_id" => "#{column2.id}",
        "new_position" => 0
      })

      tasks1 = Kanban.Tasks.list_tasks(column1)
      assert tasks1 == []

      tasks2 = Kanban.Tasks.list_tasks(column2)
      assert length(tasks2) == 2
      task_ids = Enum.map(tasks2, & &1.id)
      assert task.id in task_ids
    end
  end

  describe "Page Titles" do
    setup [:register_and_log_in_user]

    test "sets page title for show action", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      assert page_title(show_live) =~ "Show Board"
    end

    test "sets page title for new column action", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/new")

      assert page_title(show_live) =~ "New Column"
    end

    test "sets page title for edit column action", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/edit")

      assert page_title(show_live) =~ "Edit Column"
    end

    test "sets page title for new task action", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      assert page_title(show_live) =~ "New Task"
    end

    test "sets page title for edit task action", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      assert page_title(show_live) =~ "Edit Task"
    end
  end
end
