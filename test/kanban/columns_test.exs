defmodule Kanban.ColumnsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Columns
  alias Kanban.Columns.Column

  describe "list_columns/1" do
    test "returns all columns for a board ordered by position" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      columns = Columns.list_columns(board)

      assert length(columns) == 3
      assert Enum.map(columns, & &1.id) == [column1.id, column2.id, column3.id]
      assert Enum.map(columns, & &1.position) == [0, 1, 2]
    end

    test "returns empty list when board has no columns" do
      user = user_fixture()
      board = board_fixture(user)

      assert Columns.list_columns(board) == []
    end

    test "only returns columns for the specified board" do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)

      column_fixture(board1)
      column_fixture(board2)

      assert length(Columns.list_columns(board1)) == 1
      assert length(Columns.list_columns(board2)) == 1
    end
  end

  describe "get_column!/1" do
    test "returns the column with given id" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert Columns.get_column!(column.id).id == column.id
    end

    test "raises error when column does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Columns.get_column!(999_999)
      end
    end
  end

  describe "create_column/3" do
    test "creates a column with valid attributes" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "To Do"}, user)

      assert column.name == "To Do"
      assert column.position == 0
      assert column.wip_limit == 0
      assert column.board_id == board.id
    end

    test "creates columns with sequential positions" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, column1} = Columns.create_column(board, %{name: "First"}, user)
      {:ok, column2} = Columns.create_column(board, %{name: "Second"}, user)
      {:ok, column3} = Columns.create_column(board, %{name: "Third"}, user)

      assert column1.position == 0
      assert column2.position == 1
      assert column3.position == 2
    end

    test "creates a column with custom wip_limit" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "In Progress", wip_limit: 5}, user)

      assert column.wip_limit == 5
    end

    test "defaults wip_limit to 0 when not provided" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "Done"}, user)

      assert column.wip_limit == 0
    end

    test "returns error when name is missing" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:error, %Ecto.Changeset{}} = Columns.create_column(board, %{}, user)
    end

    test "accepts string-keyed attrs without raising on unknown keys" do
      # An unknown string key used to raise ArgumentError from
      # String.to_existing_atom/1. cast/3 silently ignores unknown
      # fields, so we should get a controlled {:ok, _} (when the
      # known string-keyed fields are valid) without a crash.
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{name: "From Strings"}} =
               Columns.create_column(
                 board,
                 %{
                   "name" => "From Strings",
                   "totally_unknown_field" => 42
                 },
                 user
               )
    end

    test "rejects negative wip_limit" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:error, changeset} =
               Columns.create_column(board, %{name: "Test", wip_limit: -1}, user)

      assert "must be greater than or equal to 0" in errors_on(changeset).wip_limit
    end

    test "accepts wip_limit of 0" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "Test", wip_limit: 0}, user)

      assert column.wip_limit == 0
    end

    test "accepts positive wip_limit" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "Test", wip_limit: 10}, user)

      assert column.wip_limit == 10
    end

    test "ignores a caller-supplied board_id and uses the trusted board (D93)" do
      user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(
                 board,
                 %{
                   name: "Sneaky",
                   board_id: other_board.id
                 },
                 user
               )

      assert column.board_id == board.id
      refute column.board_id == other_board.id
    end
  end

  describe "update_column/3" do
    test "updates the column with valid attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Old Name"})

      assert {:ok, %Column{} = updated_column} =
               Columns.update_column(column, %{name: "New Name"}, user)

      assert updated_column.name == "New Name"
      assert updated_column.id == column.id
    end

    test "updates wip_limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 5})

      assert {:ok, %Column{} = updated_column} =
               Columns.update_column(column, %{wip_limit: 10}, user)

      assert updated_column.wip_limit == 10
    end

    test "rejects negative wip_limit on update" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:error, changeset} =
               Columns.update_column(column, %{wip_limit: -5}, user)

      assert "must be greater than or equal to 0" in errors_on(changeset).wip_limit
    end

    test "returns error with invalid attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:error, %Ecto.Changeset{}} =
               Columns.update_column(column, %{name: nil}, user)
    end

    test "cannot reassign board_id from params (D93)" do
      user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)
      column = column_fixture(board, %{name: "Stays Put"})

      assert {:ok, %Column{} = updated_column} =
               Columns.update_column(
                 column,
                 %{
                   name: "Renamed",
                   board_id: other_board.id
                 },
                 user
               )

      assert updated_column.name == "Renamed"
      assert updated_column.board_id == board.id
      refute updated_column.board_id == other_board.id
    end
  end

  describe "delete_column/1" do
    test "deletes the column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:ok, %Column{}} = Columns.delete_column(column)
      assert_raise Ecto.NoResultsError, fn -> Columns.get_column!(column.id) end
    end

    test "reorders remaining columns after deletion" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      # Delete the middle column
      {:ok, _deleted} = Columns.delete_column(column2)

      # Refresh columns from database
      remaining_columns = Columns.list_columns(board)

      assert length(remaining_columns) == 2
      assert Enum.at(remaining_columns, 0).id == column1.id
      assert Enum.at(remaining_columns, 0).position == 0
      assert Enum.at(remaining_columns, 1).id == column3.id
      assert Enum.at(remaining_columns, 1).position == 1
    end

    test "reorders when deleting first column" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      {:ok, _deleted} = Columns.delete_column(column1)

      remaining_columns = Columns.list_columns(board)

      assert length(remaining_columns) == 2
      assert Enum.at(remaining_columns, 0).id == column2.id
      assert Enum.at(remaining_columns, 0).position == 0
      assert Enum.at(remaining_columns, 1).id == column3.id
      assert Enum.at(remaining_columns, 1).position == 1
    end

    test "does not affect other board's columns" do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)

      column1 = column_fixture(board1)
      column2 = column_fixture(board2)

      {:ok, _deleted} = Columns.delete_column(column1)

      # Board2's column should be unaffected
      assert Columns.get_column!(column2.id).position == 0
    end
  end

  describe "D140: create_column/update_column owner authorization" do
    setup do
      owner = user_fixture()
      stranger = user_fixture()
      modify_user = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)
      column = column_fixture(board, %{name: "Guarded"})
      %{owner: owner, stranger: stranger, modify_user: modify_user, board: board, column: column}
    end

    test "create_column is rejected for a stranger", %{board: board, stranger: stranger} do
      assert {:error, :unauthorized} =
               Columns.create_column(board, %{name: "Sneaky"}, stranger)
    end

    test "create_column is rejected for a non-owner :modify collaborator", %{
      board: board,
      modify_user: modify_user
    } do
      assert {:error, :unauthorized} =
               Columns.create_column(board, %{name: "Sneaky"}, modify_user)
    end

    test "update_column is rejected for a stranger", %{column: column, stranger: stranger} do
      assert {:error, :unauthorized} =
               Columns.update_column(column, %{name: "Hacked"}, stranger)
    end

    test "update_column is rejected for a non-owner :modify collaborator", %{
      column: column,
      modify_user: modify_user
    } do
      assert {:error, :unauthorized} =
               Columns.update_column(column, %{name: "Hacked"}, modify_user)
    end

    test "both succeed for the board owner", %{board: board, column: column, owner: owner} do
      assert {:ok, %Column{}} = Columns.create_column(board, %{name: "Allowed"}, owner)
      assert {:ok, %Column{}} = Columns.update_column(column, %{name: "Renamed"}, owner)
    end
  end

  describe "reorder_columns/2" do
    test "reorders columns based on list of IDs" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      # Reorder: Third, First, Second
      Columns.reorder_columns(board, [column3.id, column1.id, column2.id])

      columns = Columns.list_columns(board)

      assert Enum.at(columns, 0).id == column3.id
      assert Enum.at(columns, 0).position == 0
      assert Enum.at(columns, 1).id == column1.id
      assert Enum.at(columns, 1).position == 1
      assert Enum.at(columns, 2).id == column2.id
      assert Enum.at(columns, 2).position == 2
    end

    test "handles partial reordering" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board)
      column2 = column_fixture(board)

      # Swap them
      Columns.reorder_columns(board, [column2.id, column1.id])

      columns = Columns.list_columns(board)

      assert Enum.at(columns, 0).id == column2.id
      assert Enum.at(columns, 1).id == column1.id
    end
  end
end
