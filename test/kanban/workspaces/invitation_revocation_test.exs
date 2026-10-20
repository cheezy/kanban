defmodule Kanban.Workspaces.InvitationRevocationTest do
  @moduledoc """
  Membership changes revoke the open invitations they make stale
  (`Kanban.Workspaces.InvitationRevocation`): an Organization or workspace
  removal and a guest downgrade revoke the ones addressed to the user, and an
  org-admin's removal also revokes the ones they sent, so accepting one later
  cannot undo the change.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Organizations
  alias Kanban.Organizations.MemberRemoval
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.InvitationRevocation
  alias Kanban.Workspaces.Invitations

  setup do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    workspace = org_workspace_fixture(organization)
    member = user_fixture()
    organization_member_fixture(organization, member)
    workspace_member_fixture(workspace, member)

    %{organization: organization, org_admin: org_admin, workspace: workspace, member: member}
  end

  # Inserts an open workspace invitation and returns it with its token.
  defp invitation!(sender, workspace, attrs) do
    {token, hash} = Invitation.build_token()

    invitation =
      %Invitation{
        token_hash: hash,
        invited_by_id: sender.id,
        workspace_id: workspace.id,
        role: :member,
        expires_at: Invitation.expires_at_from(DateTime.utc_now())
      }
      |> struct(attrs)
      |> Repo.insert!()

    {invitation, token}
  end

  defp revoked?(%Invitation{id: id}), do: not is_nil(Repo.get!(Invitation, id).revoked_at)

  describe "removal from the Organization" do
    test "revokes invitations addressed to the member in every workspace, so none can be accepted",
         ctx do
      other_workspace = org_workspace_fixture(ctx.organization)
      {by_email, token} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.member.email})

      {by_registration, _} =
        invitation!(ctx.org_admin, other_workspace, %{
          email: "changed-#{System.unique_integer([:positive])}@example.com",
          registered_user_id: ctx.member.id
        })

      assert {:ok, _} =
               MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, ctx.member.id)

      assert revoked?(by_email)
      assert revoked?(by_registration)
      assert {:error, :invalid} = Invitations.accept(token, ctx.member)
      refute Organizations.member?(ctx.member, ctx.organization)
    end

    test "leaves other people's invitations and other Organizations' alone", ctx do
      {someone_else, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: "else@example.com"})

      elsewhere = organization_fixture()
      elsewhere_admin = user_fixture()
      organization_member_fixture(elsewhere, elsewhere_admin, :org_admin)

      {other_org, _} =
        invitation!(elsewhere_admin, org_workspace_fixture(elsewhere), %{email: ctx.member.email})

      assert {:ok, _} =
               MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, ctx.member.id)

      refute revoked?(someone_else)
      refute revoked?(other_org)
    end
  end

  describe "removal from a workspace" do
    test "revokes invitations addressed to the member in that workspace only", ctx do
      other_workspace = org_workspace_fixture(ctx.organization)
      {here, token} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.member.email})
      {there, _} = invitation!(ctx.org_admin, other_workspace, %{email: ctx.member.email})

      assert {:ok, _} = Workspaces.remove_member(ctx.org_admin, ctx.workspace, ctx.member)

      assert revoked?(here)
      refute revoked?(there)
      assert {:error, :invalid} = Invitations.accept(token, ctx.member)
    end
  end

  describe "a role change" do
    test "lowering a member to guest revokes their invitations in that workspace", ctx do
      {invitation, token} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.member.email})

      assert {:ok, %{role: :guest}} =
               Workspaces.update_member_role(ctx.org_admin, ctx.workspace, ctx.member, :guest)

      assert revoked?(invitation)
      assert {:error, :invalid} = Invitations.accept(token, ctx.member)
      assert Workspaces.get_member_role(ctx.workspace, ctx.member) == :guest
    end

    test "re-saving a guest as guest keeps an invitation sent to raise them", ctx do
      {:ok, _} = Workspaces.update_member_role(ctx.org_admin, ctx.workspace, ctx.member, :guest)
      {invitation, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.member.email})

      assert {:ok, _} =
               Workspaces.update_member_role(ctx.org_admin, ctx.workspace, ctx.member, :guest)

      refute revoked?(invitation)
    end

    test "raising a guest to member revokes nothing", ctx do
      {:ok, _} = Workspaces.update_member_role(ctx.org_admin, ctx.workspace, ctx.member, :guest)
      {invitation, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.member.email})

      assert {:ok, %{role: :member}} =
               Workspaces.update_member_role(ctx.org_admin, ctx.workspace, ctx.member, :member)

      refute revoked?(invitation)
    end

    test "a refused role change revokes nothing", ctx do
      {invitation, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.member.email})

      assert {:error, :unauthorized} =
               Workspaces.update_member_role(user_fixture(), ctx.workspace, ctx.member, :guest)

      refute revoked?(invitation)
    end
  end

  describe "removing an org-admin" do
    setup ctx do
      second_admin = user_fixture()
      organization_member_fixture(ctx.organization, second_admin, :org_admin)
      Map.merge(ctx, %{site_admin: admin_fixture(), second_admin: second_admin})
    end

    test "revokes the invitations they sent, which re-appointment does not revive", ctx do
      invitee = user_fixture()
      {sent, token} = invitation!(ctx.second_admin, ctx.workspace, %{email: invitee.email})
      {by_other_admin, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: "x@example.com"})

      assert {:ok, _} =
               Organizations.remove_org_admin(ctx.site_admin, ctx.organization, ctx.second_admin)

      assert revoked?(sent)
      refute revoked?(by_other_admin)

      assert {:ok, _} =
               Organizations.appoint_org_admin(ctx.site_admin, ctx.organization, ctx.second_admin)

      assert {:error, :invalid} = Invitations.accept(token, invitee)
      refute Organizations.member?(invitee, ctx.organization)
    end

    test "revokes the invitations addressed to them", ctx do
      {addressed, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.second_admin.email})

      assert {:ok, _} =
               Organizations.remove_org_admin(ctx.site_admin, ctx.organization, ctx.second_admin)

      assert revoked?(addressed)
    end

    test "a refused removal revokes nothing", ctx do
      {sent, _} = invitation!(ctx.second_admin, ctx.workspace, %{email: "y@example.com"})

      # The last org-admin of an Organization with other members is never removed.
      {1, _} =
        from(m in OrganizationMember,
          where: m.organization_id == ^ctx.organization.id and m.user_id == ^ctx.org_admin.id
        )
        |> Repo.update_all(set: [role: "member"])

      assert {:error, :last_org_admin} =
               Organizations.remove_org_admin(ctx.site_admin, ctx.organization, ctx.second_admin)

      refute revoked?(sent)
    end
  end

  describe "query helpers" do
    test "addressed_to/2 matches the user's email and the user who registered through it",
         ctx do
      {by_email, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: ctx.member.email})

      {registered, _} =
        invitation!(ctx.org_admin, ctx.workspace, %{
          email: "other@example.com",
          registered_user_id: ctx.member.id
        })

      {someone_else, _} = invitation!(ctx.org_admin, ctx.workspace, %{email: "else@example.com"})

      ids =
        ctx.member.id
        |> InvitationRevocation.addressed_to({:workspace, ctx.workspace.id})
        |> select([i], i.id)
        |> Repo.all()

      assert Enum.sort(ids) == Enum.sort([by_email.id, registered.id])
      refute someone_else.id in ids
    end

    test "lock/1 and revoke/1 handle no matching invitations", ctx do
      queries = [InvitationRevocation.sent_by(ctx.member.id, ctx.organization.id)]

      assert {:ok, :ok} = Repo.transact(fn -> {:ok, InvitationRevocation.lock(queries)} end)
      assert InvitationRevocation.revoke(queries) == 0
    end

    test "revoke/1 skips invitations already accepted or revoked", ctx do
      {accepted, _} =
        invitation!(ctx.org_admin, ctx.workspace, %{
          email: ctx.member.email,
          accepted_at: DateTime.utc_now(:second)
        })

      assert InvitationRevocation.revoke([
               InvitationRevocation.addressed_to(ctx.member.id, {:workspace, ctx.workspace.id})
             ]) == 0

      refute revoked?(accepted)
    end
  end
end
