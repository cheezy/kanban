defmodule Kanban.Workspaces.MembershipCascadeTest do
  @moduledoc """
  `Kanban.Workspaces.remove_member/3`'s board cascade, the derived-token
  revocation when an org-admin is removed, and the workspace settings reads in
  `Kanban.Workspaces.Listing` (W2218).
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Workspaces
  alias Kanban.Workspaces.MembershipCascade
  alias Kanban.Workspaces.WorkspaceMember

  defp put_in_workspace(board, workspace) do
    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.get!(Board, board.id)
  end

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  defp token(user, board) do
    {:ok, {token, _plain}} =
      ApiTokens.create_api_token(user, board, %{
        name: "Agent",
        agent_model: "claude",
        agent_version: "v1",
        agent_purpose: "work"
      })

    token
  end

  defp revoked?(token), do: not is_nil(Repo.get!(ApiToken, token.id).revoked_at)
  defp row(board, user), do: Repo.get_by(BoardUser, board_id: board.id, user_id: user.id)

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    workspace = org_workspace_fixture(organization)
    other_workspace = org_workspace_fixture(organization)
    member = user_fixture()
    organization_member_fixture(organization, member, :member)
    workspace_member_fixture(workspace, member, :member)
    workspace_member_fixture(other_workspace, member, :guest)

    %{
      organization: organization,
      admin: admin,
      workspace: workspace,
      other_workspace: other_workspace,
      member: member
    }
  end

  describe "Workspaces.remove_member/3 cascade" do
    test "deletes the member's board rows in that workspace, revokes tokens and unassigns open tasks",
         ctx do
      shared = board_fixture(user_fixture()) |> put_in_workspace(ctx.workspace)
      grant(shared, ctx.member, :modify)
      owned = board_fixture(ctx.member) |> put_in_workspace(ctx.workspace)
      elsewhere = board_fixture(user_fixture()) |> put_in_workspace(ctx.other_workspace)
      grant(elsewhere, ctx.member, :read_only)
      personal = board_fixture(user_fixture())
      grant(personal, ctx.member, :modify)

      shared_token = token(ctx.member, shared)
      elsewhere_token = token(ctx.member, elsewhere)

      column = column_fixture(shared)
      open_task = task_fixture(column, %{assigned_to_id: ctx.member.id})
      archived_task = task_fixture(column, %{assigned_to_id: ctx.member.id})

      archived_task
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
      |> Repo.update!()

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{shared.id}")

      assert {:ok, %WorkspaceMember{}} =
               Workspaces.remove_member(ctx.admin, ctx.workspace, ctx.member)

      assert row(shared, ctx.member) == nil
      assert row(owned, ctx.member) == nil
      assert row(elsewhere, ctx.member)
      assert row(personal, ctx.member)

      assert revoked?(shared_token)
      refute revoked?(elsewhere_token)

      assert Repo.get!(Task, open_task.id).assigned_to_id == nil
      assert Repo.get!(Task, archived_task.id).assigned_to_id == ctx.member.id

      board_id = shared.id
      assert_receive {Kanban.Boards, :members_changed, ^board_id}

      assert Boards.get_user_access(shared.id, ctx.member.id) == nil
      # The board the member owned stays reachable through the org-admin.
      assert Boards.get_user_access(owned.id, ctx.admin.id) == :owner
    end

    test "a refusal changes nothing", ctx do
      board = board_fixture(user_fixture()) |> put_in_workspace(ctx.workspace)
      grant(board, ctx.member, :modify)

      assert Workspaces.remove_member(ctx.member, ctx.workspace, ctx.member) ==
               {:error, :unauthorized}

      assert row(board, ctx.member)
      assert Workspaces.get_member_role(ctx.workspace, ctx.member) == :member
    end
  end

  describe "MembershipCascade.remove/2" do
    test "returns nothing for no workspaces and revokes tokens on boards without a row", ctx do
      assert MembershipCascade.remove(ctx.member.id, []) == []

      board = board_fixture(user_fixture()) |> put_in_workspace(ctx.workspace)
      grant(board, ctx.member, :modify)
      stray = token(ctx.member, board)

      BoardUser
      |> where([bu], bu.board_id == ^board.id and bu.user_id == ^ctx.member.id)
      |> Repo.delete_all()

      assert MembershipCascade.remove(ctx.member.id, [ctx.workspace.id]) == []
      assert revoked?(stray)
    end
  end

  describe "list_members/2" do
    test "lists member and guest rows with users, for anyone who reaches the workspace", ctx do
      assert [%WorkspaceMember{role: :member, user: %{id: id}}] =
               Workspaces.list_members(ctx.admin, ctx.workspace)

      assert id == ctx.member.id
      assert [_] = Workspaces.list_members(ctx.member, ctx.workspace.id)
    end

    test "is empty for a user who cannot reach the workspace, or a personal one", ctx do
      assert Workspaces.list_members(user_fixture(), ctx.workspace) == []

      assert Workspaces.list_members(ctx.admin, personal_workspace_fixture(ctx.admin)) == []
    end
  end

  describe "list_boards/2" do
    test "an org-admin sees every board; a member only boards they can access", ctx do
      visible =
        board_fixture(user_fixture(), %{name: "Visible board"}) |> put_in_workspace(ctx.workspace)

      grant(visible, ctx.member, :read_only)

      hidden =
        board_fixture(user_fixture(), %{name: "Hidden board"}) |> put_in_workspace(ctx.workspace)

      assert ctx.admin |> Workspaces.list_boards(ctx.workspace) |> Enum.map(& &1.id) ==
               [hidden.id, visible.id]

      assert ctx.member |> Workspaces.list_boards(ctx.workspace) |> Enum.map(& &1.id) ==
               [visible.id]

      assert Workspaces.list_boards(user_fixture(), ctx.workspace) == []
    end
  end

  describe "list_movable_boards/1" do
    test "lists personal boards the user owns through an owner row only", ctx do
      own = board_fixture(ctx.admin, %{name: "Own board"})
      shared_with = board_fixture(user_fixture())
      grant(shared_with, ctx.admin, :modify)
      backfilled = ctx.admin |> personal_workspace_fixture() |> place_board_in_workspace()
      _org = board_fixture(ctx.admin) |> put_in_workspace(ctx.workspace)

      ids = ctx.admin |> Workspaces.list_movable_boards() |> Enum.map(& &1.id)

      assert ids == [own.id]
      refute backfilled.id in ids
    end
  end

  describe "MembershipCascade.revoke_derived_tokens/2" do
    test "revokes only the tokens on boards whose write access was derived", ctx do
      derived = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      explicit = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      grant(explicit, ctx.admin, :modify)
      read_only = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      other_org = user_fixture() |> board_fixture()
      grant(other_org, ctx.admin, :read_only)
      other_org = put_in_workspace(other_org, org_workspace_fixture(organization_fixture()))

      derived_token = token(ctx.admin, derived)
      explicit_token = token(ctx.admin, explicit)
      # Minted through derived owner access before the :read_only row was added.
      read_only_token = token(ctx.admin, read_only)
      grant(read_only, ctx.admin, :read_only)
      other_org_token = token(ctx.admin, other_org)
      member_token = token(ctx.member, derived)

      assert MembershipCascade.revoke_derived_tokens(ctx.admin.id, ctx.organization.id) == 2

      assert revoked?(derived_token)
      assert revoked?(read_only_token)
      refute revoked?(explicit_token)
      refute revoked?(other_org_token)
      refute revoked?(member_token)
    end
  end

  describe "Organizations.remove_org_admin/3" do
    test "revokes the removed org-admin's derived-access tokens in the same change", ctx do
      organization_member_fixture(ctx.organization, user_fixture(), :org_admin)
      derived = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      explicit = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      grant(explicit, ctx.admin, :modify)
      derived_token = token(ctx.admin, derived)
      explicit_token = token(ctx.admin, explicit)

      assert {:ok, _membership} =
               Kanban.Organizations.remove_org_admin(admin_fixture(), ctx.organization, ctx.admin)

      assert revoked?(derived_token)
      refute revoked?(explicit_token)
    end

    test "revokes nothing when the removal is refused", ctx do
      derived = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      derived_token = token(ctx.admin, derived)

      assert {:error, :last_org_admin} =
               Kanban.Organizations.remove_org_admin(admin_fixture(), ctx.organization, ctx.admin)

      refute revoked?(derived_token)
    end
  end

  describe "MembershipCascade.notify_derived_access_ended/2" do
    test "tells only the boards whose write access was derived", ctx do
      derived = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      explicit = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      grant(explicit, ctx.admin, :modify)
      read_only = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)
      grant(read_only, ctx.admin, :read_only)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{derived.id}")
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{explicit.id}")
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{read_only.id}")

      assert MembershipCascade.notify_derived_access_ended(ctx.admin.id, ctx.organization.id) ==
               :ok

      derived_id = derived.id
      explicit_id = explicit.id
      read_only_id = read_only.id
      assert_receive {Kanban.Boards, :members_changed, ^derived_id}
      assert_receive {Kanban.Boards, :members_changed, ^read_only_id}
      refute_receive {Kanban.Boards, :members_changed, ^explicit_id}
    end
  end
end
