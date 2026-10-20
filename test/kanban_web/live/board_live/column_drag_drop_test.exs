defmodule KanbanWeb.BoardLive.ColumnDragDropTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  describe "Column drag and drop" do
    test "reorders columns when moved", %{conn: conn} do
      user = user_fixture()
      board = board_fixture(user)

      # Create three columns
      column1 = column_fixture(board, %{name: "Column 1"})
      column2 = column_fixture(board, %{name: "Column 2"})
      column3 = column_fixture(board, %{name: "Column 3"})

      # Verify initial order
      assert column1.position == 0
      assert column2.position == 1
      assert column3.position == 2

      # Log in and mount the board page
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      # Simulate moving column 3 to position 0 (first position)
      # The new order would be: column3, column1, column2
      new_order = [column3.id, column1.id, column2.id]

      result =
        view
        |> element("#columns")
        |> render_hook("move_column", %{
          "column_id" => to_string(column3.id),
          "column_ids" => Enum.map(new_order, &to_string/1),
          "new_position" => 0
        })

      assert result

      # Verify the columns were reordered in the database
      reloaded_column1 = Kanban.Columns.get_column!(column1.id)
      reloaded_column2 = Kanban.Columns.get_column!(column2.id)
      reloaded_column3 = Kanban.Columns.get_column!(column3.id)

      assert reloaded_column3.position == 0
      assert reloaded_column1.position == 1
      assert reloaded_column2.position == 2
    end

    test "reorders columns when moved to middle", %{conn: conn} do
      user = user_fixture()
      board = board_fixture(user)

      # Create three columns
      column1 = column_fixture(board, %{name: "Column 1"})
      column2 = column_fixture(board, %{name: "Column 2"})
      column3 = column_fixture(board, %{name: "Column 3"})

      # Log in and mount the board page
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      # Simulate moving column 1 to position 1 (middle position)
      # The new order would be: column2, column1, column3
      new_order = [column2.id, column1.id, column3.id]

      view
      |> element("#columns")
      |> render_hook("move_column", %{
        "column_id" => to_string(column1.id),
        "column_ids" => Enum.map(new_order, &to_string/1),
        "new_position" => 1
      })

      # Verify the columns were reordered in the database
      reloaded_column1 = Kanban.Columns.get_column!(column1.id)
      reloaded_column2 = Kanban.Columns.get_column!(column2.id)
      reloaded_column3 = Kanban.Columns.get_column!(column3.id)

      assert reloaded_column2.position == 0
      assert reloaded_column1.position == 1
      assert reloaded_column3.position == 2
    end

    test "handles moving column to last position", %{conn: conn} do
      user = user_fixture()
      board = board_fixture(user)

      # Create three columns
      column1 = column_fixture(board, %{name: "Column 1"})
      column2 = column_fixture(board, %{name: "Column 2"})
      column3 = column_fixture(board, %{name: "Column 3"})

      # Log in and mount the board page
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      # Simulate moving column 1 to the last position
      # The new order would be: column2, column3, column1
      new_order = [column2.id, column3.id, column1.id]

      view
      |> element("#columns")
      |> render_hook("move_column", %{
        "column_id" => to_string(column1.id),
        "column_ids" => Enum.map(new_order, &to_string/1),
        "new_position" => 2
      })

      # Verify the columns were reordered in the database
      reloaded_column1 = Kanban.Columns.get_column!(column1.id)
      reloaded_column2 = Kanban.Columns.get_column!(column2.id)
      reloaded_column3 = Kanban.Columns.get_column!(column3.id)

      assert reloaded_column2.position == 0
      assert reloaded_column3.position == 1
      assert reloaded_column1.position == 2
    end
  end

  describe "a crafted move_column event" do
    test "with malformed or oversized ids changes nothing and keeps the page alive", %{
      conn: conn
    } do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "Column 1"})
      column2 = column_fixture(board, %{name: "Column 2"})
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/boards/#{board}")

      for column_ids <- [
            [to_string(column2.id), "abc"],
            [to_string(column2.id), "99999999999999999999"],
            "#{column2.id},#{column1.id}"
          ] do
        render_hook(view, "move_column", %{
          "column_id" => to_string(column2.id),
          "column_ids" => column_ids
        })
      end

      assert render(view) =~ "Column 1"
      assert Kanban.Columns.get_column!(column1.id).position == 0
      assert Kanban.Columns.get_column!(column2.id).position == 1
    end
  end
end
