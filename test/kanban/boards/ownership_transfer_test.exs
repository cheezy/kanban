defmodule Kanban.Boards.OwnershipTransferTest do
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Workspaces

  defp add_member(board, user, access \\ :modify) do
    Repo.insert!(%BoardUser{board_id: board.id, user_id: user.id, access: access})
  end

  defp access_of(board, user) do
    from(bu in BoardUser,
      where: bu.board_id == ^board.id and bu.user_id == ^user.id,
      select: bu.access
    )
    |> Repo.one()
  end

  defp disable_directly(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp org_board(owner) do
    organization = organization_fixture()
    board = owner |> board_fixture() |> move_board_to_organization(organization)
    %{organization: organization, board: board}
  end

  describe "transfer_board_ownership/3 by the explicit owner" do
    setup do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      add_member(board, member, :read_only)
      %{owner: owner, board: board, member: member}
    end

    test "swaps the rows and moves a personal board to the new owner's personal workspace", %{
      owner: owner,
      board: board,
      member: member
    } do
      assert {:ok, %Board{} = moved} = Boards.transfer_board_ownership(board, member, owner)

      assert access_of(board, owner) == :modify
      assert access_of(board, member) == :owner
      assert moved.workspace_id == Workspaces.get_personal_workspace(member).id
      assert Repo.get!(Board, board.id).workspace_id == moved.workspace_id
    end

    test "creates the new owner's personal workspace when they have none", %{
      owner: owner,
      board: board,
      member: member
    } do
      remove_personal_workspace(member)

      assert {:ok, moved} = Boards.transfer_board_ownership(board.id, member.id, owner)

      assert %{personal: true, id: id} = Workspaces.get_personal_workspace(member)
      assert moved.workspace_id == id
    end

    test "accepts ids given as strings", %{owner: owner, board: board, member: member} do
      board_id = Integer.to_string(board.id)
      member_id = Integer.to_string(member.id)

      assert {:ok, _} = Boards.transfer_board_ownership(board_id, member_id, owner)

      assert access_of(board, member) == :owner
    end

    test "reports both changes, broadcasts and notifies", %{
      owner: owner,
      board: board,
      member: member
    } do
      attach_telemetry([[:kanban, :board, :member_access_changed]])
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")
      board_id = board.id
      owner_id = owner.id
      member_id = member.id

      assert {:ok, _} = Boards.transfer_board_ownership(board, member, owner)

      assert_received {:telemetry_event, [:kanban, :board, :member_access_changed], _,
                       %{user_id: ^owner_id, from_access: :owner, to_access: :modify}}

      assert_received {:telemetry_event, [:kanban, :board, :member_access_changed], _,
                       %{user_id: ^member_id, from_access: :read_only, to_access: :owner}}

      assert_received {Kanban.Boards, :members_changed, ^board_id}
    end

    test "keeps an org board in its workspace" do
      owner = user_fixture()
      %{board: board} = org_board(owner)
      member = user_fixture()
      add_member(board, member)

      assert {:ok, moved} = Boards.transfer_board_ownership(board, member, owner)

      assert moved.workspace_id == board.workspace_id
      assert access_of(board, member) == :owner
    end

    test "refuses a user who is not a member", %{owner: owner, board: board} do
      assert {:error, :not_a_member} =
               Boards.transfer_board_ownership(board, user_fixture(), owner)

      assert access_of(board, owner) == :owner
    end

    test "refuses the current owner as the new owner", %{owner: owner, board: board} do
      assert {:error, :already_owner} = Boards.transfer_board_ownership(board, owner, owner)
    end

    test "refuses a disabled member and changes nothing", %{
      owner: owner,
      board: board,
      member: member
    } do
      disable_directly(member)

      assert {:error, :user_disabled} = Boards.transfer_board_ownership(board, member, owner)
      assert access_of(board, owner) == :owner
      assert access_of(board, member) == :read_only
    end

    test "refuses a missing board or user", %{owner: owner, board: board} do
      assert {:error, :not_found} = Boards.transfer_board_ownership(-1, user_fixture(), owner)
      assert {:error, :not_found} = Boards.transfer_board_ownership("abc", owner, owner)
      assert {:error, :not_found} = Boards.transfer_board_ownership(board, -5, owner)
      assert {:error, :not_found} = Boards.transfer_board_ownership(board, nil, owner)
      assert {:error, :not_found} = Boards.transfer_board_ownership(999_999_999, owner, owner)
      assert {:error, :not_found} = Boards.transfer_board_ownership(board, 999_999_999, owner)
    end
  end

  describe "transfer_board_ownership/3 authorization" do
    test "refuses a member who is not the owner" do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      other = user_fixture()
      add_member(board, member)
      add_member(board, other)

      assert {:error, :unauthorized} = Boards.transfer_board_ownership(board, other, member)
      assert access_of(board, owner) == :owner
    end

    test "lets an org-admin of the board's Organization transfer it" do
      owner = user_fixture()
      %{organization: organization, board: board} = org_board(owner)
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      member = user_fixture()
      add_member(board, member)

      assert {:ok, _} = Boards.transfer_board_ownership(board, member, org_admin)
      assert access_of(board, owner) == :modify
      assert access_of(board, member) == :owner
    end

    test "lets an org-admin promote a member of an ownerless org board" do
      owner = user_fixture()
      %{organization: organization, board: board} = org_board(owner)
      member = user_fixture()
      add_member(board, member)

      from(bu in BoardUser, where: bu.board_id == ^board.id and bu.access == :owner)
      |> Repo.delete_all()

      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      assert {:ok, _} = Boards.transfer_board_ownership(board, member, org_admin)
      assert access_of(board, member) == :owner
    end

    test "refuses an org-admin of another Organization" do
      owner = user_fixture()
      %{board: board} = org_board(owner)
      member = user_fixture()
      add_member(board, member)
      outsider = user_fixture()
      organization_member_fixture(organization_fixture(), outsider, :org_admin)

      assert {:error, :unauthorized} = Boards.transfer_board_ownership(board, member, outsider)
    end

    test "refuses a disabled org-admin" do
      owner = user_fixture()
      %{organization: organization, board: board} = org_board(owner)
      member = user_fixture()
      add_member(board, member)
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      disable_directly(org_admin)

      assert {:error, :unauthorized} = Boards.transfer_board_ownership(board, member, org_admin)
    end

    test "refuses a disabled explicit owner, read from the database, and changes nothing" do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      add_member(board, member)
      workspace_id = board.workspace_id
      # `owner` stays the stale, enabled struct: the check must read the row.
      disable_directly(owner)

      assert {:error, :unauthorized} = Boards.transfer_board_ownership(board, member, owner)

      assert access_of(board, owner) == :owner
      assert access_of(board, member) == :modify
      assert Repo.get!(Board, board.id).workspace_id == workspace_id
    end

    test "refuses a disabled explicit owner of an org board" do
      owner = user_fixture()
      %{board: board} = org_board(owner)
      member = user_fixture()
      add_member(board, member)
      disable_directly(owner)

      assert {:error, :unauthorized} = Boards.transfer_board_ownership(board, member, owner)
      assert access_of(board, owner) == :owner
    end

    test "refuses an org-admin acting on a board in someone's personal workspace" do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      add_member(board, member)
      org_admin = user_fixture()
      organization_member_fixture(organization_fixture(), org_admin, :org_admin)

      assert {:error, :unauthorized} = Boards.transfer_board_ownership(board, member, org_admin)
    end
  end

  describe "list_ownership_candidates/2" do
    test "lists enabled non-owner members by name, then email" do
      owner = user_fixture()
      board = board_fixture(owner)
      zed = user_fixture(%{name: "Zed"})
      amy = user_fixture(%{name: "Amy"})
      disabled = user_fixture(%{name: "Bob"})
      add_member(board, zed)
      add_member(board, amy, :read_only)
      add_member(board, disabled)
      disable_directly(disabled)

      assert [%{id: first, name: "Amy"}, %{id: second, name: "Zed"}] =
               Boards.list_ownership_candidates(board, owner)

      assert [first, second] == [amy.id, zed.id]
    end

    test "is empty for a board only its owner uses" do
      owner = user_fixture()
      board = board_fixture(owner)
      assert Boards.list_ownership_candidates(board, owner) == []
    end

    test "is empty for an actor who may not transfer the board" do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      add_member(board, member)
      add_member(board, user_fixture())
      outsider = user_fixture()
      organization_member_fixture(organization_fixture(), outsider, :org_admin)

      assert Boards.list_ownership_candidates(board, member) == []
      assert Boards.list_ownership_candidates(board, outsider) == []
    end

    test "is empty for a disabled explicit owner" do
      owner = user_fixture()
      board = board_fixture(owner)
      add_member(board, user_fixture())
      disable_directly(owner)

      assert Boards.list_ownership_candidates(board, owner) == []
    end

    test "is empty for a disabled org-admin of the board's Organization" do
      owner = user_fixture()
      %{organization: organization, board: board} = org_board(owner)
      add_member(board, user_fixture())
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      disable_directly(org_admin)

      assert Boards.list_ownership_candidates(board, org_admin) == []
    end

    test "lists the members for an org-admin of the board's Organization" do
      owner = user_fixture()
      %{organization: organization, board: board} = org_board(owner)
      member = user_fixture()
      add_member(board, member)
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      member_id = member.id
      assert [%{id: ^member_id}] = Boards.list_ownership_candidates(board, org_admin)
    end
  end
end
