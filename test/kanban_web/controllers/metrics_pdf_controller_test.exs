defmodule KanbanWeb.MetricsPdfControllerTest do
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  setup do
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user}
  end

  describe "export/2 - access control" do
    test "redirects when board is not AI-optimized", %{conn: conn, user: user} do
      board = board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert redirected_to(conn) == ~p"/boards/#{board}"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Metrics are only available for AI-optimized boards"
    end

    test "redirects when user does not have access to board", %{conn: conn} do
      other_user = user_fixture()
      board = ai_optimized_board_fixture(other_user)

      assert_error_sent 404, fn ->
        get(conn, ~p"/boards/#{board}/metrics/throughput/export")
      end
    end
  end

  describe "export/2 - throughput metric" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "exports throughput PDF with default parameters", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".pdf"
      assert disposition =~ "throughput"
      assert byte_size(conn.resp_body) > 0
    end

    test "exports throughput PDF with time range filter", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?time_range=last_7_days")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "last_7_days"
    end

    test "exports throughput PDF with agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      conn =
        get(conn, ~p"/boards/#{board}/metrics/throughput/export?agent_name=Claude+Sonnet+4.5")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports throughput PDF with exclude weekends", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?exclude_weekends=true")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports throughput PDF with all filters combined", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      complete_task(task, %{completed_by_agent: "Claude Sonnet 4.5"})

      conn =
        get(
          conn,
          ~p"/boards/#{board}/metrics/throughput/export?time_range=last_7_days&agent_name=Claude+Sonnet+4.5&exclude_weekends=true"
        )

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports throughput PDF with empty data", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end
  end

  describe "export/2 - cycle-time metric" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "exports cycle-time PDF with default parameters", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "cycle_time"
    end

    test "exports cycle-time PDF with time range filter", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export?time_range=last_90_days")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "last_90_days"
    end

    test "exports cycle-time PDF with agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      complete_task(task, %{completed_by_agent: "GPT-4"})

      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export?agent_name=GPT-4")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports cycle-time PDF with empty data", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end
  end

  describe "export/2 - lead-time metric" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "exports lead-time PDF with default parameters", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/lead-time/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "lead_time"
    end

    test "exports lead-time PDF with filters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      complete_task(task)

      conn =
        get(
          conn,
          ~p"/boards/#{board}/metrics/lead-time/export?time_range=all_time&exclude_weekends=false"
        )

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "all_time"
    end
  end

  describe "export/2 - wait-time metric" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "exports wait-time PDF with default parameters", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      add_review_wait(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/wait-time/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "wait_time"
    end

    test "exports wait-time PDF with filters", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      add_review_wait(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/wait-time/export?time_range=today")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "today"
    end
  end

  describe "export/2 - unknown metric" do
    test "handles unknown metric gracefully", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/metrics/unknown-metric/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end
  end

  describe "export/2 - filename generation" do
    test "generates filename with board name, metric, time range, and date", %{
      conn: conn,
      user: user
    } do
      board = ai_optimized_board_fixture(user, %{name: "Test Board 123"})
      column = column_fixture(board)
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?time_range=last_7_days")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "Test_Board_123"
      assert disposition =~ "throughput"
      assert disposition =~ "last_7_days"
      assert disposition =~ Date.to_string(Date.utc_today())
    end

    test "sanitizes special characters in board name", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user, %{name: "My@Board#With$Special%Chars"})
      column = column_fixture(board)
      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "My_Board_With_Special_Chars"
      refute disposition =~ "@"
      refute disposition =~ "#"
      refute disposition =~ "$"
    end
  end

  describe "export/2 - parameter parsing" do
    test "handles invalid time range", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?time_range=invalid_range")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "handles empty agent name", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?agent_name=")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "handles invalid exclude weekends value", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?exclude_weekends=maybe")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end
  end

  describe "export/2 - data aggregation" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "includes summary statistics in throughput export", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)

      complete_task(task1, %{completed_at: DateTime.add(DateTime.utc_now(), -2, :day)})
      complete_task(task2, %{completed_at: DateTime.add(DateTime.utc_now(), -1, :day)})
      complete_task(task3, %{completed_at: DateTime.utc_now()})

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
    end

    test "filters by agent in throughput export", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      complete_task(task1, %{completed_by_agent: "Agent 1"})
      complete_task(task2, %{completed_by_agent: "Agent 2"})

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?agent_name=Agent+1")

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
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

  describe "export/2 - throughput with goals" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "includes completed goals in throughput export", %{
      conn: conn,
      board: board,
      column: column
    } do
      goal = task_fixture(column, %{type: :goal, title: "Big Feature Goal"})
      complete_task(goal, %{completed_by_agent: "Claude Sonnet 4.5"})

      task = task_fixture(column)
      complete_task(task)

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end
  end

  describe "export/2 - throughput with grouped tasks" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "groups multiple tasks completed on the same day", %{
      conn: conn,
      board: board,
      column: column
    } do
      now = DateTime.utc_now()

      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)

      complete_task(task1, %{completed_at: now, completed_by_agent: "Agent A"})

      complete_task(task2, %{
        completed_at: DateTime.add(now, -1, :hour),
        completed_by_agent: "Agent B"
      })

      complete_task(task3, %{completed_at: DateTime.add(now, -25, :hour)})

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
    end

    test "includes tasks without claimed_at in export", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column)
      # Complete without claimed_at
      Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end
  end

  describe "export/2 - additional time ranges" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)
      complete_task(task)
      %{board: board, column: column}
    end

    test "exports cycle-time PDF with today time range", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export?time_range=today")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "today"
    end

    test "exports cycle-time PDF with exclude_weekends", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export?exclude_weekends=true")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports lead-time PDF with agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      complete_task(task, %{completed_by_agent: "Claude Opus 4.6"})

      conn = get(conn, ~p"/boards/#{board}/metrics/lead-time/export?agent_name=Claude+Opus+4.6")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports lead-time PDF with today time range", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/lead-time/export?time_range=today")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "today"
    end

    test "exports wait-time PDF with agent filter", %{conn: conn, board: board, column: column} do
      task = task_fixture(column)
      add_review_wait(task, %{completed_by_agent: "Agent X"})

      conn = get(conn, ~p"/boards/#{board}/metrics/wait-time/export?agent_name=Agent+X")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports wait-time PDF with empty data", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/wait-time/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "exports throughput PDF with today time range", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?time_range=today")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "today"
    end

    test "exports throughput PDF with all_time time range", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/throughput/export?time_range=all_time")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "all_time"
    end

    test "exports cycle-time PDF with all_time time range", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export?time_range=all_time")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "all_time"
    end
  end

  describe "export/2 - filename generation for all metrics" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user, %{name: "My Project"})
      column = column_fixture(board)
      task = task_fixture(column)
      complete_task(task)
      add_review_wait(task)
      %{board: board}
    end

    test "generates correct filename for cycle-time", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/cycle-time/export?time_range=last_7_days")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "My_Project"
      assert disposition =~ "cycle_time"
      assert disposition =~ "last_7_days"
      assert disposition =~ Date.to_string(Date.utc_today())
    end

    test "generates correct filename for lead-time", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/lead-time/export?time_range=last_90_days")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "My_Project"
      assert disposition =~ "lead_time"
      assert disposition =~ "last_90_days"
    end

    test "generates correct filename for wait-time", %{conn: conn, board: board} do
      conn = get(conn, ~p"/boards/#{board}/metrics/wait-time/export?time_range=today")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "My_Project"
      assert disposition =~ "wait_time"
      assert disposition =~ "today"
    end
  end

  describe "export/2 - unknown metric handling" do
    test "generates PDF for unknown metric with fallback template", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/metrics/unknown-metric-type/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
      assert conn.resp_body != ""
    end

    test "generates filename correctly for unknown metric", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/metrics/custom-metric/export")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "custom_metric"
    end
  end
end
