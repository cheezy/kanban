defmodule Kanban.Workspaces.BoardMovesTest do
  # Not async: the cap test switches plan enforcement on for the VM.
  use Kanban.DataCase, async: false

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Workspaces

  setup do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    workspace = org_workspace_fixture(organization)
    board = board_fixture(org_admin)

    %{organization: organization, org_admin: org_admin, workspace: workspace, board: board}
  end

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  defp workspace_id(board), do: Repo.get!(Board, board.id).workspace_id

  test "moves an owned personal board, keeps its rows and adds nobody to the Organization", ctx do
    reader = user_fixture()
    grant(ctx.board, reader, :read_only)
    Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

    assert {:ok, %Board{workspace_id: workspace_id}} =
             Workspaces.move_board_to_workspace(ctx.org_admin, ctx.board, ctx.workspace)

    assert workspace_id == ctx.workspace.id
    assert Boards.get_user_access(ctx.board.id, reader.id) == :read_only
    assert Boards.get_user_access(ctx.board.id, ctx.org_admin.id) == :owner
    refute Organizations.member?(reader, ctx.organization)
    assert Plans.paid_board?(ctx.board.id)

    board_id = ctx.board.id
    assert_receive {Kanban.Boards, :members_changed, ^board_id}
  end

  test "lifts the free-board cap: a fourth member can be added", ctx do
    enforce_plans()
    for _ <- 1..2, do: grant(ctx.board, user_fixture(), :read_only)
    assert %{count: 3, reached?: true} = Boards.member_cap_status(ctx.board)

    assert {:ok, _} =
             Workspaces.move_board_to_workspace(ctx.org_admin, ctx.board.id, ctx.workspace.id)

    board = Repo.get!(Board, ctx.board.id)
    assert %{cap: nil, reached?: false} = Boards.member_cap_status(board)
    assert {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :read_only, ctx.org_admin)
  end

  test "refuses a caller with only a modify row", ctx do
    board = board_fixture(user_fixture())
    grant(board, ctx.org_admin, :modify)

    assert Workspaces.move_board_to_workspace(ctx.org_admin, board, ctx.workspace) ==
             {:error, :not_owner}
  end

  test "refuses the personal workspace's owner who has no owner row on a backfilled board", ctx do
    board = ctx.org_admin |> personal_workspace_fixture() |> place_board_in_workspace()
    before = workspace_id(board)

    assert Workspaces.move_board_to_workspace(ctx.org_admin, board, ctx.workspace) ==
             {:error, :not_owner}

    assert workspace_id(board) == before
  end

  test "refuses a board outside the caller's personal workspace, including one already moved",
       ctx do
    other_workspace = org_workspace_fixture(ctx.organization)
    {:ok, _} = Workspaces.move_board_to_workspace(ctx.org_admin, ctx.board, ctx.workspace)

    assert Workspaces.move_board_to_workspace(ctx.org_admin, ctx.board, other_workspace) ==
             {:error, :not_in_personal_workspace}

    assert workspace_id(ctx.board) == ctx.workspace.id
  end

  test "refuses a board owned outside the caller's personal workspace", ctx do
    board = board_fixture(ctx.org_admin)

    {1, _} =
      Board
      |> where([b], b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: personal_workspace_fixture(user_fixture()).id])

    assert Workspaces.move_board_to_workspace(ctx.org_admin, board, ctx.workspace) ==
             {:error, :not_in_personal_workspace}
  end

  test "refuses another Organization's, an archived and a personal workspace like a missing one",
       ctx do
    foreign = org_workspace_fixture(organization_fixture())
    archived = org_workspace_fixture(ctx.organization, archived_at: DateTime.utc_now(:second))
    personal = personal_workspace_fixture(user_fixture())

    for target <- [foreign, archived, personal, 999_999_999, "abc", nil] do
      assert Workspaces.move_board_to_workspace(ctx.org_admin, ctx.board, target) ==
               {:error, :not_found}
    end

    assert workspace_id(ctx.board) == Workspaces.get_personal_workspace(ctx.org_admin).id
  end

  test "refuses a board owner who is not an org-admin of the target's Organization", ctx do
    member = user_fixture()
    organization_member_fixture(ctx.organization, member, :member)
    workspace_member_fixture(ctx.workspace, member, :member)
    board = board_fixture(member)

    assert Workspaces.move_board_to_workspace(member, board, ctx.workspace) ==
             {:error, :not_found}
  end

  test "refuses a missing board", ctx do
    for board <- [999_999_999, "x", nil] do
      assert Workspaces.move_board_to_workspace(ctx.org_admin, board, ctx.workspace) ==
               {:error, :not_found}
    end
  end
end
