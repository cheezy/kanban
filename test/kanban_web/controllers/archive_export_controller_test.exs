defmodule KanbanWeb.ArchiveExportControllerTest do
  use KanbanWeb.ConnCase, async: true

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
end
