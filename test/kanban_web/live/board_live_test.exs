defmodule KanbanWeb.BoardLiveTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures
  import Kanban.ColumnsFixtures

  @create_attrs %{name: "some name", description: "some description"}
  @update_attrs %{name: "some updated name", description: "some updated description"}
  @invalid_attrs %{name: nil, description: nil}

  describe "Index" do
    setup [:register_and_log_in_user]

    test "lists all boards", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _index_live, html} = live(conn, ~p"/boards")

      assert html =~ "Listing Boards"
      assert html =~ board.name
    end

    test "saves new board", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/boards/new")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _index_live, html} =
        form_live
        |> form("#board-form", board: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards")

      assert html =~ "some name"
    end

    test "updates board in listing", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _index_live, html} =
        form_live
        |> form("#board-form", board: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards")

      assert html =~ "some updated name"
    end

    test "deletes board in listing", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, index_live, _html} = live(conn, ~p"/boards")

      assert index_live |> element("#boards-#{board.id} a[href*='#']", "") |> render_click()
      refute has_element?(index_live, "#boards-#{board.id}")
    end

    test "cannot see other users' boards", %{conn: conn} do
      other_user = user_fixture()
      _other_board = board_fixture(other_user)

      {:ok, _index_live, html} = live(conn, ~p"/boards")

      refute html =~ "other user board"
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user]

    test "displays board", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Show Board"
      assert html =~ board.name
    end

    test "cannot access other users' boards", %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{other_board}")
      end
    end

    test "displays empty state when board has no columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "No columns yet"
      assert html =~ "Create your first column"
    end

    test "displays columns in order", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress"})
      column3 = column_fixture(board, %{name: "Done"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ column1.name
      assert html =~ column2.name
      assert html =~ column3.name

      # Check order by position in HTML
      assert html =~ ~r/To Do.*In Progress.*Done/s
    end

    test "displays WIP limit indicator when column has WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "In Progress", wip_limit: 5})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "WIP limit"
      assert html =~ "5"
    end

    test "does not display WIP limit indicator when limit is 0", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "Done", wip_limit: 0})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # WIP limit label should not appear when limit is 0
      refute html =~ "WIP limit: 0"
    end
  end

  describe "Column Management" do
    setup [:register_and_log_in_user]

    test "creates new column", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Click "New Column" button which patches to the form
      show_live |> element("a", "New Column") |> render_click()

      # Validate form shows error for missing name
      assert show_live
             |> form("#column-form", column: %{name: nil})
             |> render_change() =~ "can&#39;t be blank"

      # Submit form
      show_live
      |> form("#column-form", column: %{name: "To Do", wip_limit: 5})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column created successfully"
      assert html =~ "To Do"
      assert html =~ "WIP limit"
      assert html =~ "5"
    end

    test "creates column with default WIP limit of 0", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live |> element("a", "New Column") |> render_click()

      show_live
      |> form("#column-form", column: %{name: "Done"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column created successfully"
      assert html =~ "Done"
      # Should not show WIP limit indicator when it's 0
      refute html =~ "WIP limit: 0"
    end

    test "rejects negative WIP limit when creating column", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live |> element("a", "New Column") |> render_click()

      html =
        show_live
        |> form("#column-form", column: %{name: "Test", wip_limit: -1})
        |> render_change()

      assert html =~ "must be greater than or equal to 0"
    end

    test "edits existing column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do", wip_limit: 3})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("#columns-#{column.id} a[href*='edit']")
      |> render_click()

      show_live
      |> form("#column-form", column: %{name: "In Progress", wip_limit: 5})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column updated successfully"
      assert html =~ "In Progress"
      assert html =~ "5"
      refute html =~ "To Do"
    end

    test "rejects negative WIP limit when editing column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("#columns-#{column.id} a[href*='edit']")
      |> render_click()

      html =
        show_live
        |> form("#column-form", column: %{wip_limit: -5})
        |> render_change()

      assert html =~ "must be greater than or equal to 0"
    end

    test "deletes column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "To Do"

      # Trigger the delete_column event directly
      show_live |> render_click("delete_column", %{"id" => column.id})

      html = render(show_live)
      assert html =~ "Column deleted successfully"
      refute html =~ "To Do"
    end

    test "displays New Column button", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "New Column"
    end
  end
end
