defmodule Kanban.BoardsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Tasks

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

  describe "get_board/2" do
    test "returns {:ok, board} when board belongs to the user" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, fetched_board} = Boards.get_board(board.id, user)
      assert fetched_board.id == board.id
      assert fetched_board.name == board.name
    end

    test "returns {:error, :not_found} when board does not exist" do
      user = user_fixture()

      assert {:error, :not_found} = Boards.get_board(999_999, user)
    end

    test "returns {:error, :not_found} when board belongs to a different user" do
      user1 = user_fixture()
      user2 = user_fixture()
      board = board_fixture(user1)

      assert {:error, :not_found} = Boards.get_board(board.id, user2)
    end

    test "accepts string ID and converts to integer" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, fetched_board} = board.id |> Integer.to_string() |> Boards.get_board(user)
      assert fetched_board.id == board.id
    end

    test "returns {:error, :not_found} for invalid string ID" do
      user = user_fixture()

      assert {:error, :not_found} = Boards.get_board("not_a_number", user)
    end

    test "returns {:error, :not_found} for string ID with trailing characters" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:error, :not_found} = Boards.get_board("#{board.id}abc", user)
    end

    test "non-member can access read-only board" do
      owner = user_fixture()
      non_member = user_fixture()
      board = board_fixture(owner, %{name: "Public Board"})
      {:ok, board} = Boards.update_board(board, %{read_only: true}, owner)

      assert {:ok, fetched_board} = Boards.get_board(board.id, non_member)
      assert fetched_board.id == board.id
      assert fetched_board.user_access == nil
    end

    test "non-member cannot access private board" do
      owner = user_fixture()
      non_member = user_fixture()
      board = board_fixture(owner, %{name: "Private Board"})

      assert {:error, :not_found} = Boards.get_board(board.id, non_member)
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

    test "accepts string ID and converts to integer" do
      user = user_fixture()
      board = board_fixture(user)

      # Pass ID as string
      fetched_board = Integer.to_string(board.id) |> Boards.get_board!(user)

      assert fetched_board.id == board.id
      assert fetched_board.name == board.name
    end

    test "raises when string ID is not a valid integer" do
      user = user_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!("not_a_number", user)
      end
    end

    test "raises when string ID has trailing characters" do
      user = user_fixture()
      board = board_fixture(user)

      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!("#{board.id}abc", user)
      end
    end

    test "non-member can access read-only board" do
      owner = user_fixture()
      non_member = user_fixture()
      board = board_fixture(owner, %{name: "Public Board"})

      # Make the board read-only
      {:ok, board} = Boards.update_board(board, %{read_only: true}, owner)

      # Non-member should be able to access it with user_access: nil
      fetched_board = Boards.get_board!(board.id, non_member)
      assert fetched_board.id == board.id
      assert fetched_board.user_access == nil
    end

    test "non-member cannot access private board" do
      owner = user_fixture()
      non_member = user_fixture()
      board = board_fixture(owner, %{name: "Private Board"})

      # Board is private by default (read_only: false)
      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!(board.id, non_member)
      end
    end

    test "member gets their user_access regardless of read_only flag" do
      owner = user_fixture()
      member = user_fixture()
      board = board_fixture(owner, %{name: "Board"})

      # Add member with read_only access
      {:ok, _} = Boards.add_user_to_board(board, member, :read_only, owner)

      # Make board read-only
      {:ok, board} = Boards.update_board(board, %{read_only: true}, owner)

      # Member should get their actual access level
      fetched_board = Boards.get_board!(board.id, member)
      assert fetched_board.user_access == :read_only

      # Owner should still be owner
      owner_board = Boards.get_board!(board.id, owner)
      assert owner_board.user_access == :owner
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

      assert {:ok, %Board{} = updated_board} = Boards.update_board(board, attrs, user)
      assert updated_board.id == board.id
      assert updated_board.name == "New Name"
      assert updated_board.description == "New Description"
    end

    test "updates only the name" do
      user = user_fixture()
      board = board_fixture(user, %{name: "Old Name", description: "Description"})

      attrs = %{name: "New Name"}

      assert {:ok, %Board{} = updated_board} = Boards.update_board(board, attrs, user)
      assert updated_board.name == "New Name"
      assert updated_board.description == "Description"
    end

    test "updates only the description" do
      user = user_fixture()
      board = board_fixture(user, %{name: "Name1", description: "Old Description"})

      attrs = %{description: "New Description"}

      assert {:ok, %Board{} = updated_board} = Boards.update_board(board, attrs, user)
      assert updated_board.name == "Name1"
      assert updated_board.description == "New Description"
    end

    test "returns error changeset when name is invalid" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{name: ""}

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.update_board(board, attrs, user)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error changeset when name is too long" do
      user = user_fixture()
      board = board_fixture(user)

      long_name = String.duplicate("a", 256)
      attrs = %{name: long_name}

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.update_board(board, attrs, user)
      assert %{name: ["should be at most 50 character(s)"]} = errors_on(changeset)
    end
  end

  describe "delete_board/1" do
    test "deletes the board" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Board{}} = Boards.delete_board(board, user)
      assert_raise Ecto.NoResultsError, fn -> Boards.get_board!(board.id, user) end
    end

    test "deleted board is removed from user's board list" do
      user = user_fixture()
      board1 = board_fixture(user, %{name: "Board 1"})
      board2 = board_fixture(user, %{name: "Board 2"})

      assert length(Boards.list_boards(user)) == 2

      Boards.delete_board(board1, user)

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

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      assert Boards.get_user_access(board.id, reader.id) == :read_only
    end

    test "returns the access level for a user with modify access" do
      owner = user_fixture()
      board = board_fixture(owner)
      collaborator = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, collaborator, :modify, owner)

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

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      assert Boards.owner?(board, reader) == false
    end

    test "returns false when user has modify access" do
      owner = user_fixture()
      board = board_fixture(owner)
      collaborator = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, collaborator, :modify, owner)

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

      {:ok, _} = Boards.add_user_to_board(board, collaborator, :modify, owner)

      assert Boards.can_modify?(board, collaborator) == true
    end

    test "returns false when user has read_only access" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

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

      assert {:error, changeset} = Boards.add_user_to_board(board, new_user, :owner, owner)
      assert "board already has an owner" in errors_on(changeset).board_id
    end

    test "adds a user with read_only access" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      assert {:ok, board_user} = Boards.add_user_to_board(board, reader, :read_only, owner)
      assert board_user.access == :read_only

      # Verify user can see the board
      assert Boards.get_board!(board.id, reader)
    end

    test "adds a user with modify access" do
      owner = user_fixture()
      board = board_fixture(owner)
      collaborator = user_fixture()

      assert {:ok, board_user} = Boards.add_user_to_board(board, collaborator, :modify, owner)
      assert board_user.access == :modify

      # Verify user can see the board
      assert Boards.get_board!(board.id, collaborator)
    end

    test "returns error when adding duplicate user" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      assert {:error, changeset} = Boards.add_user_to_board(board, reader, :modify, owner)
      assert %{board_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "board appears in user's board list after being added" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      # Reader has no boards initially
      assert Boards.list_boards(reader) == []

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

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

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      # Verify user can see the board
      assert Boards.get_board!(board.id, reader)

      assert {:ok, _} = Boards.remove_user_from_board(board, reader, owner)

      # Verify user can no longer see the board
      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!(board.id, reader)
      end
    end

    test "returns error when user is not on the board" do
      owner = user_fixture()
      board = board_fixture(owner)
      other_user = user_fixture()

      assert {:error, :not_found} = Boards.remove_user_from_board(board, other_user, owner)
    end

    test "board is removed from user's board list after being removed" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      # Reader sees the board
      assert length(Boards.list_boards(reader)) == 1

      {:ok, _} = Boards.remove_user_from_board(board, reader, owner)

      # Reader no longer sees the board
      assert Boards.list_boards(reader) == []
    end
  end

  describe "update_user_access/3" do
    test "updates a user's access from read_only to modify" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, user, :read_only, owner)
      assert Boards.get_user_access(board.id, user.id) == :read_only

      assert {:ok, board_user} = Boards.update_user_access(board, user, :modify, owner)
      assert board_user.access == :modify
      assert Boards.get_user_access(board.id, user.id) == :modify
    end

    test "updates a user's access from modify to read_only" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, user, :modify, owner)
      assert Boards.get_user_access(board.id, user.id) == :modify

      assert {:ok, board_user} = Boards.update_user_access(board, user, :read_only, owner)
      assert board_user.access == :read_only
      assert Boards.get_user_access(board.id, user.id) == :read_only
    end

    test "prevents updating a user's access to owner when board already has an owner" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, user, :modify, owner)

      assert {:error, changeset} = Boards.update_user_access(board, user, :owner, owner)
      assert "board already has an owner" in errors_on(changeset).board_id
    end

    test "returns error when user is not on the board" do
      owner = user_fixture()
      board = board_fixture(owner)
      other_user = user_fixture()

      assert {:error, :not_found} = Boards.update_user_access(board, other_user, :modify, owner)
    end
  end

  describe "list_boards/1 with shared access" do
    test "returns boards shared with user" do
      owner = user_fixture()
      reader = user_fixture()

      _board1 = board_fixture(owner, %{name: "Owner's Board"})
      board2 = board_fixture(owner, %{name: "Shared Board"})

      {:ok, _} = Boards.add_user_to_board(board2, reader, :read_only, owner)

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

      {:ok, _} = Boards.add_user_to_board(other_board, user1, :modify, user2)

      boards = Boards.list_boards(user1)

      assert length(boards) == 2
      board_ids = Enum.map(boards, & &1.id)
      assert owned_board.id in board_ids
      assert other_board.id in board_ids
    end
  end

  describe "create_ai_optimized_board/2" do
    test "creates board with ai_optimized_board flag set" do
      user = user_fixture()
      {:ok, board} = Boards.create_ai_optimized_board(user, %{name: "AI Board"})

      assert board.ai_optimized_board == true
      assert board.name == "AI Board"
    end

    test "creates five default columns in correct order" do
      user = user_fixture()
      {:ok, board} = Boards.create_ai_optimized_board(user, %{name: "AI Board"})

      column_names = Enum.map(board.columns, & &1.name)
      assert column_names == ["Backlog", "Ready", "Doing", "Review", "Done"]
    end

    test "sets user as owner" do
      user = user_fixture()
      {:ok, board} = Boards.create_ai_optimized_board(user, %{name: "AI Board"})

      assert Boards.owner?(board, user)
      assert Boards.get_user_access(board.id, user.id) == :owner
    end

    test "returns error when name is missing" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Boards.create_ai_optimized_board(user, %{})
    end

    test "returns error when name is too long" do
      user = user_fixture()
      long_name = String.duplicate("a", 256)

      assert {:error, %Ecto.Changeset{}} =
               Boards.create_ai_optimized_board(user, %{name: long_name})
    end

    test "works with default empty attrs" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Boards.create_ai_optimized_board(user)
    end
  end

  describe "list_board_users/1" do
    test "returns users with their access levels" do
      owner = user_fixture()
      board = board_fixture(owner)

      users = Boards.list_board_users(board)

      assert length(users) == 1
      assert hd(users).access == :owner
      assert hd(users).user.id == owner.id
    end

    test "returns multiple users sorted by access priority" do
      owner = user_fixture()
      board = board_fixture(owner)
      modify_user = user_fixture()
      read_only_user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, read_only_user, :read_only, owner)
      {:ok, _} = Boards.add_user_to_board(board, modify_user, :modify, owner)

      users = Boards.list_board_users(board)

      assert length(users) == 3
      access_levels = Enum.map(users, & &1.access)
      assert access_levels == [:owner, :modify, :read_only]
    end

    test "sorts alphabetically by email within same access level" do
      owner = user_fixture()
      board = board_fixture(owner)

      user_b = user_fixture(%{email: "bravo@example.com"})
      user_a = user_fixture(%{email: "alpha@example.com"})

      {:ok, _} = Boards.add_user_to_board(board, user_b, :read_only, owner)
      {:ok, _} = Boards.add_user_to_board(board, user_a, :read_only, owner)

      users = Boards.list_board_users(board)
      read_only_users = Enum.filter(users, &(&1.access == :read_only))

      emails = Enum.map(read_only_users, & &1.user.email)
      assert emails == ["alpha@example.com", "bravo@example.com"]
    end

    test "returns only users for the specified board" do
      owner = user_fixture()
      board1 = board_fixture(owner)
      board2 = board_fixture(owner)
      other_user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board2, other_user, :modify, owner)

      users = Boards.list_board_users(board1)
      assert length(users) == 1
      assert hd(users).user.id == owner.id
    end
  end

  describe "update_field_visibility/3" do
    test "owner can update field visibility" do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      new_visibility =
        Map.put(board.field_visibility, "complexity", false)

      assert {:ok, updated_board} =
               Boards.update_field_visibility(board, new_visibility, owner)

      assert updated_board.field_visibility["complexity"] == false
    end

    test "persists changes to the database" do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      new_visibility =
        board.field_visibility
        |> Map.put("complexity", false)
        |> Map.put("key_files", false)

      {:ok, _} = Boards.update_field_visibility(board, new_visibility, owner)

      reloaded = Boards.get_board!(board.id, owner)
      assert reloaded.field_visibility["complexity"] == false
      assert reloaded.field_visibility["key_files"] == false
    end

    test "returns unauthorized for non-owner" do
      owner = user_fixture()
      board = board_fixture(owner)
      other_user = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, other_user, :modify, owner)

      assert {:error, :unauthorized} =
               Boards.update_field_visibility(board, %{"complexity" => false}, other_user)
    end

    test "returns unauthorized for read-only user" do
      owner = user_fixture()
      board = board_fixture(owner)
      reader = user_fixture()

      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      assert {:error, :unauthorized} =
               Boards.update_field_visibility(board, %{"complexity" => false}, reader)
    end

    test "returns unauthorized for user with no access" do
      owner = user_fixture()
      board = board_fixture(owner)
      stranger = user_fixture()

      assert {:error, :unauthorized} =
               Boards.update_field_visibility(board, %{"complexity" => false}, stranger)
    end

    test "broadcasts field_visibility_updated via PubSub" do
      owner = user_fixture()
      board = ai_optimized_board_fixture(owner)

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      new_visibility = Map.put(board.field_visibility, "complexity", false)
      {:ok, _} = Boards.update_field_visibility(board, new_visibility, owner)

      assert_receive {:field_visibility_updated, received_visibility}
      assert received_visibility["complexity"] == false
    end
  end

  # ── W396 authorization tests ──
  #
  # The 5 mutators (update_board, delete_board, add_user_to_board,
  # remove_user_from_board, update_user_access) all require the caller to be
  # the board owner. These tests assert the new {:error, :unauthorized}
  # behavior for non-owners across each mutator.

  describe "W396: mutator authorization" do
    setup do
      owner = user_fixture()
      stranger = user_fixture()
      modify_user = user_fixture()
      read_only_user = user_fixture()
      board = board_fixture(owner)

      {:ok, _} = Boards.add_user_to_board(board, modify_user, :modify, owner)
      {:ok, _} = Boards.add_user_to_board(board, read_only_user, :read_only, owner)

      %{
        owner: owner,
        stranger: stranger,
        modify_user: modify_user,
        read_only_user: read_only_user,
        board: board
      }
    end

    test "update_board: non-owner :modify returns :unauthorized",
         %{board: board, modify_user: u} do
      assert {:error, :unauthorized} = Boards.update_board(board, %{name: "Hacked"}, u)
    end

    test "update_board: stranger returns :unauthorized",
         %{board: board, stranger: u} do
      assert {:error, :unauthorized} = Boards.update_board(board, %{name: "Hacked"}, u)
    end

    test "update_board: owner cannot have read_only mass-assigned via base changeset",
         %{board: board, owner: owner} do
      # Owner still succeeds and read_only flips through owner_changeset.
      assert {:ok, updated} = Boards.update_board(board, %{read_only: true}, owner)
      assert updated.read_only == true

      # change_board still uses the public (non-owner) changeset which excludes read_only.
      changeset = Boards.change_board(board, %{read_only: true})
      refute Map.has_key?(changeset.changes, :read_only)
    end

    test "delete_board: non-owner :modify returns :unauthorized",
         %{board: board, modify_user: u} do
      assert {:error, :unauthorized} = Boards.delete_board(board, u)
    end

    test "delete_board: stranger returns :unauthorized",
         %{board: board, stranger: u} do
      assert {:error, :unauthorized} = Boards.delete_board(board, u)
    end

    test "add_user_to_board: non-owner :modify returns :unauthorized",
         %{board: board, modify_user: actor} do
      victim = user_fixture()
      assert {:error, :unauthorized} = Boards.add_user_to_board(board, victim, :modify, actor)
    end

    test "remove_user_from_board: non-owner :modify returns :unauthorized",
         %{board: board, modify_user: actor, read_only_user: target} do
      assert {:error, :unauthorized} = Boards.remove_user_from_board(board, target, actor)
    end

    test "update_user_access: non-owner :modify returns :unauthorized",
         %{board: board, modify_user: actor, read_only_user: target} do
      assert {:error, :unauthorized} = Boards.update_user_access(board, target, :modify, actor)
    end

    test "update_user_access: stranger returns :unauthorized",
         %{board: board, stranger: stranger, read_only_user: target} do
      assert {:error, :unauthorized} = Boards.update_user_access(board, target, :modify, stranger)
    end
  end

  describe "list_boards_with_metrics/2" do
    setup do
      user = user_fixture()
      now = ~U[2026-05-15 12:00:00Z]
      %{user: user, now: now}
    end

    test "returns empty list when user has no boards", %{user: user, now: now} do
      assert Boards.list_boards_with_metrics(user, now: now) == []
    end

    test "returns the expected metrics shape for an empty board", %{user: user, now: now} do
      board = ai_optimized_board_fixture(user, %{name: "Empty Board"})

      assert [%Board{id: board_id, metrics: metrics}] =
               Boards.list_boards_with_metrics(user, now: now)

      assert board_id == board.id

      assert metrics == %{
               open: 0,
               doing: 0,
               review: 0,
               done: 0,
               throughput_14d: 0,
               pulse_14d: List.duplicate(0, 14),
               active_agents_14d: 0,
               last_activity_at: nil
             }
    end

    test "counts open/doing/review/done by column name", %{user: user, now: now} do
      board = ai_optimized_board_fixture(user, %{name: "Counts Board"})
      cols = columns_by_name(board)

      _backlog_task = task_fixture(cols["Backlog"], %{title: "B1"})
      _ready_a = task_fixture(cols["Ready"], %{title: "R1"})
      _ready_b = task_fixture(cols["Ready"], %{title: "R2"})
      _doing_task = task_fixture(cols["Doing"], %{title: "D1"})
      _review_a = task_fixture(cols["Review"], %{title: "V1"})
      _review_b = task_fixture(cols["Review"], %{title: "V2"})
      _done_task = task_fixture(cols["Done"], %{title: "Z1"})

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      # Backlog (1) + Ready (2) -> open: 3
      assert metrics.open == 3
      assert metrics.doing == 1
      assert metrics.review == 2
      assert metrics.done == 1
    end

    test "excludes archived tasks from the four buckets", %{user: user, now: now} do
      board = ai_optimized_board_fixture(user, %{name: "Archive Board"})
      cols = columns_by_name(board)

      _active = task_fixture(cols["Ready"], %{title: "Active"})
      archived = task_fixture(cols["Ready"], %{title: "Archived"})
      {:ok, _} = Tasks.update_task(archived, %{archived_at: now})

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      assert metrics.open == 1
    end

    test "excludes goals from the four buckets", %{user: user, now: now} do
      board = ai_optimized_board_fixture(user, %{name: "Goal Board"})
      cols = columns_by_name(board)

      _work_task = task_fixture(cols["Ready"], %{title: "Work", type: :work})
      _goal_task = task_fixture(cols["Ready"], %{title: "Goal", type: :goal})

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      assert metrics.open == 1
    end

    test "ignores tasks in custom-named columns for the four buckets", %{user: user, now: now} do
      board = board_fixture(user, %{name: "Custom Board"})
      {:ok, custom_col} = Kanban.Columns.create_column(board, %{name: "Triage", wip_limit: 0})
      _task = task_fixture(custom_col)

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      assert metrics.open == 0
      assert metrics.doing == 0
      assert metrics.review == 0
      assert metrics.done == 0
    end

    test "pulse_14d is exactly 14 elements with the most recent day LAST", %{user: user, now: now} do
      board = ai_optimized_board_fixture(user, %{name: "Pulse Board"})
      cols = columns_by_name(board)

      # Complete one task today (anchored to `now`) and one 5 days ago.
      done = cols["Done"]
      today_task = task_fixture(done, %{title: "Today"})
      old_task = task_fixture(done, %{title: "Five days ago"})

      {:ok, _} =
        Tasks.update_task(today_task, %{completed_at: now, completed_by_agent: "Claude"})

      five_days_ago = DateTime.add(now, -5, :day)

      {:ok, _} =
        Tasks.update_task(old_task, %{completed_at: five_days_ago, completed_by_agent: "GPT"})

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      assert length(metrics.pulse_14d) == 14
      # Today is the LAST element
      assert List.last(metrics.pulse_14d) == 1
      # Index 8 (zero-indexed) corresponds to 5 days ago: 13 - 5 = 8.
      assert Enum.at(metrics.pulse_14d, 8) == 1
      # Everything else is zero.
      assert Enum.sum(metrics.pulse_14d) == 2
      assert metrics.throughput_14d == 2
    end

    test "completions older than 14 days do not appear in pulse or throughput", %{
      user: user,
      now: now
    } do
      board = ai_optimized_board_fixture(user, %{name: "Old Completions"})
      cols = columns_by_name(board)
      old_task = task_fixture(cols["Done"], %{title: "Ancient"})

      # 30 days ago — well outside the 14-day window.
      ancient = DateTime.add(now, -30, :day)

      {:ok, _} =
        Tasks.update_task(old_task, %{completed_at: ancient, completed_by_agent: "Claude"})

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      assert metrics.throughput_14d == 0
      assert metrics.pulse_14d == List.duplicate(0, 14)
      assert metrics.active_agents_14d == 0
      # Last activity does pick it up — it's the latest completed_at on record.
      assert metrics.last_activity_at == DateTime.truncate(ancient, :second)
    end

    test "no recent activity returns last_activity_at = nil for a fresh board", %{
      user: user,
      now: now
    } do
      board = ai_optimized_board_fixture(user, %{name: "Fresh Board"})
      cols = columns_by_name(board)
      _ = task_fixture(cols["Ready"], %{title: "Open task"})

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      assert metrics.last_activity_at == nil
    end

    test "active_agents_14d counts DISTINCT completed_by_agent within 14 days", %{
      user: user,
      now: now
    } do
      board = ai_optimized_board_fixture(user, %{name: "Agents Board"})
      cols = columns_by_name(board)

      one = task_fixture(cols["Done"], %{title: "T1"})
      two = task_fixture(cols["Done"], %{title: "T2"})
      three = task_fixture(cols["Done"], %{title: "T3"})

      {:ok, _} = Tasks.update_task(one, %{completed_at: now, completed_by_agent: "Claude"})

      {:ok, _} =
        Tasks.update_task(two, %{
          completed_at: DateTime.add(now, -2, :day),
          completed_by_agent: "Claude"
        })

      {:ok, _} =
        Tasks.update_task(three, %{
          completed_at: DateTime.add(now, -3, :day),
          completed_by_agent: "GPT-4"
        })

      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)

      assert metrics.active_agents_14d == 2
    end

    test "last_activity_at picks the latest of claimed_at and completed_at", %{
      user: user,
      now: now
    } do
      board = ai_optimized_board_fixture(user, %{name: "Activity Board"})
      cols = columns_by_name(board)

      claim_time = DateTime.add(now, -2, :hour)
      older_completion = DateTime.add(now, -10, :hour)
      claimed = task_fixture(cols["Doing"], %{title: "Recent claim"})
      older = task_fixture(cols["Done"], %{title: "Older completion"})

      {:ok, _} = Tasks.update_task(claimed, %{claimed_at: claim_time})
      {:ok, _} = Tasks.update_task(older, %{completed_at: older_completion})

      # Recent claim wins over older completion.
      [%Board{metrics: metrics}] = Boards.list_boards_with_metrics(user, now: now)
      assert metrics.last_activity_at == DateTime.truncate(claim_time, :second)

      # Now add a completion that is more recent than the claim.
      newest = task_fixture(cols["Done"], %{title: "Newest"})
      {:ok, _} = Tasks.update_task(newest, %{completed_at: now})

      [%Board{metrics: metrics2}] = Boards.list_boards_with_metrics(user, now: now)
      assert metrics2.last_activity_at == DateTime.truncate(now, :second)
    end

    test "does NOT return boards the user has no access to", %{user: user, now: now} do
      _mine = ai_optimized_board_fixture(user, %{name: "Mine Board"})

      other = user_fixture()
      _theirs = ai_optimized_board_fixture(other, %{name: "Theirs Board"})

      boards = Boards.list_boards_with_metrics(user, now: now)
      assert length(boards) == 1
      assert hd(boards).name == "Mine Board"
    end

    test "populates the :members list with each board's users", %{user: user, now: now} do
      board = ai_optimized_board_fixture(user, %{name: "Members Board"})
      teammate = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, teammate, :modify, user)

      [%Board{members: members}] = Boards.list_boards_with_metrics(user, now: now)

      assert length(members) == 2
      assert Enum.all?(members, &(&1.kind == :human))

      palettes = Enum.map(members, & &1.palette)
      assert Enum.all?(palettes, &(&1 in ~w(human-blue human-amber human-green human-pink)))
    end

    test "members display name falls back to email local-part when name is blank",
         %{user: _user, now: now} do
      user = user_fixture()
      _board = ai_optimized_board_fixture(user, %{name: "Solo Board"})

      [%Board{members: [member]}] = Boards.list_boards_with_metrics(user, now: now)

      assert member.kind == :human
      assert is_binary(member.name)
      refute String.contains?(member.name, "@")
    end

    test "returns boards in the same order as list_boards/1", %{user: user, now: now} do
      _ = ai_optimized_board_fixture(user, %{name: "First"})
      _ = ai_optimized_board_fixture(user, %{name: "Second"})
      _ = ai_optimized_board_fixture(user, %{name: "Third"})

      list_only = Boards.list_boards(user) |> Enum.map(& &1.id)
      with_metrics = Boards.list_boards_with_metrics(user, now: now) |> Enum.map(& &1.id)

      assert with_metrics == list_only
    end

    test "aggregates each board independently (no cross-board leakage)", %{user: user, now: now} do
      a = ai_optimized_board_fixture(user, %{name: "Board A"})
      b = ai_optimized_board_fixture(user, %{name: "Board B"})
      cols_a = columns_by_name(a)
      cols_b = columns_by_name(b)

      _ = task_fixture(cols_a["Ready"], %{title: "A open"})
      _ = task_fixture(cols_b["Doing"], %{title: "B doing"})

      done_b = task_fixture(cols_b["Done"], %{title: "B done"})
      {:ok, _} = Tasks.update_task(done_b, %{completed_at: now, completed_by_agent: "Claude"})

      results = Boards.list_boards_with_metrics(user, now: now)
      by_id = Map.new(results, &{&1.id, &1.metrics})

      assert by_id[a.id].open == 1
      assert by_id[a.id].doing == 0
      assert by_id[a.id].throughput_14d == 0

      assert by_id[b.id].open == 0
      assert by_id[b.id].doing == 1
      assert by_id[b.id].throughput_14d == 1
      assert by_id[b.id].active_agents_14d == 1
    end

    defp columns_by_name(board) do
      board
      |> Kanban.Repo.preload(:columns)
      |> Map.fetch!(:columns)
      |> Map.new(fn col -> {col.name, col} end)
    end
  end
end
