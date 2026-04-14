defmodule KanbanWeb.MetricsLive.ComplianceTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Compliance - Basic Display" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays compliance metrics page with board name", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "Compliance Metrics"
      assert html =~ board.name
    end

    test "displays back to dashboard link", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "Back to Dashboard"
      assert html =~ ~p"/boards/#{board}/metrics"
    end

    test "displays all three section headings", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "Step Dispatch Rates"
      assert html =~ "Skip Reasons"
      assert html =~ "Compliance by Agent"
    end

    test "displays empty state for all sections when board has no tasks", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "No workflow step data yet"
      assert html =~ "No skipped steps recorded"
      assert html =~ "No agent activity recorded"
    end

    test "does not render filter UI (context does not support filters)", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      refute html =~ "Time Range"
      refute html =~ "Agent Filter"
    end
  end

  describe "Compliance - Populated Board" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "renders dispatch rates from context", %{conn: conn, board: board, column: column} do
      task_fixture(column, %{workflow_steps: [%{"name" => "build", "dispatched" => true}]})
      task_fixture(column, %{workflow_steps: [%{"name" => "build", "dispatched" => false}]})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "build"
      assert html =~ "50.0%"
      refute html =~ "No workflow step data yet"
    end

    test "renders skip reasons from context", %{conn: conn, board: board, column: column} do
      task_fixture(column, %{
        workflow_steps: [
          %{"name" => "deploy", "skipped" => true, "reason" => "manual override"}
        ]
      })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "manual override"
      refute html =~ "No skipped steps recorded"
    end

    test "labels empty-string reason as '(no reason given)'", %{
      conn: conn,
      board: board,
      column: column
    } do
      task_fixture(column, %{
        workflow_steps: [%{"name" => "deploy", "skipped" => true}]
      })

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "(no reason given)"
    end

    test "renders per-agent compliance from context", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{workflow_steps: [%{"name" => "build"}]})
      {:ok, _} = Tasks.update_task(task, %{completed_by_agent: "Claude Opus 4.6"})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/metrics/compliance")

      assert html =~ "Claude Opus 4.6"
      refute html =~ "No agent activity recorded"
    end
  end

  describe "Compliance - Access Control" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "denies access to non-board-members", %{conn: conn, board: board} do
      other_user = user_fixture()
      conn = log_in_user(conn, other_user)

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => _}}}} =
               live(conn, ~p"/boards/#{board}/metrics/compliance")
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = ai_optimized_board_fixture(user)
    column = column_fixture(board)
    %{board: board, column: column}
  end
end
