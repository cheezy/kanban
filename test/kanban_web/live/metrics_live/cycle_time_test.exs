defmodule KanbanWeb.MetricsLive.CycleTimeTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Cycle Time - Basic Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays cycle time page with board name", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Cycle Time Metrics"
      assert html =~ board.name
    end

    test "displays back to dashboard link", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Back to Dashboard"
      assert html =~ ~p"/boards/#{board}/metrics"
    end

    test "displays summary stats cards", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Average"
      assert html =~ "Median"
      assert html =~ "Min"
      assert html =~ "Max"
    end

    test "displays filter controls", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Time Range"
      assert html =~ "Last 7 Days"
      assert html =~ "Last 30 Days"
      assert html =~ "Agent Filter"
      assert html =~ "Exclude Weekends"
    end

    test "displays export PDF button", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Export to PDF"
    end

    test "displays empty state when no tasks completed", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "No tasks completed in this time range"
    end
  end

  describe "Cycle Time - Data Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays cycle time data with completed tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Completed Tasks"
      assert html =~ task.identifier
      refute html =~ "No tasks completed in this time range"
    end

    test "displays task in table with cycle time", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ task.identifier
      assert html =~ task.title
    end

    test "handles tasks without claimed_at gracefully", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "No tasks completed in this time range"
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

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "First Task"
      assert html =~ "Second Task"
      assert html =~ "Third Task"
    end

    test "displays agent name when present", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "displays N/A when agent name is missing", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: nil})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "N/A"
    end
  end

  describe "Cycle Time - Filter Events" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "changes time range filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end

    test "changes agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      assert view
             |> element("select[name='agent_name']")
             |> render() =~ "Claude Sonnet 4.5"
    end

    test "toggles weekend exclusion", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      html =
        view
        |> element("form")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"
    end

    test "filters tasks by agent", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "Task by Agent 1"})
      task2 = task_fixture(column, %{title: "Task by Agent 2"})

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => "Agent 1"})

      assert html =~ "Task by Agent 1"
      refute html =~ "Task by Agent 2"
    end

    test "filters tasks outside time range", %{conn: conn, board: board, column: column} do
      old_task = task_fixture(column, %{title: "Old Task"})
      recent_task = task_fixture(column, %{title: "Recent Task"})

      {:ok, _} =
        complete_task(old_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -60, :day)
        })

      {:ok, _} = complete_task(recent_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Recent Task"
      refute html =~ "Old Task"
    end

    test "clears agent filter when empty string selected", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Agent 1"})

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => ""})

      assert html =~ "Task 1"
      assert html =~ "Task 2"
    end
  end

  describe "Cycle Time - Export PDF" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "export PDF button is clickable", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert view |> element("button", "Export to PDF") |> has_element?()
    end

    test "clicking export PDF triggers event", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert view
             |> element("button", "Export to PDF")
             |> render_click() =~ "Cycle Time Metrics"
    end
  end

  describe "Cycle Time - Query Parameter Handling" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "applies time_range from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?time_range=last_7_days")

      assert html =~ "Last 7 Days"
    end

    test "applies agent_name from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?agent_name=Claude+Sonnet+4.5")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "applies exclude_weekends from query parameters", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?exclude_weekends=true")

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
          ~p"/boards/#{board}/metrics/cycle-time?time_range=last_7_days&agent_name=Claude+Sonnet+4.5&exclude_weekends=true"
        )

      assert html =~ "Last 7 Days"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "checked"
    end

    test "handles invalid time_range gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?time_range=invalid")

      assert html =~ "Last 30 Days"
    end

    test "handles empty query parameters gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?time_range=&agent_name=&exclude_weekends=")

      assert html =~ "Last 30 Days"
      refute html =~ "checked"
    end
  end

  describe "Cycle Time - Edge Cases and Additional Coverage" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "handles today time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "today"})

      assert html =~ "Today"
    end

    test "handles last_90_days time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_90_days"})

      assert html =~ "Last 90 Days"
    end

    test "handles all_time time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "All Time"
    end

    test "handles exclude_weekends with false value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?exclude_weekends=false")

      refute html =~ "checked"
    end

    test "handles exclude_weekends with unexpected value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?exclude_weekends=maybe")

      refute html =~ "checked"
    end

    test "handles non-existent atom in parse_time_range", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/cycle-time?time_range=nonexistent_range_abc")

      assert html =~ "Last 30 Days"
    end
  end

  describe "Cycle Time - Trend Chart" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays trend chart section when tasks exist", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Cycle Time Trend"
      assert html =~ "Average cycle time per day"
      assert html =~ "<svg"
    end

    test "displays empty state for chart when no cycle time data", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Cycle Time Trend"
      assert html =~ "No cycle time data available"
    end

    test "chart renders with multiple data points across different days", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -1, :day)
      two_days_ago = DateTime.add(today, -2, :day)

      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_at: two_days_ago})
      {:ok, _} = complete_task(task2, %{completed_at: yesterday})
      {:ok, _} = complete_task(task3, %{completed_at: today})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "<polyline"
      assert html =~ "fill=\"none\""
      assert html =~ "stroke=\"url(#lineGradient)\""
    end

    test "chart includes data point circles for each day", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_at: DateTime.add(DateTime.utc_now(), -1, :day)})
      {:ok, _} = complete_task(task2, %{completed_at: DateTime.utc_now()})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "<circle"
      assert html =~ "fill=\"rgb(59, 130, 246)\""
    end

    test "chart displays date labels on x-axis", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "text-anchor=\"middle\""
      assert html =~ ~r/\d{2}\/\d{2}/
    end

    test "chart calculates daily averages for multiple tasks on same day", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} =
        complete_task(task1, %{
          claimed_at: DateTime.add(today, -2, :hour),
          completed_at: today
        })

      {:ok, _} =
        complete_task(task2, %{
          claimed_at: DateTime.add(today, -4, :hour),
          completed_at: today
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Cycle Time Trend"
      assert html =~ "<svg"
    end

    test "displays grey dashed trend line with multiple data points", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_at: DateTime.add(today, -2, :day)})
      {:ok, _} = complete_task(task2, %{completed_at: DateTime.add(today, -1, :day)})
      {:ok, _} = complete_task(task3, %{completed_at: today})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "stroke=\"#9ca3af\""
      assert html =~ "stroke-dasharray=\"5,5\""
      assert html =~ "opacity=\"0.7\""
    end

    test "does not display trend line with single data point", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      refute html =~ "stroke-dasharray=\"5,5\""
    end

    test "does not display trend line with empty data", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      refute html =~ "stroke-dasharray=\"5,5\""
    end
  end

  describe "Cycle Time - Task Grouping" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "groups tasks by completion date", %{conn: conn, board: board, column: column} do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -1, :day)

      task1 = task_fixture(column, %{title: "Today Task"})
      task2 = task_fixture(column, %{title: "Yesterday Task"})

      {:ok, _} = complete_task(task1, %{completed_at: today})
      {:ok, _} = complete_task(task2, %{completed_at: yesterday})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Today Task"
      assert html =~ "Yesterday Task"
    end

    test "sorts tasks within a date by completion time descending", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      task1 = task_fixture(column, %{identifier: "W1"})
      task2 = task_fixture(column, %{identifier: "W2"})
      task3 = task_fixture(column, %{identifier: "W3"})

      {:ok, _} = complete_task(task1, %{completed_at: DateTime.new!(DateTime.to_date(today), ~T[10:00:00])})
      {:ok, _} = complete_task(task2, %{completed_at: DateTime.new!(DateTime.to_date(today), ~T[14:00:00])})
      {:ok, _} = complete_task(task3, %{completed_at: DateTime.new!(DateTime.to_date(today), ~T[18:00:00])})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      [_before, tasks_section] = String.split(html, "Completed Tasks", parts: 2)

      w3_index = :binary.match(tasks_section, "W3") |> elem(0)
      w2_index = :binary.match(tasks_section, "W2") |> elem(0)
      w1_index = :binary.match(tasks_section, "W1") |> elem(0)

      assert w3_index < w2_index
      assert w2_index < w1_index
    end

    test "does not display task count in date headers", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_at: today})
      {:ok, _} = complete_task(task2, %{completed_at: today})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      refute html =~ "2 tasks"
      refute html =~ "tasks completed"
    end
  end

  describe "Cycle Time - Task Display Format" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays Claimed timestamp before Completed timestamp", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      claimed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        complete_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      [_before_task, task_section] = String.split(html, task.identifier, parts: 2)

      claimed_index = :binary.match(task_section, "Claimed:") |> elem(0)
      completed_index = :binary.match(task_section, "Completed:") |> elem(0)

      assert claimed_index < completed_index, "Claimed should appear before Completed"
    end

    test "displays full datetime for claimed timestamp", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Claimed:"
      assert html =~ ~r/\d{1,2}:\d{2} (AM|PM)/
    end

    test "displays only time for completed timestamp", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/cycle-time")

      assert html =~ "Completed:"
      assert html =~ ~r/\d{1,2}:\d{2} (AM|PM)/
    end
  end

  describe "Cycle Time - Access Control" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "denies access to non-board-members", %{conn: conn, board: board} do
      other_user = user_fixture()
      conn = log_in_user(conn, other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{board}/metrics/cycle-time")
      end
    end

    test "redirects non-AI-optimized boards to board page", %{conn: conn, user: user} do
      regular_board = board_fixture(user)

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/boards/#{regular_board}/metrics/cycle-time")

      assert to == "/boards/#{regular_board.id}"
      assert flash["error"] == "Metrics are only available for AI-optimized boards."
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = ai_optimized_board_fixture(user)
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
