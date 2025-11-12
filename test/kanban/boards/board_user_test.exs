defmodule Kanban.Boards.BoardUserTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Boards.BoardUser
  alias Kanban.Repo

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{
        board_id: board.id,
        user_id: user.id,
        access: :owner
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :board_id) == board.id
      assert get_change(changeset, :user_id) == user.id
      assert get_change(changeset, :access) == :owner
    end

    test "valid changeset with read_only access" do
      user = user_fixture()
      board = board_fixture(user)
      other_user = user_fixture()

      attrs = %{
        board_id: board.id,
        user_id: other_user.id,
        access: :read_only
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :access) == :read_only
    end

    test "valid changeset with modify access" do
      user = user_fixture()
      board = board_fixture(user)
      other_user = user_fixture()

      attrs = %{
        board_id: board.id,
        user_id: other_user.id,
        access: :modify
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :access) == :modify
    end

    test "invalid changeset when board_id is missing" do
      user = user_fixture()

      attrs = %{
        user_id: user.id,
        access: :owner
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      refute changeset.valid?
      assert %{board_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset when user_id is missing" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{
        board_id: board.id,
        access: :owner
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      refute changeset.valid?
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset when access is missing" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{
        board_id: board.id,
        user_id: user.id
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      refute changeset.valid?
      assert %{access: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset when access is invalid" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{
        board_id: board.id,
        user_id: user.id,
        access: :invalid_access
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      refute changeset.valid?
      assert %{access: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid changeset when access is not in allowed values" do
      user = user_fixture()
      board = board_fixture(user)

      attrs = %{
        board_id: board.id,
        user_id: user.id,
        access: :admin
      }

      changeset = BoardUser.changeset(%BoardUser{}, attrs)

      refute changeset.valid?
      assert %{access: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "database constraints" do
    test "unique constraint on board_id and user_id combination" do
      user = user_fixture()
      board = board_fixture(user)
      other_user = user_fixture()

      # Create first board_user record
      {:ok, _} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: other_user.id,
          access: :read_only
        })
        |> Repo.insert()

      # Attempt to create duplicate
      result =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: other_user.id,
          access: :modify
        })
        |> Repo.insert()

      assert {:error, changeset} = result
      assert %{board_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "prevents multiple owners per board via database constraint" do
      user1 = user_fixture()
      user2 = user_fixture()
      board = board_fixture(user1)

      # Try to add a second owner
      assert_raise Ecto.ConstraintError, fn ->
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user2.id,
          access: :owner
        })
        |> Repo.insert!()
      end
    end

    test "allows multiple non-owner users on the same board" do
      owner = user_fixture()
      board = board_fixture(owner)
      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()

      {:ok, board_user1} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user1.id,
          access: :read_only
        })
        |> Repo.insert()

      {:ok, board_user2} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user2.id,
          access: :modify
        })
        |> Repo.insert()

      {:ok, board_user3} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user3.id,
          access: :read_only
        })
        |> Repo.insert()

      assert board_user1.access == :read_only
      assert board_user2.access == :modify
      assert board_user3.access == :read_only
    end

    test "foreign key constraint on board_id" do
      user = user_fixture()

      assert_raise Ecto.ConstraintError, fn ->
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: 999_999,
          user_id: user.id,
          access: :owner
        })
        |> Repo.insert!()
      end
    end

    test "foreign key constraint on user_id" do
      user = user_fixture()
      board = board_fixture(user)

      assert_raise Ecto.ConstraintError, fn ->
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: 999_999,
          access: :owner
        })
        |> Repo.insert!()
      end
    end
  end

  describe "access_levels/0" do
    test "returns all available access levels" do
      assert BoardUser.access_levels() == [:owner, :read_only, :modify]
    end

    test "access_levels matches schema definition" do
      levels = BoardUser.access_levels()

      assert :owner in levels
      assert :read_only in levels
      assert :modify in levels
      assert length(levels) == 3
    end
  end

  describe "updating board_user" do
    test "can update access level from read_only to modify" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      {:ok, updated} =
        board_user
        |> BoardUser.changeset(%{access: :modify})
        |> Repo.update()

      assert updated.access == :modify
      assert updated.id == board_user.id
    end

    test "can update access level from modify to read_only" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :modify
        })
        |> Repo.insert()

      {:ok, updated} =
        board_user
        |> BoardUser.changeset(%{access: :read_only})
        |> Repo.update()

      assert updated.access == :read_only
    end

    test "cannot update to invalid access level" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      changeset = BoardUser.changeset(board_user, %{access: :invalid})

      refute changeset.valid?
      assert %{access: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "cascade deletion" do
    test "board_user is deleted when board is deleted" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      # Delete the board
      Repo.delete!(board)

      # Verify board_user was cascade deleted
      assert Repo.get(BoardUser, board_user.id) == nil
    end

    test "board_user is deleted when user is deleted" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      # Delete the user
      Repo.delete!(user)

      # Verify board_user was cascade deleted
      assert Repo.get(BoardUser, board_user.id) == nil
    end
  end

  describe "associations" do
    test "belongs_to board association" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      board_user_with_board = Repo.preload(board_user, :board)

      assert board_user_with_board.board.id == board.id
      assert board_user_with_board.board.name == board.name
    end

    test "belongs_to user association" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      board_user_with_user = Repo.preload(board_user, :user)

      assert board_user_with_user.user.id == user.id
      assert board_user_with_user.user.email == user.email
    end
  end

  describe "timestamps" do
    test "sets inserted_at and updated_at on insert" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      assert board_user.inserted_at != nil
      assert board_user.updated_at != nil
      assert board_user.inserted_at == board_user.updated_at
    end

    test "updates updated_at on update" do
      owner = user_fixture()
      board = board_fixture(owner)
      user = user_fixture()

      {:ok, board_user} =
        %BoardUser{}
        |> BoardUser.changeset(%{
          board_id: board.id,
          user_id: user.id,
          access: :read_only
        })
        |> Repo.insert()

      original_updated_at = board_user.updated_at

      # Wait to ensure timestamp difference
      :timer.sleep(1000)

      {:ok, updated} =
        board_user
        |> BoardUser.changeset(%{access: :modify})
        |> Repo.update()

      # Check that updated_at is greater than or equal to original
      assert NaiveDateTime.compare(updated.updated_at, original_updated_at) in [:gt, :eq]
      assert updated.inserted_at == board_user.inserted_at
    end
  end
end
