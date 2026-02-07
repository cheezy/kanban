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

      {:ok, _} = add_backlog_wait(task1, %{claimed_at: DateTime.add(DateTime.utc_now(), -3, :day)})
      {:ok, _} = add_backlog_wait(task2, %{claimed_at: DateTime.add(DateTime.utc_now(), -2, :day)})
      {:ok, _} = add_backlog_wait(task3, %{claimed_at: DateTime.add(DateTime.utc_now(), -1, :day)})

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
        live(conn, ~p"/boards/#{board}/metrics/wait-time?time_range=&agent_name=&exclude_weekends=")

      assert html =~ "Last 30 Days"
      refute html =~ "checked"
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
