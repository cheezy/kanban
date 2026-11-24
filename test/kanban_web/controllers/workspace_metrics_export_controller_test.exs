defmodule KanbanWeb.WorkspaceMetricsExportControllerTest do
  # async: false — the PDF path drives ChromicPDF, a shared resource, matching
  # the board export controller test.
  use KanbanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

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

  # The workbook's data sections: the section strings AND every numeric cell.
  #
  # Two separately-issued requests can never be byte-identical — elixlsx stamps
  # a second-resolution `dcterms:created` into docProps/core.xml on every write,
  # and since W1726 the header block also carries the generation time and the
  # REQUESTED board count, which differs whenever one request names a forged id
  # the other does not. None of that is what the authorization tests assert;
  # they are about the DATA the report exposes.
  #
  # Both halves are required. Elixlsx interns strings in sharedStrings.xml but
  # writes numbers inline into the worksheet, so comparing strings alone would
  # miss a leak that shows up only in a count — and the fixtures here stamp the
  # same timestamps and set no agent name, so a leaked board would differ
  # NUMERICALLY and not otherwise.
  defp data_sections(resp_body) do
    {section_strings(resp_body), numeric_cells(resp_body)}
  end

  defp section_strings(resp_body) do
    # Shared strings are stored in first-occurrence order, so the header block's
    # strings precede every section string. "Summary" titles the first section.
    [_header, sections] =
      resp_body |> zip_entry(~c"xl/sharedStrings.xml") |> String.split("Summary", parts: 2)

    sections
  end

  # Every cell EXCEPT the shared-string ones, whose `<v>` holds a table index
  # rather than a value — those are already covered by section_strings/1, and
  # their indices shift whenever a header string changes.
  defp numeric_cells(resp_body) do
    ~r/<c(?![^>]*t="s")[^>]*>\s*<v>([^<]*)<\/v>/
    |> Regex.scan(zip_entry(resp_body, ~c"xl/worksheets/sheet1.xml"), capture: :all_but_first)
    |> List.flatten()
  end

  defp zip_entry(resp_body, path) do
    {:ok, handle} = :zip.zip_open(resp_body, [:memory])
    {:ok, {_path, xml}} = :zip.zip_get(path, handle)
    :zip.zip_close(handle)
    to_string(xml)
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

  # The start and stop metadata of the next export span, without the span
  # context.
  defp export_span_metadata do
    assert_receive {:telemetry_event, [:kanban, :export, :start], _, start}
    assert_receive {:telemetry_event, [:kanban, :export, :stop], %{duration: _}, stop}
    {Map.delete(start, :telemetry_span_context), Map.delete(stop, :telemetry_span_context)}
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

    test "excel export emits the export span", %{conn: conn, user: user} do
      board_with_completed_task!(user)
      attach_telemetry([[:kanban, :export, :start], [:kanban, :export, :stop]])

      conn = get(conn, ~p"/metrics/export?format=excel&window_days=30")
      assert conn.status == 200

      assert export_span_metadata() ==
               {%{kind: :workspace_metrics, format: :xlsx},
                %{kind: :workspace_metrics, format: :xlsx}}
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
      # The unfiltered export aggregates both boards' completed work, so its
      # data must differ from the single-board export. Asserted on the data
      # sections rather than the raw bytes: elixlsx stamps a timestamp into
      # every workbook, so byte-inequality would hold even if the aggregation
      # were identical, making the original assertion vacuous.
      refute data_sections(both.resp_body) == data_sections(only_a.resp_body)
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
      # Identical data sections: the response reveals nothing about whether the
      # board exists. Both requests name exactly one board id, so their header
      # blocks agree too — only the generation timestamp separates the bytes.
      assert data_sections(forged.resp_body) == data_sections(nonexistent.resp_body)
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
      # The forged board contributes no data, so the sections match. The header
      # blocks deliberately do NOT: the report states the board selection that
      # was REQUESTED ("2 boards" vs "1 board"), echoing the caller's own input
      # rather than disclosing which ids resolved.
      assert data_sections(both.resp_body) == data_sections(visible_only.resp_body)
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

    test "a valid session timezone wins over the timezone param", %{scope: scope} do
      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"timezone" => "Pacific/Midway"},
          "Europe/Berlin"
        )

      assert opts[:timezone] == "Europe/Berlin"
    end

    test "an invalid session timezone falls back to the timezone param", %{scope: scope} do
      opts =
        WorkspaceMetricsExportController.build_export_opts(
          scope,
          %{"timezone" => "Pacific/Midway"},
          "Not/AZone"
        )

      assert opts[:timezone] == "Pacific/Midway"
    end

    test "the export uses the zone the Timezone plug stored for the request",
         %{conn: conn, user: user} do
      board_with_completed_task!(user)

      conn =
        conn
        |> put_req_cookie("stride_tz", "Pacific%2FKiritimati")
        |> get(~p"/metrics/export?format=excel&timezone=Pacific/Midway")

      assert [disposition] = get_resp_header(conn, "content-disposition")

      assert disposition =~
               "Pacific/Kiritimati" |> Kanban.Timezone.local_today() |> Date.to_string()

      assert zip_entry(conn.resp_body, ~c"xl/sharedStrings.xml") =~
               "Times shown in Pacific/Kiritimati"
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

  describe "HEAD (D472)" do
    @export_events [[:kanban, :export, :start], [:kanban, :export, :stop]]

    test "GET still emits the export span in both formats", %{conn: conn, user: user} do
      board_with_completed_task!(user)
      attach_telemetry(@export_events)

      for {query, format} <- [{"", :pdf}, {"?format=excel", :xlsx}] do
        got = get(conn, "/metrics/export#{query}")

        assert got.status == 200
        assert byte_size(got.resp_body) > 0

        assert export_span_metadata() ==
                 {%{kind: :workspace_metrics, format: format},
                  %{kind: :workspace_metrics, format: format}}
      end

      # Each GET consumed exactly one start/stop pair: nothing is left over.
      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
      refute_received {:telemetry_event, [:kanban, :export, :stop], _, _}
    end

    test "HEAD emits no export span and its headers match GET", %{conn: conn, user: user} do
      board_with_completed_task!(user)

      paths =
        for query <- ["", "?format=excel", "?format=excel&window_days=30", "?window_days=7"],
            do: "/metrics/export#{query}"

      # Every GET runs before the handler is attached, so any export event
      # received below came from a HEAD.
      gets = Map.new(paths, &{&1, get(conn, &1)})
      attach_telemetry(@export_events)

      for path <- paths do
        got = Map.fetch!(gets, path)
        headed = head(conn, path)

        assert got.status == 200
        assert headed.status == got.status
        assert headed.resp_body == ""

        for header <- ["content-type", "content-disposition"] do
          assert [_value] = get_resp_header(headed, header)
          assert get_resp_header(headed, header) == get_resp_header(got, header)
        end
      end

      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
      refute_received {:telemetry_event, [:kanban, :export, :stop], _, _}
    end

    test "HEAD on an empty workspace behaves like GET with no span", %{conn: conn} do
      got = get(conn, ~p"/metrics/export?format=excel")

      attach_telemetry(@export_events)
      headed = head(conn, ~p"/metrics/export?format=excel")

      assert headed.status == 200
      assert headed.resp_body == ""

      assert get_resp_header(headed, "content-disposition") ==
               get_resp_header(got, "content-disposition")

      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
    end

    test "an unauthenticated HEAD gets the same log-in redirect as GET and no span" do
      got = get(build_conn(), ~p"/metrics/export")

      attach_telemetry(@export_events)
      headed = head(build_conn(), ~p"/metrics/export")

      assert redirected_to(headed) =~ "/users/log-in"
      assert redirected_to(headed) == redirected_to(got)
      assert get_resp_header(headed, "content-disposition") == []
      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
    end
  end

  describe "a failed build still ends the export span" do
    # Stubs for the controller's export seams (:export_pdf_printer and
    # :workspace_metrics_excel_export): each forces {:error, reason} from the
    # build.
    defmodule FailingPdfPrinter do
      def print_to_pdf(_content, _opts), do: {:error, :forced_pdf_failure}
    end

    defmodule FailingExcelExport do
      def generate(_assigns), do: {:error, :forced_excel_failure}
    end

    @span_events [
      [:kanban, :export, :start],
      [:kanban, :export, :stop],
      [:kanban, :export, :exception]
    ]

    for {query, format, key, stub, reason} <- [
          {"", :pdf, :export_pdf_printer, FailingPdfPrinter, "forced_pdf_failure"},
          {"?format=excel", :xlsx, :workspace_metrics_excel_export, FailingExcelExport,
           "forced_excel_failure"}
        ] do
      @query query
      @format format
      @key key
      @stub stub
      @reason reason

      test "a forced #{format} failure redirects with the error flash and ends the span with :stop",
           %{conn: conn, user: user} do
        board_with_completed_task!(user)
        override_export_seam(@key, @stub)
        attach_telemetry(@span_events)

        {conn, log} = with_log(fn -> get(conn, "/metrics/export#{@query}") end)

        assert redirected_to(conn) == ~p"/metrics"

        flash = Phoenix.Flash.get(conn.assigns.flash, :error)
        assert flash == WorkspaceMetricsExportController.export_error_flash_message()
        refute flash =~ @reason

        # The raw reason still reaches the operator log, and only there.
        assert log =~ @reason

        # One start and one stop, carrying only the kind and format.
        assert export_span_metadata() ==
                 {%{kind: :workspace_metrics, format: @format},
                  %{kind: :workspace_metrics, format: @format}}

        refute_received {:telemetry_event, [:kanban, :export, :stop], _, _}
        refute_received {:telemetry_event, [:kanban, :export, :exception], _, _}
      end
    end
  end

  describe "a raised PDF build failure (D475)" do
    # ChromicPDF never returns {:error, _}: a failed print raises, or exits
    # when a Chrome process dies mid-call. Each stub fails the way it does.
    defmodule RaisingPdfPrinter do
      def print_to_pdf(_content, _opts) do
        raise ChromicPDF.Browser.ExecutionError, "forced_pdf_raise"
      end
    end

    defmodule ChromeErrorPdfPrinter do
      def print_to_pdf(_content, _opts) do
        raise ChromicPDF.ChromeError, error: "forced_chrome_error", opts: []
      end
    end

    defmodule ConnectionLostPdfPrinter do
      def print_to_pdf(_content, _opts) do
        raise ChromicPDF.Connection.ConnectionLostError, "forced_connection_lost"
      end
    end

    defmodule ExitingPdfPrinter do
      def print_to_pdf(_content, _opts), do: exit(:forced_pdf_exit)
    end

    defmodule MessagelessPdfPrinter do
      def print_to_pdf(_content, _opts), do: raise(ChromicPDF.Browser.ExecutionError)
    end

    defmodule BuggyPdfPrinter do
      def print_to_pdf(_content, _opts), do: raise("forced_bug")
    end

    @span_events [
      [:kanban, :export, :start],
      [:kanban, :export, :stop],
      [:kanban, :export, :exception]
    ]

    for {stub, reason} <- [
          {RaisingPdfPrinter, "forced_pdf_raise"},
          {ChromeErrorPdfPrinter, "forced_chrome_error"},
          {ConnectionLostPdfPrinter, "forced_connection_lost"},
          {ExitingPdfPrinter, "forced_pdf_exit"}
        ] do
      @stub stub
      @reason reason

      test "redirects when the PDF build raises: #{inspect(stub)}", %{conn: conn, user: user} do
        board_with_completed_task!(user)
        override_export_seam(:export_pdf_printer, @stub)

        {conn, log} = with_log(fn -> get(conn, "/metrics/export") end)

        assert redirected_to(conn) == ~p"/metrics"

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 WorkspaceMetricsExportController.export_error_flash_message()

        assert log =~ "Workspace metrics export generation failed"
        assert log =~ @reason
      end

      test "does not leak the raised reason: #{inspect(stub)}", %{conn: conn, user: user} do
        board_with_completed_task!(user)
        override_export_seam(:export_pdf_printer, @stub)

        {conn, _log} = with_log(fn -> get(conn, "/metrics/export") end)

        refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ @reason
        refute conn.resp_body =~ @reason
        refute conn.resp_body =~ "ChromicPDF"
      end

      test "a raised build failure ends the export span with :stop: #{inspect(stub)}",
           %{conn: conn, user: user} do
        board_with_completed_task!(user)
        override_export_seam(:export_pdf_printer, @stub)
        attach_telemetry(@span_events)

        with_log(fn -> get(conn, "/metrics/export") end)

        assert export_span_metadata() ==
                 {%{kind: :workspace_metrics, format: :pdf},
                  %{kind: :workspace_metrics, format: :pdf}}

        refute_received {:telemetry_event, [:kanban, :export, :stop], _, _}
        refute_received {:telemetry_event, [:kanban, :export, :exception], _, _}
      end
    end

    test "shows the export-failed flash in the session's locale when the build raises",
         %{conn: conn, user: user} do
      board_with_completed_task!(user)
      override_export_seam(:export_pdf_printer, RaisingPdfPrinter)

      {conn, _log} =
        with_log(fn -> conn |> put_session(:locale, "de") |> get("/metrics/export") end)

      german =
        Gettext.with_locale(
          KanbanWeb.Gettext,
          "de",
          &WorkspaceMetricsExportController.export_error_flash_message/0
        )

      assert german !=
               Gettext.with_locale(
                 KanbanWeb.Gettext,
                 "en",
                 &WorkspaceMetricsExportController.export_error_flash_message/0
               )

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == german
    end

    test "handles a raised build failure with no message", %{conn: conn, user: user} do
      board_with_completed_task!(user)
      override_export_seam(:export_pdf_printer, MessagelessPdfPrinter)

      {conn, log} = with_log(fn -> get(conn, "/metrics/export") end)

      assert redirected_to(conn) == ~p"/metrics"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               WorkspaceMetricsExportController.export_error_flash_message()

      assert log =~ "ChromicPDF.Browser.ExecutionError"
    end

    test "an exception that is not a failed print still surfaces", %{conn: conn, user: user} do
      board_with_completed_task!(user)
      override_export_seam(:export_pdf_printer, BuggyPdfPrinter)
      attach_telemetry(@span_events)

      assert_raise RuntimeError, "forced_bug", fn -> get(conn, "/metrics/export") end

      assert_receive {:telemetry_event, [:kanban, :export, :exception], _, _}
      refute_received {:telemetry_event, [:kanban, :export, :stop], _, _}
    end
  end

  describe "export seams" do
    test "default to the real PDF printer and Excel generator" do
      assert Application.fetch_env(:kanban, :export_pdf_printer) == :error
      assert Application.fetch_env(:kanban, :workspace_metrics_excel_export) == :error

      assert WorkspaceMetricsExportController.pdf_printer() == ChromicPDF

      assert WorkspaceMetricsExportController.excel_exporter() ==
               KanbanWeb.WorkspaceMetricsExcelExport
    end

    test "are set by no config file, so dev and prod get the real modules" do
      for file <- File.cwd!() |> Path.join("config/*.exs") |> Path.wildcard(),
          key <- ["export_pdf_printer", "workspace_metrics_excel_export"] do
        refute File.read!(file) =~ key, "#{Path.basename(file)} sets :#{key}"
      end
    end
  end

  # Puts `stub` under the export seam `key` for this test only, then restores
  # the previous value, or removes the key, when the test exits.
  defp override_export_seam(key, stub) do
    original = Application.fetch_env(:kanban, key)
    Application.put_env(:kanban, key, stub)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:kanban, key, value)
        :error -> Application.delete_env(:kanban, key)
      end
    end)
  end
end
