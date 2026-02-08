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

      assert html =~ "Created:"
      assert html =~ "Claimed:"
      assert html =~ "Completed:"
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

    test "export PDF link exists with correct parameters", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Export to PDF"
      assert html =~ ~r|/boards/#{board.id}/metrics/throughput/export\?|
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
        live(
          conn,
          ~p"/boards/#{board}/metrics/throughput?time_range=&agent_name=&exclude_weekends="
        )

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

  describe "Throughput - Calendar Day Filtering" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "filters by calendar days, not exact hours for last_7_days", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      jan_31_task = task_fixture(column, %{title: "Jan 31 Task"})
      feb_01_task = task_fixture(column, %{title: "Feb 01 Task"})
      feb_07_task = task_fixture(column, %{title: "Feb 07 Task"})

      jan_31_date = Date.add(today, -7)
      feb_01_date = Date.add(today, -6)

      {:ok, _} =
        complete_task(jan_31_task, %{
          completed_at: DateTime.new!(jan_31_date, ~T[23:00:00])
        })

      {:ok, _} =
        complete_task(feb_01_task, %{
          completed_at: DateTime.new!(feb_01_date, ~T[01:00:00])
        })

      {:ok, _} = complete_task(feb_07_task)

      {:ok, view, _html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=last_7_days")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Feb 01 Task"
      assert html =~ "Feb 07 Task"
      refute html =~ "Jan 31 Task"
    end

    test "filters by calendar days for last_30_days", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      day_30_ago = Date.add(today, -30)
      day_29_ago = Date.add(today, -29)

      old_task = task_fixture(column, %{title: "Day 30 Task"})
      recent_task = task_fixture(column, %{title: "Day 29 Task"})

      {:ok, _} =
        complete_task(old_task, %{
          completed_at: DateTime.new!(day_30_ago, ~T[12:00:00])
        })

      {:ok, _} =
        complete_task(recent_task, %{
          completed_at: DateTime.new!(day_29_ago, ~T[12:00:00])
        })

      {:ok, view, _html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=last_30_days")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_30_days"})

      assert html =~ "Day 29 Task"
      refute html =~ "Day 30 Task"
    end

    test "filters by calendar days for last_90_days", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      day_90_ago = Date.add(today, -90)
      day_89_ago = Date.add(today, -89)

      old_task = task_fixture(column, %{title: "Day 90 Task"})
      recent_task = task_fixture(column, %{title: "Day 89 Task"})

      {:ok, _} =
        complete_task(old_task, %{
          completed_at: DateTime.new!(day_90_ago, ~T[12:00:00])
        })

      {:ok, _} =
        complete_task(recent_task, %{
          completed_at: DateTime.new!(day_89_ago, ~T[12:00:00])
        })

      {:ok, view, _html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=last_90_days")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_90_days"})

      assert html =~ "Day 89 Task"
      refute html =~ "Day 90 Task"
    end

    test "includes tasks from today regardless of time", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      morning_task = task_fixture(column, %{title: "Morning Task"})
      evening_task = task_fixture(column, %{title: "Evening Task"})

      {:ok, _} =
        complete_task(morning_task, %{
          completed_at: DateTime.new!(today, ~T[08:00:00])
        })

      {:ok, _} =
        complete_task(evening_task, %{
          completed_at: DateTime.new!(today, ~T[20:00:00])
        })

      {:ok, view, _html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=last_7_days")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Morning Task"
      assert html =~ "Evening Task"
    end
  end

  describe "Throughput - Grouped Tasks Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays tasks grouped by completion date", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      yesterday = Date.add(today, -1)

      task1 = task_fixture(column, %{title: "Today Task 1"})
      task2 = task_fixture(column, %{title: "Today Task 2"})
      task3 = task_fixture(column, %{title: "Yesterday Task"})

      {:ok, _} =
        complete_task(task1, %{
          completed_at: DateTime.new!(today, ~T[10:00:00])
        })

      {:ok, _} =
        complete_task(task2, %{
          completed_at: DateTime.new!(today, ~T[14:00:00])
        })

      {:ok, _} =
        complete_task(task3, %{
          completed_at: DateTime.new!(yesterday, ~T[15:00:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Today Task 1"
      assert html =~ "Today Task 2"
      assert html =~ "Yesterday Task"
    end

    test "displays date headers with task counts", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, _} =
        complete_task(task1, %{
          completed_at: DateTime.new!(today, ~T[10:00:00])
        })

      {:ok, _} =
        complete_task(task2, %{
          completed_at: DateTime.new!(today, ~T[11:00:00])
        })

      {:ok, _} =
        complete_task(task3, %{
          completed_at: DateTime.new!(today, ~T[12:00:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "3 tasks"
    end

    test "sorts tasks within each date by completion time descending", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      task1 = task_fixture(column, %{title: "Morning Task", identifier: "W1"})
      task2 = task_fixture(column, %{title: "Afternoon Task", identifier: "W2"})
      task3 = task_fixture(column, %{title: "Evening Task", identifier: "W3"})

      {:ok, _} =
        complete_task(task1, %{
          completed_at: DateTime.new!(today, ~T[08:00:00])
        })

      {:ok, _} =
        complete_task(task2, %{
          completed_at: DateTime.new!(today, ~T[14:00:00])
        })

      {:ok, _} =
        complete_task(task3, %{
          completed_at: DateTime.new!(today, ~T[20:00:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      # Extract only the Completed Tasks section to avoid matching goals
      [_before, tasks_section] = String.split(html, "Completed Tasks", parts: 2)

      w3_index = :binary.match(tasks_section, "W3") |> elem(0)
      w2_index = :binary.match(tasks_section, "W2") |> elem(0)
      w1_index = :binary.match(tasks_section, "W1") |> elem(0)

      assert w3_index < w2_index
      assert w2_index < w1_index
    end

    test "displays only completion time for tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)

      task = task_fixture(column, %{title: "Test Task"})

      {:ok, _} =
        complete_task(task, %{
          completed_at: DateTime.new!(today, ~T[14:30:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "02:30 PM"
    end

    test "displays empty state when no grouped tasks", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "No tasks completed in this time range"
    end

    test "groups tasks across multiple dates correctly", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      yesterday = Date.add(today, -1)
      two_days_ago = Date.add(today, -2)

      task1 = task_fixture(column, %{title: "Today Task"})
      task2 = task_fixture(column, %{title: "Yesterday Task"})
      task3 = task_fixture(column, %{title: "Two Days Ago Task"})

      {:ok, _} =
        complete_task(task1, %{
          completed_at: DateTime.new!(today, ~T[10:00:00])
        })

      {:ok, _} =
        complete_task(task2, %{
          completed_at: DateTime.new!(yesterday, ~T[10:00:00])
        })

      {:ok, _} =
        complete_task(task3, %{
          completed_at: DateTime.new!(two_days_ago, ~T[10:00:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      today_formatted = Calendar.strftime(today, "%b %d, %Y")
      yesterday_formatted = Calendar.strftime(yesterday, "%b %d, %Y")
      two_days_ago_formatted = Calendar.strftime(two_days_ago, "%b %d, %Y")

      assert html =~ today_formatted
      assert html =~ yesterday_formatted
      assert html =~ two_days_ago_formatted

      assert html =~ "1 task"
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = board_fixture(user)
    column = column_fixture(board)
    %{board: board, column: column}
  end

  describe "Throughput - Completed Goals" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays completed goals section when goals exist", %{
      conn: conn,
      board: board,
      column: column
    } do
      goal = task_fixture(column, %{title: "Test Goal", type: :goal})
      {:ok, _} = complete_task(goal)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Completed Goals"
      assert html =~ "Test Goal"
      assert html =~ "Goals completed in this time range"
    end

    test "hides completed goals section when no goals exist", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Regular Task", type: :work})
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      refute html =~ "Completed Goals"
      assert html =~ "Regular Task"
    end

    test "excludes goals from task calculations and completed tasks section", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "Work Task 1", type: :work})
      task2 = task_fixture(column, %{title: "Work Task 2", type: :work})
      goal = task_fixture(column, %{title: "Goal Task", type: :goal})

      {:ok, _} = complete_task(task1)
      {:ok, _} = complete_task(task2)
      {:ok, _} = complete_task(goal)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ "Work Task 1"
      assert html =~ "Work Task 2"

      # Goal appears in Completed Goals section
      assert html =~ "Completed Goals"
      assert html =~ "Goal Task"

      # Total tasks should be 2, not 3 (goals excluded)
      # Extract the Total Tasks stat card to check the count
      [_, total_section | _] = String.split(html, "Total Tasks")
      [total_card | _] = String.split(total_section, "Avg Per Day")

      # Check that the total is 2, not 3
      assert total_card =~ ~r/>\s*2\s*</
      refute total_card =~ ~r/>\s*3\s*</
    end

    test "displays goal with identifier and dates", %{
      conn: conn,
      board: board,
      column: column
    } do
      goal = task_fixture(column, %{title: "My Goal", type: :goal})
      {:ok, _} = complete_task(goal)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      assert html =~ goal.identifier
      assert html =~ "My Goal"
      assert html =~ "Completed:"
      assert html =~ "Created:"
    end

    test "does not display agent name for goals", %{
      conn: conn,
      board: board,
      column: column
    } do
      goal = task_fixture(column, %{title: "Test Goal", type: :goal})
      {:ok, updated_goal} = complete_task(goal, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      # Goal section should exist
      assert html =~ "Completed Goals"
      assert html =~ "Test Goal"

      # Agent name should not appear in the goals section
      # We'll check by looking for the goal identifier followed by agent name
      refute html =~ ~r/#{updated_goal.identifier}.*Claude Sonnet 4\.5/s
    end

    test "filters goals by time range", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      old_date = Date.add(today, -10)

      recent_goal = task_fixture(column, %{title: "Recent Goal", type: :goal})
      old_goal = task_fixture(column, %{title: "Old Goal", type: :goal})

      {:ok, _} = complete_task(recent_goal, %{completed_at: DateTime.utc_now()})
      {:ok, _} = complete_task(old_goal, %{completed_at: DateTime.new!(old_date, ~T[12:00:00])})

      {:ok, view, _html} =
        live(conn, ~p"/boards/#{board}/metrics/throughput?time_range=last_7_days")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Recent Goal"
      refute html =~ "Old Goal"
    end

    test "filters goals by agent", %{
      conn: conn,
      board: board,
      column: column
    } do
      goal1 = task_fixture(column, %{title: "Goal 1", type: :goal})
      goal2 = task_fixture(column, %{title: "Goal 2", type: :goal})

      {:ok, _} = complete_task(goal1, %{completed_by_agent: "Claude Sonnet 4.5"})
      {:ok, _} = complete_task(goal2, %{completed_by_agent: "GPT-4"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      html =
        view
        |> element("form")
        |> render_change(%{
          "time_range" => "last_30_days",
          "agent_name" => "Claude Sonnet 4.5",
          "exclude_weekends" => "false"
        })

      assert html =~ "Goal 1"
      refute html =~ "Goal 2"
    end

    test "displays multiple goals sorted by completion date descending", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      yesterday = Date.add(today, -1)
      two_days_ago = Date.add(today, -2)

      goal1 = task_fixture(column, %{title: "Goal Today", type: :goal, identifier: "G1"})
      goal2 = task_fixture(column, %{title: "Goal Yesterday", type: :goal, identifier: "G2"})
      goal3 = task_fixture(column, %{title: "Goal Two Days Ago", type: :goal, identifier: "G3"})

      {:ok, _} = complete_task(goal1, %{completed_at: DateTime.new!(today, ~T[10:00:00])})

      {:ok, _} =
        complete_task(goal2, %{completed_at: DateTime.new!(yesterday, ~T[10:00:00])})

      {:ok, _} =
        complete_task(goal3, %{completed_at: DateTime.new!(two_days_ago, ~T[10:00:00])})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      # Find positions of goal identifiers
      g1_index = :binary.match(html, "G1") |> elem(0)
      g2_index = :binary.match(html, "G2") |> elem(0)
      g3_index = :binary.match(html, "G3") |> elem(0)

      # Most recent should appear first
      assert g1_index < g2_index
      assert g2_index < g3_index
    end

    test "goals section appears above completed tasks section", %{
      conn: conn,
      board: board,
      column: column
    } do
      goal = task_fixture(column, %{title: "Test Goal", type: :goal})
      task = task_fixture(column, %{title: "Test Task", type: :work})

      {:ok, _} = complete_task(goal)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      goals_index = :binary.match(html, "Completed Goals") |> elem(0)
      tasks_index = :binary.match(html, "Completed Tasks") |> elem(0)

      assert goals_index < tasks_index
    end

    test "handles mixed task types correctly", %{
      conn: conn,
      board: board,
      column: column
    } do
      work_task = task_fixture(column, %{title: "Work Task", type: :work})
      defect = task_fixture(column, %{title: "Bug Fix", type: :defect})
      goal = task_fixture(column, %{title: "Project Goal", type: :goal})

      {:ok, _} = complete_task(work_task)
      {:ok, _} = complete_task(defect)
      {:ok, _} = complete_task(goal)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/throughput")

      # Goals section exists
      assert html =~ "Completed Goals"
      assert html =~ "Project Goal"

      # Work and defect tasks appear in tasks section
      assert html =~ "Completed Tasks"
      assert html =~ "Work Task"
      assert html =~ "Bug Fix"

      # Total count should be 2 (work + defect, excluding goal)
      # Extract the Total Tasks stat card to check the count
      [_, total_section | _] = String.split(html, "Total Tasks")
      [total_card | _] = String.split(total_section, "Avg Per Day")

      # Check that the total is 2, not 3
      assert total_card =~ ~r/>\s*2\s*</
      refute total_card =~ ~r/>\s*3\s*</
    end
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
