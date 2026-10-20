defmodule KanbanWeb.WorkspaceLive.SettingsTest do
  # Not async: some tests switch plan enforcement on for the VM.
  use KanbanWeb.ConnCase, async: false

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
end
