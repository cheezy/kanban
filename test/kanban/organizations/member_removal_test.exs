defmodule Kanban.Organizations.MemberRemovalTest do
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.MemberRemoval
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.WorkspaceMember

  @removed [:kanban, :organization, :member_removed]

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

  setup do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    member = user_fixture()
    organization_member_fixture(organization, member, :member)

    active = org_workspace_fixture(organization)
    archived = org_workspace_fixture(organization, archived_at: DateTime.utc_now(:second))
    workspace_member_fixture(active, member, :member)
    workspace_member_fixture(archived, member, :guest)

    %{
      organization: organization,
      org_admin: org_admin,
      member: member,
      active: active,
      archived: archived
    }
  end

  test "removes the member from the Organization and cascades through every workspace", ctx do
    active_board = board_fixture(user_fixture()) |> put_in_workspace(ctx.active)
    grant(active_board, ctx.member, :modify)
    archived_board = board_fixture(ctx.member) |> put_in_workspace(ctx.archived)
    personal_board = board_fixture(user_fixture())
    grant(personal_board, ctx.member, :read_only)
    active_token = token(ctx.member, active_board)

    attach_telemetry(@removed)

    assert {:ok, %OrganizationMember{role: :member}} =
             MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, ctx.member.id)

    refute Organizations.member?(ctx.member, ctx.organization)
    # Only the personal workspace's owner row is left.
    assert [%WorkspaceMember{role: :owner}] =
             WorkspaceMember |> where([m], m.user_id == ^ctx.member.id) |> Repo.all()

    assert Boards.get_user_access(active_board.id, ctx.member.id) == nil
    assert Boards.get_user_access(archived_board.id, ctx.member.id) == nil
    assert Boards.get_user_access(personal_board.id, ctx.member.id) == :read_only
    assert Repo.get!(ApiToken, active_token.id).revoked_at

    member_id = ctx.member.id
    admin_id = ctx.org_admin.id

    assert_receive {:telemetry_event, @removed, %{count: 1},
                    %{user_id: ^member_id, role: :member, actor_user_id: ^admin_id}}

    assert [event] = AuditLog.list_events(action: :org_member_removed)
    assert event.organization_id == ctx.organization.id
  end

  test "rejoining later restores no workspace or board access", ctx do
    board = board_fixture(user_fixture()) |> put_in_workspace(ctx.active)
    grant(board, ctx.member, :modify)

    {:ok, _} = MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, ctx.member.id)
    {:ok, _} = Organizations.add_member(ctx.organization, ctx.member, :member)

    assert Workspaces.get_member_role(ctx.active, ctx.member) == nil
    assert Workspaces.list_workspaces_for_user(ctx.member) == []
    assert Boards.get_user_access(board.id, ctx.member.id) == nil
  end

  test "refuses to remove an org-admin, including the actor themselves", ctx do
    other_admin = user_fixture()
    organization_member_fixture(ctx.organization, other_admin, :org_admin)

    for target <- [other_admin, ctx.org_admin] do
      assert MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, target.id) ==
               {:error, :org_admin}

      assert Organizations.org_admin?(target, ctx.organization.id)
    end
  end

  test "refuses actors who are not enabled org-admins of the Organization", ctx do
    other_member = user_fixture()
    organization_member_fixture(ctx.organization, other_member, :member)
    foreign_admin = user_fixture()
    organization_member_fixture(organization_fixture(), foreign_admin, :org_admin)

    disabled_admin =
      ctx.org_admin
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
      |> Repo.update!()

    for actor <- [other_member, foreign_admin, disabled_admin, user_fixture()] do
      assert MemberRemoval.remove_member(actor, ctx.organization.id, ctx.member.id) ==
               {:error, :unauthorized}
    end

    assert Organizations.member?(ctx.member, ctx.organization)
    assert Workspaces.get_member_role(ctx.active, ctx.member) == :member
  end

  test "a user outside the Organization, a bad id or a missing Organization is not found", ctx do
    outsider = user_fixture()
    organization_member_fixture(organization_fixture(), outsider, :member)

    for id <- [outsider.id, Integer.to_string(user_fixture().id), "abc", nil, -1] do
      assert MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, id) ==
               {:error, :not_found}
    end

    assert MemberRemoval.remove_member(ctx.org_admin, -1, ctx.member.id) == {:error, :not_found}
    assert Organizations.member?(outsider, Organizations.get_membership(outsider).organization_id)
  end
end
