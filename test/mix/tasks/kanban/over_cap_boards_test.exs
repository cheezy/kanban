defmodule Mix.Tasks.Kanban.OverCapBoardsTest do
  # async: false — swaps the process-wide Mix shell.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureIO
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Mix.Tasks.Kanban.OverCapBoards

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  defp personal_board_with_members(extra, owner_attrs \\ %{}) do
    owner = user_fixture(owner_attrs)
    board = board_fixture(owner, %{name: "Over Cap Board #{System.unique_integer([:positive])}"})

    for _ <- List.duplicate(nil, extra) do
      {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)
    end

    %{owner: owner, board: board}
  end

  defp snapshot do
    {Repo.aggregate(Board, :count), Repo.aggregate(BoardUser, :count)}
  end

  test "prints a no-boards message when no board is over the cap" do
    personal_board_with_members(2)

    output = capture_io(fn -> assert OverCapBoards.run([]) == :ok end)

    assert output == "No personal-workspace boards are over the free member cap of 3.\n"
  end

  test "prints a summary line and one line per board, without names or emails" do
    %{owner: first_owner, board: first} =
      personal_board_with_members(3, %{email: "first-owner-w2402@example.com"})

    %{owner: second_owner, board: second} = personal_board_with_members(4)
    personal_board_with_members(1)
    before = snapshot()

    output = capture_io(fn -> assert OverCapBoards.run([]) == :ok end)

    assert output ==
             """
             2 personal-workspace board(s) over the free member cap of 3:
               board #{first.id} — owner user #{first_owner.id}, 4 members
               board #{second.id} — owner user #{second_owner.id}, 5 members
             """

    refute output =~ first.name
    refute output =~ first_owner.email
    refute output =~ second_owner.email
    assert snapshot() == before
  end

  test "prints none for a board with no owner row" do
    %{board: board} = personal_board_with_members(4)

    {1, _} =
      from(bu in BoardUser, where: bu.board_id == ^board.id and bu.access == :owner)
      |> Repo.delete_all()

    output = capture_io(fn -> OverCapBoards.run([]) end)

    assert output =~ "  board #{board.id} — owner user none, 4 members\n"
  end
end
