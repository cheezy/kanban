defmodule KanbanWeb.WorkspaceMetricsExportControllerTest do
  # async: false — the PDF path drives ChromicPDF, a shared resource, matching
  # the board export controller test.
  use KanbanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Tasks
  alias KanbanWeb.WorkspaceMetricsExportController

  @excel_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  setup do
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, scope: Scope.for_user(user)}
  end

  defp complete_task!(column) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    task = task_fixture(column)

    {:ok, task} =
      Tasks.update_task(task, %{
        claimed_at: DateTime.add(now, -3600, :second),
        completed_at: now
      })

    task
  end

  defp board_with_completed_task!(user) do
    board = board_fixture(user)
    board |> column_fixture() |> complete_task!()
    board
  end

  describe "authentication" do
    test "an unauthenticated request is redirected by the plug and never reaches the controller" do
      conn = get(build_conn(), ~p"/metrics/export")

      assert redirected_to(conn) =~ "/users/log-in"
    end

    test "an authenticated request returns a PDF download response", %{conn: conn, user: user} do
      board_with_completed_task!(user)

      conn = get(conn, ~p"/metrics/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".pdf"
      assert byte_size(conn.resp_body) > 0
    end
  end

  describe "format dispatch" do
    test "the default format is PDF", %{conn: conn, user: user} do
      board_with_completed_task!(user)

      conn = get(conn, ~p"/metrics/export")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "format=excel returns the spreadsheet content type", %{conn: conn, user: user} do
      board_with_completed_task!(user)

      conn = get(conn, ~p"/metrics/export?format=excel")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ @excel_content_type
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ".xlsx"
      assert byte_size(conn.resp_body) > 0
    end

    test "an unknown format falls back to PDF", %{conn: conn, user: user} do
      board_with_completed_task!(user)

      conn = get(conn, ~p"/metrics/export?format=csv")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end
  end

  describe "build_export_opts/2 - scope and board subset" do
    test "passes the scope through rather than resolving board identifiers", %{user: user} do
      scope = Scope.for_user(user)

      opts = WorkspaceMetricsExportController.build_export_opts(scope, %{})

      assert opts[:scope] == scope
    end

    test "the controller module never references Kanban.Boards" do
      # The enforceable form of the pitfall: resolving board ids here would
      # duplicate the intersection the context performs, and a divergence
      # between the two copies is how an authorization bypass gets introduced.
      source = File.read!("lib/kanban_web/controllers/workspace_metrics_export_controller.ex")
      [_moduledoc, code] = String.split(source, ~s(  use KanbanWeb, :controller), parts: 2)

      refute code =~ "Boards"
    end

    test "omitting board_ids passes nil so every visible board is included", %{scope: scope} do
      opts = WorkspaceMetricsExportController.build_export_opts(scope, %{})

      assert opts[:board_ids] == nil
    end

    test "a requested subset of visible boards is passed through as a list", %{
      user: user,
      scope: scope
    } do
      board_a = board_fixture(user)
      board_b = board_fixture(user)

      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"board_ids" => [to_string(board_a.id), to_string(board_b.id)]}
        )

      assert Enum.sort(opts[:board_ids]) == Enum.sort([board_a.id, board_b.id])
    end

    test "a scalar board_ids param parses to a single-element list", %{user: user, scope: scope} do
      board = board_fixture(user)

      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"board_ids" => to_string(board.id)}
        )

      assert opts[:board_ids] == [board.id]
    end

    test "a non-numeric board id is dropped rather than raising", %{user: user, scope: scope} do
      board = board_fixture(user)

      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"board_ids" => ["not-a-number", to_string(board.id), "12x"]}
        )

      assert opts[:board_ids] == [board.id]
    end

    test "a subset of only forged ids stays empty and does not fall back to all boards",
         %{user: user, scope: scope} do
      # Anti-regression for the LiveView's "none selected -> nil -> all boards"
      # affordance: applied here it would silently widen a forged request to
      # every visible board.
      board_fixture(user)

      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"board_ids" => ["nope", "999999999"]}
        )

      assert opts[:board_ids] == [999_999_999]
      refute opts[:board_ids] == nil
    end

    test "an unrecognized board_ids shape yields an empty selection, not every board",
         %{user: user, scope: scope} do
      # `?board_ids[a]=1` arrives as a map. Failing to understand a subset
      # request must not widen the export to all visible boards.
      board_fixture(user)

      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"board_ids" => %{"a" => "1"}}
        )

      assert opts[:board_ids] == []
      refute opts[:board_ids] == nil
    end
  end

  describe "multi-board scope" do
    test "a user who can see two boards exports data covering both",
         %{conn: conn, user: user} do
      board_a = board_with_completed_task!(user)
      board_with_completed_task!(user)

      both = get(conn, ~p"/metrics/export?format=excel")

      second_conn = log_in_user(build_conn(), user)

      only_a = get(second_conn, ~p"/metrics/export?format=excel&board_ids[]=#{board_a.id}")

      assert both.status == 200
      assert only_a.status == 200
      # The unfiltered export aggregates both boards' completed work, so it
      # cannot be byte-identical to the single-board export.
      refute both.resp_body == only_a.resp_body
    end
  end

  describe "authorization - forged board identifiers" do
    test "a forged board id yields the same empty report as a nonexistent one, with a 200",
         %{conn: conn, user: user} do
      # A board belonging to someone else, carrying completed work.
      other_board = board_with_completed_task!(user_fixture())

      forged = get(conn, ~p"/metrics/export?format=excel&board_ids[]=#{other_board.id}")

      second_conn = log_in_user(build_conn(), user)

      nonexistent =
        get(second_conn, ~p"/metrics/export?format=excel&board_ids[]=999999999")

      assert forged.status == 200
      assert nonexistent.status == 200
      # Byte-identical: the response reveals nothing about whether the board exists.
      assert forged.resp_body == nonexistent.resp_body
    end

    test "a forged id alongside a visible one drops only the forged board",
         %{conn: conn, user: user} do
      visible = board_with_completed_task!(user)
      other = board_with_completed_task!(user_fixture())

      both =
        get(
          conn,
          ~p"/metrics/export?format=excel&board_ids[]=#{visible.id}&board_ids[]=#{other.id}"
        )

      second_conn = log_in_user(build_conn(), user)

      visible_only =
        get(second_conn, ~p"/metrics/export?format=excel&board_ids[]=#{visible.id}")

      assert both.status == 200
      assert both.resp_body == visible_only.resp_body
    end
  end

  describe "window_days parsing" do
    test "an out-of-range window_days falls back to the default", %{scope: scope} do
      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"window_days" => "99999"}
        )

      assert opts[:window_days] == 14
    end

    test "a non-numeric window_days falls back to the default", %{scope: scope} do
      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"window_days" => "abc"}
        )

      assert opts[:window_days] == 14
    end

    test "an allow-listed window_days is honored", %{scope: scope} do
      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"window_days" => "30"}
        )

      assert opts[:window_days] == 30
    end
  end

  describe "timezone parsing" do
    test "a valid timezone param reaches the context options", %{scope: scope} do
      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"timezone" => "America/Toronto"}
        )

      assert opts[:timezone] == "America/Toronto"
    end

    test "a missing timezone param resolves to Etc/UTC", %{scope: scope} do
      opts = WorkspaceMetricsExportController.build_export_opts(scope, %{})

      assert opts[:timezone] == "Etc/UTC"
    end

    test "an unknown timezone param falls back to Etc/UTC", %{scope: scope} do
      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"timezone" => "Not/AZone"}
        )

      assert opts[:timezone] == "Etc/UTC"
    end

    test "the timezone parameter shifts the day the export anchors to",
         %{conn: conn, user: user} do
      # Pacific/Kiritimati (UTC+14) and Pacific/Midway (UTC-11) are 25 hours
      # apart, so their local calendar dates ALWAYS differ regardless of when
      # this test runs — no wall-clock flake. If the timezone were ignored (or
      # silently defaulted to UTC) both exports would anchor to the same day.
      board_with_completed_task!(user)

      ahead = get(conn, ~p"/metrics/export?format=excel&timezone=Pacific/Kiritimati")

      second_conn = log_in_user(build_conn(), user)

      behind = get(second_conn, ~p"/metrics/export?format=excel&timezone=Pacific/Midway")

      assert [ahead_disposition] = get_resp_header(ahead, "content-disposition")
      assert [behind_disposition] = get_resp_header(behind, "content-disposition")

      refute ahead_disposition == behind_disposition
    end
  end

  describe "empty workspace" do
    test "a user with no visible boards receives a 200 empty report, not a 404",
         %{conn: conn} do
      conn = get(conn, ~p"/metrics/export?format=excel")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ @excel_content_type
      assert byte_size(conn.resp_body) > 0
    end
  end

  describe "download filename" do
    test "contains no user-controlled input", %{conn: conn, user: user} do
      board_with_completed_task!(user)

      conn = get(conn, ~p"/metrics/export?format=excel")

      assert [disposition] = get_resp_header(conn, "content-disposition")

      assert disposition =~
               ~r/^attachment; filename="stride_workspace_metrics_\d+d_\d{4}-\d{2}-\d{2}\.xlsx"$/
    end

    test "carries the resolved window, not the raw param", %{conn: conn, user: user} do
      board_with_completed_task!(user)

      conn = get(conn, ~p"/metrics/export?format=excel&window_days=99999")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "_14d_"
      refute disposition =~ "99999"
    end

    test "a board name with header-hostile characters never reaches the filename",
         %{conn: conn, user: user} do
      board_fixture(user, %{name: ~s(Ev"il; filename="pwned.xlsx)})

      conn = get(conn, ~p"/metrics/export?format=excel")

      assert [disposition] = get_resp_header(conn, "content-disposition")

      assert disposition =~
               ~r/^attachment; filename="stride_workspace_metrics_\d+d_\d{4}-\d{2}-\d{2}\.xlsx"$/

      refute disposition =~ "pwned"
    end
  end

  describe "generation failure" do
    test "handle_export_error/2 logs the raw reason but flashes only a generic message",
         %{conn: conn} do
      reason = {:chromic_pdf_crashed, %{port: 4001, path: "/tmp/secret-internal-path"}}

      {result, log} =
        with_log(fn ->
          conn
          |> Phoenix.ConnTest.fetch_flash()
          |> WorkspaceMetricsExportController.handle_export_error(reason)
        end)

      assert log =~ "chromic_pdf_crashed"
      assert log =~ "secret-internal-path"

      assert redirected_to(result) == ~p"/metrics"

      flash = Phoenix.Flash.get(result.assigns.flash, :error)
      assert flash == WorkspaceMetricsExportController.export_error_flash_message()
      refute flash =~ "chromic_pdf_crashed"
      refute flash =~ "secret-internal-path"
      refute flash =~ "{"
    end

    test "export_error_flash_message/0 is generic and leaks no internals" do
      message = WorkspaceMetricsExportController.export_error_flash_message()

      assert is_binary(message)
      refute message =~ "{"
      refute message =~ ":"
    end
  end
end
