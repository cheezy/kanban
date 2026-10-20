defmodule KanbanWeb.WorkspaceLive.InvitationRegistrationTest do
  @moduledoc """
  A new user registering from an invitation link joins once their email is
  confirmed (W2219): the registration page carries the token, the register
  action links the invitation to the new account, and the confirmation page
  accepts it.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Invitations
  alias Kanban.Workspaces.WorkspaceMember

  setup do
    organization = organization_fixture(%{name: "Acme Org"})
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    workspace = org_workspace_fixture(organization, name: "Platform")
    %{organization: organization, admin: admin, workspace: workspace}
  end

  defp invite(ctx, email, extra \\ %{}) do
    {:ok, invitation} =
      Invitations.invite_to_workspace(
        ctx.admin,
        ctx.workspace,
        Map.merge(%{"email" => email, "role" => "member"}, extra),
        &"https://example.test/invitations/#{&1}"
      )

    {invitation, sent_token()}
  end

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

  defp register(conn, email, token) do
    post(conn, ~p"/users/register", %{
      "user" => %{"email" => email, "password" => valid_user_password()},
      "invitation_token" => token
    })
  end

  defp confirm(conn, user) do
    token =
      extract_user_token(fn url -> Accounts.deliver_user_confirmation_instructions(user, url) end)

    {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
    render(lv)
  end

  describe "the registration page" do
    test "carries a token-shaped invitation_token as a hidden field", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation_token=abc_DEF-123")

      assert has_element?(lv, ~s|input[type=hidden][name=invitation_token][value="abc_DEF-123"]|)
    end

    test "drops anything that is not shaped like a token", %{conn: conn} do
      for bad <- ["<script>", "a b", String.duplicate("a", 65)] do
        {:ok, lv, html} = live(conn, ~p"/users/register?#{[invitation_token: bad]}")

        refute has_element?(lv, "input[name=invitation_token]")
        refute html =~ "&lt;script&gt;"
      end

      {:ok, lv, _html} = live(conn, ~p"/users/register")
      refute has_element?(lv, "input[name=invitation_token]")
    end
  end

  describe "registering from the link" do
    test "joins the Organization, the workspace and the board once the email is confirmed",
         ctx do
      board = place_board_in_workspace(ctx.workspace)

      {invitation, token} =
        invite(ctx, "new.person@example.test", %{
          "role" => "guest",
          "board_id" => board.id,
          "board_access" => "modify"
        })

      conn = register(ctx.conn, "New.Person@example.test", token)
      assert redirected_to(conn) =~ "/users/confirmation-pending"

      user = Repo.get_by!(User, email: "New.Person@example.test")
      assert Repo.get!(Invitation, invitation.id).registered_user_id == user.id
      refute Organizations.get_membership(user)

      html = confirm(build_conn(), user)

      assert html =~ "You joined #{board.name}."
      assert Organizations.get_membership(user).organization_id == ctx.organization.id
      assert Repo.get!(Invitation, invitation.id).accepted_at

      assert Repo.get_by!(WorkspaceMember, workspace_id: ctx.workspace.id, user_id: user.id).role ==
               :guest

      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: user.id).access == :modify
    end

    test "a different email registers normally and links nothing", ctx do
      {invitation, token} = invite(ctx, "invited@example.test")

      conn = register(ctx.conn, "someone.else@example.test", token)
      assert redirected_to(conn) =~ "/users/confirmation-pending"

      user = Repo.get_by!(User, email: "someone.else@example.test")
      refute Repo.get!(Invitation, invitation.id).registered_user_id

      html = confirm(build_conn(), user)
      refute html =~ "You joined"
      refute Organizations.get_membership(user)
    end

    test "a bad, revoked or missing token gives the same registration response", ctx do
      {invitation, token} = invite(ctx, "revoked@example.test")
      {:ok, _} = Invitations.revoke(ctx.admin, invitation.id)

      for {email, value} <- [
            {"revoked@example.test", token},
            {"garbage@example.test", "not a token"},
            {"nothing@example.test", nil}
          ] do
        conn = register(build_conn(), email, value)
        assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"
      end

      refute Repo.get!(Invitation, invitation.id).registered_user_id
    end

    test "an invitation revoked before confirmation is not accepted", ctx do
      {invitation, token} = invite(ctx, "late@example.test")
      register(ctx.conn, "late@example.test", token)
      user = Repo.get_by!(User, email: "late@example.test")

      {:ok, _} = Invitations.revoke(ctx.admin, invitation.id)

      html = confirm(build_conn(), user)
      refute html =~ "You joined"
      refute Organizations.get_membership(user)
    end
  end
end
