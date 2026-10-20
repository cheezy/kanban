defmodule Kanban.Workspaces.InvitationSenderRecheckTest do
  @moduledoc """
  Accepting an invitation re-checks that its sender may still send it, and a
  board that moves into an Organization keeps its open board-only invitations
  under the org-board rule.

  async: false - one test switches the global `:plans_enforced` application
  env.
  """
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Invitations
  alias Kanban.Workspaces.WorkspaceMember

  setup do
    previous = Application.fetch_env(:kanban, :plans_enforced)
    on_exit(fn -> restore_plans_enforced(previous) end)
    Application.put_env(:kanban, :plans_enforced, false)
    :ok
  end

  # Inserts an open invitation sent by `sender` and returns it with its token.
  defp invitation!(sender, attrs) do
    {token, hash} = Invitation.build_token()

    invitation =
      %Invitation{
        token_hash: hash,
        invited_by_id: sender && sender.id,
        expires_at: Invitation.expires_at_from(DateTime.utc_now())
      }
      |> struct(attrs)
      |> Repo.insert!()

    {invitation, token}
  end

  defp disable!(user),
    do: user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()

  defp set_org_role!(organization, user, role) do
    {1, _} =
      from(m in OrganizationMember,
        where: m.organization_id == ^organization.id and m.user_id == ^user.id
      )
      |> Repo.update_all(set: [role: role])
  end

  defp revoked?(invitation), do: Repo.get!(Invitation, invitation.id).revoked_at != nil

  describe "a workspace invitation" do
    setup do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)
      invitee = user_fixture()

      {invitation, token} =
        invitation!(admin, workspace_id: workspace.id, email: invitee.email, role: :member)

      %{
        organization: organization,
        admin: admin,
        workspace: workspace,
        invitee: invitee,
        invitation: invitation,
        token: token
      }
    end

    test "is accepted while its sender is an enabled org-admin", ctx do
      assert {:ok, %{workspace: workspace}} = Invitations.accept(ctx.token, ctx.invitee)
      assert workspace.id == ctx.workspace.id
      assert Organizations.member?(ctx.invitee, ctx.organization)
    end

    test "is refused and revoked once its sender is no longer an org-admin", ctx do
      set_org_role!(ctx.organization, ctx.admin, :member)

      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
      assert_refused_and_revoked(ctx)

      # Revoked, so it stays unusable even when the sender is appointed again.
      set_org_role!(ctx.organization, ctx.admin, :org_admin)
      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
    end

    test "is refused and revoked once its sender has left the Organization", ctx do
      from(m in OrganizationMember, where: m.user_id == ^ctx.admin.id) |> Repo.delete_all()
      organization_member_fixture(organization_fixture(), ctx.admin, :org_admin)

      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
      assert_refused_and_revoked(ctx)
    end

    test "is refused and revoked once its sender is disabled", ctx do
      disable!(ctx.admin)

      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
      assert_refused_and_revoked(ctx)
    end

    test "is refused and revoked once its sender's account is gone", ctx do
      {1, _} =
        from(i in Invitation, where: i.id == ^ctx.invitation.id)
        |> Repo.update_all(set: [invited_by_id: nil])

      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
      assert_refused_and_revoked(ctx)
    end

    test "accept_registered/1 re-checks the sender too", ctx do
      {1, _} =
        from(i in Invitation, where: i.id == ^ctx.invitation.id)
        |> Repo.update_all(set: [registered_user_id: ctx.invitee.id])

      set_org_role!(ctx.organization, ctx.admin, :member)

      assert {:error, :invalid} = Invitations.accept_registered(ctx.invitee)
      assert_refused_and_revoked(ctx)
    end

    defp assert_refused_and_revoked(ctx) do
      assert revoked?(ctx.invitation)
      assert Repo.get!(Invitation, ctx.invitation.id).accepted_at == nil
      refute Organizations.get_membership(ctx.invitee)
      refute Repo.get_by(WorkspaceMember, workspace_id: ctx.workspace.id, user_id: ctx.invitee.id)
    end
  end

  describe "a board-only invitation to a free board" do
    setup do
      owner = user_fixture()
      board = board_fixture(owner)
      invitee = user_fixture()

      {invitation, token} =
        invitation!(owner,
          workspace_id: Workspaces.get_personal_workspace(owner).id,
          email: invitee.email,
          board_id: board.id,
          board_access: :read_only
        )

      %{owner: owner, board: board, invitee: invitee, invitation: invitation, token: token}
    end

    test "is accepted while its sender owns the board", ctx do
      assert {:ok, %{board: board}} = Invitations.accept(ctx.token, ctx.invitee)
      assert board.id == ctx.board.id
      assert Boards.get_user_access(ctx.board.id, ctx.invitee.id) == :read_only
    end

    test "is refused and revoked once its sender no longer owns the board", ctx do
      new_owner = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, new_owner, :modify, ctx.owner)
      {:ok, _} = Boards.transfer_board_ownership(ctx.board, new_owner, ctx.owner)

      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
      assert revoked?(ctx.invitation)
      refute Repo.get_by(BoardUser, board_id: ctx.board.id, user_id: ctx.invitee.id)
    end

    test "is refused and revoked once its sender is disabled", ctx do
      disable!(ctx.owner)

      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
      assert revoked?(ctx.invitation)
      refute Repo.get_by(BoardUser, board_id: ctx.board.id, user_id: ctx.invitee.id)
    end
  end

  describe "moving a board into an Organization workspace" do
    setup do
      organization = organization_fixture()
      owner = user_fixture()
      organization_member_fixture(organization, owner, :org_admin)
      workspace = org_workspace_fixture(organization)
      board = board_fixture(owner)
      invitee = user_fixture()

      {invitation, token} =
        invitation!(owner,
          workspace_id: Workspaces.get_personal_workspace(owner).id,
          email: invitee.email,
          board_id: board.id,
          board_access: :modify
        )

      {:ok, _moved} = Workspaces.move_board_to_workspace(owner, board, workspace)

      %{
        organization: organization,
        owner: owner,
        board: board,
        invitee: invitee,
        invitation: invitation,
        token: token
      }
    end

    test "keeps the board's open invitations, accepted uncapped while the sender is an org-admin",
         ctx do
      refute revoked?(ctx.invitation)
      enforce_plans()
      for _ <- 1..3, do: grant!(ctx.board, user_fixture())

      assert {:ok, %{board: board}} = Invitations.accept(ctx.token, ctx.invitee)
      assert board.id == ctx.board.id
      assert Boards.get_user_access(ctx.board.id, ctx.invitee.id) == :modify
      refute Organizations.member?(ctx.invitee, ctx.organization)
    end

    test "refuses the invitation once its sender, still the board's owner, is no org-admin",
         ctx do
      set_org_role!(ctx.organization, ctx.owner, :member)
      assert Boards.owner?(ctx.board, %User{id: ctx.owner.id})

      assert {:error, :invalid} = Invitations.accept(ctx.token, ctx.invitee)
      assert revoked?(ctx.invitation)
      refute Repo.get_by(BoardUser, board_id: ctx.board.id, user_id: ctx.invitee.id)
    end

    defp grant!(board, user) do
      %BoardUser{}
      |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: :read_only})
      |> Repo.insert!()
    end
  end
end
