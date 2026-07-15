defmodule Kanban.Boards.MembershipTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Boards

  describe "board_counts_by_user/0" do
    test "returns an empty map when nobody belongs to a board" do
      _user = user_fixture()

      assert Boards.board_counts_by_user() == %{}
    end

    test "counts each user's boards" do
      user = user_fixture()
      _one = board_fixture(user)
      _two = board_fixture(user)

      assert %{} = counts = Boards.board_counts_by_user()
      assert counts[user.id] == 2
    end

    test "omits users with no boards rather than reporting zero" do
      with_board = user_fixture()
      without_board = user_fixture()
      _board = board_fixture(with_board)

      counts = Boards.board_counts_by_user()

      assert counts[with_board.id] == 1
      refute Map.has_key?(counts, without_board.id)
      assert Map.get(counts, without_board.id, 0) == 0
    end

    test "counts each user separately" do
      one = user_fixture()
      two = user_fixture()
      _a = board_fixture(one)
      _b = board_fixture(one)
      _c = board_fixture(two)

      counts = Boards.board_counts_by_user()

      assert counts[one.id] == 2
      assert counts[two.id] == 1
    end

    test "counts a board the user was added to, not only ones they own" do
      owner = user_fixture()
      member = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      counts = Boards.board_counts_by_user()

      assert counts[member.id] == 1
    end
  end
end
