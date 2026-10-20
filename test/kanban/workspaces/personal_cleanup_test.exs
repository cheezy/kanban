defmodule Kanban.Workspaces.PersonalCleanupTest do
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Workspaces

  setup do
    user = user_fixture()
    workspace = Workspaces.get_personal_workspace(user)

    # A board in the user's personal workspace with no board_users rows; each
    # test adds the rows it needs, in the order they should be read.
    board = place_board_in_workspace(workspace)
    from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.delete_all()

    %{user: user, board: board}
  end

  defp add_member(board, user, access \\ :modify) do
    Repo.insert!(%BoardUser{board_id: board.id, user_id: user.id, access: access})
  end

  defp disabled_user_fixture(attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp disable(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp home_of(board), do: Repo.get!(Board, board.id).workspace_id

  defp personal_workspace_id(user), do: Workspaces.get_personal_workspace(user).id

  test "gives the board to another enabled owner before an earlier member", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    add_member(board, user_fixture())
    owner = user_fixture()
    add_member(board, owner, :owner)

    assert {:ok, %{rehomed: [{board_id, owner_id}], deleted: []}} =
             Workspaces.clear_personal_boards(user)

    assert {board_id, owner_id} == {board.id, owner.id}
    assert home_of(board) == personal_workspace_id(owner)
  end

  test "skips a disabled owner and gives the board to the earliest enabled member", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    add_member(board, disabled_user_fixture(), :owner)
    member = user_fixture()
    add_member(board, member)

    assert {:ok, %{rehomed: [{_board_id, member_id}]}} = Workspaces.clear_personal_boards(user)

    assert member_id == member.id
    assert home_of(board) == personal_workspace_id(member)
  end

  test "skips a disabled member listed before an enabled one", %{user: user, board: board} do
    add_member(board, user)
    disabled = disabled_user_fixture()
    add_member(board, disabled)
    enabled = user_fixture()
    add_member(board, enabled)

    assert {:ok, %{rehomed: [{_board_id, target_id}]}} = Workspaces.clear_personal_boards(user)

    assert target_id == enabled.id
    assert home_of(board) == personal_workspace_id(enabled)
    refute home_of(board) == personal_workspace_id(disabled)
  end

  test "gives a board whose other members are all disabled to the earliest enabled admin", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    add_member(board, disabled_user_fixture(), :owner)
    add_member(board, disabled_user_fixture())
    admin_fixture() |> disable()
    admin = admin_fixture()

    assert {:ok, %{rehomed: [{_board_id, target_id}]}} = Workspaces.clear_personal_boards(user)

    assert target_id == admin.id
    assert home_of(board) == personal_workspace_id(admin)
  end

  test "deletes a board whose other members are all disabled when no enabled admin exists", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    add_member(board, disabled_user_fixture())
    admin_fixture() |> disable()

    assert {:ok, %{deleted: [%Board{id: board_id}], rehomed: []}} =
             Workspaces.clear_personal_boards(user)

    assert board_id == board.id
    refute Repo.get(Board, board.id)
  end

  test "skips a disabled admin for a board with no members", %{user: user, board: board} do
    admin_fixture() |> disable()
    admin = admin_fixture()

    assert {:ok, %{rehomed: [{_board_id, target_id}]}} = Workspaces.clear_personal_boards(user)

    assert target_id == admin.id
    assert home_of(board) == personal_workspace_id(admin)
  end

  test "deletes a board only the user uses, even when an enabled admin exists", %{
    user: user,
    board: board
  } do
    add_member(board, user, :owner)
    admin_fixture()

    assert {:ok, %{deleted: [%Board{}], rehomed: []}} = Workspaces.clear_personal_boards(user)
    refute Repo.get(Board, board.id)
  end
end
