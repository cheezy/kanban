defmodule KanbanWeb.MetricsLive.WaitTimeTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Wait Time - Basic Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays wait time page with board name", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Wait Time Metrics"
      assert html =~ board.name
    end

    test "displays back to dashboard link", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Back to Dashboard"
      assert html =~ ~p"/boards/#{board}/metrics"
    end

    test "displays both metric sections", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Review Wait Time"
      assert html =~ "Backlog Wait Time"
    end

    test "redirects non-AI-optimized boards to board page", %{conn: conn, user: user} do
      regular_board = board_fixture(user)

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/boards/#{regular_board}/metrics/wait-time")

      assert to == "/boards/#{regular_board.id}"
      assert flash["error"] == "Metrics are only available for AI-optimized boards."
    end

    test "displays filter controls", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Time Range"
      assert html =~ "Last 7 Days"
      assert html =~ "Last 30 Days"
      assert html =~ "Agent Filter"
      assert html =~ "Exclude Weekends"
    end

    test "displays export PDF button", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Export to PDF"
    end
  end

  describe "Wait Time - Review Wait Data" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays review wait tasks", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_review_wait(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Review Wait Time"
      assert html =~ task.identifier
    end

    test "displays empty state when no review wait tasks", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "No tasks waiting for review in this time range"
    end

    test "shows review wait time in table", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_review_wait(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ task.identifier
      assert html =~ task.title
    end

    test "displays multiple review tasks sorted by reviewed_at", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "First Review"})
      task2 = task_fixture(column, %{title: "Second Review"})
      task3 = task_fixture(column, %{title: "Third Review"})

      {:ok, _} =
        add_review_wait(task1, %{
          completed_at: DateTime.add(DateTime.utc_now(), -5, :day),
          reviewed_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      {:ok, _} =
        add_review_wait(task2, %{
          completed_at: DateTime.add(DateTime.utc_now(), -4, :day),
          reviewed_at: DateTime.add(DateTime.utc_now(), -2, :day)
        })

      {:ok, _} =
        add_review_wait(task3, %{
          completed_at: DateTime.add(DateTime.utc_now(), -3, :day),
          reviewed_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "First Review"
      assert html =~ "Second Review"
      assert html =~ "Third Review"
    end

    test "displays agent name when present in review wait", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = add_review_wait(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "displays N/A when agent name is missing in review wait", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = add_review_wait(task, %{completed_by_agent: nil})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "N/A"
    end
  end

  describe "Wait Time - Backlog Wait Data" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays backlog wait tasks", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Backlog Wait Time"
      assert html =~ task.identifier
    end

    test "displays empty state when no backlog wait tasks", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "No tasks claimed in this time range"
    end

    test "shows backlog wait time in table", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ task.identifier
      assert html =~ task.title
    end

    test "displays multiple backlog tasks sorted by claimed_at", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "First Backlog"})
      task2 = task_fixture(column, %{title: "Second Backlog"})
      task3 = task_fixture(column, %{title: "Third Backlog"})

      {:ok, _} =
        add_backlog_wait(task1, %{claimed_at: DateTime.add(DateTime.utc_now(), -3, :day)})

      {:ok, _} =
        add_backlog_wait(task2, %{claimed_at: DateTime.add(DateTime.utc_now(), -2, :day)})

      {:ok, _} =
        add_backlog_wait(task3, %{claimed_at: DateTime.add(DateTime.utc_now(), -1, :day)})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "First Backlog"
      assert html =~ "Second Backlog"
      assert html =~ "Third Backlog"
    end

    test "displays agent name when present in backlog wait", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "displays N/A when agent name is missing in backlog wait", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task, %{completed_by_agent: nil})

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "N/A"
    end
  end

  describe "Wait Time - Filter Events" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "changes time range filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end

    test "changes agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      view
      |> element("form")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      assert view
             |> element("select[name='agent_name']")
             |> render() =~ "Claude Sonnet 4.5"
    end

    test "toggles weekend exclusion", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"
    end

    test "filters review wait tasks by agent", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "Review by Agent 1"})
      task2 = task_fixture(column, %{title: "Review by Agent 2"})

      {:ok, _} = add_review_wait(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = add_review_wait(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => "Agent 1"})

      assert html =~ "Review by Agent 1"
      refute html =~ "Review by Agent 2"
    end

    test "filters backlog wait tasks by agent", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "Backlog by Agent 1"})
      task2 = task_fixture(column, %{title: "Backlog by Agent 2"})

      {:ok, _} = add_backlog_wait(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = add_backlog_wait(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"agent_name" => "Agent 1"})

      assert html =~ "Backlog by Agent 1"
      refute html =~ "Backlog by Agent 2"
    end

    test "filters review wait tasks outside time range", %{
      conn: conn,
      board: board,
      column: column
    } do
      old_task = task_fixture(column, %{title: "Old Review Task"})
      recent_task = task_fixture(column, %{title: "Recent Review Task"})

      {:ok, _} =
        add_review_wait(old_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -60, :day),
          reviewed_at: DateTime.add(DateTime.utc_now(), -59, :day)
        })

      {:ok, _} = add_review_wait(recent_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Recent Review Task"
      refute html =~ "Old Review Task"
    end

    test "clears agent filter when empty string selected", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _} = add_review_wait(task1, %{completed_by_agent: "Agent 1"})
      {:ok, _} = add_review_wait(task2, %{completed_by_agent: "Agent 2"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

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

  describe "Wait Time - Export PDF" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "export PDF button is clickable", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert view |> element("button", "Export to PDF") |> has_element?()
    end

    test "clicking export PDF triggers event", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert view
             |> element("button", "Export to PDF")
             |> render_click() =~ "Wait Time Metrics"
    end
  end

  describe "Wait Time - Query Parameter Handling" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "applies time_range from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task)

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/wait-time?time_range=last_7_days")

      assert html =~ "Last 7 Days"
    end

    test "applies agent_name from query parameters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/wait-time?agent_name=Claude+Sonnet+4.5")

      assert html =~ "Claude Sonnet 4.5"
    end

    test "applies exclude_weekends from query parameters", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/wait-time?exclude_weekends=true")

      assert html =~ "checked"
    end

    test "applies multiple filters from query parameters", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = add_backlog_wait(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _view, html} =
        live(
          conn,
          ~p"/boards/#{board}/metrics/wait-time?time_range=last_7_days&agent_name=Claude+Sonnet+4.5&exclude_weekends=true"
        )

      assert html =~ "Last 7 Days"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "checked"
    end

    test "handles invalid time_range gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/wait-time?time_range=invalid")

      assert html =~ "Last 30 Days"
    end

    test "handles empty query parameters gracefully", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(
          conn,
          ~p"/boards/#{board}/metrics/wait-time?time_range=&agent_name=&exclude_weekends="
        )

      assert html =~ "Last 30 Days"
      refute html =~ "checked"
    end
  end

  describe "Wait Time - Time Range Options" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "filters with :today time range for review wait", %{
      conn: conn,
      board: board,
      column: column
    } do
      old_task = task_fixture(column, %{title: "Yesterday Review"})
      today_task = task_fixture(column, %{title: "Today Review"})

      {:ok, _} =
        add_review_wait(old_task, %{
          completed_at: DateTime.add(DateTime.utc_now(), -30, :hour),
          reviewed_at: DateTime.add(DateTime.utc_now(), -29, :hour)
        })

      {:ok, _} = add_review_wait(today_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "today"})

      assert html =~ "Today Review"
      refute html =~ "Yesterday Review"
    end

    test "filters with :last_90_days time range", %{conn: conn, board: board, column: column} do
      recent_task = task_fixture(column, %{title: "Recent Backlog"})
      {:ok, _} = add_backlog_wait(recent_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "last_90_days"})

      assert html =~ "Recent Backlog"
      assert html =~ "Last 90 Days"
    end

    test "filters with :all_time time range", %{conn: conn, board: board, column: column} do
      ancient_task = task_fixture(column, %{title: "Ancient Backlog"})

      {:ok, _} =
        add_backlog_wait(ancient_task, %{
          claimed_at: DateTime.add(DateTime.utc_now(), -365, :day)
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      html =
        view
        |> element("form")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "Ancient Backlog"
      assert html =~ "All Time"
    end
  end

  describe "Wait Time - Summary Statistics" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays review wait statistics", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = add_review_wait(task1)
      {:ok, _} = add_review_wait(task2)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Average"
      assert html =~ "Median"
    end

    test "displays backlog wait statistics", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} = add_backlog_wait(task1)
      {:ok, _} = add_backlog_wait(task2)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Average"
      assert html =~ "Median"
    end
  end

  describe "Wait Time - Task Grouping" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "groups review wait tasks by reviewed date", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -1, :day)

      task1 = task_fixture(column, %{title: "Today Review"})
      task2 = task_fixture(column, %{title: "Yesterday Review"})

      {:ok, _} =
        add_review_wait(task1, %{
          completed_at: DateTime.add(today, -12, :hour),
          reviewed_at: today
        })

      {:ok, _} =
        add_review_wait(task2, %{
          completed_at: DateTime.add(yesterday, -12, :hour),
          reviewed_at: yesterday
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Today Review"
      assert html =~ "Yesterday Review"
    end

    test "groups backlog wait tasks by claimed date", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -1, :day)

      task1 = task_fixture(column, %{title: "Today Claimed"})
      task2 = task_fixture(column, %{title: "Yesterday Claimed"})

      {:ok, _} = add_backlog_wait(task1, %{claimed_at: today})
      {:ok, _} = add_backlog_wait(task2, %{claimed_at: yesterday})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Today Claimed"
      assert html =~ "Yesterday Claimed"
    end

    test "sorts review tasks within a date by reviewed time descending", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      task1 = task_fixture(column, %{identifier: "W1"})
      task2 = task_fixture(column, %{identifier: "W2"})
      task3 = task_fixture(column, %{identifier: "W3"})

      {:ok, _} =
        add_review_wait(task1, %{
          completed_at: DateTime.add(today, -24, :hour),
          reviewed_at: today |> DateTime.to_date() |> DateTime.new!(~T[10:00:00])
        })

      {:ok, _} =
        add_review_wait(task2, %{
          completed_at: DateTime.add(today, -24, :hour),
          reviewed_at: today |> DateTime.to_date() |> DateTime.new!(~T[14:00:00])
        })

      {:ok, _} =
        add_review_wait(task3, %{
          completed_at: DateTime.add(today, -24, :hour),
          reviewed_at: today |> DateTime.to_date() |> DateTime.new!(~T[18:00:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      [_before, review_section] = String.split(html, "Review Wait Time", parts: 2)
      [tasks_section, _after] = String.split(review_section, "Backlog Wait Time", parts: 2)

      w3_index = :binary.match(tasks_section, "W3") |> elem(0)
      w2_index = :binary.match(tasks_section, "W2") |> elem(0)
      w1_index = :binary.match(tasks_section, "W1") |> elem(0)

      assert w3_index < w2_index
      assert w2_index < w1_index
    end

    test "sorts backlog tasks within a date by claimed time descending", %{
      conn: conn,
      board: board,
      column: column
    } do
      today = DateTime.utc_now()
      task1 = task_fixture(column, %{identifier: "W1"})
      task2 = task_fixture(column, %{identifier: "W2"})
      task3 = task_fixture(column, %{identifier: "W3"})

      {:ok, _} =
        add_backlog_wait(task1, %{
          claimed_at: today |> DateTime.to_date() |> DateTime.new!(~T[10:00:00])
        })

      {:ok, _} =
        add_backlog_wait(task2, %{
          claimed_at: today |> DateTime.to_date() |> DateTime.new!(~T[14:00:00])
        })

      {:ok, _} =
        add_backlog_wait(task3, %{
          claimed_at: today |> DateTime.to_date() |> DateTime.new!(~T[18:00:00])
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      [_before, backlog_section] = String.split(html, "Backlog Wait Time", parts: 2)

      w3_index = :binary.match(backlog_section, "W3") |> elem(0)
      w2_index = :binary.match(backlog_section, "W2") |> elem(0)
      w1_index = :binary.match(backlog_section, "W1") |> elem(0)

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

      {:ok, _} = add_review_wait(task1, %{reviewed_at: today})
      {:ok, _} = add_review_wait(task2, %{reviewed_at: today})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      refute html =~ "2 tasks"
      refute html =~ "tasks waiting"
    end
  end

  describe "Wait Time - Task Display Format" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays Completed before Reviewed in review wait tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      completed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
      reviewed_at = DateTime.utc_now()

      {:ok, _} =
        add_review_wait(task, %{
          completed_at: completed_at,
          reviewed_at: reviewed_at
        })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      [_before_task, task_section] = String.split(html, task.identifier, parts: 2)

      completed_index = :binary.match(task_section, "Completed:") |> elem(0)
      reviewed_index = :binary.match(task_section, "Reviewed:") |> elem(0)

      assert completed_index < reviewed_index, "Completed should appear before Reviewed"
    end

    test "displays Created before Claimed in backlog wait tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      claimed_at = DateTime.utc_now()

      {:ok, _} = add_backlog_wait(task, %{claimed_at: claimed_at})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      [_before_task, task_section] = String.split(html, task.identifier, parts: 2)

      created_index = :binary.match(task_section, "Created:") |> elem(0)
      claimed_index = :binary.match(task_section, "Claimed:") |> elem(0)

      assert created_index < claimed_index, "Created should appear before Claimed"
    end

    test "displays full datetime for all timestamps", %{
      conn: conn,
      board: board,
      column: column
    } do
      review_task = task_fixture(column, %{title: "Review Task"})
      backlog_task = task_fixture(column, %{title: "Backlog Task"})

      {:ok, _} = add_review_wait(review_task)
      {:ok, _} = add_backlog_wait(backlog_task)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert html =~ "Completed:"
      assert html =~ "Reviewed:"
      assert html =~ "Created:"
      assert html =~ "Claimed:"
      assert html =~ ~r/\d{1,2}:\d{2} (AM|PM)/
    end
  end

  describe "Wait Time - Access Control" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "denies access to non-board-members", %{conn: conn, board: board} do
      other_user = user_fixture()
      conn = log_in_user(conn, other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{board}/metrics/wait-time")
      end
    end

    test "handles non-existent atom in parse_time_range", %{conn: conn, board: board} do
      {:ok, _view, html} =
        live(conn, ~p"/boards/#{board}/metrics/wait-time?time_range=nonexistent_range_abc")

      assert html =~ "Last 30 Days"
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = ai_optimized_board_fixture(user)
    column = column_fixture(board)
    %{board: board, column: column}
  end

  defp add_review_wait(task, attrs \\ %{}) do
    completed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
    reviewed_at = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          completed_at: completed_at,
          reviewed_at: reviewed_at,
          needs_review: true
        },
        attrs
      )

    Tasks.update_task(task, attrs)
  end

  defp add_backlog_wait(task, attrs \\ %{}) do
    claimed_at = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          claimed_at: claimed_at
        },
        attrs
      )

    Tasks.update_task(task, attrs)
  end
end
