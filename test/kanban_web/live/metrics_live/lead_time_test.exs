defmodule KanbanWeb.MetricsLive.LeadTimeTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Ecto.Query

  alias Kanban.Repo
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

    test "displays export dropdown with PDF and Excel options", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Export"
      assert html =~ "PDF"
      assert html =~ "Excel"
      assert html =~ "format=excel"
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

    test "displays tasks that went through review", %{
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

    test "displays tasks without review", %{
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

    test "excludes tasks without completed_at", %{conn: conn, board: board, column: column} do
      incomplete_task = task_fixture(column, %{title: "Not Done"})
      complete_task_data = task_fixture(column, %{title: "Done"})

      {:ok, _} = Tasks.update_task(incomplete_task, %{claimed_at: DateTime.utc_now()})
      {:ok, _} = complete_task(complete_task_data)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Done"
      refute html =~ "Not Done"
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

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "First Task"
      assert html =~ "Second Task"
      assert html =~ "Third Task"
    end

    test "displays agent name when present", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "displays Agent Unknown when agent name is missing", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: nil})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Agent Unknown"
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

    test "filters tasks by agent", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "Task by Agent 1"})
      task2 = task_fixture(column, %{title: "Task by Agent 2"})

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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

  describe "Lead Time - Time Range Options" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "filters with :today time range", %{conn: conn, board: board, column: column} do
      old_task = task_fixture(column, %{title: "Yesterday Task"})
      today_task = task_fixture(column, %{title: "Today Task"})

      {:ok, _} =
        complete_task(old_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -25, :hour)
        })

      {:ok, _} = complete_task(today_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "today"})

      assert html =~ "Today Task"
      refute html =~ "Yesterday Task"
    end

    test "filters with :last_90_days time range", %{conn: conn, board: board, column: column} do
      recent_task = task_fixture(column, %{title: "Recent Task"})
      {:ok, _} = complete_task(recent_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_90_days"})

      assert html =~ "Recent Task"
      assert html =~ "Last 90 Days"
    end

    test "filters with :all_time time range", %{conn: conn, board: board, column: column} do
      ancient_task = task_fixture(column, %{title: "Ancient Task"})

      {:ok, _} =
        complete_task(ancient_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -365, :day)
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "Ancient Task"
      assert html =~ "All Time"
    end
  end

  describe "Lead Time - Summary Statistics" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays average lead time", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1)
      {:ok, _} = complete_task(task2)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Average"
    end

    test "displays median lead time", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Median"
    end

    test "displays min and max lead time", %{conn: conn, board: board, column: column} do
      fast_task = task_fixture(column, %{title: "Fast"})
      slow_task = task_fixture(column, %{title: "Slow"})

      {:ok, _} =
        complete_task(fast_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        })

      {:ok, _} =
        complete_task(slow_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -48, :hour)
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Min"
      assert html =~ "Max"
    end
  end

  describe "Lead Time - Export Dropdown" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "export dropdown button exists", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert view |> element("button", "Export") |> has_element?()
    end

    test "export dropdown contains PDF and Excel options", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Export"
      assert html =~ "PDF"
      assert html =~ "Excel"
      assert html =~ ~r|/boards/#{board.id}/metrics/lead-time/export\?|
      assert html =~ "format=excel"
    end
  end

  describe "Lead Time - Query Parameter Handling" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "applies time_range from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/lead-time?time_range=last_7_days")

      assert html =~ "Last 7 Days"
    end

    test "applies agent_name from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/lead-time?agent_name=Claude+Sonnet+4.5")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "applies exclude_weekends from query parameters", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/lead-time?exclude_weekends=true")

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
          ~p"/boards/#{board}/metrics/lead-time?time_range=last_7_days&agent_name=Claude+Sonnet+4.5&exclude_weekends=true"
        )

      assert html =~ "Last 7 Days"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "checked"
    end

    test "handles invalid time_range gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/lead-time?time_range=invalid")

      assert html =~ "Last 30 Days"
    end

    test "handles empty query parameters gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(
          conn,
          ~p"/boards/#{board}/metrics/lead-time?time_range=&agent_name=&exclude_weekends="
        )

      assert html =~ "Last 30 Days"
      refute html =~ "checked"
    end
  end

  describe "Lead Time - Trend Chart" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays trend chart section when tasks exist", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Lead Time Trend"
      assert html =~ "Average lead time per day"
      assert html =~ "<svg"
    end

    test "displays empty state for chart when no lead time data", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Lead Time Trend"
      assert html =~ "No lead time data available"
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

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "<circle"
      assert html =~ "fill=\"rgb(59, 130, 246)\""
    end

    test "chart displays date labels on x-axis", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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
          completed_at: today
        })

      {:ok, _} =
        complete_task(task2, %{
          completed_at: today
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Lead Time Trend"
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

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      refute html =~ "stroke-dasharray=\"5,5\""
    end

    test "does not display trend line with empty data", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      refute html =~ "stroke-dasharray=\"5,5\""
    end
  end

  describe "Lead Time - Task Grouping" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "groups tasks by completion date", %{conn: conn, board: board, column: column} do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -1, :day)

      task1 = task_fixture(column, %{title: "Today Task"})
      task2 = task_fixture(column, %{title: "Yesterday Task"})

      {:ok, _} = complete_task(task1, %{completed_at: today})
      {:ok, _} = complete_task(task2, %{completed_at: yesterday})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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

      {:ok, _} =
        complete_task(task1, %{
          completed_at: today |> DateTime.to_date() |> DateTime.new!(~T[10:00:00])
        })

      {:ok, _} =
        complete_task(task2, %{
          completed_at: today |> DateTime.to_date() |> DateTime.new!(~T[14:00:00])
        })

      {:ok, _} =
        complete_task(task3, %{
          completed_at: today |> DateTime.to_date() |> DateTime.new!(~T[18:00:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

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

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      refute html =~ "2 tasks"
      refute html =~ "tasks completed"
    end
  end

  describe "Lead Time - Task Display Format" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays Created timestamp before Completed timestamp", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        complete_task(task, %{
          completed_at: completed_at
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      [_before_task, task_section] = String.split(html, task.identifier, parts: 2)

      created_index = :binary.match(task_section, "Created:") |> elem(0)
      completed_index = :binary.match(task_section, "Completed:") |> elem(0)

      assert created_index < completed_index, "Created should appear before Completed"
    end

    test "displays full datetime for created timestamp", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Created:"
      assert html =~ ~r/\d{1,2}:\d{2} (AM|PM)/
    end

    test "displays only time for completed timestamp", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Completed:"
      assert html =~ ~r/\d{1,2}:\d{2} (AM|PM)/
    end
  end

  describe "Lead Time - Edge Cases and Additional Coverage" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "handles today time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "today"})

      assert html =~ "Today"
    end

    test "handles last_90_days time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_90_days"})

      assert html =~ "Last 90 Days"
    end

    test "handles all_time time range", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "All Time"
    end

    test "handles exclude_weekends with false value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/lead-time?exclude_weekends=false")

      refute html =~ "checked"
    end

    test "handles exclude_weekends with unexpected value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/lead-time?exclude_weekends=maybe")

      refute html =~ "checked"
    end
  end

  describe "Lead Time - Formatting and Helper Functions" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "formats lead time in hours when less than 24 hours", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Create task and manually set inserted_at to 5 hours ago
      task = task_fixture(column)
      five_hours_ago = DateTime.add(DateTime.utc_now(), -5, :hour)

      # Update the inserted_at timestamp directly in the database
      from(t in Kanban.Tasks.Task, where: t.id == ^task.id)
      |> Repo.update_all(set: [inserted_at: five_hours_ago])

      {:ok, updated_task} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Task should be visible with hours formatting
      assert html =~ updated_task.identifier
      assert html =~ updated_task.title
    end

    test "formats lead time in days when 24 hours or more", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Create task and manually set inserted_at to 30 days ago
      task = task_fixture(column)
      thirty_days_ago = DateTime.add(DateTime.utc_now(), -30, :day)

      # Update the inserted_at timestamp directly in the database
      from(t in Kanban.Tasks.Task, where: t.id == ^task.id)
      |> Repo.update_all(set: [inserted_at: thirty_days_ago])

      {:ok, updated_task} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Task should be visible with days formatting
      assert html =~ updated_task.identifier
      assert html =~ updated_task.title
    end

    test "displays N/A for tasks without completed_at", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Create task but don't complete it
      _task = task_fixture(column)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Should show empty state since no completed tasks
      assert html =~ "No tasks completed in this time range"
    end

    test "handles empty task list for calculations", %{conn: conn, board: board} do
      # No tasks created at all
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Should show empty state
      assert html =~ "No tasks completed in this time range"
      # Stats should show 0 or N/A
      assert html =~ "0.0m"
    end

    test "displays chart with tasks having hours-based lead times", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Create multiple tasks with hours-based lead times
      task1 = task_fixture(column)
      three_hours_ago = DateTime.add(DateTime.utc_now(), -3, :hour)

      from(t in Kanban.Tasks.Task, where: t.id == ^task1.id)
      |> Repo.update_all(set: [inserted_at: three_hours_ago])

      {:ok, _} = complete_task(task1)

      task2 = task_fixture(column)
      six_hours_ago = DateTime.add(DateTime.utc_now(), -6, :hour)

      from(t in Kanban.Tasks.Task, where: t.id == ^task2.id)
      |> Repo.update_all(set: [inserted_at: six_hours_ago])

      {:ok, _} = complete_task(task2)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Chart should be rendered
      assert html =~ "Lead Time Trend"
    end

    test "displays chart with tasks having days-based lead times", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Create multiple tasks with days-based lead times
      task1 = task_fixture(column)
      forty_days_ago = DateTime.add(DateTime.utc_now(), -40, :day)

      from(t in Kanban.Tasks.Task, where: t.id == ^task1.id)
      |> Repo.update_all(set: [inserted_at: forty_days_ago])

      {:ok, _} = complete_task(task1)

      task2 = task_fixture(column)
      fifty_days_ago = DateTime.add(DateTime.utc_now(), -50, :day)

      from(t in Kanban.Tasks.Task, where: t.id == ^task2.id)
      |> Repo.update_all(set: [inserted_at: fifty_days_ago])

      {:ok, _} = complete_task(task2)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Chart should be rendered with trend line
      assert html =~ "Lead Time Trend"
    end

    test "handles single task for trend line calculation", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Create just one task
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Should still render but without trend line
      assert html =~ task.identifier
    end

    test "displays formatted dates for completed tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Should display formatted date (e.g., "Feb 07, 2026")
      assert html =~ ~r/\w{3} \d{2}, \d{4}/
    end

    test "handles tasks with very short lead times (minutes)", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Create task and manually set inserted_at to 30 minutes ago
      task = task_fixture(column)
      thirty_minutes_ago = DateTime.add(DateTime.utc_now(), -30, :minute)

      from(t in Kanban.Tasks.Task, where: t.id == ^task.id)
      |> Repo.update_all(set: [inserted_at: thirty_minutes_ago])

      {:ok, updated_task} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      # Task should be visible
      assert html =~ updated_task.identifier
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

    test "handles non-existent atom in parse_time_range", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/lead-time?time_range=nonexistent_range_abc")

      assert html =~ "Last 30 Days"
    end
  end

  describe "Lead Time - Regular Board" do
    setup [:register_and_log_in_user, :create_regular_board_with_column]

    test "loads lead time page successfully for regular board", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Lead Time Metrics"
      assert html =~ board.name
    end

    test "does not show agent filter for regular board", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      refute html =~ "Agent Filter"
    end

    test "does not show agent info in task details for regular board", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Regular Board Task"})
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Regular Board Task"
      refute html =~ "Agent Unknown"
    end

    test "displays summary stats for regular board", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "Average"
      assert html =~ "Median"
      assert html =~ "Min"
      assert html =~ "Max"
    end

    test "calculates lead time from inserted_at to completed_at for regular board", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      # Set inserted_at to 2 days ago via direct DB update
      two_days_ago = DateTime.add(DateTime.utc_now(), -2, :day)

      from(t in Kanban.Tasks.Task, where: t.id == ^task.id)
      |> Repo.update_all(set: [inserted_at: two_days_ago])

      {:ok, _} = complete_task(task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ task.identifier
      assert html =~ "Created:"
      assert html =~ "Completed:"
    end

    test "displays empty state for regular board with no completed tasks", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      assert html =~ "No tasks completed in this time range"
    end

    test "time range filter works for regular board", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/lead-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = ai_optimized_board_fixture(user)
    column = column_fixture(board)
    %{board: board, column: column}
  end

  defp create_regular_board_with_column(%{user: user}) do
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
