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
  end

  describe "Wait Time - Export PDF" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "export PDF button is clickable", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/metrics/wait-time")

      assert view |> element("button", "Export to PDF") |> has_element?()
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
    board = board_fixture(user)
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
