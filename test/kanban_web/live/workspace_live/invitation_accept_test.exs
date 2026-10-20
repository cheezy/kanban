defmodule KanbanWeb.WorkspaceLive.InvitationAcceptTest do
  @moduledoc """
  The invitation link page, `/invitations/:token` (W2219).

  async: false - one test switches the global `:plans_enforced` application
  env.
  """
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Invitations

  @invalid "This invitation link is invalid or has expired."

  setup do
    previous = Application.fetch_env(:kanban, :plans_enforced)
    on_exit(fn -> restore_plans_enforced(previous) end)
    Application.put_env(:kanban, :plans_enforced, false)

    organization = organization_fixture(%{name: "Acme Org"})
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    workspace = org_workspace_fixture(organization, name: "Platform")

    %{organization: organization, admin: admin, workspace: workspace}
  end

  defp url_fun, do: &"https://example.test/invitations/#{&1}"

  defp sent_token do
    receive do
      {:email, %{subject: "You're invited to" <> _, html_body: body}} ->
        [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)}, body)
        token

      {:email, _other} ->
        sent_token()
    after
      1_000 -> flunk("no invitation email was sent")
    end
  end

  defp invite(ctx, email, extra \\ %{}) do
    {:ok, invitation} =
      Invitations.invite_to_workspace(
        ctx.admin,
        ctx.workspace,
        Map.merge(%{"email" => email, "role" => "member"}, extra),
        url_fun()
      )

    {invitation, sent_token()}
  end

  describe "signed out" do
    test "names nothing about the invitation and carries the token to registration", ctx do
      {_invitation, token} = invite(ctx, "secret.invitee@example.test")

      {:ok, view, html} = live(build_conn(), ~p"/invitations/#{token}")

      assert has_element?(view, "#invitation[data-state=sign_in]")
      refute html =~ "secret.invitee@example.test"
      refute html =~ "Platform"
      refute html =~ "Acme Org"

      assert has_element?(
               view,
               ~s|#invitation-register[href="/users/register?invitation_token=#{token}"]|
             )

      assert has_element?(view, "#invitation-sign-in")
    end

    test "an unknown or malformed token shows the generic message" do
      for token <- ["nope", String.duplicate("a", 43), "bad%20token"] do
        {:ok, view, html} = live(build_conn(), "/invitations/#{token}")
        assert has_element?(view, "#invitation[data-state=invalid]")
        assert html =~ @invalid
        refute has_element?(view, "#invitation-register")
      end
    end
  end

  describe "signed in" do
    test "a matching user sees the target, accepts and is redirected", ctx do
      invitee = user_fixture(%{email: "match.me@example.test"})
      {_invitation, token} = invite(ctx, "Match.Me@Example.test")

      {:ok, view, html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")

      assert html =~ "Join the workspace Platform in Acme Org."
      refute Organizations.get_membership(invitee)

      view |> element("#accept-invitation") |> render_click()

      assert %{"info" => "You joined Platform."} = assert_redirect(view, ~p"/boards")
      assert Organizations.get_membership(invitee).organization_id == ctx.organization.id
    end

    test "a workspace invitation with a board redirects to that board", ctx do
      invitee = user_fixture()
      board = place_board_in_workspace(ctx.workspace)

      {_invitation, token} =
        invite(ctx, invitee.email, %{"board_id" => board.id, "board_access" => "modify"})

      {:ok, view, html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")
      assert html =~ "with access to"

      board_path = ~p"/boards/#{board.id}"

      assert {:error, {:live_redirect, %{to: ^board_path}}} =
               view |> element("#accept-invitation") |> render_click()

      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: invitee.id).access == :modify
    end

    test "a different account sees the generic message and its own address only", ctx do
      other = user_fixture(%{email: "someone.else@example.test"})
      {invitation, token} = invite(ctx, "the.invitee@example.test")

      {:ok, view, html} = live(log_in_user(build_conn(), other), ~p"/invitations/#{token}")

      assert has_element?(view, "#invitation[data-state=invalid]")
      assert html =~ @invalid
      assert has_element?(view, "#invitation-account", "someone.else@example.test")
      refute html =~ "the.invitee@example.test"
      refute html =~ "Platform"
      refute has_element?(view, "#accept-invitation")

      assert render_click(view, "accept", %{}) =~ @invalid
      refute Organizations.get_membership(other)
      refute Repo.get!(Invitation, invitation.id).accepted_at
    end

    test "an invitee in another Organization sees the generic message", ctx do
      invitee = user_fixture()
      organization_member_fixture(organization_fixture(), invitee, :member)
      {invitation, token} = invite(ctx, invitee.email)

      {:ok, view, html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")

      assert has_element?(view, "#invitation[data-state=invalid]")
      assert html =~ @invalid
      refute html =~ "Acme Org"
      refute Repo.get!(Invitation, invitation.id).accepted_at
    end

    test "a revoked or used link shows the generic message", ctx do
      invitee = user_fixture()
      {invitation, token} = invite(ctx, invitee.email)
      {:ok, _} = Invitations.revoke(ctx.admin, invitation.id)

      {:ok, view, _html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")
      assert has_element?(view, "#invitation[data-state=invalid]")

      {_second, token2} = invite(ctx, invitee.email)
      {:ok, _} = Invitations.accept(token2, invitee)

      {:ok, view, _html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token2}")
      assert has_element?(view, "#invitation[data-state=invalid]")
    end

    test "a link revoked while the page is open is refused on accept", ctx do
      invitee = user_fixture()
      {invitation, token} = invite(ctx, invitee.email)

      {:ok, view, _html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")
      {:ok, _} = Invitations.revoke(ctx.admin, invitation.id)

      assert view |> element("#accept-invitation") |> render_click() =~ @invalid
      refute Organizations.get_membership(invitee)
    end

    test "a free board that filled up shows the full message and grants nothing" do
      owner = user_fixture()
      board = board_fixture(owner)
      invitee = user_fixture()

      {:ok, _invitation} =
        Invitations.invite_to_board(
          owner,
          board,
          %{"email" => invitee.email, "access" => "read_only"},
          url_fun()
        )

      token = sent_token()

      {:ok, view, html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")
      assert html =~ "Join the board"

      enforce_plans()

      for _ <- 1..(Kanban.Plans.free_board_member_cap() - 1),
          do: {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :read_only, owner)

      html = view |> element("#accept-invitation") |> render_click()

      assert has_element?(view, "#invitation[data-state=full]")
      assert html =~ "This board is full"
      refute Repo.get_by(BoardUser, board_id: board.id, user_id: invitee.id)
    end
  end

  describe "audit trail" do
    test "the joining is audited for this Organization's admin only, without an email", ctx do
      invitee = user_fixture()
      {invitation, token} = invite(ctx, invitee.email)

      {:ok, view, _html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")
      view |> element("#accept-invitation") |> render_click()

      assert [event] = Kanban.AuditLog.list_events(action: :org_member_added)
      assert event.organization_id == ctx.organization.id
      assert event.metadata["member_user_id"] == invitee.id
      assert event.metadata["invitation_id"] == invitation.id
      refute inspect(event.metadata) =~ invitee.email

      admin_conn = log_in_user(build_conn(), ctx.admin)
      {:ok, audit_view, _html} = live(admin_conn, ~p"/org/audit")
      assert has_element?(audit_view, "#events-#{event.id}", "Organization member added")

      rows = admin_conn |> get(~p"/org/audit/export?format=json") |> json_response(200)
      assert Enum.any?(rows, &(&1["action"] == "org_member_added"))

      csv = admin_conn |> get(~p"/org/audit/export") |> response(200)
      assert csv =~ ",org_member_added,"

      other_org = organization_fixture()
      other_admin = user_fixture()
      organization_member_fixture(other_org, other_admin, :org_admin)
      other_conn = log_in_user(build_conn(), other_admin)

      {:ok, other_view, _html} = live(other_conn, ~p"/org/audit")
      refute has_element?(other_view, "#events-#{event.id}")

      other_rows = other_conn |> get(~p"/org/audit/export?format=json") |> json_response(200)
      refute Enum.any?(other_rows, &(&1["action"] == "org_member_added"))
    end

    test "joining an Organization the user already belongs to records nothing", ctx do
      invitee = user_fixture()
      organization_member_fixture(ctx.organization, invitee, :member)
      {_invitation, token} = invite(ctx, invitee.email)

      {:ok, view, _html} = live(log_in_user(build_conn(), invitee), ~p"/invitations/#{token}")
      view |> element("#accept-invitation") |> render_click()

      assert Kanban.AuditLog.list_events(action: :org_member_added) == []
    end
  end
end
