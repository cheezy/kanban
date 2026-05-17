defmodule KanbanWeb.MetricsLive.DashboardTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Dashboard - Basic Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays metrics dashboard page with board name", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Metrics Dashboard"
      assert html =~ board.name
    end

    test "displays back to board link", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Back to Board"
      assert html =~ ~p"/boards/#{board}"
    end

    test "displays all four metric cards", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Throughput"
      assert html =~ "Cycle Time"
      assert html =~ "Lead Time"
      assert html =~ "Wait Time"
    end

    test "displays filter controls", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Time Range"
      assert html =~ "Last 7 Days"
      assert html =~ "Last 30 Days"
      assert html =~ "Last 90 Days"
      assert html =~ "All Time"
      assert html =~ "Agent Filter"
      assert html =~ "Exclude Weekends"
    end

    test "displays empty metrics when no completed tasks exist", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "0"
      assert html =~ "tasks completed"
    end

    test "displays throughput count correctly", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1)
      {:ok, _} = complete_task(task2)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "2"
      assert html =~ "tasks completed"
    end

    test "throughput sums tasks across multiple days, not count of days", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)
      task4 = task_fixture(column)
      task5 = task_fixture(column)

      day1 = DateTime.utc_now()
      day2 = DateTime.add(DateTime.utc_now(), -1, :day)

      _task1 =
        force_update_timestamps(task1, %{
          claimed_at: DateTime.add(day1, -1, :hour),
          completed_at: day1
        })

      _task2 =
        force_update_timestamps(task2, %{
          claimed_at: DateTime.add(day1, -1, :hour),
          completed_at: day1
        })

      _task3 =
        force_update_timestamps(task3, %{
          claimed_at: DateTime.add(day1, -1, :hour),
          completed_at: day1
        })

      _task4 =
        force_update_timestamps(task4, %{
          claimed_at: DateTime.add(day2, -1, :hour),
          completed_at: day2
        })

      _task5 =
        force_update_timestamps(task5, %{
          claimed_at: DateTime.add(day2, -1, :hour),
          completed_at: day2
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "5"
      assert html =~ "tasks completed"
      refute html =~ ">2<"
    end

    test "displays cycle time stats", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Cycle Time"
      assert html =~ "1.0d"
    end

    test "mount assigns correct initial data", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      assert view
             |> element("select[name='time_range']")
             |> render() =~ "selected"
    end

    test "handle_event changes time_range filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end

    test "handle_event changes agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      _html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => ""})

      assert view
             |> element("select[name='agent_name']")
             |> render() =~ "All Agents"
    end

    test "handle_event toggles weekend exclusion", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"
    end

    test "denies access to non-board-members", %{conn: conn, board: board} do
      other_user = user_fixture()
      conn = log_in_user(conn, other_user)

      {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => _}}}} =
        live(conn, ~p"/boards/#{board}/metrics")
    end

    test "handles board with no completed tasks gracefully", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "0"
      assert html =~ "0h"
    end
  end

  describe "Dashboard - Lead Time Stats" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays lead time stats with inserted_at to completed_at", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      inserted_at = DateTime.add(DateTime.utc_now(), -48, :hour)
      completed_at = DateTime.utc_now()

      _task =
        force_update_timestamps(task, %{
          inserted_at: inserted_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Lead Time"
      assert html =~ "2.0d"
    end

    test "displays lead time with multiple tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      inserted_at1 = DateTime.add(DateTime.utc_now(), -24, :hour)
      inserted_at2 = DateTime.add(DateTime.utc_now(), -48, :hour)
      completed_at = DateTime.utc_now()

      _task1 =
        force_update_timestamps(task1, %{
          inserted_at: inserted_at1,
          completed_at: completed_at
        })

      _task2 =
        force_update_timestamps(task2, %{
          inserted_at: inserted_at2,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Lead Time"
    end
  end

  describe "Dashboard - Wait Time Stats" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays review wait time when tasks have review_started_at", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      completed_at = DateTime.utc_now()
      review_started_at = DateTime.add(completed_at, -12, :hour)

      {:ok, _} =
        Tasks.update_task(task, %{
          completed_at: completed_at,
          review_started_at: review_started_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Wait Time"
      assert html =~ "Review"
    end

    test "displays backlog wait time when tasks have claimed_at", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      inserted_at = DateTime.add(DateTime.utc_now(), -36, :hour)
      claimed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
      completed_at = DateTime.utc_now()

      _task =
        force_update_timestamps(task, %{
          inserted_at: inserted_at,
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Wait Time"
      assert html =~ "Backlog"
    end
  end

  describe "Dashboard - Time Range Filters" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "filters metrics by last 90 days", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_90_days"})

      assert html =~ "Last 90 Days"
    end

    test "filters metrics by all time", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      completed_at = DateTime.add(DateTime.utc_now(), -365, :day)

      _task =
        force_update_timestamps(task, %{
          inserted_at: DateTime.add(completed_at, -1, :day),
          claimed_at: DateTime.add(completed_at, -1, :hour),
          completed_at: completed_at
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "All Time"
    end

    test "filters metrics by today only", %{conn: conn, board: board, column: column} do
      task_today = task_fixture(column)
      task_yesterday = task_fixture(column)

      completed_today = DateTime.utc_now()
      completed_yesterday = DateTime.add(DateTime.utc_now(), -1, :day)

      _task_today =
        force_update_timestamps(task_today, %{
          inserted_at: DateTime.add(completed_today, -1, :hour),
          claimed_at: DateTime.add(completed_today, -30, :minute),
          completed_at: completed_today
        })

      _task_yesterday =
        force_update_timestamps(task_yesterday, %{
          inserted_at: DateTime.add(completed_yesterday, -1, :hour),
          claimed_at: DateTime.add(completed_yesterday, -30, :minute),
          completed_at: completed_yesterday
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "today"})

      assert html =~ "Today"
      assert html =~ "1"
      assert html =~ "tasks completed"
    end
  end

  describe "Dashboard - Agent Filters" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "filters metrics by specific agent", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Claude Sonnet 4.5"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Claude Opus 3"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      _html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      rendered = render(view)
      assert rendered =~ "Metrics Dashboard"
    end

    test "displays agent filter dropdown with All Agents option", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = complete_task(task1, %{completed_by_agent: "Claude Sonnet 4.5"})
      {:ok, _} = complete_task(task2, %{completed_by_agent: "Claude Opus 3"})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Agent Filter"
      assert html =~ "All Agents"
    end

    test "clears agent filter when selecting all agents", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => ""})

      assert html =~ "All Agents"
    end
  end

  describe "Dashboard - Weekend Exclusion" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "toggles weekend exclusion on and off", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)

      claimed_at = ~U[2026-01-30 18:00:00Z]
      completed_at = ~U[2026-02-02 10:00:00Z]

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"

      html =
        view
        |> element("form")
        |> render_change(%{"exclude_weekends" => "false"})

      refute html =~ "checked"
    end

    test "recalculates metrics when weekend exclusion changes", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = ~U[2026-01-30 18:00:00Z]
      completed_at = ~U[2026-02-02 10:00:00Z]

      _task =
        force_update_timestamps(task, %{
          inserted_at: claimed_at,
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      view
      |> element("form")
      |> render_change(%{"exclude_weekends" => "true"})

      html = render(view)

      assert html =~ "Cycle Time"
    end
  end

  describe "Dashboard - Combined Filters" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "applies time range, agent, and weekend filters together", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      claimed_at = ~U[2026-01-30 18:00:00Z]
      completed_at = ~U[2026-02-02 10:00:00Z]

      {:ok, _} =
        Tasks.update_task(task1, %{
          claimed_at: claimed_at,
          completed_at: completed_at,
          completed_by_agent: "Claude Sonnet 4.5"
        })

      {:ok, _} =
        Tasks.update_task(task2, %{
          claimed_at: claimed_at,
          completed_at: completed_at,
          completed_by_agent: "Claude Opus 3"
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      view
      |> element("form")
      |> render_change(%{"time_range" => "last_7_days"})

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      view
      |> element("form")
      |> render_change(%{"exclude_weekends" => "true"})

      html = render(view)

      assert html =~ "Last 7 Days"
      assert html =~ "checked"
    end

    test "rapid filter changes maintain consistent state", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      view
      |> element("form")
      |> render_change(%{"time_range" => "last_7_days"})

      view
      |> element("form")
      |> render_change(%{"time_range" => "last_90_days"})

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "All Time"
    end
  end

  describe "Dashboard - Format Hours Helper" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "formats minutes correctly when less than 1 hour", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -30, :minute)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "m"
    end

    test "formats hours correctly when 1-23 hours", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -12, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "12.0h"
    end

    test "formats days correctly when 24+ hours", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -48, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "2.0d"
    end

    test "formats fractional hours correctly", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -90, :minute)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "1.5h"
    end

    test "formats zero hours as 0h", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "0h"
    end
  end

  describe "Dashboard - Query Parameter Handling" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "applies time_range from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?time_range=last_7_days")

      assert html =~ "Last 7 Days"
    end

    test "applies agent_name from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?agent_name=Claude+Sonnet+4.5")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "applies exclude_weekends from query parameters", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?exclude_weekends=true")

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
          ~p"/boards/#{board}/metrics?time_range=last_7_days&agent_name=Claude+Sonnet+4.5&exclude_weekends=true"
        )

      assert html =~ "Last 7 Days"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "checked"
    end

    test "handles invalid time_range gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?time_range=invalid")

      assert html =~ "Last 30 Days"
    end

    test "handles empty query parameters gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?time_range=&agent_name=&exclude_weekends=")

      assert html =~ "Last 30 Days"
      refute html =~ "checked"
    end
  end

  describe "Dashboard - Additional Coverage" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "handles exclude_weekends with false value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?exclude_weekends=false")

      refute html =~ "checked"
    end

    test "handles exclude_weekends with unexpected value", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?exclude_weekends=maybe")

      refute html =~ "checked"
    end

    test "handles non-existent atom in parse_time_range", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?time_range=nonexistent_range_xyz")

      assert html =~ "Last 30 Days"
    end
  end

  describe "Dashboard - Throughput Helper" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "total_throughput sums up counts from multiple days", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)
      task4 = task_fixture(column)
      task5 = task_fixture(column)
      task6 = task_fixture(column)
      task7 = task_fixture(column)
      task8 = task_fixture(column)

      day1 = DateTime.utc_now()
      day2 = DateTime.add(DateTime.utc_now(), -1, :day)
      day3 = DateTime.add(DateTime.utc_now(), -2, :day)

      _task1 =
        force_update_timestamps(task1, %{
          claimed_at: DateTime.add(day1, -1, :hour),
          completed_at: day1
        })

      _task2 =
        force_update_timestamps(task2, %{
          claimed_at: DateTime.add(day1, -1, :hour),
          completed_at: day1
        })

      _task3 =
        force_update_timestamps(task3, %{
          claimed_at: DateTime.add(day1, -1, :hour),
          completed_at: day1
        })

      _task4 =
        force_update_timestamps(task4, %{
          claimed_at: DateTime.add(day2, -1, :hour),
          completed_at: day2
        })

      _task5 =
        force_update_timestamps(task5, %{
          claimed_at: DateTime.add(day2, -1, :hour),
          completed_at: day2
        })

      _task6 =
        force_update_timestamps(task6, %{
          claimed_at: DateTime.add(day3, -1, :hour),
          completed_at: day3
        })

      _task7 =
        force_update_timestamps(task7, %{
          claimed_at: DateTime.add(day3, -1, :hour),
          completed_at: day3
        })

      _task8 =
        force_update_timestamps(task8, %{
          claimed_at: DateTime.add(day3, -1, :hour),
          completed_at: day3
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      # Extract the throughput number from inside the W589-restyled
      # throughput KPI card (now identified by data-metrics-board-kpi-card="throughput").
      throughput_match =
        Regex.run(
          ~r/data-metrics-board-kpi-card="throughput"[\s\S]*?font-size: 24px[^>]*>\s*(\d+)\s*</,
          html
        )

      throughput_value = if throughput_match, do: Enum.at(throughput_match, 1), else: nil

      assert throughput_value == "8",
             "Expected throughput to be 8 (total tasks), but got #{inspect(throughput_value)}"

      assert html =~ "tasks completed"
    end
  end

  describe "Dashboard - Edge Cases" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "handles tasks with only claimed_at gracefully", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -24, :hour)

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Metrics Dashboard"
    end

    test "handles tasks with only inserted_at gracefully", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      inserted_at = DateTime.add(DateTime.utc_now(), -48, :hour)

      _task =
        force_update_timestamps(task, %{
          inserted_at: inserted_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Metrics Dashboard"
    end

    test "handles board with mixed completed and incomplete tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)

      {:ok, _} = complete_task(task1)
      {:ok, _} = complete_task(task2)

      {:ok, _} =
        Tasks.update_task(task3, %{
          claimed_at: DateTime.utc_now()
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "2"
      assert html =~ "tasks completed"
    end

    test "handles very small time values correctly", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -5, :minute)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "m"
    end

    test "handles very large time values correctly", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -720, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "30.0d"
    end
  end

  describe "Dashboard - Regular Board" do
    setup [:register_and_log_in_user, :create_regular_board_with_column]

    test "loads dashboard for regular board without redirect", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Metrics Dashboard"
      assert html =~ board.name
    end

    test "does not show agent filter for regular board", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      refute html =~ "Agent Filter"
    end

    test "shows all four metric cards for regular board", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Throughput"
      assert html =~ "Cycle Time"
      assert html =~ "Lead Time"
      assert html =~ "Wait Time"
    end

    test "shows Queue label instead of Backlog for wait time", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Queue"
      refute html =~ "Backlog"
    end

    test "does not show Review wait time for regular board", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      # The Review wait-time row uses a specific text-sm font-medium label.
      # Match that exact wrapping (not the "Review queue" sidebar nav item)
      # so we can prove the wait-time row is suppressed for non-AI boards.
      refute html =~ ~r/text-sm font-medium[^"]*">\s*Review\s*</
    end

    test "displays throughput for regular board with completed tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)

      force_update_timestamps(task, %{
        completed_at: DateTime.utc_now()
      })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "1"
      assert html =~ "tasks completed"
    end

    test "displays time range filter for regular board", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Time Range"
      assert html =~ "Last 30 Days"
    end

    test "displays exclude weekends filter for regular board", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Exclude Weekends"
    end

    test "handles filter changes for regular board", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end
  end

  describe "mount/3 — unauthorized board" do
    setup [:register_and_log_in_user]

    test "non-existent board id redirects to /boards with a flash",
         %{conn: conn} do
      assert {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
               live(conn, ~p"/boards/99999999/metrics")

      assert redirect_to == "/boards"
      assert flash["error"] =~ "Board not found" or flash["error"] != nil
    end

    test "another user's board is treated as not-found and redirects to /boards",
         %{conn: conn} do
      other = user_fixture()
      foreign_board = board_fixture(other)

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               live(conn, ~p"/boards/#{foreign_board}/metrics")

      assert redirect_to == "/boards"
    end
  end

  describe "unauthenticated access" do
    test "anonymous user is redirected to log-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} =
               live(conn, ~p"/boards/1/metrics")

      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "Dashboard - filter event coverage" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "filter_change exclude_weekends=true re-derives the page without crashing",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        render_change(view, "filter_change", %{
          "time_range" => "last_30_days",
          "agent_name" => "",
          "exclude_weekends" => "true"
        })

      # The page re-renders without crashing; the value here is the
      # no-crash guarantee on the toggle-to-true branch.
      assert html =~ "Metrics Dashboard"
    end

    test "filter_change with an unknown agent_name leaves the dashboard rendering",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        render_change(view, "filter_change", %{
          "time_range" => "last_30_days",
          "agent_name" => "nonexistent-agent-9999",
          "exclude_weekends" => "false"
        })

      assert html =~ "Metrics Dashboard"
    end
  end

  describe "Dashboard - regular (non-AI) board conditional rendering" do
    setup [:register_and_log_in_user, :create_regular_board_with_column]

    test "Compliance card is HIDDEN on regular boards",
         %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      # The Compliance card is wrapped in :if={@board.ai_optimized_board}
      # on AI-optimized boards. On a regular board its label should not
      # surface in the dashboard chrome.
      refute html =~ "Compliance"
    end
  end

  describe "Dashboard - AI board KPI card rendering (Compliance + Review)" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "Compliance KPI card is SHOWN on AI-optimized boards", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Compliance"

      assert html =~
               ~s(data-metrics-board-kpi-card="compliance")

      # The Compliance card links to the per-board compliance route.
      assert html =~ ~p"/boards/#{board}/metrics/compliance"
    end

    test "Compliance KPI card describes workflow step dispatch rates", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      assert html =~ "Workflow step dispatch rates and agent compliance"
    end

    test "Wait Time card renders Review row on AI-optimized boards", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      # On AI boards, the Wait Time card renders BOTH a Review row
      # (:if={@board.ai_optimized_board}) and a Backlog row. This is
      # the positive case the regular-board describe asserts the absence
      # of via `refute html =~ ~r/text-sm font-medium[^"]*">\s*Review\s*</`.
      assert html =~ "Wait Time"
      assert html =~ "Review"
      assert html =~ "Backlog"
    end
  end

  describe "Dashboard - KPI card links carry current filter state" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "Throughput KPI link includes current filter query params", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} =
        live(
          conn,
          ~p"/boards/#{board}/metrics?time_range=last_7_days&exclude_weekends=true"
        )

      # The throughput card links to its detail page with the current
      # filter state encoded in the URL so a click does not reset the
      # user's filters when drilling in.
      assert html =~ ~p"/boards/#{board}/metrics/throughput"
      assert html =~ "time_range=last_7_days"
      assert html =~ "exclude_weekends=true"
    end

    test "Cycle Time KPI link includes current filter query params", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(
          conn,
          ~p"/boards/#{board}/metrics?agent_name=Claude+Sonnet+4.5"
        )

      assert html =~ ~p"/boards/#{board}/metrics/cycle-time"
      assert html =~ "agent_name=Claude+Sonnet+4.5"
    end

    test "Lead Time KPI link includes current filter query params", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?time_range=all_time")

      assert html =~ ~p"/boards/#{board}/metrics/lead-time"
      assert html =~ "time_range=all_time"
    end

    test "Wait Time KPI link includes current filter query params", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics?time_range=today")

      assert html =~ ~p"/boards/#{board}/metrics/wait-time"
      assert html =~ "time_range=today"
    end

    test "Default-filter mount leaves agent_name empty in KPI card links", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      # No agent filter set → the card href encodes agent_name= (empty)
      # so the detail page reads "all agents". The point of this test is
      # to guarantee we do not accidentally URL-encode `nil` into
      # "agent_name=null" or omit the param entirely.
      assert html =~ "agent_name=&"
    end
  end

  describe "Dashboard - format_hours/1 helper (direct unit tests)" do
    alias KanbanWeb.MetricsLive.Dashboard

    test "returns 0h for exactly 0" do
      assert Dashboard.format_hours(0) == "0h"
      assert Dashboard.format_hours(0.0) == "0h"
    end

    test "returns minutes for sub-hour values" do
      assert Dashboard.format_hours(0.5) == "30.0m"
      assert Dashboard.format_hours(0.25) == "15.0m"
      assert Dashboard.format_hours(0.01) == "0.6m"
    end

    test "returns hours for 1..23 values" do
      assert Dashboard.format_hours(1) == "1.0h"
      assert Dashboard.format_hours(12.5) == "12.5h"
      assert Dashboard.format_hours(23.99) == "24.0h"
    end

    test "returns days for >=24 values" do
      assert Dashboard.format_hours(24) == "1.0d"
      assert Dashboard.format_hours(48) == "2.0d"
      assert Dashboard.format_hours(720) == "30.0d"
    end

    test "returns N/A for nil" do
      assert Dashboard.format_hours(nil) == "N/A"
    end

    test "returns N/A for atom inputs" do
      assert Dashboard.format_hours(:not_available) == "N/A"
    end

    test "returns N/A for string inputs" do
      assert Dashboard.format_hours("12.5") == "N/A"
    end

    test "returns N/A for binary inputs" do
      assert :erlang.term_to_binary(0) |> Dashboard.format_hours() == "N/A"
    end
  end

  describe "Dashboard - error path from Kanban.Metrics" do
    setup [:register_and_log_in_user, :create_board_with_column]

    # The dashboard's load_data/1 calls `Metrics.get_dashboard_summary/2`
    # and falls back to an empty-zeros dashboard when it returns
    # `{:error, _}`. In production `Kanban.Metrics` does not currently
    # return an error tuple, but the fallback is defensive code for
    # future failure modes (DB unavailable, calculation crash, etc.).
    # We use the `:kanban / :metrics_module` Application env seam to
    # inject a stub that returns `{:error, _}` and assert the fallback
    # renders the empty-zeros chrome without crashing the LiveView.
    defmodule MetricsErrorStub do
      def get_dashboard_summary(_board_id, _opts), do: {:error, :network_unavailable}
    end

    setup do
      original = Application.get_env(:kanban, :metrics_module)
      Application.put_env(:kanban, :metrics_module, MetricsErrorStub)

      on_exit(fn ->
        if original do
          Application.put_env(:kanban, :metrics_module, original)
        else
          Application.delete_env(:kanban, :metrics_module)
        end
      end)

      :ok
    end

    test "renders the empty-dashboard chrome when Metrics returns an error",
         %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics")

      # The page should render — not 500. All four KPI cards present.
      assert html =~ "Metrics Dashboard"
      assert html =~ "Throughput"
      assert html =~ "Cycle Time"
      assert html =~ "Lead Time"
      assert html =~ "Wait Time"

      # Throughput count is the empty-state zero.
      assert html =~ ~s(data-metrics-board-kpi-card="throughput")
      assert html =~ "tasks completed"

      # Cycle/Lead time render as 0h (the empty stats are {average_hours: 0, ...}).
      assert html =~ "0h"
    end

    test "filter changes after a Metrics error keep rendering empty zeros",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      # The LiveView keeps polling Metrics on each filter change; the
      # stub continues to return {:error, _}, and the empty-state chrome
      # continues to render. The point of this test is the no-crash
      # round-trip on the error branch under filter churn.
      assert html =~ "Metrics Dashboard"
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

  defp force_update_timestamps(task, attrs) do
    set_clause =
      Enum.map_join(attrs, ", ", fn {key, _value} -> "#{key} = $#{map_index(attrs, key) + 1}" end)

    values = Map.values(attrs)

    query = "UPDATE tasks SET #{set_clause} WHERE id = $#{map_size(attrs) + 1}"

    Ecto.Adapters.SQL.query!(
      Kanban.Repo,
      query,
      values ++ [task.id]
    )

    Kanban.Repo.get!(Kanban.Tasks.Task, task.id)
  end

  defp map_index(map, key) do
    map
    |> Map.keys()
    |> Enum.find_index(&(&1 == key))
  end
end
