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
        |> element("select[name='time_range']")
        |> render_change(%{"time_range" => "last_7_days"})

      assert html =~ "Last 7 Days"
    end

    test "handle_event changes agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      _html =
        view
        |> element("select[name='agent_name']")
        |> render_change(%{"agent_name" => ""})

      assert view
             |> element("select[name='agent_name']")
             |> render() =~ "All Agents"
    end

    test "handle_event toggles weekend exclusion", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics")

      html =
        view
        |> element("#exclude_weekends")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"
    end

    test "denies access to non-board-members", %{conn: conn, board: board} do
      other_user = user_fixture()
      conn = log_in_user(conn, other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{board}/metrics")
      end
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
      assert html =~ "Review:"
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
      assert html =~ "Backlog:"
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
        |> element("select[name='time_range']")
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
        |> element("select[name='time_range']")
        |> render_change(%{"time_range" => "all_time"})

      assert html =~ "All Time"
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
        |> element("select[name='agent_name']")
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
      |> element("select[name='agent_name']")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      html =
        view
        |> element("select[name='agent_name']")
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
        |> element("#exclude_weekends")
        |> render_change(%{"exclude_weekends" => "true"})

      assert html =~ "checked"

      html =
        view
        |> element("#exclude_weekends")
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
      |> element("#exclude_weekends")
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
      |> element("select[name='time_range']")
      |> render_change(%{"time_range" => "last_7_days"})

      view
      |> element("select[name='agent_name']")
      |> render_change(%{"agent_name" => "Claude Sonnet 4.5"})

      view
      |> element("#exclude_weekends")
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
      |> element("select[name='time_range']")
      |> render_change(%{"time_range" => "last_7_days"})

      view
      |> element("select[name='time_range']")
      |> render_change(%{"time_range" => "last_90_days"})

      html =
        view
        |> element("select[name='time_range']")
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
