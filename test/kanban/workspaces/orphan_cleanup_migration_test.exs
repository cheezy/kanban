defmodule Kanban.Workspaces.OrphanCleanupMigrationTest do
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @cleanup "priv/repo/migrations/20261018173500_delete_orphaned_personal_workspaces.exs"

  setup_all do
    [{cleanup, _bytecode}] = Code.require_file(@cleanup)
    %{cleanup: cleanup}
  end

  defp run(migration), do: Enum.each(migration.cleanup_statements(), &Repo.query!/1)

  defp workspace_ids, do: Workspace |> select([w], w.id) |> order_by([w], w.id) |> Repo.all()

  # Leaves `user`'s personal workspace as a pre-D381 account delete did: the
  # owner row gone, the workspace row still there.
  defp orphan_personal_workspace(user) do
    workspace = Workspaces.get_personal_workspace(user)
    WorkspaceMember |> where([m], m.workspace_id == ^workspace.id) |> Repo.delete_all()
    workspace
  end

  test "deletes an owner-less personal workspace that holds no boards", %{cleanup: cleanup} do
    orphan = orphan_personal_workspace(user_fixture())

    run(cleanup)

    assert Repo.get(Workspace, orphan.id) == nil
  end

  test "keeps an owner-less personal workspace that still holds a board", %{cleanup: cleanup} do
    keeper = orphan_personal_workspace(user_fixture())
    board = place_board_in_workspace(keeper)

    run(cleanup)

    assert Repo.get(Workspace, keeper.id)
    assert Repo.get!(Board, board.id).workspace_id == keeper.id
  end

  test "keeps every owned personal workspace, with or without boards", %{cleanup: cleanup} do
    empty_owner = user_fixture()
    board_owner = user_fixture()
    board_fixture(board_owner)
    empty = Workspaces.get_personal_workspace(empty_owner)
    with_board = Workspaces.get_personal_workspace(board_owner)

    run(cleanup)

    assert Repo.get(Workspace, empty.id)
    assert Repo.get(Workspace, with_board.id)
    assert Workspaces.get_member_role(empty, empty_owner) == :owner
  end

  test "is a no-op on a second run", %{cleanup: cleanup} do
    orphan = orphan_personal_workspace(user_fixture())
    keeper = orphan_personal_workspace(user_fixture())
    place_board_in_workspace(keeper)

    run(cleanup)
    after_first = workspace_ids()
    run(cleanup)

    assert workspace_ids() == after_first
    refute orphan.id in after_first
    assert keeper.id in after_first
  end
end
