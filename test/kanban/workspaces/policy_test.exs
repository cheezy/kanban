defmodule Kanban.Workspaces.PolicyTest do
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Workspaces.Policy

  @levels [nil, :read_only, :modify, :owner]

  # A board whose explicit access for `user` is `access` (nil for no row),
  # placed in `workspace` (nil leaves it in its owner's personal workspace).
  defp board_with_access(user, access, workspace) do
    board =
      case access do
        :owner -> board_fixture(user)
        _ -> board_fixture(user_fixture())
      end

    if access in [:read_only, :modify] do
      %BoardUser{}
      |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
      |> Repo.insert!()
    end

    case workspace do
      nil -> board
      workspace -> put_in_workspace(board, workspace)
    end
  end

  defp put_in_workspace(board, workspace) do
    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.get!(Board, board.id)
  end

  defp disable(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  # Single, batched and listed access must always agree.
  defp assert_access(board, user, expected) do
    assert Policy.effective_board_access(board, user) == expected
    assert Policy.effective_board_access(board.id, user.id) == expected
    assert Policy.effective_board_accesses([board.id], user) == %{board.id => expected}
    assert_listed_access(board, user, expected)
  end

  defp assert_listed_access(board, user, expected) do
    listed = user |> Policy.list_accessible_boards() |> Enum.find(&(&1.id == board.id))
    scoped_ids = user.id |> Policy.accessible_board_ids() |> Repo.all() |> Enum.map(& &1.board_id)
    assert board.id in scoped_ids == not is_nil(expected)

    case expected do
      nil -> assert listed == nil
      access -> assert %Board{user_access: ^access} = listed
    end
  end

  setup do
    organization = organization_fixture()
    workspace = org_workspace_fixture(organization)
    %{organization: organization, workspace: workspace}
  end

  describe "effective_board_access/2 on an org workspace board" do
    test "an org-admin of the owning Organization gets owner-equivalent access at every level",
         %{organization: organization, workspace: workspace} do
      for level <- @levels do
        org_admin = user_fixture()
        organization_member_fixture(organization, org_admin, :org_admin)
        board = board_with_access(org_admin, level, workspace)

        assert_access(board, org_admin, :owner)
      end
    end

    test "a workspace member, a guest and an Organization member keep only their explicit access",
         %{organization: organization, workspace: workspace} do
      for role <- [:member, :guest, :no_row], level <- @levels do
        user = user_fixture()
        organization_member_fixture(organization, user, :member)
        if role != :no_row, do: workspace_member_fixture(workspace, user, role)
        board = board_with_access(user, level, workspace)

        assert_access(board, user, level)
      end
    end

    test "an org-admin of a different Organization, a site admin and an outsider keep only explicit access",
         %{workspace: workspace} do
      for kind <- [:other_org_admin, :site_admin, :outsider], level <- @levels do
        user =
          case kind do
            :other_org_admin ->
              user = user_fixture()
              organization_member_fixture(organization_fixture(), user, :org_admin)
              user

            :site_admin ->
              user_fixture() |> Ecto.Changeset.change(type: :admin) |> Repo.update!()

            :outsider ->
              user_fixture()
          end

        board = board_with_access(user, level, workspace)

        assert_access(board, user, level)
      end
    end

    test "a disabled org-admin derives nothing", %{
      organization: organization,
      workspace: workspace
    } do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      board = board_with_access(org_admin, :read_only, workspace)

      disabled = disable(org_admin)

      assert_access(board, disabled, :read_only)
    end
  end

  describe "effective_board_access/2 on a personal workspace board" do
    test "every role gets exactly its board_users access", %{organization: organization} do
      for kind <- [:org_admin, :member, :outsider], level <- @levels do
        user = user_fixture()
        if kind != :outsider, do: organization_member_fixture(organization, user, kind)
        board = board_with_access(user, level, nil)

        assert_access(board, user, level)
      end
    end

    test "the personal workspace's owner gets nothing from a board placed there without a row" do
      site_admin = user_fixture() |> Ecto.Changeset.change(type: :admin) |> Repo.update!()

      board = site_admin |> personal_workspace_fixture() |> place_board_in_workspace()

      assert_access(board, site_admin, nil)
    end

    test "an ownerless board placed with its earliest member gives that member their own access, not owner" do
      member = user_fixture()
      board = board_fixture(user_fixture())

      BoardUser |> where([bu], bu.board_id == ^board.id) |> Repo.delete_all()

      %BoardUser{}
      |> BoardUser.changeset(%{board_id: board.id, user_id: member.id, access: :modify})
      |> Repo.insert!()

      board = put_in_workspace(board, personal_workspace_fixture(member))

      assert_access(board, member, :modify)
    end
  end

  describe "effective_board_access/2 inputs" do
    test "invalid ids give nil", %{organization: organization} do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      for id <- [nil, "abc", "99999999999999999999", -1, 0] do
        assert Policy.effective_board_access(id, org_admin) == nil
      end

      assert Policy.effective_board_access(1, nil) == nil
    end

    test "a string id is accepted", %{organization: organization, workspace: workspace} do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      board = board_with_access(org_admin, nil, workspace)

      assert board.id |> Integer.to_string() |> Policy.effective_board_access(org_admin) == :owner
    end
  end

  describe "org-admin reach" do
    test "is limited to their own Organization's workspaces", %{organization: organization} do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      own = board_with_access(user_fixture(), nil, org_workspace_fixture(organization))

      foreign =
        board_with_access(user_fixture(), nil, org_workspace_fixture(organization_fixture()))

      assert Policy.effective_board_access(own, org_admin) == :owner
      assert Policy.effective_board_access(foreign, org_admin) == nil

      assert Policy.effective_board_accesses([own.id, foreign.id, -5], org_admin) == %{
               own.id => :owner,
               foreign.id => nil
             }
    end
  end

  describe "fetch_board/2" do
    test "returns the board with the effective access, or nil", %{
      organization: organization,
      workspace: workspace
    } do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      board = board_with_access(user_fixture(), nil, workspace)
      outsider = user_fixture()

      assert {%Board{id: id}, :owner} = Policy.fetch_board(board.id, org_admin)
      assert id == board.id
      assert {%Board{}, nil} = Policy.fetch_board(board.id, outsider)
      assert Policy.fetch_board(-1, outsider) == nil
      assert Policy.fetch_board("x", outsider) == nil
      assert Policy.fetch_board(999_999_999, outsider) == nil
    end
  end

  describe "list_accessible_boards/2" do
    test "lists explicit and derived boards once each, from one query", %{
      organization: organization,
      workspace: workspace
    } do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      own_personal = board_fixture(org_admin)
      derived = board_with_access(user_fixture(), nil, workspace)
      both = board_with_access(org_admin, :read_only, workspace)
      _unrelated = board_fixture(user_fixture())

      ref = attach_query_counter()
      boards = Policy.list_accessible_boards(org_admin)
      assert query_count(ref) == 1

      assert boards |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([own_personal.id, derived.id, both.id])

      assert Enum.all?(boards, &(&1.user_access == :owner))
    end

    test "workspace_id: limits the list to one workspace", %{
      organization: organization,
      workspace: workspace
    } do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      inside = board_with_access(user_fixture(), nil, workspace)
      _outside = board_fixture(org_admin)

      assert [%Board{id: id}] =
               Policy.list_accessible_boards(org_admin, workspace_id: workspace.id)

      assert id == inside.id
    end
  end

  describe "accessible_board_ids/1" do
    test "selects explicit and derived board ids once each, and nothing else", %{
      organization: organization,
      workspace: workspace
    } do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      own_personal = board_fixture(org_admin)
      derived = board_with_access(user_fixture(), nil, workspace)
      both = board_with_access(org_admin, :read_only, workspace)
      _unrelated = board_fixture(user_fixture())

      _other_org =
        board_with_access(user_fixture(), nil, org_workspace_fixture(organization_fixture()))

      ids = org_admin.id |> Policy.accessible_board_ids() |> Repo.all() |> Enum.map(& &1.board_id)

      assert Enum.sort(ids) == Enum.sort([own_personal.id, derived.id, both.id])
    end

    test "gives a member, a disabled org-admin and an outsider only their board_users boards", %{
      organization: organization,
      workspace: workspace
    } do
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)
      disabled_admin = user_fixture()
      organization_member_fixture(organization, disabled_admin, :org_admin)
      disabled_admin = disable(disabled_admin)
      _org_board = board_with_access(user_fixture(), nil, workspace)
      readable = board_with_access(member, :read_only, workspace)

      ids_for = fn user ->
        user.id |> Policy.accessible_board_ids() |> Repo.all() |> Enum.map(& &1.board_id)
      end

      assert ids_for.(member) == [readable.id]
      assert ids_for.(disabled_admin) == []
      assert ids_for.(user_fixture()) == []
    end
  end

  describe "can_manage_workspace?/2" do
    test "is true only for an enabled org-admin of the workspace's Organization", %{
      organization: organization,
      workspace: workspace
    } do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)
      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      assert Policy.can_manage_workspace?(org_admin, workspace)
      refute Policy.can_manage_workspace?(member, workspace)
      refute Policy.can_manage_workspace?(other_admin, workspace)
      refute org_admin |> disable() |> Policy.can_manage_workspace?(workspace)
      refute Policy.can_manage_workspace?(org_admin, personal_workspace_fixture(org_admin))
      refute Policy.can_manage_workspace?(org_admin, nil)
    end
  end

  describe "can_create_board_in?/2" do
    test "allows the org-admin and workspace members, never guests, outsiders or archived workspaces",
         %{organization: organization, workspace: workspace} do
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)
      guest = user_fixture()
      organization_member_fixture(organization, guest, :member)
      workspace_member_fixture(workspace, guest, :guest)
      org_member_no_row = user_fixture()
      organization_member_fixture(organization, org_member_no_row, :member)
      archived = org_workspace_fixture(organization, archived_at: DateTime.utc_now(:second))

      assert Policy.can_create_board_in?(org_admin, workspace)
      assert Policy.can_create_board_in?(member, workspace)
      refute Policy.can_create_board_in?(guest, workspace)
      refute Policy.can_create_board_in?(org_member_no_row, workspace)
      refute Policy.can_create_board_in?(user_fixture(), workspace)
      refute Policy.can_create_board_in?(org_admin, archived)
      refute Policy.can_create_board_in?(org_admin, personal_workspace_fixture(org_admin))
      refute Policy.can_create_board_in?(org_admin, nil)
    end

    test "a member row left behind after leaving the Organization does not count", %{
      workspace: workspace
    } do
      former = user_fixture()
      workspace_member_fixture(workspace, former, :member)

      refute Policy.can_create_board_in?(former, workspace)
    end
  end

  defp attach_query_counter do
    ref = make_ref()
    parent = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        # Async tests run their queries through the same handler; count only
        # this test's own.
        if self() == parent, do: send(parent, {:query, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp query_count(ref) do
    receive_count(ref, 0)
  end

  defp receive_count(ref, count) do
    receive do
      {:query, ^ref} -> receive_count(ref, count + 1)
    after
      0 -> count
    end
  end
end
