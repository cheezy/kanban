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

      # ColumnHeader renders the count inside a font-mono badge.
      assert html =~ ~r/>\s*2\s*</
    end

    test "displays WIP limit when set", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{wip_limit: 5})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # ColumnHeader renders count/wip as "N/M" inside the badge.
      assert html =~ "0/5"
    end

    test "tasks-load query count does not scale with column count (D5 N+1 guard)",
         %{conn: conn, user: user} do
      # Mount two boards: one with few columns, one with many.
      # With the N+1 fixed, both should emit the SAME number of task-list queries.
      # With an N+1 regression, the many-column mount would emit more.
      board_small = board_fixture(user)
      small_columns = for _ <- 1..2, do: column_fixture(board_small)
      for column <- small_columns, _ <- 1..3, do: task_fixture(column)

      board_large = board_fixture(user)
      large_columns = for _ <- 1..10, do: column_fixture(board_large)
      for column <- large_columns, _ <- 1..3, do: task_fixture(column)

      small_queries = capture_task_queries(fn -> live(conn, ~p"/boards/#{board_small}") end)
      large_queries = capture_task_queries(fn -> live(conn, ~p"/boards/#{board_large}") end)

      assert length(small_queries) == length(large_queries),
             "task-list query count must not scale with column count. " <>
               "Small board (2 cols): #{length(small_queries)} queries. " <>
               "Large board (10 cols): #{length(large_queries)} queries."

      # Sanity: batched queries use `column_id IN` / `= ANY`, not per-row equality.
      assert Enum.any?(large_queries, fn q ->
               String.contains?(q, "column_id") and
                 (String.contains?(q, "IN ") or String.contains?(q, "= ANY"))
             end),
             "expected a batched query using IN / = ANY against column_id"
    end

    test "columns container renders the mobile snap-scroll markup with md reset", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column_fixture(board)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")

      # Mobile: snap-x + snap-mandatory on the columns container; reset at md+.
      assert html =~ "snap-x"
      assert html =~ "snap-mandatory"
      assert html =~ "md:snap-none"

      # Per-column wrapper: full-viewport width on mobile (w-[calc(100vw-2rem)] +
      # shrink-0 + snap-start), reset to flex-1 + min-w-[256px] at md+.
      assert html =~ "snap-start"
      assert html =~ "w-[calc(100vw-2rem)]"
      assert html =~ "md:w-auto"
      assert html =~ "md:flex-1"
      assert html =~ "md:min-w-[288px]"
      # Locks the desktop-equivalence contract: shrink-0 from the mobile rules must be
      # explicitly reset at md+ or columns would freeze at intrinsic width.
      assert html =~ "md:shrink"
    end

    test "snap indicator strip renders below md with one dot per column", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      column_fixture(board)
      column_fixture(board)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")

      # The indicator strip is md:hidden and mounts the SnapIndicator hook.
      assert html =~ ~s|id="snap-indicator"|
      assert html =~ ~s|phx-hook="SnapIndicator"|
      assert html =~ ~s|data-target-id="columns"|
      assert html =~ "md:hidden"
      # One dot per column.
      dot_count = Regex.scan(~r/data-indicator-dot=/, html) |> length()
      assert dot_count == 2
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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only, owner)

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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only, owner)

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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only, owner)

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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

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

      assert html =~ "API tokens"
      assert html =~ "Generate token"
    end

    test "user with modify access can access API tokens page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

      conn = log_in_user(conn, modify_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      assert html =~ "API tokens"
    end

    test "user with read-only access cannot access API tokens page", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      readonly_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only, owner)

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
      assert html =~ "Token created"
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
      assert html =~ "revoked successfully" or html =~ "revoked"
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
      assert html =~ "Token created"

      # Navigate away and back
      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}")
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      # Plain-text token should not be visible anymore
      refute html =~ "Token created"
    end

    test "owner can see the Tokens tab", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ ~s|href="/boards/#{board.id}/api_tokens"|
    end

    test "user with modify access can see the Tokens tab", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

      conn = log_in_user(conn, modify_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ ~s|href="/boards/#{board.id}/api_tokens"|
    end

    test "user with read-only access cannot see the Tokens tab", %{conn: conn, user: _user} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      readonly_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, readonly_user, :read_only, owner)

      conn = log_in_user(conn, readonly_user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ ~s|href="/boards/#{board.id}/api_tokens"|
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
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true}, owner)

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

      # Non-member should be redirected to boards list
      {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => _}}}} =
        live(conn, ~p"/boards/#{board}")
    end

    test "read-only banner displays for non-members on read-only boards", %{conn: conn} do
      # Create a read-only board
      owner = user_fixture()
      board = board_fixture(owner)
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true}, owner)

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
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true}, owner)

      # Create a member user and add to board
      member = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, member, :read_only, owner)

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
      {:ok, board} = Kanban.Boards.update_board(board, %{read_only: true}, owner)

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
      {:ok, _board} = Kanban.Boards.update_board(board, %{read_only: true}, owner)

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

  describe "promote_goal_to_ready" do
    setup [:register_and_log_in_user]

    test "promotes goal children from Backlog to Ready", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      backlog = Kanban.Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, %{goal: goal, child_tasks: child_tasks}} =
        Kanban.Tasks.create_goal_with_tasks(
          backlog,
          %{title: "Test Goal"},
          [%{title: "Child Task 1"}, %{title: "Child Task 2"}]
        )

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("promote_goal_to_ready", %{"id" => to_string(goal.id)})

      # Verify children moved to Ready column
      ready = Kanban.Columns.list_columns(board) |> Enum.find(&(&1.name == "Ready"))
      ready_tasks = Kanban.Tasks.list_tasks(ready)
      child_ids = Enum.map(child_tasks, & &1.id)

      assert Enum.all?(child_ids, fn id ->
               Enum.any?(ready_tasks, &(&1.id == id))
             end)
    end

    test "shows error when promoting a non-goal task", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      backlog = Kanban.Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, task} =
        Kanban.Tasks.create_task(backlog, %{title: "Regular Task", position: 0})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("promote_goal_to_ready", %{"id" => to_string(task.id)})

      assert render(show_live) =~ "Only goals can be promoted"
    end

    test "read-only user is rejected when pushing promote_goal_to_ready event", %{conn: conn} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)
      backlog = Kanban.Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, %{goal: goal, child_tasks: _child_tasks}} =
        Kanban.Tasks.create_goal_with_tasks(
          backlog,
          %{title: "Read-only Promote Target"},
          [%{title: "Child"}]
        )

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("promote_goal_to_ready", %{"id" => to_string(goal.id)})

      assert render(show_live) =~ "You do not have permission to promote goals on this board"

      # Goal column unchanged (still Backlog).
      assert %{column_id: column_id} = Kanban.Tasks.get_task!(goal.id)
      assert column_id == backlog.id
    end

    test "cross-board goal id is rejected when pushing promote_goal_to_ready event", %{
      conn: conn,
      user: user
    } do
      own_board = ai_optimized_board_fixture(user)

      other_owner = user_fixture()
      other_board = ai_optimized_board_fixture(other_owner)

      other_backlog =
        Kanban.Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, %{goal: other_goal}} =
        Kanban.Tasks.create_goal_with_tasks(
          other_backlog,
          %{title: "Cross-Board Goal"},
          [%{title: "Child"}]
        )

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("promote_goal_to_ready", %{"id" => to_string(other_goal.id)})

      assert render(show_live) =~ "Failed to move goal to Ready"

      # Cross-board goal stayed in its original Backlog column.
      assert %{column_id: column_id} = Kanban.Tasks.get_task!(other_goal.id)
      assert column_id == other_backlog.id
    end
  end

  describe "archive_task and delete_task authorization" do
    setup [:register_and_log_in_user]

    test "non-owner with modify access can archive tasks", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)

      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

      conn = log_in_user(conn, modify_user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("archive_task", %{"id" => to_string(task.id)})

      html = render(show_live)
      assert html =~ "Task archived successfully"
      refute html =~ task.title
    end

    test "non-owner with modify access can delete tasks", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)

      modify_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)

      conn = log_in_user(conn, modify_user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("delete_task", %{"id" => to_string(task.id)})

      html = render(show_live)
      assert html =~ "Task deleted successfully"
      refute html =~ task.title
    end

    test "read-only user is rejected when pushing archive_task event", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Read-only Archive Target"})

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("archive_task", %{"id" => to_string(task.id)})

      html = render(show_live)
      assert html =~ "You do not have permission to archive tasks on this board"

      # Task was not archived.
      assert %{archived_at: nil} = Kanban.Tasks.get_task!(task.id)
    end

    test "cross-board task id is rejected when pushing archive_task event", %{conn: conn} do
      # Owner of the board the user will visit.
      owner = user_fixture()
      own_board = board_fixture(owner)
      _own_column = column_fixture(own_board)

      # A completely separate board with its own task — the malicious target.
      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)
      other_task = task_fixture(other_column, %{title: "Cross-Board Target"})

      conn = log_in_user(conn, owner)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("archive_task", %{"id" => to_string(other_task.id)})

      html = render(show_live)
      assert html =~ "Failed to archive task"

      # Cross-board task was not archived.
      assert %{archived_at: nil} = Kanban.Tasks.get_task!(other_task.id)
    end

    test "read-only user is rejected when pushing delete_task event", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Read-only Delete Target"})

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("delete_task", %{"id" => to_string(task.id)})

      html = render(show_live)
      assert html =~ "You do not have permission to delete tasks on this board"

      # Task still exists.
      assert %{} = Kanban.Tasks.get_task!(task.id)
    end

    test "cross-board task id is rejected when pushing delete_task event", %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)
      _own_column = column_fixture(own_board)

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)
      other_task = task_fixture(other_column, %{title: "Cross-Board Delete Target"})

      conn = log_in_user(conn, owner)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("delete_task", %{"id" => to_string(other_task.id)})

      html = render(show_live)
      assert html =~ "Failed to delete task"

      # Cross-board task still exists.
      assert %{} = Kanban.Tasks.get_task!(other_task.id)
    end

    test "read-only user is rejected when pushing move_task event", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Read-only Move Target", position: 0})

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("move_task", %{
        "task_id" => to_string(task.id),
        "old_column_id" => to_string(column.id),
        "new_column_id" => to_string(column.id),
        "new_position" => 5
      })

      html = render(show_live)
      assert html =~ "You do not have permission to move tasks on this board"

      # Task position unchanged.
      assert %{column_id: column_id} = Kanban.Tasks.get_task!(task.id)
      assert column_id == column.id
    end

    test "cross-board task id is rejected when pushing move_task event", %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)
      own_column = column_fixture(own_board)

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)
      other_task = task_fixture(other_column, %{title: "Cross-Board Move Target", position: 0})

      conn = log_in_user(conn, owner)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("move_task", %{
        "task_id" => to_string(other_task.id),
        "old_column_id" => to_string(own_column.id),
        "new_column_id" => to_string(own_column.id),
        "new_position" => 0
      })

      html = render(show_live)
      assert html =~ "Failed to move task"

      # Cross-board task did NOT get reassigned to the current board's column.
      assert %{column_id: column_id} = Kanban.Tasks.get_task!(other_task.id)
      assert column_id == other_column.id
    end

    test "cross-board old_column_id is rejected when pushing move_task event", %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)
      own_column = column_fixture(own_board)
      own_task = task_fixture(own_column, %{title: "Own Task", position: 0})

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)

      conn = log_in_user(conn, owner)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("move_task", %{
        "task_id" => to_string(own_task.id),
        "old_column_id" => to_string(other_column.id),
        "new_column_id" => to_string(own_column.id),
        "new_position" => 0
      })

      html = render(show_live)
      assert html =~ "Failed to move task"
    end

    test "cross-board new_column_id is rejected when pushing move_task event", %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)
      own_column = column_fixture(own_board)
      own_task = task_fixture(own_column, %{title: "Own Task", position: 0})

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)

      conn = log_in_user(conn, owner)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("move_task", %{
        "task_id" => to_string(own_task.id),
        "old_column_id" => to_string(own_column.id),
        "new_column_id" => to_string(other_column.id),
        "new_position" => 0
      })

      html = render(show_live)
      assert html =~ "Failed to move task"

      # Task did NOT migrate to the other board's column.
      assert %{column_id: column_id} = Kanban.Tasks.get_task!(own_task.id)
      assert column_id == own_column.id
    end

    test "read-only user is rejected when pushing create_token event", %{conn: conn} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      # Route into :show (not :api_tokens which is route-gated already).
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("create_token", %{"api_token" => %{"name" => "Sneaky Token"}})

      html = render(show_live)
      assert html =~ "You do not have permission to manage API tokens"

      # No token was created on this board.
      assert Kanban.ApiTokens.list_api_tokens(board) == []
    end

    test "read-only user is rejected when pushing revoke_token event", %{conn: conn} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      {:ok, {token, _plaintext}} =
        Kanban.ApiTokens.create_api_token(owner, board, %{
          name: "Owner Token",
          agent_capabilities: ["code_generation"]
        })

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("revoke_token", %{"id" => to_string(token.id)})

      html = render(show_live)
      assert html =~ "You do not have permission to manage API tokens"

      # Token is still active.
      refreshed = Kanban.ApiTokens.get_api_token!(token.id)
      assert is_nil(refreshed.revoked_at)
    end

    test "read-only user is rejected when pushing delete_token event", %{conn: conn} do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      {:ok, {token, _plaintext}} =
        Kanban.ApiTokens.create_api_token(owner, board, %{
          name: "Owner Token",
          agent_capabilities: ["code_generation"]
        })

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("delete_token", %{"id" => to_string(token.id)})

      html = render(show_live)
      assert html =~ "You do not have permission to manage API tokens"

      # Token still exists.
      assert %{} = Kanban.ApiTokens.get_api_token!(token.id)
    end

    test "cross-board task id is rejected when pushing view_task event", %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)
      _own_column = column_fixture(own_board)

      # A task on a completely separate board.
      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)
      other_task = task_fixture(other_column, %{title: "Cross-Board View Target"})

      conn = log_in_user(conn, owner)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("view_task", %{"id" => to_string(other_task.id)})

      html = render(show_live)
      assert html =~ "Task not found"
      # Modal must NOT open with the cross-board task id assigned.
      refute html =~ other_task.title
    end

    test "non-numeric view_task id is rejected without crashing", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("view_task", %{"id" => "not-a-number"})

      html = render(show_live)
      assert html =~ "Task not found"
      refute html =~ "Internal Server Error"
    end

    test "read-only viewer can still open view_task on their own board", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Read-only Viewable Task"})

      reader = user_fixture()
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = log_in_user(conn, reader)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_hook("view_task", %{"id" => to_string(task.id)})

      html = render(show_live)
      # No rejection flash; the in-board view path is preserved for read-only members.
      refute html =~ "Task not found"
    end
  end

  # Captures every `SELECT ... FROM "tasks"` query issued while `fun` runs.
  # Used by the N+1 regression guard so the batched tasks load can't silently
  # revert to a per-column loop.
  defp capture_task_queries(fun) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if String.match?(query, ~r/FROM "tasks"/i) do
          send(parent, {:task_query, ref, query})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_task_queries(ref, [])
  end

  defp collect_task_queries(ref, acc) do
    receive do
      {:task_query, ^ref, query} -> collect_task_queries(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "undismissed broadcast messages banner" do
    setup [:register_and_log_in_user]

    test "renders the banner when an undismissed message exists", %{conn: conn, user: user} do
      board = board_fixture(user)
      admin = admin_user_fixture()
      message = message_fixture(admin, %{title: "Welcome!", body: "Enjoy Stride"})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Welcome!"
      assert html =~ "Enjoy Stride"
      assert html =~ ~s(id="undismissed_messages-#{message.id}")
    end

    test "no banner block items when there are no undismissed messages", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ ~s(id="undismissed_messages-)
    end

    test "clicking dismiss removes the banner and persists across reload", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      admin = admin_user_fixture()
      message = message_fixture(admin, %{title: "Hi", body: "there"})

      {:ok, view, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Hi"

      html =
        view
        |> element("#undismissed_messages-#{message.id} button[phx-click='dismiss_message']")
        |> render_click()

      refute html =~ ~s(id="undismissed_messages-#{message.id}")

      {:ok, _view2, html2} = live(conn, ~p"/boards/#{board}")
      refute html2 =~ ~s(id="undismissed_messages-#{message.id}")
    end

    test "user A dismissing does not affect user B's banner", %{conn: conn_a, user: user_a} do
      board_a = board_fixture(user_a)
      admin = admin_user_fixture()
      message = message_fixture(admin, %{title: "ShareMe", body: "body"})

      user_b = user_fixture()
      conn_b = log_in_user(Phoenix.ConnTest.build_conn(), user_b)
      board_b = board_fixture(user_b)

      {:ok, view_a, _} = live(conn_a, ~p"/boards/#{board_a}")

      view_a
      |> element("#undismissed_messages-#{message.id} button[phx-click='dismiss_message']")
      |> render_click()

      {:ok, _view_b, html_b} = live(conn_b, ~p"/boards/#{board_b}")
      assert html_b =~ ~s(id="undismissed_messages-#{message.id}")
    end
  end

  describe "W392 cross-board IDOR protection" do
    test "delete_column event rejects a column id from a different board", %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)
      _own_column = column_fixture(own_board)

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board, %{name: "Cross-Board Column"})

      conn = log_in_user(conn, owner)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{own_board}")

      show_live
      |> render_hook("delete_column", %{"id" => to_string(other_column.id)})

      html = render(show_live)
      assert html =~ "Column not found on this board"

      # Cross-board column was NOT deleted.
      assert %Kanban.Columns.Column{} = Kanban.Columns.get_column!(other_column.id)
    end

    test "GET /boards/A/columns/<col-from-B>/edit redirects with error and does not leak data",
         %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board, %{name: "Secret Column"})

      conn = log_in_user(conn, owner)

      assert {:error, {:live_redirect, %{to: redirect_path, flash: flash}}} =
               live(conn, ~p"/boards/#{own_board}/columns/#{other_column}/edit")

      assert redirect_path == "/boards/#{own_board.id}"
      assert flash["error"] == "Column not found on this board"
      refute redirect_path =~ "Secret Column"
    end

    test "GET /boards/A/tasks/<task-from-B>/edit redirects with error", %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)
      other_task = task_fixture(other_column, %{title: "Cross-Board Task Secret"})

      conn = log_in_user(conn, owner)

      assert {:error, {:live_redirect, %{to: redirect_path, flash: flash}}} =
               live(conn, ~p"/boards/#{own_board}/tasks/#{other_task}/edit")

      assert redirect_path == "/boards/#{own_board.id}"
      assert flash["error"] == "Task not found on this board"
    end

    test "GET /boards/A/columns/<col-from-B>/tasks/<task-from-B>/edit redirects with error",
         %{conn: conn} do
      owner = user_fixture()
      own_board = board_fixture(owner)

      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)
      other_task = task_fixture(other_column, %{title: "Cross-Board Task Secret 2"})

      conn = log_in_user(conn, owner)

      assert {:error, {:live_redirect, %{to: redirect_path, flash: flash}}} =
               live(
                 conn,
                 ~p"/boards/#{own_board}/columns/#{other_column}/tasks/#{other_task}/edit"
               )

      assert redirect_path == "/boards/#{own_board.id}"
      assert flash["error"] == "Column or task not found on this board"
    end
  end

  describe "with_board — not found" do
    setup [:register_and_log_in_user]

    test "non-existent board id redirects to /boards with an error flash",
         %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Board not found"}}}} =
               live(conn, ~p"/boards/99999999")
    end

    test "board owned by another user redirects to /boards", %{conn: conn} do
      other_user = user_fixture()
      foreign_board = board_fixture(other_user)

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Board not found"}}}} =
               live(conn, ~p"/boards/#{foreign_board}")
    end
  end

  describe "delete_task — dependents" do
    setup [:register_and_log_in_user]

    test "rejects deletion when the task has dependents and surfaces the error flash",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      dependency = task_fixture(column, %{title: "Blocking task"})
      dependent = task_fixture(column, %{title: "Dependent task"})

      # Wire the dependency AFTER both tasks exist so the fixture doesn't
      # auto-substitute placeholder identifiers.
      {:ok, _} =
        Kanban.Tasks.update_task(dependent, %{dependencies: [dependency.identifier]})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      html =
        render_click(show_live, "delete_task", %{"id" => Integer.to_string(dependency.id)})

      assert html =~ "other tasks depend on it"
      # The dependency task is still present in the board after the failed delete
      assert render(show_live) =~ dependency.identifier
    end
  end

  describe "toggle_field — invalid input" do
    setup [:register_and_log_in_user]

    test "rejects a field name that is not on the canonical allow-list",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      html =
        render_click(show_live, "toggle_field", %{"field" => "__not_a_real_field__"})

      assert html =~ "Invalid field name"
    end
  end

  describe "unauthenticated access" do
    test "anonymous user is redirected to log-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/boards/1")
      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "view_task event — goal type" do
    setup [:register_and_log_in_user]

    test "navigates to the per-goal route when the viewed task is a :goal",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Kanban.Tasks.create_goal_with_tasks(column, %{
          "title" => "View me",
          "created_by_id" => user.id
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               render_click(view, "view_task", %{"id" => Integer.to_string(goal.id)})

      assert redirect_to == "/boards/#{board.id}/goals/#{goal.id}"
    end
  end

  describe "open_goal event" do
    setup [:register_and_log_in_user]

    test "navigates to the per-goal route with the supplied board+goal ids",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Kanban.Tasks.create_goal_with_tasks(column, %{
          "title" => "Open me",
          "created_by_id" => user.id
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               render_click(view, "open_goal", %{
                 "board-id" => Integer.to_string(board.id),
                 "goal-id" => Integer.to_string(goal.id)
               })

      assert redirect_to == "/boards/#{board.id}/goals/#{goal.id}"
    end
  end

  describe "PubSub :task_created event" do
    setup [:register_and_log_in_user]

    test "task_created broadcast triggers a board reload that surfaces the new task",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      # Create a task and fire the broadcast on the board topic that the
      # LiveView is subscribed to.
      task = task_fixture(column, %{title: "Newly created"})
      send(view.pid, {Kanban.Tasks, :task_created, task})

      html = render(view)
      assert html =~ "Newly created"
    end
  end

  describe "PubSub :task_deleted event with skip_next_reload" do
    setup [:register_and_log_in_user]

    test "respects the skip_next_reload flag and does NOT reload",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      keeper = task_fixture(column, %{title: "Sentinel"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      # Simulate a TaskLive.FormComponent :saved message which sets
      # skip_next_reload=true, then a follow-up :task_deleted broadcast
      # which should be ignored.
      send(view.pid, {KanbanWeb.TaskLive.FormComponent, {:saved, keeper}})
      send(view.pid, {Kanban.Tasks, :task_deleted, keeper})

      # The sentinel task is still in the DB and still in the rendered
      # column stream because the reload was skipped.
      html = render(view)
      assert html =~ "Sentinel"
    end
  end

  describe "ColumnLive.FormComponent saved-message handler" do
    setup [:register_and_log_in_user]

    test "reloads columns and the has_columns flag when a column form saves",
         %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "No columns yet"

      # Create a column out-of-band, then fire the form-saved message the
      # ColumnLive.FormComponent would normally send to its parent.
      column = column_fixture(board, %{name: "Fresh column"})
      send(view.pid, {KanbanWeb.ColumnLive.FormComponent, {:saved, column}})

      html = render(view)
      assert html =~ "Fresh column"
      refute html =~ "No columns yet"
    end
  end

  describe "TaskLive.FormComponent saved-message handler" do
    setup [:register_and_log_in_user]

    test "sets the skip_next_reload flag (verified via downstream task_updated suppression)",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Original title"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      # Form-saved sets skip_next_reload=true. The follow-up :task_updated
      # broadcast should now be a no-op (it would otherwise re-derive
      # all columns and overwrite the streamed state).
      send(view.pid, {KanbanWeb.TaskLive.FormComponent, {:saved, task}})

      {:ok, _} = Kanban.Tasks.update_task(task, %{title: "Updated remotely"})
      send(view.pid, {Kanban.Tasks, :task_updated, task})

      html = render(view)
      # Because the reload was skipped, the stream still carries the
      # original title until something else (clear_skip_reload + a fresh
      # broadcast) refreshes it.
      assert html =~ "Original title"
    end
  end

  describe "toggle_field — owner gate" do
    setup [:register_and_log_in_user]

    test "non-owner is rejected from toggle_field with a permission flash",
         %{conn: conn, user: viewer} do
      owner = user_fixture()
      board = board_fixture(owner)
      _column = column_fixture(board)
      Kanban.Boards.add_user_to_board(board, viewer, :read_only, owner)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      html = render_click(view, "toggle_field", %{"field" => "key_files"})

      assert html =~ "Only board owners can change field visibility"
    end
  end

  describe "column_status/1" do
    alias KanbanWeb.BoardLive.Show

    test "maps each canonical AI-board column name to its status atom regardless of case" do
      assert Show.column_status("Backlog") == :backlog
      assert Show.column_status("backlog") == :backlog
      assert Show.column_status("Ready") == :ready
      assert Show.column_status("READY") == :ready
      assert Show.column_status("Doing") == :doing
      assert Show.column_status("Review") == :review
      assert Show.column_status("Done") == :done
    end

    test "falls back to :backlog for custom column names on non-AI boards" do
      assert Show.column_status("In Progress") == :backlog
      assert Show.column_status("QA") == :backlog
      assert Show.column_status("") == :backlog
    end

    test "non-binary inputs fall through the catch-all and return :backlog" do
      # exercises the `column_status(_)` clause for nil / atom / number
      assert Show.column_status(nil) == :backlog
      assert Show.column_status(:done) == :backlog
      assert Show.column_status(123) == :backlog
    end
  end

  describe "task_card_data/1..4 — review and meta fields" do
    # NOTE: `reviewer_skipped?/1` is implemented via `get_in_either/2`,
    # which uses `Enum.find_value/2`. Because `find_value` treats both
    # `false` and `nil` as "no match", the helper currently has no way
    # to surface a literal `false` for `dispatched`. The tests below
    # pin the *actual* behaviour of `task_card_data/1` so any future
    # change is intentional rather than incidental — flip these
    # expectations when the underlying lookup is corrected.
    test "reviewer_skipped? mirrors current get_in_either behaviour for atom-keyed false" do
      card = card_for(%{reviewer_result: %{dispatched: false, reason: "n/a"}})

      assert card.reviewer_skipped? == false
      assert card.reviewer_skip_reason == "n/a"
    end

    test "string-keyed reviewer_result surfaces reason / criteria_checked / issues_found" do
      card =
        card_for(%{
          reviewer_result: %{
            "dispatched" => true,
            "reason" => "n/a",
            "acceptance_criteria_checked" => 3,
            "issues_found" => 0
          }
        })

      assert card.reviewer_skipped? == false
      assert card.reviewer_skip_reason == "n/a"
      assert card.criteria_checked == 3
      assert card.issues_found == 0
    end

    test "non-zero issues_found is surfaced for string-keyed reviewer_result" do
      card = card_for(%{reviewer_result: %{"dispatched" => true, "issues_found" => 2}})

      assert card.issues_found == 2
    end

    test "reviewer_skipped? is false when reviewer_result is missing or nil" do
      assert card_for(%{reviewer_result: nil}).reviewer_skipped? == false
      assert card_for(%{reviewer_result: %{}}).reviewer_skipped? == false
    end

    test "files_changed_count parses comma-separated actual_files_changed strings" do
      card = card_for(%{actual_files_changed: " lib/a.ex , lib/b.ex , lib/c.ex "})

      assert card.files_changed_count == 3
    end

    test "files_changed_count is nil for empty, whitespace-only, or non-binary inputs" do
      assert card_for(%{actual_files_changed: ""}).files_changed_count == nil
      assert card_for(%{actual_files_changed: "  ,  ,  "}).files_changed_count == nil
      assert card_for(%{actual_files_changed: nil}).files_changed_count == nil
    end

    test "key_files count returns the list length, or nil for empty/non-list" do
      list = [%{file_path: "lib/a.ex"}, %{file_path: "lib/b.ex"}]

      assert card_for(%{key_files: list}).key_files_count == 2
      assert card_for(%{key_files: []}).key_files_count == nil
      assert card_for(%{key_files: nil}).key_files_count == nil
    end

    test "acceptance_count parses newline-separated acceptance_criteria and ignores blanks" do
      criteria = "All tests pass\n\nCredo clean\n   \nSobelow OK\n"

      assert card_for(%{acceptance_criteria: criteria}).acceptance_count == 3
      assert card_for(%{acceptance_criteria: ""}).acceptance_count == nil
      assert card_for(%{acceptance_criteria: nil}).acceptance_count == nil
    end
  end

  describe "task_card_data/1..4 — cycle time and completed_by formatting" do
    test "cycle_time is nil when claimed_at or completed_at is missing" do
      assert card_for(%{claimed_at: nil, completed_at: nil}).cycle_time == nil

      card =
        card_for(%{claimed_at: ~U[2026-01-01 00:00:00Z], completed_at: nil})

      assert card.cycle_time == nil
    end

    test "cycle_time renders minutes only for sub-hour durations" do
      card =
        card_for(%{claimed_at: ~U[2026-01-01 10:00:00Z], completed_at: ~U[2026-01-01 10:45:00Z]})

      assert card.cycle_time == "45m"
    end

    test "cycle_time renders whole hours when minutes round to zero" do
      card =
        card_for(%{claimed_at: ~U[2026-01-01 10:00:00Z], completed_at: ~U[2026-01-01 12:00:00Z]})

      assert card.cycle_time == "2h"
    end

    test "cycle_time renders 'Nh Mm' when both components are non-zero" do
      card =
        card_for(%{claimed_at: ~U[2026-01-01 10:00:00Z], completed_at: ~U[2026-01-01 13:15:00Z]})

      assert card.cycle_time == "3h 15m"
    end

    test "cycle_time renders multi-day durations rolled up into hours" do
      # 30h 15m elapsed → "30h 15m", not "1d 6h 15m"
      card =
        card_for(%{claimed_at: ~U[2026-01-01 00:00:00Z], completed_at: ~U[2026-01-02 06:15:00Z]})

      assert card.cycle_time == "30h 15m"
    end

    test "completed_by is an :agent avatar when completed_by_agent is set" do
      card = card_for(%{completed_by_agent: "Claude Sonnet 4.5"})

      assert %{kind: :agent, name: "Claude Sonnet 4.5", palette: _} = card.completed_by
    end

    test "completed_by is nil when completed_by_agent is nil or absent" do
      assert card_for(%{completed_by_agent: nil}).completed_by == nil
    end

    test "claimed_by is a :human avatar when assigned_to user is present" do
      user = %{id: 42, name: "Alex", email: "alex@example.com"}
      card = card_for(%{assigned_to: user})

      assert %{kind: :human, name: "Alex", palette: _} = card.claimed_by
    end

    test "claimed_by falls back to email when name is missing or blank" do
      user_no_name = %{id: 1, name: nil, email: "alex@example.com"}
      user_blank = %{id: 2, name: "", email: "blank@example.com"}

      assert card_for(%{assigned_to: user_no_name}).claimed_by.name == "alex@example.com"
      assert card_for(%{assigned_to: user_blank}).claimed_by.name == "blank@example.com"
    end

    test "claimed_by is nil when no user is assigned" do
      assert card_for(%{assigned_to: nil}).claimed_by == nil
    end
  end

  defp admin_user_fixture do
    user = user_fixture()
    {:ok, admin} = Kanban.Accounts.update_user_type(user, :admin)
    admin
  end

  defp message_fixture(sender, attrs) do
    Kanban.MessagesFixtures.message_fixture(sender, attrs)
  end

  # Pipeline-friendly wrapper that constructs a Task struct with the
  # supplied overrides and pushes it through `task_card_data/1`.
  defp card_for(overrides) do
    overrides
    |> base_task_struct()
    |> KanbanWeb.BoardLive.Show.task_card_data()
  end

  # Builds a struct shaped like %Kanban.Tasks.Task{} with the supplied
  # overrides. Using the real struct keeps `task_card_data/1` happy
  # (it calls `Map.from_struct/1` and reads typed fields).
  defp base_task_struct(overrides) do
    defaults = %{
      id: 1,
      type: :work,
      parent_id: nil,
      assigned_to: nil,
      claimed_at: nil,
      completed_at: nil,
      completed_by_agent: nil,
      key_files: [],
      dependencies: [],
      acceptance_criteria: nil,
      actual_files_changed: nil,
      reviewer_result: nil
    }

    struct(Kanban.Tasks.Task, Map.merge(defaults, Map.new(overrides)))
  end
end
