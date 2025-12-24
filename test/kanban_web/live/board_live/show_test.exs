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
  end
end
