defmodule Kanban.Boards.OrgBoardMembersTest do
  @moduledoc """
  A board in an Organization workspace takes only members of that
  Organization: `Kanban.Boards.OrgBoardMembers`, asked by
  `Boards.add_user_to_board/4` and `Boards.add_invited_user/4`.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [from: 2, where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Boards.OrgBoardMembers
  alias Kanban.Organizations.MemberRemoval
  alias Kanban.Repo

  setup do
    organization = organization_fixture()
    workspace = org_workspace_fixture(organization)
    owner = user_fixture()
    organization_member_fixture(organization, owner)
    board = board_fixture(owner)

    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    %{organization: organization, owner: owner, board: Repo.get!(Board, board.id)}
  end

  defp member_row?(board, user) do
    from(bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^user.id)
    |> Repo.exists?()
  end

  describe "add_user_to_board/4 on an org board" do
    test "adds a member of the board's Organization", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)

      assert {:ok, %BoardUser{}} = Boards.add_user_to_board(ctx.board, member, :modify, ctx.owner)
      assert member_row?(ctx.board, member)
    end

    test "adds an org-admin of the board's Organization", ctx do
      org_admin = user_fixture()
      organization_member_fixture(ctx.organization, org_admin, :org_admin)

      assert {:ok, %BoardUser{}} =
               Boards.add_user_to_board(ctx.board, org_admin, :read_only, ctx.owner)
    end

    test "refuses a user who belongs to no Organization and writes nothing", ctx do
      outsider = user_fixture()

      assert {:error, :not_org_member} =
               Boards.add_user_to_board(ctx.board, outsider, :modify, ctx.owner)

      refute member_row?(ctx.board, outsider)
    end

    test "refuses a member of another Organization", ctx do
      other_member = user_fixture()
      organization_member_fixture(organization_fixture(), other_member)

      assert {:error, :not_org_member} =
               Boards.add_user_to_board(ctx.board, other_member, :read_only, ctx.owner)

      refute member_row?(ctx.board, other_member)
    end

    test "refuses an ex-member an org-admin removed from the Organization", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      org_admin = user_fixture()
      organization_member_fixture(ctx.organization, org_admin, :org_admin)

      assert {:ok, _} = MemberRemoval.remove_member(org_admin, ctx.organization.id, member.id)

      assert {:error, :not_org_member} =
               Boards.add_user_to_board(ctx.board, member, :modify, ctx.owner)
    end

    test "refuses an outsider added by an org-admin with derived access", ctx do
      org_admin = user_fixture()
      organization_member_fixture(ctx.organization, org_admin, :org_admin)

      assert {:error, :not_org_member} =
               Boards.add_user_to_board(ctx.board, user_fixture(), :modify, org_admin)
    end
  end

  describe "add_invited_user/4 on an org board" do
    test "refuses an invited user who is not a member of the Organization", ctx do
      outsider = user_fixture()

      assert {:error, :not_org_member} =
               Boards.add_invited_user(ctx.board, outsider, :modify, ctx.owner)

      refute member_row?(ctx.board, outsider)
    end
  end

  describe "personal-workspace boards" do
    test "still take a user from outside any Organization" do
      owner = user_fixture()
      board = board_fixture(owner)

      assert {:ok, %BoardUser{}} =
               Boards.add_user_to_board(board, user_fixture(), :modify, owner)
    end
  end

  describe "lock_and_check/3" do
    test "returns the Organization id for a member", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      organization_id = ctx.organization.id

      assert {:ok, {:ok, ^organization_id}} =
               Repo.transaction(fn ->
                 OrgBoardMembers.lock_and_check(Repo, ctx.board.id, member.id)
               end)
    end

    test "returns nil for a personal-workspace board" do
      board = board_fixture(user_fixture())

      assert {:ok, {:ok, nil}} =
               Repo.transaction(fn ->
                 OrgBoardMembers.lock_and_check(Repo, board.id, user_fixture().id)
               end)
    end

    test "returns :not_found for a board that does not exist" do
      assert {:ok, {:error, :not_found}} =
               Repo.transaction(fn ->
                 OrgBoardMembers.lock_and_check(Repo, -1, user_fixture().id)
               end)
    end
  end
end
