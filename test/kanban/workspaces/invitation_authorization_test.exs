defmodule Kanban.Workspaces.InvitationAuthorizationTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.InvitationAuthorization
  alias Kanban.Workspaces.Invitations
  alias Kanban.Workspaces.Workspace

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    member = user_fixture()
    organization_member_fixture(organization, member, :member)
    workspace = org_workspace_fixture(organization)
    %{organization: organization, admin: admin, member: member, workspace: workspace}
  end

  describe "managed_workspace/2" do
    test "an org-admin manages the org workspace, by struct or by id", ctx do
      assert {:ok, actor, ws} =
               InvitationAuthorization.managed_workspace(ctx.admin, ctx.workspace)

      assert actor.id == ctx.admin.id and ws.id == ctx.workspace.id

      assert {:ok, _actor, _ws} =
               InvitationAuthorization.managed_workspace(ctx.admin, "#{ctx.workspace.id}")
    end

    test "a member, a disabled org-admin, an archived workspace and a bad id are refused",
         ctx do
      assert {:error, :unauthorized} =
               InvitationAuthorization.managed_workspace(ctx.member, ctx.workspace)

      for bad <- ["x", -1, nil, 9_223_372_036_854_775_808] do
        assert {:error, :unauthorized} = InvitationAuthorization.managed_workspace(ctx.admin, bad)
      end

      archived =
        ctx.workspace
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
        |> Repo.update!()

      assert {:error, :unauthorized} =
               InvitationAuthorization.managed_workspace(ctx.admin, archived)

      ctx.admin |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()

      assert {:error, :unauthorized} =
               InvitationAuthorization.managed_workspace(
                 ctx.admin,
                 org_workspace_fixture(ctx.organization)
               )
    end
  end

  describe "workspace_board/2" do
    test "accepts no board or a board in the workspace and refuses any other", ctx do
      board = place_board_in_workspace(ctx.workspace)
      elsewhere = board_fixture(user_fixture())

      assert {:ok, nil} = InvitationAuthorization.workspace_board(ctx.workspace, nil)
      assert {:ok, nil} = InvitationAuthorization.workspace_board(ctx.workspace, "")
      assert {:ok, %{id: id}} = InvitationAuthorization.workspace_board(ctx.workspace, board.id)
      assert id == board.id

      for bad <- [elsewhere.id, "abc", 0] do
        assert {:error, :invalid_board} =
                 InvitationAuthorization.workspace_board(ctx.workspace, bad)
      end
    end
  end

  describe "invitable_board/2" do
    test "a personal board's owner may invite and an editor may not" do
      owner = user_fixture()
      editor = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Boards.add_user_to_board(board, editor, :modify, owner)

      assert {:ok, _actor, _board, %{personal: true}} =
               InvitationAuthorization.invitable_board(owner, board)

      assert {:error, :unauthorized} = InvitationAuthorization.invitable_board(editor, board)
      assert {:error, :unauthorized} = InvitationAuthorization.invitable_board(owner, nil)
    end

    test "on an org board an org-admin may invite and a member may not", ctx do
      board = place_board_in_workspace(ctx.workspace)

      assert {:ok, _actor, _board, %{personal: false}} =
               InvitationAuthorization.invitable_board(ctx.admin, board.id)

      assert {:error, :unauthorized} = InvitationAuthorization.invitable_board(ctx.member, board)
    end
  end

  describe "managed_invitation/2" do
    test "returns an open invitation to its manager only", ctx do
      {:ok, invitation} =
        Invitations.invite_to_workspace(
          ctx.admin,
          ctx.workspace,
          %{"email" => "x@example.test", "role" => "guest"},
          &"https://example.test/invitations/#{&1}"
        )

      assert {:ok, _actor, found, _ws, nil} =
               InvitationAuthorization.managed_invitation(ctx.admin, invitation.id)

      assert found.id == invitation.id

      assert {:error, :unauthorized} =
               InvitationAuthorization.managed_invitation(ctx.member, invitation.id)

      assert {:error, :not_found} = InvitationAuthorization.managed_invitation(ctx.admin, "nope")

      {:ok, _} = Invitations.revoke(ctx.admin, invitation.id)

      assert {:error, :not_found} =
               InvitationAuthorization.managed_invitation(ctx.admin, invitation.id)
    end
  end

  describe "inviter_may_send?/3" do
    # Builds an invitation sent by `sender` (nil: a deleted account) with
    # `role` and asks whether it may still be sent to `workspace` and `board`.
    defp may_send?(sender, role, workspace, board) do
      %Invitation{invited_by_id: sender && sender.id, role: role}
      |> InvitationAuthorization.inviter_may_send?(workspace, board)
    end

    defp disable(user),
      do: user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()

    test "a workspace invitation needs an enabled org-admin of the workspace's Organization",
         ctx do
      assert may_send?(ctx.admin, :member, ctx.workspace, nil)
      refute may_send?(ctx.member, :member, ctx.workspace, nil)
      refute may_send?(nil, :member, ctx.workspace, nil)

      admin = disable(ctx.admin)
      refute may_send?(admin, :guest, ctx.workspace, nil)
    end

    test "a board-only invitation on a free board needs the board's enabled owner" do
      owner = user_fixture()
      editor = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Boards.add_user_to_board(board, editor, :modify, owner)
      workspace = Workspaces.get_personal_workspace(owner)

      assert may_send?(owner, nil, workspace, board)
      refute may_send?(editor, nil, workspace, board)
      refute may_send?(owner, nil, workspace, nil)

      owner = disable(owner)
      refute may_send?(owner, nil, workspace, board)
    end

    test "a board-only invitation on a board moved into an Organization needs an org-admin",
         ctx do
      owner = user_fixture()
      organization_member_fixture(ctx.organization, owner, :member)
      board = board_fixture(owner)
      moved = move_board_to_organization(board, ctx.organization)
      workspace = Repo.get!(Workspace, moved.workspace_id)

      # Still the board's owner, but no longer allowed under the free-board rule.
      assert Boards.owner?(moved, owner)
      refute may_send?(owner, nil, workspace, moved)
      assert may_send?(ctx.admin, nil, workspace, moved)
    end
  end
end
