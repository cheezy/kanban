defmodule KanbanWeb.WorkspaceLive.SettingsTest do
  # Not async: some tests switch plan enforcement on for the VM.
  use KanbanWeb.ConnCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Invitations

  @refusal "Workspace settings are not available."
  @denied "Only an org-admin can manage this workspace."

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  defp put_in_workspace(board, workspace) do
    {1, _} =
      from(b in Board, where: b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.get!(Board, board.id)
  end

  defp switch(conn, workspace) do
    conn
    |> post(~p"/workspace/switch", %{"workspace_id" => workspace.id})
    |> recycle()
  end

  setup %{conn: conn} do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    member = user_fixture()
    organization_member_fixture(organization, member, :member)
    guest = user_fixture()
    organization_member_fixture(organization, guest, :member)

    workspace = org_workspace_fixture(organization, name: "Platform")
    workspace_member_fixture(workspace, member, :member)
    workspace_member_fixture(workspace, guest, :guest)

    %{
      conn: conn,
      organization: organization,
      org_admin: org_admin,
      member: member,
      guest: guest,
      workspace: workspace
    }
  end

  defp admin_view(ctx, path \\ ~p"/workspace/settings") do
    conn = ctx.conn |> log_in_user(ctx.org_admin) |> switch(ctx.workspace)
    {:ok, view, html} = live(conn, path)
    {view, html}
  end

  describe "mount" do
    test "an org-admin sees the current workspace's members with role controls", ctx do
      {view, html} = admin_view(ctx)

      assert html =~ "Platform"
      assert has_element?(view, "#workspace-member-#{ctx.member.id}")
      assert has_element?(view, "#role-select-#{ctx.guest.id}")
      assert has_element?(view, "#remove-workspace-member-#{ctx.member.id}[data-confirm]")
    end

    test "a member sees a read-only list with no controls", ctx do
      conn = ctx.conn |> log_in_user(ctx.member) |> switch(ctx.workspace)
      {:ok, view, _html} = live(conn, ~p"/workspace/settings")

      assert has_element?(view, "#workspace-member-role-#{ctx.guest.id}", "Guest")
      refute has_element?(view, "#role-form-#{ctx.guest.id}")
      refute has_element?(view, "#remove-workspace-member-#{ctx.guest.id}")

      render_click(view, "select_section", %{"section" => "boards"})
      refute has_element?(view, "#move-board")
    end

    test "refuses a user without an Organization, while plans are enforced or not", ctx do
      free_conn = log_in_user(ctx.conn, user_fixture())

      assert {:error, {:redirect, %{to: "/boards", flash: %{"error" => @refusal}}}} =
               live(free_conn, ~p"/workspace/settings")

      enforce_plans()

      assert {:error, {:redirect, %{to: "/boards", flash: %{"error" => @refusal}}}} =
               live(free_conn, ~p"/workspace/settings")
    end

    test "refuses an Organization member with no reachable workspace", ctx do
      lonely = user_fixture()
      organization_member_fixture(ctx.organization, lonely, :member)

      assert {:error, {:redirect, %{to: "/boards", flash: %{"error" => @refusal}}}} =
               live(log_in_user(ctx.conn, lonely), ~p"/workspace/settings")
    end

    test "a workspace archived after it was chosen is not shown", ctx do
      conn = ctx.conn |> log_in_user(ctx.member) |> switch(ctx.workspace)

      ctx.workspace
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:error, {:redirect, %{to: "/boards"}}} = live(conn, ~p"/workspace/settings")
    end

    test "requires a signed-in user", ctx do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(ctx.conn, ~p"/workspace/settings")
    end
  end

  describe "sections" do
    test "select_section patches to an allow-listed section and ignores others", ctx do
      {view, _html} = admin_view(ctx)

      render_click(view, "select_section", %{"section" => "boards"})
      assert_patch(view, ~p"/workspace/settings?section=boards")
      assert has_element?(view, "#boards")

      for params <- [%{"section" => "billing"}, %{"section" => "__struct__"}, %{}] do
        render_click(view, "select_section", params)
        assert has_element?(view, "#boards")
      end

      render_patch(view, ~p"/workspace/settings?section=nope")
      assert has_element?(view, "#members")
    end

    test "the boards section lists the workspace's boards and not other boards", ctx do
      in_workspace =
        board_fixture(user_fixture(), %{name: "Inside board"}) |> put_in_workspace(ctx.workspace)

      outside = board_fixture(user_fixture(), %{name: "Outside board"})

      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=boards")

      assert has_element?(view, "#workspace-board-#{in_workspace.id}")
      refute has_element?(view, "#workspace-board-#{outside.id}")
    end
  end

  describe "update_role" do
    test "an org-admin changes a member's role", ctx do
      {view, _html} = admin_view(ctx)

      view
      |> form("#role-form-#{ctx.member.id}", %{"role" => "guest"})
      |> render_submit()

      assert render(view) =~ "Role updated."
      assert Workspaces.get_member_role(ctx.workspace, ctx.member) == :guest
    end

    test "an unknown role or a user outside the workspace is not found", ctx do
      {view, _html} = admin_view(ctx)
      outsider = user_fixture()

      assert render_click(view, "update_role", %{
               "user_id" => Integer.to_string(ctx.member.id),
               "role" => "owner"
             }) =~ "Member not found."

      assert render_click(view, "update_role", %{
               "user_id" => Integer.to_string(outsider.id),
               "role" => "guest"
             }) =~ "Member not found."

      assert Workspaces.get_member_role(ctx.workspace, ctx.member) == :member
      assert Workspaces.get_member_role(ctx.workspace, outsider) == nil
    end
  end

  describe "remove_member" do
    test "removes the member, their board rows here and their API tokens here", ctx do
      board = board_fixture(user_fixture()) |> put_in_workspace(ctx.workspace)
      grant(board, ctx.member, :modify)

      {view, _html} = admin_view(ctx)

      view |> element("#remove-workspace-member-#{ctx.member.id}") |> render_click()

      assert render(view) =~ "Member removed from the workspace."
      refute has_element?(view, "#workspace-member-#{ctx.member.id}")
      assert Workspaces.get_member_role(ctx.workspace, ctx.member) == nil
      assert Boards.get_user_access(board.id, ctx.member.id) == nil
    end

    test "a user id outside the workspace is not found", ctx do
      {view, _html} = admin_view(ctx)

      assert render_click(view, "remove_member", %{
               "user_id" => Integer.to_string(user_fixture().id)
             }) =~
               "Member not found."

      assert render_click(view, "remove_member", %{"user_id" => "abc"}) =~ "Member not found."
    end

    test "a crafted non-scalar user id changes nothing and does not crash the view", ctx do
      {view, _html} = admin_view(ctx)

      render_click(view, "remove_member", %{"user_id" => %{"id" => "1"}})
      render_click(view, "update_role", %{"user_id" => [ctx.member.id], "role" => "guest"})

      assert Process.alive?(view.pid)
      assert has_element?(view, "#workspace-member-#{ctx.member.id}")
      assert Workspaces.get_member_role(ctx.workspace, ctx.member) == :member
    end
  end

  describe "move_board" do
    test "moves an owned personal board into the workspace", ctx do
      board = board_fixture(ctx.org_admin, %{name: "Personal roadmap"})

      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=boards")

      view
      |> form("#move-board-form", %{"move" => %{"board_id" => Integer.to_string(board.id)}})
      |> render_submit()

      assert render(view) =~ "Board moved into this workspace."
      assert Repo.get!(Board, board.id).workspace_id == ctx.workspace.id
      assert has_element?(view, "#workspace-board-#{board.id}")
      assert has_element?(view, "#no-movable-boards")
    end

    test "a board the org-admin does not own is refused", ctx do
      _own = board_fixture(ctx.org_admin, %{name: "Own board"})
      foreign = board_fixture(user_fixture(), %{name: "Foreign board"})

      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=boards")

      assert render_click(view, "move_board", %{
               "move" => %{"board_id" => Integer.to_string(foreign.id)}
             }) =~
               "That board can&#39;t be moved here."

      refute Repo.get!(Board, foreign.id).workspace_id == ctx.workspace.id
    end
  end

  describe "invitations (W2219)" do
    defp invitation_emails(acc \\ []) do
      receive do
        {:email, %{subject: "You're invited to" <> _} = email} -> invitation_emails([email | acc])
        {:email, _other} -> invitation_emails(acc)
      after
        200 -> Enum.reverse(acc)
      end
    end

    defp pending_invitation(ctx, email) do
      {:ok, invitation} =
        Invitations.invite_to_workspace(
          ctx.org_admin,
          ctx.workspace,
          %{"email" => email, "role" => "guest"},
          &"https://example.test/invitations/#{&1}"
        )

      invitation_emails()
      invitation
    end

    test "the section is listed for an org-admin and hidden from a member", ctx do
      {view, _html} = admin_view(ctx)
      assert has_element?(view, "#settings-tab-invitations")

      conn = ctx.conn |> log_in_user(ctx.member) |> switch(ctx.workspace)
      {:ok, member_view, _html} = live(conn, ~p"/workspace/settings?section=invitations")

      refute has_element?(member_view, "#settings-tab-invitations")
      refute has_element?(member_view, "#invite-form")
      assert has_element?(member_view, "#members")
    end

    test "an org-admin sends an invitation that is listed and emailed", ctx do
      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=invitations")
      assert has_element?(view, "#no-invitations")

      html =
        view
        |> form("#invite-form", %{"invite" => %{"email" => "New.Person@Example.test"}})
        |> render_submit()

      assert html =~ "Invitation sent to new.person@example.test."
      assert [invitation] = Invitations.list_pending(ctx.org_admin, ctx.workspace)
      assert invitation.role == :member
      assert has_element?(view, "#invitation-#{invitation.id}", "new.person@example.test")

      assert [email] = invitation_emails()
      assert email.to == [{"", "new.person@example.test"}]
      assert email.html_body =~ "/invitations/"
    end

    test "an invalid email shows the form error and sends nothing", ctx do
      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=invitations")

      view
      |> form("#invite-form", %{"invite" => %{"email" => "not-an-email"}})
      |> render_submit()

      assert render(view) =~ "must have the @ sign and no spaces"
      assert Invitations.list_pending(ctx.org_admin, ctx.workspace) == []
      assert invitation_emails() == []
    end

    test "typing an invalid email shows the error before submitting", ctx do
      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=invitations")

      html =
        view
        |> form("#invite-form", %{"invite" => %{"email" => "still typing"}})
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
      assert Invitations.list_pending(ctx.org_admin, ctx.workspace) == []
      assert invitation_emails() == []

      refute view
             |> form("#invite-form", %{"invite" => %{"email" => "fine@example.test"}})
             |> render_change() =~ "must have the @ sign and no spaces"
    end

    test "resend replaces the token and revoke removes the invitation", ctx do
      invitation = pending_invitation(ctx, "guest.to.be@example.test")
      old_hash = invitation.token_hash

      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=invitations")

      assert view |> element("#resend-invitation-#{invitation.id}") |> render_click() =~
               "Invitation sent again."

      assert Repo.get!(Invitation, invitation.id).token_hash != old_hash
      assert [_resent] = invitation_emails()

      assert view |> element("#revoke-invitation-#{invitation.id}") |> render_click() =~
               "Invitation revoked."

      refute has_element?(view, "#invitation-#{invitation.id}")
      assert Repo.get!(Invitation, invitation.id).revoked_at
    end

    test "a member or guest crafting invitation events is denied and nothing changes", ctx do
      invitation = pending_invitation(ctx, "someone@example.test")

      for viewer <- [ctx.member, ctx.guest] do
        conn = ctx.conn |> log_in_user(viewer) |> switch(ctx.workspace)
        {:ok, view, _html} = live(conn, ~p"/workspace/settings")

        events = [
          {"invite", %{"invite" => %{"email" => "crafted@example.test", "role" => "member"}}},
          {"resend_invitation", %{"id" => Integer.to_string(invitation.id)}},
          {"revoke_invitation", %{"id" => Integer.to_string(invitation.id)}},
          {"invite", %{}},
          {"resend_invitation", %{}},
          {"revoke_invitation", %{}}
        ]

        for {event, params} <- events do
          assert render_click(view, event, params) =~ @denied
        end
      end

      assert [%{id: id, revoked_at: nil}] = Invitations.list_pending(ctx.org_admin, ctx.workspace)
      assert id == invitation.id
      assert Repo.get!(Invitation, invitation.id).token_hash == invitation.token_hash
      assert invitation_emails() == []
    end

    test "an invitation id from another workspace is not found", ctx do
      other = org_with_admin_workspace()

      {:ok, foreign} =
        Invitations.invite_to_workspace(
          other.admin,
          other.workspace,
          %{"email" => "foreign@example.test", "role" => "member"},
          &"https://example.test/invitations/#{&1}"
        )

      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=invitations")

      assert render_click(view, "revoke_invitation", %{"id" => Integer.to_string(foreign.id)}) =~
               "Invitation not found."

      refute Repo.get!(Invitation, foreign.id).revoked_at
    end
  end

  defp org_with_admin_workspace do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    %{admin: admin, workspace: org_workspace_fixture(organization)}
  end

  # Every token of the workspace, newest first, read without the org-admin
  # check Kanban.ApiTokens.list_workspace_api_tokens/2 makes.
  defp workspace_tokens(workspace) do
    from(t in Kanban.ApiTokens.ApiToken,
      where: t.workspace_id == ^workspace.id,
      order_by: [desc: t.inserted_at, desc: t.id]
    )
    |> Repo.all()
  end

  defp shown_token(view) do
    case Regex.run(~r/id="workspace-token-value"[^>]*>([^<]+)</, render(view)) do
      [_, plain] -> String.trim(plain)
      nil -> nil
    end
  end

  defp create_token(view, name \\ "Fleet") do
    view
    |> form("#workspace-token-form",
      token: %{name: name, agent_capabilities: "code_generation, testing"}
    )
    |> render_submit()
  end

  describe "tokens (W2220)" do
    test "an org-admin sees the Tokens section and creates a token shown once", ctx do
      {view, _html} = admin_view(ctx)
      assert has_element?(view, "#settings-tab-tokens")

      render_click(view, "select_section", %{"section" => "tokens"})
      assert_patch(view, ~p"/workspace/settings?section=tokens")
      assert has_element?(view, "#no-workspace-tokens")

      assert create_token(view) =~ "Workspace token created."

      plain = shown_token(view)
      assert plain
      assert [api_token] = workspace_tokens(ctx.workspace)
      assert api_token.token_hash == Kanban.ApiTokens.ApiToken.hash_token_string(plain)
      assert api_token.user_id == ctx.org_admin.id
      assert api_token.agent_capabilities == ["code_generation", "testing"]
      assert has_element?(view, "#workspace-token-#{api_token.id}", "Fleet")
      assert has_element?(view, "#workspace-token-status-#{api_token.id}", "Active")

      render_click(view, "select_section", %{"section" => "boards"})
      assert_patch(view, ~p"/workspace/settings?section=boards")
      render_click(view, "select_section", %{"section" => "tokens"})
      assert_patch(view, ~p"/workspace/settings?section=tokens")
      assert shown_token(view) == nil
      refute render(view) =~ plain

      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=tokens")
      refute render(view) =~ plain
      assert has_element?(view, "#workspace-token-#{api_token.id}")
    end

    test "dismissing the new token hides it", ctx do
      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=tokens")
      create_token(view)
      plain = shown_token(view)

      view |> element("#workspace-token-dismiss") |> render_click()

      refute has_element?(view, "#workspace-token-reveal")
      refute render(view) =~ plain
    end

    test "a blank name shows the form error and creates nothing", ctx do
      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=tokens")

      assert create_token(view, "") =~ "can&#39;t be blank"
      assert workspace_tokens(ctx.workspace) == []
      refute has_element?(view, "#workspace-token-reveal")
    end

    test "an org-admin revokes a token, and a foreign token id is not found", ctx do
      {:ok, {api_token, _}} =
        Kanban.ApiTokens.create_workspace_api_token(ctx.org_admin, ctx.workspace, %{name: "A"})

      other = org_with_admin_workspace()

      {:ok, {foreign, _}} =
        Kanban.ApiTokens.create_workspace_api_token(other.admin, other.workspace, %{name: "B"})

      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=tokens")

      assert render_click(view, "revoke_token", %{"id" => Integer.to_string(foreign.id)}) =~
               "Token not found."

      refute Repo.reload!(foreign).revoked_at

      assert view |> element("#revoke-workspace-token-#{api_token.id}") |> render_click() =~
               "Workspace token revoked."

      assert Repo.reload!(api_token).revoked_at
      assert has_element?(view, "#workspace-token-status-#{api_token.id}", "Revoked")
      refute has_element?(view, "#revoke-workspace-token-#{api_token.id}")
    end

    test "a member or guest has no Tokens section and crafted token events are denied", ctx do
      {:ok, {api_token, _}} =
        Kanban.ApiTokens.create_workspace_api_token(ctx.org_admin, ctx.workspace, %{name: "A"})

      for viewer <- [ctx.member, ctx.guest] do
        conn = ctx.conn |> log_in_user(viewer) |> switch(ctx.workspace)
        {:ok, view, _html} = live(conn, ~p"/workspace/settings?section=tokens")

        refute has_element?(view, "#settings-tab-tokens")
        refute has_element?(view, "#workspace-token-form")
        assert has_element?(view, "#members")

        events = [
          {"create_token", %{"token" => %{"name" => "Crafted"}}},
          {"revoke_token", %{"id" => Integer.to_string(api_token.id)}},
          {"create_token", %{}},
          {"revoke_token", %{}}
        ]

        for {event, params} <- events do
          assert render_click(view, event, params) =~ @denied
        end

        refute render(view) =~ "workspace-token-value"
      end

      assert [%{id: id, revoked_at: nil}] =
               workspace_tokens(ctx.workspace)

      assert id == api_token.id
    end

    test "an org-admin demoted while the page is open cannot create a token", ctx do
      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=tokens")

      from(m in OrganizationMember, where: m.user_id == ^ctx.org_admin.id)
      |> Repo.update_all(set: [role: :member])

      assert create_token(view) =~ @denied
      assert workspace_tokens(ctx.workspace) == []
    end
  end

  describe "denial" do
    test "a member or guest crafting every management event is denied and audited", ctx do
      board = board_fixture(ctx.member, %{name: "Member board"})

      for viewer <- [ctx.member, ctx.guest] do
        conn = ctx.conn |> log_in_user(viewer) |> switch(ctx.workspace)
        {:ok, view, _html} = live(conn, ~p"/workspace/settings")

        events = [
          {"update_role", %{"user_id" => Integer.to_string(ctx.guest.id), "role" => "member"}},
          {"remove_member", %{"user_id" => Integer.to_string(ctx.guest.id)}},
          {"move_board", %{"move" => %{"board_id" => Integer.to_string(board.id)}}},
          {"update_role", %{}},
          {"remove_member", %{}},
          {"move_board", %{}}
        ]

        for {event, params} <- events do
          assert render_click(view, event, params) =~ @denied
        end

        assert [_ | _] =
                 AuditLog.list_events(action: :permission_denied, actor_user_id: viewer.id)
      end

      assert Workspaces.get_member_role(ctx.workspace, ctx.guest) == :guest
      refute Repo.get!(Board, board.id).workspace_id == ctx.workspace.id
    end

    test "an org-admin demoted while the page is open is denied", ctx do
      {view, _html} = admin_view(ctx)

      from(m in OrganizationMember, where: m.user_id == ^ctx.org_admin.id)
      |> Repo.update_all(set: [role: :member])

      assert render_click(view, "remove_member", %{"user_id" => Integer.to_string(ctx.member.id)}) =~
               @denied

      assert Workspaces.get_member_role(ctx.workspace, ctx.member) == :member
    end

    test "a disabled org-admin is denied", ctx do
      {view, _html} = admin_view(ctx)

      ctx.org_admin
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert render_click(view, "update_role", %{
               "user_id" => Integer.to_string(ctx.member.id),
               "role" => "guest"
             }) =~ @denied
    end
  end

  describe "export (W2222)" do
    setup do
      dir =
        Path.join([
          System.tmp_dir!(),
          "stride_settings_export",
          "#{System.unique_integer([:positive])}"
        ])

      previous = Application.get_env(:kanban, :export_dir)
      Application.put_env(:kanban, :export_dir, dir)

      on_exit(fn ->
        Application.put_env(:kanban, :export_dir, previous)
        File.rm_rf(dir)
      end)

      :ok
    end

    test "an org-admin requests an export and sees it become ready without waiting", ctx do
      {view, _html} = admin_view(ctx)
      assert has_element?(view, "#settings-tab-export")

      render_click(view, "select_section", %{"section" => "export"})
      assert_patch(view, ~p"/workspace/settings?section=export")
      assert has_element?(view, "#no-workspace-exports")

      assert view |> element("#request-workspace-export") |> render_click() =~ "Export requested."

      assert [export] = Repo.all(Kanban.Workspaces.Export.WorkspaceExport)
      assert export.workspace_id == ctx.workspace.id
      assert_enqueued(worker: Kanban.Workspaces.Export.Worker, args: %{"export_id" => export.id})
      assert has_element?(view, "#workspace-export-status-#{export.id}", "Pending")
      assert has_element?(view, "#request-workspace-export[disabled]")
      refute has_element?(view, "#download-workspace-export-#{export.id}")

      assert %{success: 1} = Oban.drain_queue(queue: :workspace_exports)

      assert render(view) =~ "Ready to download"
      assert has_element?(view, "#workspace-export-status-#{export.id}", "Ready to download")

      assert has_element?(
               view,
               ~s(#download-workspace-export-#{export.id}[href="/workspace/exports/#{export.id}/download"])
             )

      refute has_element?(view, "#request-workspace-export[disabled]")
    end

    test "a second request while one is pending says so", ctx do
      {view, _html} = admin_view(ctx, ~p"/workspace/settings?section=export")
      render_click(view, "request_export", %{})
      assert render_click(view, "request_export", %{}) =~ "already in progress"
      assert Repo.aggregate(Kanban.Workspaces.Export.WorkspaceExport, :count) == 1
    end

    test "a member or guest has no Export section and a crafted request is denied", ctx do
      for viewer <- [ctx.member, ctx.guest] do
        conn = ctx.conn |> log_in_user(viewer) |> switch(ctx.workspace)
        {:ok, view, _html} = live(conn, ~p"/workspace/settings?section=export")

        refute has_element?(view, "#settings-tab-export")
        refute has_element?(view, "#request-workspace-export")
        assert has_element?(view, "#members")
        assert render_click(view, "request_export", %{}) =~ @denied
      end

      assert Repo.aggregate(Kanban.Workspaces.Export.WorkspaceExport, :count) == 0
      refute_enqueued(worker: Kanban.Workspaces.Export.Worker)
    end
  end
end
