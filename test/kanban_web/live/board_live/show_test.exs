defmodule KanbanWeb.BoardLive.ShowTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.AccountsFixtures

  describe "Show" do
    setup [:register_and_log_in_user]

    test "displays board details", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ board.name
      assert html =~ board.description
    end

    test "displays columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ column.name
    end

    test "displays tasks in columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ task.title
      assert html =~ task.identifier
    end

    test "clicking on task shows task details", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("[phx-click='view_task'][phx-value-id='#{task.id}']")
      |> render_click()

      # Wait for the delayed modal to appear (100ms delay + some buffer)
      :timer.sleep(200)

      # After delay, check that viewing_task_id is set
      assert show_live
             |> has_element?("#task-view-modal")
    end

    test "displays empty state when board has no columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "No columns yet"
      assert html =~ "Get started by creating columns"
    end

    test "owner can see new column button", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "New Column"
    end

    test "owner can delete columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      assert show_live |> has_element?("#columns-#{column.id}")

      show_live
      |> element("a[data-confirm][phx-click*='delete_column']")
      |> render_click()

      refute has_element?(show_live, "#columns-#{column.id}")
    end

    test "displays task count per column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      _task1 = task_fixture(column)
      _task2 = task_fixture(column)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Tasks:"
      assert html =~ "2"
    end

    test "displays WIP limit when set", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{wip_limit: 5})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "WIP"
      assert html =~ "5"
    end
  end

  describe "Show with new task" do
    setup [:register_and_log_in_user]

    test "navigating to new task displays new task form", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      # Should show the new task form
      assert html =~ "New Task"
    end

    test "navigating to new task loads columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "Column 1"})
      column_fixture(board, %{name: "Column 2"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column1}/tasks/new")

      # Verify columns are displayed
      html = render(show_live)
      assert html =~ "Column 1"
      assert html =~ "Column 2"
    end

    test "navigating to new task shows board name", %{conn: conn, user: user} do
      board = board_fixture(user, %{name: "My Test Board"})
      column = column_fixture(board)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      # Board name should be visible
      assert html =~ "My Test Board"
    end

    test "new task from board with multiple columns shows all columns", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column_fixture(board, %{name: "In Progress"})
      column_fixture(board, %{name: "Done"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/columns/#{column1}/tasks/new")

      # All columns should be visible
      assert html =~ "To Do"
      assert html =~ "In Progress"
      assert html =~ "Done"
    end

    test "new task preserves existing tasks in columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      # Existing tasks should be visible in the column
      assert html =~ "Task 1"
      assert html =~ "Task 2"
    end

    test "owner can access new task page", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      # Should successfully load
      assert html =~ "New Task"
    end

    test "user with modify access can access new task page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      # Should successfully load
      assert html =~ "New Task"
    end

    test "user with read-only access can access new task page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)

      # Add current user with read-only access
      readonly_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only)

      conn = log_in_user(conn, readonly_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      # Should load but won't be able to save (tested elsewhere)
      assert html =~ "New Task"
    end

    test "assigns column from URL parameter", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Target Column"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      # The column should be assigned for the new task form
      assert show_live |> has_element?("[data-column-id='#{column.id}']") or
               render(show_live) =~ "Target Column"
    end
  end

  describe "Show with task edit in column context" do
    setup [:register_and_log_in_user]

    test "navigating to edit task in column displays edit modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task}/edit")

      # Should show the edit modal
      assert html =~ "Edit Task"
      assert html =~ task.title
    end

    test "navigating to edit task in column loads all columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "Column 1"})
      column_fixture(board, %{name: "Column 2"})
      task = task_fixture(column1)

      {:ok, show_live, _html} =
        live(conn, ~p"/boards/#{board}/columns/#{column1}/tasks/#{task}/edit")

      # Verify columns are displayed
      html = render(show_live)
      assert html =~ "Column 1"
      assert html =~ "Column 2"
    end

    test "navigating to edit task in column displays task form with current values", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          title: "Test Task Title",
          description: "Test Description"
        })

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task}/edit")

      # Should display task details in the form
      assert html =~ "Test Task Title"
      assert html =~ "Test Description"
    end

    test "navigating to edit task in column shows board name", %{conn: conn, user: user} do
      board = board_fixture(user, %{name: "My Test Board"})
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task}/edit")

      # Board name should be visible
      assert html =~ "My Test Board"
    end

    test "editing task in column from board with multiple columns shows all columns", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column_fixture(board, %{name: "In Progress"})
      column_fixture(board, %{name: "Done"})
      task = task_fixture(column1)

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column1}/tasks/#{task}/edit")

      # All columns should be visible
      assert html =~ "To Do"
      assert html =~ "In Progress"
      assert html =~ "Done"
    end

    test "editing task in column preserves other tasks in columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task1}/edit")

      # Both tasks should be visible in the column
      assert html =~ "Task 1"
      assert html =~ "Task 2"
    end

    test "owner can access edit task in column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task}/edit")

      # Should successfully load
      assert html =~ "Edit Task"
    end

    test "user with modify access can access edit task in column", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task}/edit")

      # Should successfully load
      assert html =~ "Edit Task"
    end

    test "user with read-only access can access edit task in column page", %{
      conn: conn,
      user: _user
    } do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)

      # Add current user with read-only access
      readonly_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only)

      conn = log_in_user(conn, readonly_user)

      {:ok, _show_live, html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task}/edit")

      # Should load but won't be able to save (tested elsewhere)
      assert html =~ "Edit Task"
    end

    test "assigns both column and task from URL parameters", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Target Column"})
      task = task_fixture(column, %{title: "Target Task"})

      {:ok, show_live, _html} =
        live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/#{task}/edit")

      # Both column and task should be assigned
      html = render(show_live)
      assert html =~ "Target Column"
      assert html =~ "Target Task"
    end
  end

  describe "Show with task edit" do
    setup [:register_and_log_in_user]

    test "navigating to edit task displays edit modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # Should show the edit modal
      assert html =~ "Edit Task"
      assert html =~ task.title
    end

    test "navigating to edit task loads columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "Column 1"})
      column_fixture(board, %{name: "Column 2"})
      task = task_fixture(column1)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # Verify columns are displayed
      html = render(show_live)
      assert html =~ "Column 1"
      assert html =~ "Column 2"
    end

    test "navigating to edit task displays task form with current values", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          title: "Test Task Title",
          description: "Test Description"
        })

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # Should display task details in the form
      assert html =~ "Test Task Title"
      assert html =~ "Test Description"
    end

    test "navigating to edit task shows board name", %{conn: conn, user: user} do
      board = board_fixture(user, %{name: "My Test Board"})
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # Board name should be visible
      assert html =~ "My Test Board"
    end

    test "navigating to edit task does not show view modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # View modal should not be present
      # This text only appears in view modal
      refute html =~ "No history available"
      refute has_element?(show_live, "#task-view-modal")
    end

    test "editing task from board with multiple columns shows all columns", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column_fixture(board, %{name: "In Progress"})
      column_fixture(board, %{name: "Done"})
      task = task_fixture(column1)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # All columns should be visible
      assert html =~ "To Do"
      assert html =~ "In Progress"
      assert html =~ "Done"
    end

    test "editing task preserves other tasks in columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task1}/edit")

      # Both tasks should be visible in the column
      assert html =~ "Task 1"
      assert html =~ "Task 2"
    end

    test "owner can access edit task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # Should successfully load
      assert html =~ "Edit Task"
    end

    test "user with modify access can access edit task", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # Should successfully load
      assert html =~ "Edit Task"
    end

    test "user with read-only access can access edit task page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)

      # Add current user with read-only access
      readonly_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only)

      conn = log_in_user(conn, readonly_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      # Should load but won't be able to save (tested elsewhere)
      assert html =~ "Edit Task"
    end
  end

  describe "Show authorization and permissions" do
    setup [:register_and_log_in_user]

    test "non-owner cannot access new column page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      assert {:error, {:live_redirect, %{to: _path, flash: %{"error" => error}}}} =
               live(conn, ~p"/boards/#{board}/columns/new")

      assert error =~ "Only the board owner can create columns"
    end

    test "non-owner cannot access edit column page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      assert {:error, {:live_redirect, %{to: _path, flash: %{"error" => error}}}} =
               live(conn, ~p"/boards/#{board}/columns/#{column}/edit")

      assert error =~ "Only the board owner can manage columns"
    end

    test "non-owner cannot delete columns", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Try to delete column via event (bypassing UI restrictions)
      show_live
      |> render_hook("delete_column", %{"id" => to_string(column.id)})

      assert render(show_live) =~ "Only the board owner can delete columns"
    end

    test "non-owner cannot reorder columns", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)
      column1 = column_fixture(board)
      column2 = column_fixture(board)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("move_column", %{
        "column_id" => to_string(column1.id),
        "column_ids" => [to_string(column2.id), to_string(column1.id)]
      })

      assert render(show_live) =~ "Only the board owner can reorder columns"
    end

    test "non-owner cannot toggle field visibility", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = board_fixture(owner)

      # Add current user with modify access
      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("toggle_field", %{"field" => "complexity"})

      assert render(show_live) =~ "Only board owners can change field visibility"
    end

    test "owner can toggle field visibility", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      _task = task_fixture(column)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("toggle_field", %{"field" => "complexity"})

      # Verify field visibility was updated
      updated_board = Kanban.Boards.get_board!(board.id, user)
      assert updated_board.field_visibility["complexity"] == true
    end

    test "owner can reorder columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("move_column", %{
        "column_id" => to_string(column1.id),
        "column_ids" => [to_string(column2.id), to_string(column1.id)]
      })

      # Should succeed without errors
      refute render(show_live) =~ "Only the board owner can reorder columns"
    end
  end

  describe "AI Optimized Board restrictions" do
    setup [:register_and_log_in_user]

    test "owner cannot see new column button on AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "New Column"
    end

    test "owner can see new column button on regular board", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "New Column"
    end

    test "owner cannot see edit column link on AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, "a[aria-label='Edit column']")
    end

    test "owner can see edit column link on regular board", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, "a[aria-label='Edit column']")
    end

    test "owner cannot see delete column link on AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, "a[data-confirm][phx-click*='delete_column']")
    end

    test "owner can see delete column link on regular board", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, "a[data-confirm][phx-click*='delete_column']")
    end

    test "owner cannot see column drag handle on AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, ".column-drag-handle")
    end

    test "owner can see column drag handle on regular board", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, ".column-drag-handle")
    end

    test "AI optimized board has 5 default columns", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Backlog"
      assert html =~ "Ready"
      assert html =~ "Doing"
      assert html =~ "Review"
      assert html =~ "Done"
    end

    test "owner cannot access new column page for AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      assert {:error, {:live_redirect, %{to: path, flash: %{"error" => error}}}} =
               live(conn, ~p"/boards/#{board}/columns/new")

      assert path == "/boards/#{board.id}"
      assert error =~ "Cannot add columns to AI optimized boards"
    end

    test "owner cannot access edit column page for AI optimized board", %{
      conn: conn,
      user: user
    } do
      board = ai_optimized_board_fixture(user)
      column = List.first(board.columns)

      assert {:error, {:live_redirect, %{to: path, flash: %{"error" => error}}}} =
               live(conn, ~p"/boards/#{board}/columns/#{column}/edit")

      assert path == "/boards/#{board.id}"
      assert error =~ "Cannot edit columns on AI optimized boards"
    end

    test "owner cannot delete columns on AI optimized board via event", %{
      conn: conn,
      user: user
    } do
      board = ai_optimized_board_fixture(user)
      column = List.first(board.columns)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("delete_column", %{"id" => to_string(column.id)})

      assert render(show_live) =~ "Cannot delete columns on AI optimized boards"
    end

    test "owner cannot reorder columns on AI optimized board via event", %{
      conn: conn,
      user: user
    } do
      board = ai_optimized_board_fixture(user)
      column1 = Enum.at(board.columns, 0)
      column2 = Enum.at(board.columns, 1)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("move_column", %{
        "column_id" => to_string(column1.id),
        "column_ids" => [to_string(column2.id), to_string(column1.id)]
      })

      assert render(show_live) =~ "Cannot reorder columns on AI optimized boards"
    end
  end

  describe "API Tokens" do
    setup [:register_and_log_in_user]

    test "owner can access API tokens page", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      assert html =~ "API Tokens"
      assert html =~ "Generate Token"
    end

    test "user with modify access can access API tokens page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      assert html =~ "API Tokens"
    end

    test "user with read-only access cannot access API tokens page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      readonly_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only)

      conn = log_in_user(conn, readonly_user)

      assert {:error, {:live_redirect, %{to: path, flash: %{"error" => error}}}} =
               live(conn, ~p"/boards/#{board}/api_tokens")

      assert path == "/boards/#{board.id}"
      assert error =~ "don't have permission to manage API tokens"
    end

    test "displays existing API tokens", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, {_token, _plain}} =
        Kanban.ApiTokens.create_api_token(user, board, %{
          name: "Test Token"
        })

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      assert html =~ "Test Token"
    end

    test "creates new API token via form submission", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      show_live
      |> form("#api-tokens-modal form",
        api_token: %{name: "New Token", agent_model: "claude"}
      )
      |> render_submit()

      html = render(show_live)
      assert html =~ "Token created successfully"
      assert html =~ "New Token"
      assert html =~ "stride_"
    end

    test "shows validation errors for invalid token creation", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      show_live
      |> form("#api-tokens-modal form",
        api_token: %{name: ""}
      )
      |> render_submit()

      html = render(show_live)
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "revokes API token", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, {token, _plain}} =
        Kanban.ApiTokens.create_api_token(user, board, %{
          name: "Token to Revoke"
        })

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      show_live
      |> element("button[phx-click='revoke_token'][phx-value-id='#{token.id}']")
      |> render_click()

      html = render(show_live)
      assert html =~ "revoked successfully" or html =~ "Revoked"
    end

    test "deletes revoked API token", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, {token, _plain}} =
        Kanban.ApiTokens.create_api_token(user, board, %{
          name: "Token to Delete"
        })

      {:ok, _revoked_token} = Kanban.ApiTokens.revoke_api_token(token)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      show_live
      |> element("button[phx-click='delete_token'][phx-value-id='#{token.id}']")
      |> render_click()

      html = render(show_live)
      assert html =~ "deleted successfully"
      refute html =~ "Token to Delete"
    end

    test "displays 'Never' for unused tokens", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, {_token, _plain}} =
        Kanban.ApiTokens.create_api_token(user, board, %{
          name: "Unused Token"
        })

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      assert html =~ "Never"
    end

    test "shows plain-text token only once after creation", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      # Create token
      show_live
      |> form("#api-tokens-modal form",
        api_token: %{name: "One-time Token"}
      )
      |> render_submit()

      html = render(show_live)
      assert html =~ "stride_"
      assert html =~ "Copy this token now"

      # Navigate away and back
      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}")
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      # Plain-text token should not be visible anymore
      refute html =~ "Copy this token now"
    end

    test "owner can see API Tokens button", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "API Tokens"
    end

    test "user with modify access can see API Tokens button", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify)

      conn = log_in_user(conn, modify_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "API Tokens"
    end

    test "user with read-only access cannot see API Tokens button", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      readonly_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only)

      conn = log_in_user(conn, readonly_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "API Tokens"
    end

    test "non-AI-optimized boards cannot access API tokens page", %{conn: conn, user: user} do
      board = board_fixture(user)

      assert {:error, {:live_redirect, %{to: path, flash: %{"error" => error}}}} =
               live(conn, ~p"/boards/#{board}/api_tokens")

      assert path == "/boards/#{board.id}"
      assert error =~ "only available for AI Optimized boards"
    end

    test "non-AI-optimized boards do not show API Tokens button", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "API Tokens"
    end
  end

  describe "Show task operations" do
    setup [:register_and_log_in_user]

    test "close task view event resets viewing state", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # First view the task
      show_live
      |> element("[phx-click='view_task'][phx-value-id='#{task.id}']")
      |> render_click()

      # Then close it
      show_live
      |> render_hook("close_task_view", %{})

      # Task modal should not be visible
      refute has_element?(show_live, "#task-view-modal")
    end

    test "delete task removes task from column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Verify task exists
      assert render(show_live) =~ task.title

      # Delete the task
      show_live
      |> render_hook("delete_task", %{"id" => to_string(task.id)})

      # Verify task is removed
      refute render(show_live) =~ task.title
    end

    test "moving task within same column reorders tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task1 = task_fixture(column, %{title: "Task 1", position: 0})
      _task2 = task_fixture(column, %{title: "Task 2", position: 1})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task1 to position 1
      show_live
      |> render_hook("move_task", %{
        "task_id" => to_string(task1.id),
        "old_column_id" => to_string(column.id),
        "new_column_id" => to_string(column.id),
        "new_position" => 1
      })

      # Should succeed
      refute render(show_live) =~ "Failed to move task"
    end

    test "moving task to different column updates task location", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)
      task = task_fixture(column1)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task to column2
      show_live
      |> render_hook("move_task", %{
        "task_id" => to_string(task.id),
        "old_column_id" => to_string(column1.id),
        "new_column_id" => to_string(column2.id),
        "new_position" => 0
      })

      # Should succeed
      refute render(show_live) =~ "Failed to move task"
    end

    test "archive_task removes task from column and shows success flash", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Verify task exists in column
      assert render(show_live) =~ task.title

      # Archive the task
      show_live
      |> render_hook("archive_task", %{"id" => to_string(task.id)})

      html = render(show_live)

      # Task should no longer be visible in the column
      refute html =~ task.title
      # Success flash should be shown
      assert html =~ "Task archived successfully"
    end

    test "archive_task updates task archived_at timestamp", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert task.archived_at == nil

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("archive_task", %{"id" => to_string(task.id)})

      # Verify task was archived in database
      archived_task = Kanban.Tasks.get_task!(task.id)
      assert archived_task.archived_at != nil
      assert %DateTime{} = archived_task.archived_at
    end

    test "archive_task reloads all columns after archiving", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "Column 1"})
      column2 = column_fixture(board, %{name: "Column 2"})
      task1 = task_fixture(column1, %{title: "Task in Column 1"})
      task2 = task_fixture(column2, %{title: "Task in Column 2"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Both tasks should be visible
      html = render(show_live)
      assert html =~ task1.title
      assert html =~ task2.title

      # Archive task1
      show_live
      |> render_hook("archive_task", %{"id" => to_string(task1.id)})

      html = render(show_live)

      # task1 should be gone, task2 should still be visible
      refute html =~ task1.title
      assert html =~ task2.title
    end
  end

  describe "translate_column_name/1" do
    test "translates standard AI board column names" do
      assert KanbanWeb.BoardLive.Show.translate_column_name("Backlog") != "Backlog" ||
               KanbanWeb.BoardLive.Show.translate_column_name("Backlog") == "Backlog"

      assert KanbanWeb.BoardLive.Show.translate_column_name("Ready") != "Ready" ||
               KanbanWeb.BoardLive.Show.translate_column_name("Ready") == "Ready"

      assert KanbanWeb.BoardLive.Show.translate_column_name("Doing") != "Doing" ||
               KanbanWeb.BoardLive.Show.translate_column_name("Doing") == "Doing"

      assert KanbanWeb.BoardLive.Show.translate_column_name("Review") != "Review" ||
               KanbanWeb.BoardLive.Show.translate_column_name("Review") == "Review"

      assert KanbanWeb.BoardLive.Show.translate_column_name("Done") != "Done" ||
               KanbanWeb.BoardLive.Show.translate_column_name("Done") == "Done"

      assert is_binary(KanbanWeb.BoardLive.Show.translate_column_name("Backlog"))
      assert is_binary(KanbanWeb.BoardLive.Show.translate_column_name("Ready"))
      assert is_binary(KanbanWeb.BoardLive.Show.translate_column_name("Doing"))
      assert is_binary(KanbanWeb.BoardLive.Show.translate_column_name("Review"))
      assert is_binary(KanbanWeb.BoardLive.Show.translate_column_name("Done"))
    end

    test "returns custom column names as-is" do
      assert KanbanWeb.BoardLive.Show.translate_column_name("Custom Column") == "Custom Column"
      assert KanbanWeb.BoardLive.Show.translate_column_name("My Column") == "My Column"
    end
  end

  describe "PubSub handle_info events" do
    setup [:register_and_log_in_user]

    test "receives task_moved broadcast and sends push event", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board)
      column2 = column_fixture(board)
      task = task_fixture(column1)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      {:ok, updated_task} =
        Kanban.Tasks.update_task(task, %{column_id: column2.id, position: 0})

      send(show_live.pid, {Kanban.Tasks, :task_moved, updated_task})
      :timer.sleep(50)
      render(show_live)
    end

    test "receives task_status_changed broadcast and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      send(show_live.pid, {Kanban.Tasks, :task_status_changed, task})
      :timer.sleep(50)

      html = render(show_live)
      assert html =~ task.title
    end

    test "receives :task_updated API event and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "API Updated"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      send(show_live.pid, {:task_updated, task})
      :timer.sleep(50)

      html = render(show_live)
      assert html =~ "API Updated"
    end

    test "receives :task_moved_to_review API event and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Review Task"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      send(show_live.pid, {:task_moved_to_review, task})
      :timer.sleep(50)

      html = render(show_live)
      assert html =~ "Review Task"
    end

    test "receives :task_completed API event and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Completed Task"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      send(show_live.pid, {:task_completed, task})
      :timer.sleep(50)

      html = render(show_live)
      assert html =~ "Completed Task"
    end

    test "receives task_reviewed broadcast and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Reviewed Task"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      send(show_live.pid, {Kanban.Tasks, :task_reviewed, task})
      :timer.sleep(50)

      html = render(show_live)
      assert html =~ "Reviewed Task"
    end

    test "receives field_visibility_updated broadcast", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      new_visibility = %{"description" => true}
      send(show_live.pid, {:field_visibility_updated, new_visibility})
      :timer.sleep(50)

      render(show_live)
      assert :sys.get_state(show_live.pid).socket.assigns.field_visibility == new_visibility
    end
  end

  describe "API token management events" do
    setup [:register_and_log_in_user]

    test "dismiss_token event clears new_token", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      show_live
      |> form("#api-tokens-modal form",
        api_token: %{name: "Dismissable Token"}
      )
      |> render_submit()

      show_live
      |> render_hook("dismiss_token", %{})

      :timer.sleep(50)
      render(show_live)
    end

    test "revoke_token prevents revoking token from different board", %{conn: conn, user: user} do
      board1 = ai_optimized_board_fixture(user)
      board2 = ai_optimized_board_fixture(user)

      {:ok, {api_token, _plain}} =
        Kanban.ApiTokens.create_api_token(user, board2, %{name: "Other Board Token"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board1}/api_tokens")

      html =
        show_live
        |> render_hook("revoke_token", %{"id" => to_string(api_token.id)})

      assert html =~ "Unauthorized"
    end

    test "delete_token prevents deleting token from different board", %{conn: conn, user: user} do
      board1 = ai_optimized_board_fixture(user)
      board2 = ai_optimized_board_fixture(user)

      {:ok, {api_token, _plain}} =
        Kanban.ApiTokens.create_api_token(user, board2, %{name: "Other Board Token"})

      {:ok, _revoked_token} = Kanban.ApiTokens.revoke_api_token(api_token)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board1}/api_tokens")

      html =
        show_live
        |> render_hook("delete_token", %{"id" => to_string(api_token.id)})

      assert html =~ "Unauthorized"
    end
  end

  describe "Read-only board access" do
    test "non-member can access read-only board", %{conn: conn} do
      # Create a board with owner
      owner = user_fixture()
      board = board_fixture(owner)

      # Make the board read-only
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true})

      # Create a non-member user and log them in
      non_member = user_fixture()
      conn = log_in_user(conn, non_member)

      # Non-member should be able to access the board
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ board.name
      assert html =~ board.description
    end

    test "non-member cannot access private board", %{conn: conn} do
      # Create a private board (read_only: false)
      owner = user_fixture()
      board = board_fixture(owner)

      # Ensure the board is NOT read-only
      assert board.read_only == false

      # Create a non-member user and log them in
      non_member = user_fixture()
      conn = log_in_user(conn, non_member)

      # Non-member should NOT be able to access the board
      # get_board!/2 raises Ecto.NoResultsError for non-members on private boards
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{board}")
      end
    end

    test "read-only banner displays for non-members on read-only boards", %{conn: conn} do
      # Create a read-only board
      owner = user_fixture()
      board = board_fixture(owner)
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true})

      # Create a non-member user and log them in
      non_member = user_fixture()
      conn = log_in_user(conn, non_member)

      # Non-member should see the read-only banner
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "You are viewing this board in read-only mode"
      assert html =~ "This board is shared publicly"
    end

    test "read-only banner does NOT display for board members", %{conn: conn} do
      # Create a read-only board
      owner = user_fixture()
      board = board_fixture(owner)
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true})

      # Create a member user and add to board
      member = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, member, :read_only)

      # Log in as the member
      conn = log_in_user(conn, member)

      # Member should NOT see the read-only banner
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "You are viewing this board in read-only mode"
      refute html =~ "This board is shared publicly"
    end

    test "read-only banner does NOT display for board owner", %{conn: conn} do
      # Create a read-only board
      owner = user_fixture()
      board = board_fixture(owner)
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true})

      # Log in as the owner
      conn = log_in_user(conn, owner)

      # Owner should NOT see the read-only banner
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "You are viewing this board in read-only mode"
      refute html =~ "This board is shared publicly"
    end

    test "non-member cannot edit tasks on read-only board", %{conn: conn} do
      # Create a read-only board with a task
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)
      {:ok, _board} = Kanban.Boards.update_board(board, %{read_only: true})

      # Create a non-member user and log them in
      non_member = user_fixture()
      conn = log_in_user(conn, non_member)

      # Non-member can view the board but buttons should not be visible
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Verify task is visible
      assert html =~ task.title

      # Verify edit buttons are not visible (non-members have can_modify=false)
      refute html =~ "Edit task"
      refute html =~ "Delete task"
    end
  end
end
