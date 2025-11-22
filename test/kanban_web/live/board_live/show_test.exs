defmodule KanbanWeb.BoardLive.ShowTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

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

      assert html =~ "WIP limit"
      assert html =~ "5"
    end
  end
end
