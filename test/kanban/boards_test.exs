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
      # Verify user is owner
      assert Boards.get_user_access(board.id, user.id) == :owner
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
    test "board_users are deleted when user is deleted" do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)

      # Verify boards exist and user has access
      assert Boards.get_board!(board1.id, user)
      assert Boards.get_board!(board2.id, user)

      # Delete the user - this deletes board_users but not boards
      Repo.delete(user)

      # Boards still exist but without the user relationship
      assert Repo.get(Board, board1.id)
      assert Repo.get(Board, board2.id)
    end
  end

  describe "get_user_access/2" do
    test "returns the access level for a user with owner access" do
      user = user_fixture()
      board = board_fixture(user)

      assert Boards.get_user_access(board.id, user.id) == :owner
    end

    test "returns the access level for a user with read_only access" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only)

      assert Boards.get_user_access(board.id, reader.id) == :read_only
    end

    test "returns the access level for a user with modify access" do
      owner = user_fixture()
      board = board_fixture(owner)
      collaborator = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, collaborator, :modify)

      assert Boards.get_user_access(board.id, collaborator.id) == :modify
    end

    test "returns nil when user has no access to board" do
      user1 = user_fixture()
      user2 = user_fixture()
      board = board_fixture(user1)

      assert Boards.get_user_access(board.id, user2.id) == nil
    end
  end

  describe "owner?/2" do
    test "returns true when user is owner" do
      user = user_fixture()
      board = board_fixture(user)

      assert Boards.owner?(board, user) == true
    end

    test "returns false when user has read_only access" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only)

      assert Boards.owner?(board, reader) == false
    end

    test "returns false when user has modify access" do
      owner = user_fixture()
      board = board_fixture(owner)
      collaborator = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, collaborator, :modify)

      assert Boards.owner?(board, collaborator) == false
    end

    test "returns false when user has no access" do
      user1 = user_fixture()
      user2 = user_fixture()
      board = board_fixture(user1)

      assert Boards.owner?(board, user2) == false
    end
  end

  describe "can_modify?/2" do
    test "returns true when user is owner" do
      user = user_fixture()
      board = board_fixture(user)

      assert Boards.can_modify?(board, user) == true
    end

    test "returns true when user has modify access" do
      owner = user_fixture()
      board = board_fixture(owner)
      collaborator = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, collaborator, :modify)

      assert Boards.can_modify?(board, collaborator) == true
    end

    test "returns false when user has read_only access" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only)

      assert Boards.can_modify?(board, reader) == false
    end

    test "returns false when user has no access" do
      user1 = user_fixture()
      user2 = user_fixture()
      board = board_fixture(user1)

      assert Boards.can_modify?(board, user2) == false
    end
  end

  describe "add_user_to_board/3" do
    test "prevents adding a second owner to a board" do
      owner = user_fixture()
      board = board_fixture(owner)
      new_user = user_fixture()

      assert_raise Ecto.ConstraintError, fn ->
        Boards.add_user_to_board(board, new_user, :owner)
      end
    end

    test "adds a user with read_only access" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      assert {:ok, board_user} = Boards.add_user_to_board(board, reader, :read_only)
      assert board_user.access == :read_only

      # Verify user can see the board
      assert Boards.get_board!(board.id, reader)
    end

    test "adds a user with modify access" do
      owner = user_fixture()
      board = board_fixture(owner)
      collaborator = user_fixture()

      assert {:ok, board_user} = Boards.add_user_to_board(board, collaborator, :modify)
      assert board_user.access == :modify

      # Verify user can see the board
      assert Boards.get_board!(board.id, collaborator)
    end

    test "returns error when adding duplicate user" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only)

      assert {:error, changeset} = Boards.add_user_to_board(board, reader, :modify)
      assert %{board_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "board appears in user's board list after being added" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      # Reader has no boards initially
      assert Boards.list_boards(reader) == []

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only)

      # Reader now sees the board
      boards = Boards.list_boards(reader)
      assert length(boards) == 1
      assert hd(boards).id == board.id
    end
  end

  describe "remove_user_from_board/2" do
    test "removes a user from a board" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only)

      # Verify user can see the board
      assert Boards.get_board!(board.id, reader)

      assert {:ok, _} = Boards.remove_user_from_board(board, reader)

      # Verify user can no longer see the board
      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!(board.id, reader)
      end
    end

    test "returns error when user is not on the board" do
      owner = user_fixture()
      board = board_fixture(owner)
      other_user = user_fixture()

      assert {:error, :not_found} = Boards.remove_user_from_board(board, other_user)
    end

    test "board is removed from user's board list after being removed" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only)

      # Reader sees the board
      assert length(Boards.list_boards(reader)) == 1

      {:ok, _} = Boards.remove_user_from_board(board, reader)

      # Reader no longer sees the board
      assert Boards.list_boards(reader) == []
    end
  end

  describe "update_user_access/3" do
    test "updates a user's access from read_only to modify" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, user, :read_only)
      assert Boards.get_user_access(board.id, user.id) == :read_only

      assert {:ok, board_user} = Boards.update_user_access(board, user, :modify)
      assert board_user.access == :modify
      assert Boards.get_user_access(board.id, user.id) == :modify
    end

    test "updates a user's access from modify to read_only" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, user, :modify)
      assert Boards.get_user_access(board.id, user.id) == :modify

      assert {:ok, board_user} = Boards.update_user_access(board, user, :read_only)
      assert board_user.access == :read_only
      assert Boards.get_user_access(board.id, user.id) == :read_only
    end

    test "prevents updating a user's access to owner when board already has an owner" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, user, :modify)

      assert_raise Ecto.ConstraintError, fn ->
        Boards.update_user_access(board, user, :owner)
      end
    end

    test "returns error when user is not on the board" do
      owner = user_fixture()
      board = board_fixture(owner)
      other_user = user_fixture()

      assert {:error, :not_found} = Boards.update_user_access(board, other_user, :modify)
    end
  end

  describe "list_boards/1 with shared access" do
    test "returns boards shared with user" do
      owner = user_fixture()
      reader = user_fixture()

      _board1 = board_fixture(owner, %{name: "Owner's Board"})
      board2 = board_fixture(owner, %{name: "Shared Board"})

      {:ok, _} = Boards.add_user_to_board(board2, reader, :read_only)

      boards = Boards.list_boards(reader)

      assert length(boards) == 1
      assert hd(boards).id == board2.id
      assert hd(boards).name == "Shared Board"
    end

    test "returns both owned and shared boards" do
      user1 = user_fixture()
      user2 = user_fixture()

      owned_board = board_fixture(user1, %{name: "My Board"})
      other_board = board_fixture(user2, %{name: "Shared with Me"})

      {:ok, _} = Boards.add_user_to_board(other_board, user1, :modify)

      boards = Boards.list_boards(user1)

      assert length(boards) == 2
      board_ids = Enum.map(boards, & &1.id)
      assert owned_board.id in board_ids
      assert other_board.id in board_ids
    end
  end
end
