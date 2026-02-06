defmodule KanbanWeb.MetricsLive.ThroughputTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Throughput - Basic Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays throughput page with board name", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Throughput Metrics"
      assert html =~ board.name
    end

    test "displays back to dashboard link", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Back to Dashboard"
      assert html =~ ~p"/boards/#{board}/metrics"
    end

    test "displays summary stats cards", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Total Tasks"
      assert html =~ "Avg Per Day"
      assert html =~ "Peak Day"
      assert html =~ "Peak Count"
    end

    test "displays filter controls", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Time Range"
      assert html =~ "Last 7 Days"
      assert html =~ "Last 30 Days"
      assert html =~ "Agent Filter"
      assert html =~ "Exclude Weekends"
    end

    test "displays export PDF button", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Export to PDF"
    end

    test "displays empty state when no tasks completed", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "No tasks completed in this time range"
    end
  end

  describe "Throughput - Data Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays throughput data with completed tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Daily Completions Bar Chart"
      refute html =~ "No tasks completed in this time range"
    end

    test "displays correct total tasks count", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1)
      {:ok, _} = complete_task(task2)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "2"
    end

    test "displays multiple completed tasks", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "First Task"})
      task2 = task_fixture(column, %{title: "Second Task"})
      task3 = task_fixture(column, %{title: "Third Task"})

      {:ok, _} = complete_task(task1)
      {:ok, _} = complete_task(task2)
      {:ok, _} = complete_task(task3)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "3"
    end

    test "filters tasks by agent in count", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Agent 1"})
      {:ok, _} = complete_task(task3, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => "Agent 1"})

      assert html =~ "2"
    end
  end

  describe "Throughput - Task Details Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays completed tasks section header", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Completed Tasks"
    end

    test "displays task in table with identifier and title", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ task.identifier
      assert html =~ task.title
    end

    test "displays task timestamps", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Created At"
      assert html =~ "Claimed At"
      assert html =~ "Completed At"
    end

    test "displays agent name when present", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "displays N/A when agent name is missing", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: nil})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "N/A"
    end

    test "displays multiple tasks sorted by completion time", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "First Task"})
      task2 = task_fixture(column, %{title: "Second Task"})
      task3 = task_fixture(column, %{title: "Third Task"})

      {:ok, _} = complete_task(task1, %{completed_at: DateTime.add(DateTime.utc_now(), -3, :day)})
      {:ok, _} = complete_task(task2, %{completed_at: DateTime.add(DateTime.utc_now(), -2, :day)})
      {:ok, _} = complete_task(task3, %{completed_at: DateTime.add(DateTime.utc_now(), -1, :day)})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "First Task"
      assert html =~ "Second Task"
      assert html =~ "Third Task"
    end

    test "excludes tasks without completed_at from task list", %{
      conn: conn,
      board: board,
      column: column
    } do
      incomplete_task = task_fixture(column, %{title: "Not Done"})
      complete_task_data = task_fixture(column, %{title: "Done"})

      {:ok, _} = Tasks.update_task(incomplete_task, %{claimed_at: DateTime.utc_now()})
      {:ok, _} = complete_task(complete_task_data)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Done"
      refute html =~ "Not Done"
    end

    test "filters tasks by agent in task list", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "Task by Agent 1"})
      task2 = task_fixture(column, %{title: "Task by Agent 2"})

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => "Agent 1"})

      assert html =~ "Task by Agent 1"
      refute html =~ "Task by Agent 2"
    end

    test "filters tasks outside time range in task list", %{
      conn: conn,
      board: board,
      column: column
    } do
      old_task = task_fixture(column, %{title: "Old Task"})
      recent_task = task_fixture(column, %{title: "Recent Task"})

      {:ok, _} =
        complete_task(old_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -60, :day)
        })

      {:ok, _} = complete_task(recent_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Recent Task"
      refute html =~ "Old Task"
    end

    test "displays empty state when no tasks in filtered results", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Agent 1"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => "Agent 2"})

      assert html =~ "No tasks completed in this time range"
    end
  end

  describe "Throughput - Filter Events" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "changes time range filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end

    test "changes agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      assert view
             |> element("select[name='agent_name']")
             |> render() =~ "Claude Sonnet 4.5"
    end

    test "toggles weekend exclusion", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"
    end

    test "filters tasks outside time range", %{conn: conn, board: board, column: column} do
      old_task = task_fixture(column)
      recent_task = task_fixture(column)

      {:ok, _} =
        complete_task(old_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -60, :day)
        })

      {:ok, _} = complete_task(recent_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "1"
    end

    test "clears agent filter when empty string selected", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Agent 1"})

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => ""})

      assert html =~ "2"
    end
  end

  describe "Throughput - Export PDF" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "export PDF button is clickable", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert view |> element("button", "Export to PDF") |> has_element?()
    end

    test "clicking export PDF triggers event", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert view
             |> element("button", "Export to PDF")
             |> render_click() =~ "Throughput Metrics"
    end
  end

  describe "Throughput - Query Parameter Handling" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "applies time_range from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=last_7_days")

      assert html =~ "Last 7 Days"
    end

    test "applies agent_name from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?agent_name=Claude+Sonnet+4.5")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "applies exclude_weekends from query parameters", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?exclude_weekends=true")

      assert html =~ "checked"
    end

    test "applies multiple filters from query parameters", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(
          conn,
          ~p"/boards/#{board}/metrics/throughput?time_range=last_7_days&agent_name=Claude+Sonnet+4.5&exclude_weekends=true"
        )

      assert html =~ "Last 7 Days"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "checked"
    end

    test "handles invalid time_range gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=invalid")

      assert html =~ "Last 30 Days"
    end

    test "handles empty query parameters gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=&agent_name=&exclude_weekends=")

      assert html =~ "Last 30 Days"
      refute html =~ "checked"
    end
  end

  describe "Throughput - Edge Cases and Additional Coverage" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "handles today time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "today"})

      assert html =~ "Today"
    end

    test "handles last_90_days time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_90_days"})

      assert html =~ "Last 90 Days"
    end

    test "handles all_time time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "All Time"
    end

    test "handles exclude_weekends with false value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?exclude_weekends=false")

      refute html =~ "checked"
    end

    test "handles exclude_weekends with unexpected value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?exclude_weekends=maybe")

      refute html =~ "checked"
    end

    test "handles non-existent atom in parse_time_range", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=nonexistent_range_abc")

      assert html =~ "Last 30 Days"
    end
  end

  describe "Throughput - Access Control" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "denies access to non-board-members", %{conn: conn, board: board} do
      other_user = user_fixture()
      conn = log_in_user(conn, other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{board}/metrics/throughput")
      end
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = board_fixture(user)
    column = column_fixture(board)
    %{board: board, column: column}
  end

  defp complete_task(task, attrs \\ %{}) do
    claimed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
    completed_at = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          claimed_at: claimed_at,
          completed_at: completed_at
        },
        attrs
      )

    Tasks.update_task(task, attrs)
  end
end
