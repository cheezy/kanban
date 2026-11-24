defmodule KanbanWeb.ArchiveExportControllerTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Tasks

  setup do
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user}
  end

  describe "export/2" do
    test "returns a text/csv attachment of the board's archived tasks",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      column
      |> task_fixture(%{title: "Exported Task"})
      |> Tasks.archive_task()

      conn = get(conn, ~p"/boards/#{board}/archive/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/csv"

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".csv"

      assert conn.resp_body =~ "Identifier,Title,Type,Goal,Assignee,Archive Reason"
      assert conn.resp_body =~ "Exported Task"
    end

    test "controller export emits span", %{conn: conn, user: user} do
      board = board_fixture(user)

      board
      |> column_fixture()
      |> task_fixture(%{title: "Exported Task"})
      |> Tasks.archive_task()

      attach_telemetry([[:kanban, :export, :start], [:kanban, :export, :stop]])

      conn = get(conn, ~p"/boards/#{board}/archive/export")
      assert conn.status == 200

      assert_receive {:telemetry_event, [:kanban, :export, :start], _,
                      %{kind: :archive_csv, format: :csv}}

      assert_receive {:telemetry_event, [:kanban, :export, :stop], %{row_count: 1},
                      %{kind: :archive_csv, format: :csv}}
    end

    test "exports a header-only CSV for an empty archive", %{conn: conn, user: user} do
      board = board_fixture(user)

      conn = get(conn, ~p"/boards/#{board}/archive/export")

      assert conn.status == 200
      assert conn.resp_body =~ "Identifier,Title,Type"
      refute conn.resp_body =~ "\r\n\r\n"
    end

    test "redirects to login when unauthenticated", %{user: user} do
      board = board_fixture(user)

      conn = get(build_conn(), ~p"/boards/#{board}/archive/export")

      assert redirected_to(conn) =~ "/users/log-in"
    end

    test "does not leak the archive of a board the user cannot access",
         %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)
      other_column = column_fixture(other_board)

      other_column
      |> task_fixture(%{title: "Secret Task"})
      |> Tasks.archive_task()

      conn = get(conn, ~p"/boards/#{other_board}/archive/export")

      assert redirected_to(conn) == ~p"/boards"
      refute conn.resp_body =~ "Secret Task"
    end
  end

  describe "export/2 - HEAD (D474)" do
    @export_events [[:kanban, :export, :start], [:kanban, :export, :stop]]

    defp archived_board(user, attrs \\ %{}) do
      board = board_fixture(user, attrs)

      board
      |> column_fixture()
      |> task_fixture(%{title: "Exported Task"})
      |> Tasks.archive_task()

      board
    end

    defp assert_same_headers(headed, got) do
      assert headed.status == got.status
      assert headed.resp_body == ""

      for header <- ["content-type", "content-disposition"] do
        assert [_value] = get_resp_header(headed, header)
        assert get_resp_header(headed, header) == get_resp_header(got, header)
      end
    end

    defp refute_export_span do
      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
      refute_received {:telemetry_event, [:kanban, :export, :stop], _, _}
    end

    test "GET still emits the export span", %{conn: conn, user: user} do
      board = archived_board(user)
      attach_telemetry(@export_events)

      got = get(conn, ~p"/boards/#{board}/archive/export")

      assert got.status == 200
      assert got.resp_body =~ "Exported Task"

      assert_received {:telemetry_event, [:kanban, :export, :start], _,
                       %{kind: :archive_csv, format: :csv}}

      assert_received {:telemetry_event, [:kanban, :export, :stop], %{row_count: 1},
                       %{kind: :archive_csv, format: :csv}}

      refute_export_span()
    end

    test "HEAD emits no export span and its headers match GET",
         %{conn: conn, user: user} do
      board = archived_board(user)
      got = get(conn, ~p"/boards/#{board}/archive/export")

      attach_telemetry(@export_events)
      headed = head(conn, ~p"/boards/#{board}/archive/export")

      assert headed.status == 200
      assert [content_type] = get_resp_header(headed, "content-type")
      assert content_type =~ "text/csv"
      assert_same_headers(headed, got)
      refute_export_span()
    end

    test "HEAD with no archived tasks returns the headers and no span",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      got = get(conn, ~p"/boards/#{board}/archive/export")

      attach_telemetry(@export_events)
      headed = head(conn, ~p"/boards/#{board}/archive/export")

      assert_same_headers(headed, got)
      refute_export_span()
    end

    test "HEAD keeps the sanitized filename in the content-disposition",
         %{conn: conn, user: user} do
      board = archived_board(user, %{name: ~s(Q4 "Plan"; a/b\\c)})
      got = get(conn, ~p"/boards/#{board}/archive/export")

      attach_telemetry(@export_events)
      headed = head(conn, ~p"/boards/#{board}/archive/export")

      assert [disposition] = get_resp_header(headed, "content-disposition")

      assert disposition ==
               ~s(attachment; filename="Q4__Plan___a_b_c_archive_#{Date.utc_today()}.csv")

      assert_same_headers(headed, got)
      refute_export_span()
    end

    test "HEAD on another user's board redirects like GET", %{conn: conn} do
      other_board = archived_board(user_fixture())
      got = get(conn, ~p"/boards/#{other_board}/archive/export")

      attach_telemetry(@export_events)
      headed = head(conn, ~p"/boards/#{other_board}/archive/export")

      assert redirected_to(headed) == ~p"/boards"
      assert redirected_to(headed) == redirected_to(got)
      refute headed.resp_body =~ "Exported Task"
      refute_export_span()
    end

    test "HEAD on a malformed board id redirects like GET", %{conn: conn} do
      got = get(conn, "/boards/not-a-board/archive/export")

      attach_telemetry(@export_events)
      headed = head(conn, "/boards/not-a-board/archive/export")

      assert redirected_to(headed) == ~p"/boards"
      assert redirected_to(headed) == redirected_to(got)
      refute_export_span()
    end
  end
end
