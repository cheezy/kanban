defmodule KanbanWeb.BoardLive.WorkspaceBoardsTest do
  # Not async: some tests switch plan enforcement on for the VM.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Workspaces

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

  setup do
    organization = organization_fixture()
    member = user_fixture()
    organization_member_fixture(organization, member, :member)
    workspace = org_workspace_fixture(organization, name: "Platform")
    workspace_member_fixture(workspace, member, :member)

    %{organization: organization, member: member, workspace: workspace}
  end

  describe "/boards grouping" do
    test "a user with a current workspace sees the workspace, personal and shared groups", ctx do
      in_workspace =
        board_fixture(user_fixture(), %{name: "Workspace board"})
        |> put_in_workspace(ctx.workspace)

      grant(in_workspace, ctx.member, :read_only)
      personal = board_fixture(ctx.member, %{name: "Personal board"})
      shared = board_fixture(user_fixture(), %{name: "Shared board"})
      grant(shared, ctx.member, :modify)

      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.member), ~p"/boards")

      assert has_element?(view, "#workspace-boards #workspace_boards-#{in_workspace.id}")
      assert has_element?(view, "#personal-boards #personal_boards-#{personal.id}")
      assert has_element?(view, "#shared-boards #shared_boards-#{shared.id}")
      refute has_element?(view, "#boards")
    end

    test "a user without a current workspace sees the flat list as before" do
      user = user_fixture()
      board = board_fixture(user, %{name: "Flat board"})

      {:ok, view, _html} = live(log_in_user(build_conn(), user), ~p"/boards")

      assert has_element?(view, "#boards #boards-#{board.id}")
      refute has_element?(view, "#workspace-boards")
      refute has_element?(view, "#personal-boards")
    end

    test "a memberless board backfilled into a site admin's personal workspace is neither listed nor reachable" do
      admin = user_fixture()
      admin |> Ecto.Changeset.change(type: :admin) |> Repo.update!()
      own = board_fixture(admin, %{name: "Admin board"})
      backfilled = admin |> personal_workspace_fixture() |> place_board_in_workspace()
      conn = log_in_user(build_conn(), admin)

      {:ok, view, html} = live(conn, ~p"/boards")

      assert has_element?(view, "#boards-#{own.id}")
      refute html =~ "boards-#{backfilled.id}\""

      assert {:error, {_kind, %{to: "/boards"}}} = live(conn, ~p"/boards/#{backfilled.id}")
    end
  end

  describe "creating a board" do
    test "a workspace member's new board lands in their current workspace", ctx do
      conn = log_in_user(build_conn(), ctx.member)
      {:ok, lv, _html} = live(conn, ~p"/boards/new")

      lv
      |> form("#board-form", board: %{name: "Team roadmap", description: "Next quarter"})
      |> render_submit()

      board = Repo.get_by!(Board, name: "Team roadmap")
      assert board.workspace_id == ctx.workspace.id
    end

    test "a user without a current workspace's new board lands in their personal workspace" do
      user = user_fixture()
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), ~p"/boards/new")

      lv
      |> form("#board-form", board: %{name: "Solo roadmap", description: "Mine"})
      |> render_submit()

      board = Repo.get_by!(Board, name: "Solo roadmap")
      assert board.workspace_id == Workspaces.get_personal_workspace(user).id
    end

    test "a guest's new board lands in their personal workspace, not the current one", ctx do
      guest = user_fixture()
      organization_member_fixture(ctx.organization, guest, :member)
      workspace_member_fixture(ctx.workspace, guest, :guest)
      {:ok, lv, _html} = live(log_in_user(build_conn(), guest), ~p"/boards/new")

      lv
      |> form("#board-form", board: %{name: "Guest roadmap", description: "Theirs"})
      |> render_submit()

      board = Repo.get_by!(Board, name: "Guest roadmap")
      assert board.workspace_id == Workspaces.get_personal_workspace(guest).id
    end
  end

  describe "moving a board with the members screen open" do
    test "drops the free-board cap line without a reload", ctx do
      org_admin = user_fixture()
      organization_member_fixture(ctx.organization, org_admin, :org_admin)
      board = board_fixture(org_admin, %{name: "Capped board"})
      grant(board, user_fixture(), :read_only)
      enforce_plans()

      {:ok, lv, _html} = live(log_in_user(build_conn(), org_admin), ~p"/boards/#{board}/members")
      assert lv |> element("#member-cap-line") |> render() =~ "2 of 3 people"

      {:ok, _} = Workspaces.move_board_to_workspace(org_admin, board, ctx.workspace)

      # The broadcast and the component update are messages; render/1 is a
      # synchronous call that lets the view process both first.
      _ = render(lv)
      refute has_element?(lv, "#member-cap-line")
    end
  end

  describe "access going stale while the board is open" do
    test "a member removed from the board is sent back to /boards", ctx do
      owner = user_fixture()
      board = board_fixture(owner)
      grant(board, ctx.member, :modify)

      {:ok, lv, _html} = live(log_in_user(build_conn(), ctx.member), ~p"/boards/#{board}")

      {:ok, _} = Kanban.Boards.remove_user_from_board(board, ctx.member, owner)

      assert_redirect(lv, ~p"/boards")
    end

    test "a member removed from a public read-only board stays on it", ctx do
      owner = user_fixture()
      board = board_fixture(owner)
      board |> Ecto.Changeset.change(read_only: true) |> Repo.update!()
      grant(board, ctx.member, :modify)

      {:ok, lv, _html} = live(log_in_user(build_conn(), ctx.member), ~p"/boards/#{board}")

      {:ok, _} = Kanban.Boards.remove_user_from_board(board, ctx.member, owner)

      assert render(lv) =~ board.name
    end

    test "an org-admin with derived access mints a token, and cannot once demoted", ctx do
      org_admin = user_fixture()
      organization_member_fixture(ctx.organization, org_admin, :org_admin)
      board = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)

      {:ok, lv, _html} = live(log_in_user(build_conn(), org_admin), ~p"/boards/#{board}")

      render_hook(lv, "create_token", %{"api_token" => %{"name" => "Admin Token"}})
      assert [_token] = Kanban.ApiTokens.list_api_tokens(board)

      {1, _} =
        from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^org_admin.id)
        |> Repo.update_all(set: [role: :member])

      render_hook(lv, "create_token", %{"api_token" => %{"name" => "Stale Token"}})

      assert render(lv) =~ "You do not have permission to manage API tokens"
      assert [_token] = Kanban.ApiTokens.list_api_tokens(board)
    end

    test "a demoted org-admin can no longer change field visibility", ctx do
      org_admin = user_fixture()
      organization_member_fixture(ctx.organization, org_admin, :org_admin)
      board = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)

      {:ok, lv, _html} = live(log_in_user(build_conn(), org_admin), ~p"/boards/#{board}")

      {1, _} =
        from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^org_admin.id)
        |> Repo.update_all(set: [role: :member])

      [field | _] = Board.toggleable_fields()
      render_hook(lv, "toggle_field", %{"field" => field})

      assert render(lv) =~ "Only board owners can change field visibility"
      assert Repo.get!(Board, board.id).field_visibility == board.field_visibility
    end

    test "an org-admin removed from the Organization is sent back to /boards", ctx do
      org_admin = user_fixture()
      organization_member_fixture(ctx.organization, org_admin, :org_admin)
      organization_member_fixture(ctx.organization, user_fixture(), :org_admin)
      board = user_fixture() |> board_fixture() |> put_in_workspace(ctx.workspace)

      {:ok, lv, _html} = live(log_in_user(build_conn(), org_admin), ~p"/boards/#{board}")

      {:ok, _} =
        Kanban.Organizations.remove_org_admin(admin_fixture(), ctx.organization, org_admin)

      assert_redirect(lv, ~p"/boards")
    end

    test "a member whose access went without a broadcast cannot delete a task", ctx do
      owner = user_fixture()
      board = board_fixture(owner)
      task = board |> column_fixture() |> task_fixture()
      grant(board, ctx.member, :modify)

      {:ok, lv, _html} = live(log_in_user(build_conn(), ctx.member), ~p"/boards/#{board}")

      from(bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^ctx.member.id)
      |> Repo.delete_all()

      assert render_hook(lv, "delete_task", %{"id" => Integer.to_string(task.id)}) =~
               "You do not have permission to delete tasks on this board"

      assert Repo.get(Kanban.Tasks.Task, task.id)
    end

    test "a member whose access went without a broadcast cannot run a bulk action", ctx do
      owner = user_fixture()
      board = board_fixture(owner)
      task = board |> column_fixture() |> task_fixture()
      grant(board, ctx.member, :modify)

      {:ok, lv, _html} = live(log_in_user(build_conn(), ctx.member), ~p"/boards/#{board}")
      lv |> element("#bulk-select-toggle") |> render_click()
      lv |> element("#bulk-select-#{task.id}") |> render_click()

      from(bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^ctx.member.id)
      |> Repo.delete_all()

      assert render_hook(lv, "bulk_archive", %{}) =~
               "You do not have permission to modify tasks on this board"

      assert is_nil(Repo.get!(Kanban.Tasks.Task, task.id).archived_at)
    end
  end
end
