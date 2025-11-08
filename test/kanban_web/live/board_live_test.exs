defmodule KanbanWeb.BoardLiveTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

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

      assert html =~ "WIP limit"
      assert html =~ "5"
    end

    test "does not display WIP limit indicator when limit is 0", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "Done", wip_limit: 0})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # WIP limit label should not appear when limit is 0
      refute html =~ "WIP limit: 0"
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
      assert html =~ "WIP limit"
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
      refute html =~ "WIP limit: 0"
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
      show_live |> element("a[href='/boards/#{board.id}/columns/#{column.id}/tasks/new']") |> render_click()

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
      show_live |> element("a[href='/boards/#{board.id}/tasks/#{task.id}/edit']") |> render_click()

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

    test "shows warning indicator when column at WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for red warning badge indicating limit reached
      assert html =~ "bg-red-100 text-red-800"
    end

    test "displays blue indicator when column under WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      _task1 = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for blue badge when under limit
      assert html =~ "bg-blue-100 text-blue-800"
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

      # Check for red border/background indicating WIP limit reached
      assert html =~ "bg-red-50"
      assert html =~ "border-red-200"
    end
  end
end
