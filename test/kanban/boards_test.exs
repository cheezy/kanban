defmodule Kanban.BoardsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Boards
  alias Kanban.Boards.Board

  describe "list_boards/1" do
    test "returns all boards for a specific user" do
      user1 = user_fixture()
      user2 = user_fixture()

      board1 = board_fixture(user1, %{name: "User 1 Board 1"})
      board2 = board_fixture(user1, %{name: "User 1 Board 2"})
      _board3 = board_fixture(user2, %{name: "User 2 Board"})

      boards = Boards.list_boards(user1)

      assert length(boards) == 2
      assert Enum.any?(boards, &(&1.id == board1.id))
      assert Enum.any?(boards, &(&1.id == board2.id))
    end

    test "returns boards ordered by most recent first" do
      user = user_fixture()

      _board1 = board_fixture(user, %{name: "First Board"})
      _board2 = board_fixture(user, %{name: "Second Board"})
      _board3 = board_fixture(user, %{name: "Third Board"})

      boards = Boards.list_boards(user)

      assert length(boards) == 3
      # Verify boards are ordered by inserted_at descending
      assert Enum.at(boards, 0).inserted_at >= Enum.at(boards, 1).inserted_at
      assert Enum.at(boards, 1).inserted_at >= Enum.at(boards, 2).inserted_at
    end

    test "returns empty list when user has no boards" do
      user = user_fixture()
      boards = Boards.list_boards(user)

      assert boards == []
    end
  end

  describe "get_board!/2" do
    test "returns the board when it belongs to the user" do
      user = user_fixture()
      board = board_fixture(user)

      fetched_board = Boards.get_board!(board.id, user)

      assert fetched_board.id == board.id
      assert fetched_board.name == board.name
    end

    test "raises when board does not exist" do
      user = user_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!(999_999, user)
      end
    end

    test "raises when board belongs to a different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      board = board_fixture(user1)

      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!(board.id, user2)
      end
    end
  end

  describe "create_board/2" do
    test "creates a board with valid attributes" do
      user = user_fixture()
      attrs = %{name: "My Board", description: "My board description"}

      assert {:ok, %Board{} = board} = Boards.create_board(user, attrs)
      assert board.name == "My Board"
      assert board.description == "My board description"
      assert board.user_id == user.id
    end

    test "creates a board without description" do
      user = user_fixture()
      attrs = %{name: "My Board"}

      assert {:ok, %Board{} = board} = Boards.create_board(user, attrs)
      assert board.name == "My Board"
      assert is_nil(board.description)
    end

    test "returns error changeset when name is missing" do
      user = user_fixture()
      attrs = %{description: "Description only"}

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.create_board(user, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error changeset when name is empty" do
      user = user_fixture()
      attrs = %{name: "", description: "Description"}

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.create_board(user, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error changeset when name is too long" do
      user = user_fixture()
      long_name = String.duplicate("a", 51)
      attrs = %{name: long_name}

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.create_board(user, attrs)
      assert %{name: ["should be at most 50 character(s)"]} = errors_on(changeset)
    end
  end

  describe "update_board/2" do
    test "updates the board with valid attributes" do
      user = user_fixture()
      board = board_fixture(user, %{name: "Old Name", description: "Old Description"})

      attrs = %{name: "New Name", description: "New Description"}

      assert {:ok, %Board{} = updated_board} = Boards.update_board(board, attrs)
      assert updated_board.id == board.id
      assert updated_board.name == "New Name"
      assert updated_board.description == "New Description"
    end

    test "updates only the name" do
      user = user_fixture()
      board = board_fixture(user, %{name: "Old Name", description: "Description"})

      attrs = %{name: "New Name"}

      assert {:ok, %Board{} = updated_board} = Boards.update_board(board, attrs)
      assert updated_board.name == "New Name"
      assert updated_board.description == "Description"
    end

    test "updates only the description" do
      user = user_fixture()
      board = board_fixture(user, %{name: "Name1", description: "Old Description"})

      attrs = %{description: "New Description"}

      assert {:ok, %Board{} = updated_board} = Boards.update_board(board, attrs)
      assert updated_board.name == "Name1"
      assert updated_board.description == "New Description"
    end

    test "returns error changeset when name is invalid" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{name: ""}

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.update_board(board, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error changeset when name is too long" do
      user = user_fixture()
      board = board_fixture(user)

      long_name = String.duplicate("a", 256)
      attrs = %{name: long_name}

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.update_board(board, attrs)
      assert %{name: ["should be at most 50 character(s)"]} = errors_on(changeset)
    end
  end

  describe "delete_board/1" do
    test "deletes the board" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Board{}} = Boards.delete_board(board)
      assert_raise Ecto.NoResultsError, fn -> Boards.get_board!(board.id, user) end
    end

    test "deleted board is removed from user's board list" do
      user = user_fixture()
      board1 = board_fixture(user, %{name: "Board 1"})
      board2 = board_fixture(user, %{name: "Board 2"})

      assert length(Boards.list_boards(user)) == 2

      Boards.delete_board(board1)

      boards = Boards.list_boards(user)
      assert length(boards) == 1
      assert hd(boards).id == board2.id
    end
  end

  describe "change_board/2" do
    test "returns a board changeset" do
      user = user_fixture()
      board = board_fixture(user)

      assert %Ecto.Changeset{} = changeset = Boards.change_board(board)
      assert changeset.data == board
    end

    test "returns a changeset with changes" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{name: "New Name"}
      changeset = Boards.change_board(board, attrs)

      assert %Ecto.Changeset{} = changeset
      assert changeset.changes.name == "New Name"
    end
  end

  describe "cascade deletion" do
    test "boards are deleted when user is deleted" do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)

      # Verify boards exist
      assert Boards.get_board!(board1.id, user)
      assert Boards.get_board!(board2.id, user)

      # Delete the user
      Repo.delete(user)

      # Verify boards are deleted
      refute Repo.get(Board, board1.id)
      refute Repo.get(Board, board2.id)
    end
  end
end
