defmodule KanbanWeb.MetricsLive.LeadTimeTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Lead Time - Basic Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays lead time page with board name", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Lead Time Metrics"
      assert html =~ board.name
    end

    test "displays back to dashboard link", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Back to Dashboard"
      assert html =~ ~p"/boards/#{board}/metrics"
    end

    test "displays summary stats cards", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Average"
      assert html =~ "Median"
      assert html =~ "Min"
      assert html =~ "Max"
    end

    test "displays filter controls", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Time Range"
      assert html =~ "Last 7 Days"
      assert html =~ "Last 30 Days"
      assert html =~ "Agent Filter"
      assert html =~ "Exclude Weekends"
    end

    test "displays export PDF button", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Export to PDF"
    end

    test "displays empty state when no tasks completed", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "No tasks completed in this time range"
    end
  end

  describe "Lead Time - Data Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays lead time data with completed tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Completed Tasks"
      assert html =~ task.identifier
      refute html =~ "No tasks completed in this time range"
    end

    test "displays task in table with lead time", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ task.identifier
      assert html =~ task.title
    end

    test "uses reviewed_at for tasks that went through review", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      reviewed_at = DateTime.add(DateTime.utc_now(), -12, :hour)

      {:ok, _} =
        complete_task(task, %{
          needs_review: true,
          reviewed_at: reviewed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ task.identifier
    end

    test "uses completed_at for tasks without review", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      {:ok, _} =
        complete_task(task, %{
          needs_review: false,
          reviewed_at: nil
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ task.identifier
    end
  end

  describe "Lead Time - Filter Events" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "changes time range filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end

    test "changes agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      assert view
             |> element("select[name='agent_name']")
             |> render() =~ "Claude Sonnet 4.5"
    end

    test "toggles weekend exclusion", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"
    end
  end

  describe "Lead Time - Export PDF" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "export PDF button is clickable", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert view |> element("button", "Export to PDF") |> has_element?()
    end
  end

  describe "Lead Time - Access Control" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "denies access to non-board-members", %{conn: conn, board: board} do
      other_user = user_fixture()
      conn = log_in_user(conn, other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{board}/metrics/lead-time")
      end
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = board_fixture(user)
    column = column_fixture(board)
    %{board: board, column: column}
  end

  defp complete_task(task, attrs \\ %{}) do
    completed_at = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          completed_at: completed_at
        },
        attrs
      )

    Tasks.update_task(task, attrs)
  end
end
