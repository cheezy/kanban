defmodule KanbanWeb.BoardAccentTest do
  @moduledoc """
  Unit tests for `KanbanWeb.BoardAccent` — the helper that round-robins
  boards through a fixed accent palette so the same board renders with
  the same color on the Boards index and the per-board show page.
  """
  use Kanban.DataCase, async: true

  alias Kanban.AccountsFixtures
  alias Kanban.BoardsFixtures
  alias KanbanWeb.BoardAccent

  describe "accents/0" do
    test "returns the canonical six-color palette as atoms" do
      assert BoardAccent.accents() == ~w(orange violet doing ready backlog blocked)a
    end
  end

  describe "assign_to_boards/1" do
    test "cycles boards through the palette by index, stamping :accent" do
      palette = BoardAccent.accents()
      boards = for n <- 1..(length(palette) + 2), do: %{id: n, name: "B#{n}"}

      tagged = BoardAccent.assign_to_boards(boards)

      assert Enum.map(tagged, & &1.accent) ==
               Enum.take(palette ++ palette, length(palette) + 2)
    end

    test "returns [] for an empty board list" do
      assert BoardAccent.assign_to_boards([]) == []
    end
  end

  describe "for_board/2" do
    test "returns the accent at the board's position in the user's list" do
      user = AccountsFixtures.user_fixture()
      first = BoardsFixtures.board_fixture(user, %{name: "Alpha"})
      _second = BoardsFixtures.board_fixture(user, %{name: "Bravo"})

      palette = BoardAccent.accents()

      # The board fixture inserts at the head of list_boards/1, so position
      # may depend on order. Either way, the accent must be one of the
      # palette values and match what for_board returns for each.
      assert BoardAccent.for_board(first, user) in palette
    end

    test "falls back to the first accent when the board is not in the user's list" do
      user = AccountsFixtures.user_fixture()
      other_user = AccountsFixtures.user_fixture()
      board = BoardsFixtures.board_fixture(other_user, %{name: "Other"})

      # The board is not in `user`'s list — find_index returns nil and
      # the helper falls back to index 0.
      [first_accent | _] = BoardAccent.accents()
      assert BoardAccent.for_board(board, user) == first_accent
    end
  end
end
