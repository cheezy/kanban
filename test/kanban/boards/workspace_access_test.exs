defmodule Kanban.Boards.WorkspaceAccessTest do
  @moduledoc """
  `Kanban.Boards` access and creation through workspaces (W2218): derived
  org-admin access in `get_board/2`, `get_user_access/2`, `owner?/2`,
  `can_modify?/2` and `list_boards/1`, in the board-scoped reads (labels, goal
  children, member search, `Kanban.Queries.BoardScope` and My Work), and
  `create_board/3` targeting the current workspace.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [from: 2, where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Boards.MemberSearch
  alias Kanban.Labels
  alias Kanban.Labels.TaskLabel
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias Kanban.Workspaces

  setup do
    organization = organization_fixture()
    workspace = org_workspace_fixture(organization)
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)

    %{organization: organization, workspace: workspace, org_admin: org_admin}
  end

  defp org_board(workspace, attrs \\ %{}) do
    board = board_fixture(user_fixture(), attrs)

    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.get!(Board, board.id)
  end

  describe "derived access" do
    test "an org-admin with no row reaches and owns an org board", %{
      workspace: workspace,
      org_admin: org_admin
    } do
      board = org_board(workspace)

      assert {:ok, %Board{user_access: :owner}} = Boards.get_board(board.id, org_admin)
      assert Boards.get_user_access(board.id, org_admin.id) == :owner
      assert Boards.owner?(board, org_admin)
      assert Boards.can_modify?(board, org_admin)
    end

    test "an org-admin with a read_only row gets the stronger, owner access", %{
      workspace: workspace,
      org_admin: org_admin
    } do
      board = org_board(workspace)

      %BoardUser{}
      |> BoardUser.changeset(%{board_id: board.id, user_id: org_admin.id, access: :read_only})
      |> Repo.insert!()

      assert Boards.get_user_access(board.id, org_admin.id) == :owner
    end

    test "a workspace member with no row gets no access", %{
      organization: organization,
      workspace: workspace
    } do
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)
      board = org_board(workspace)

      assert Boards.get_board(board.id, member) == {:error, :not_found}
      assert Boards.get_user_access(board.id, member.id) == nil
      refute Boards.owner?(board, member)
      refute Boards.can_modify?(board, member)
    end

    test "a read-only org board is visible to an outsider with user_access nil", %{
      workspace: workspace
    } do
      board = org_board(workspace, %{read_only: true})

      board
      |> Ecto.Changeset.change(read_only: true)
      |> Repo.update!()

      assert {:ok, %Board{user_access: nil}} = Boards.get_board(board.id, user_fixture())
    end

    test "legacy board_users access is honoured unchanged on a personal board" do
      owner = user_fixture()
      reader = user_fixture()
      board = board_fixture(owner)

      %BoardUser{}
      |> BoardUser.changeset(%{board_id: board.id, user_id: reader.id, access: :read_only})
      |> Repo.insert!()

      assert {:ok, %Board{user_access: :owner}} = Boards.get_board(board.id, owner)
      assert {:ok, %Board{user_access: :read_only}} = Boards.get_board(board.id, reader)
      assert Boards.get_board(board.id, user_fixture()) == {:error, :not_found}
    end
  end

  describe "derived access in board-scoped reads" do
    setup %{organization: organization, workspace: workspace} do
      board = org_board(workspace)
      column = column_fixture(board)
      label = label_fixture(board)
      task = task_fixture(column)
      Repo.insert!(%TaskLabel{task_id: task.id, label_id: label.id})
      goal = task_fixture(column, %{type: :goal})
      child = task_fixture(column, %{parent_id: goal.id})

      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)

      %{board: board, label: label, task: task, goal: goal, child: child, member: member}
    end

    test "labels reach an org-admin with no row, never a workspace member", ctx do
      admin_scope = Scope.for_user(ctx.org_admin)
      member_scope = Scope.for_user(ctx.member)

      assert [%{id: label_id}] = Labels.list_labels(admin_scope, ctx.board)
      assert label_id == ctx.label.id
      assert [%{id: ^label_id}] = Labels.list_viewable_labels(admin_scope, ctx.board)
      assert Labels.list_task_label_ids(admin_scope, ctx.task) == [label_id]

      assert Labels.list_labels(member_scope, ctx.board) == []
      assert Labels.list_viewable_labels(member_scope, ctx.board) == []
      assert Labels.list_task_label_ids(member_scope, ctx.task) == []
    end

    test "goal children reach an org-admin with no row, never a workspace member", ctx do
      assert [%{id: child_id}] = Tasks.list_children_for_goal(ctx.org_admin, ctx.goal.id)
      assert child_id == ctx.child.id
      assert Tasks.list_children_for_goal(ctx.member, ctx.goal.id) == []
    end

    test "member search reaches an org-admin with no row, never a workspace member", ctx do
      admin_scope = Scope.for_user(ctx.org_admin)
      member_scope = Scope.for_user(ctx.member)

      assert {:ok, _members} = MemberSearch.search_board_members(admin_scope, ctx.board, "", 5)

      assert MemberSearch.search_board_members(member_scope, ctx.board, "", 5) ==
               {:error, :unauthorized}
    end

    test "BoardScope lists the board's tasks to an org-admin once each, never to a member", ctx do
      scoped_ids = fn scope ->
        from(t in Task, join: c in assoc(t, :column), as: :column)
        |> BoardScope.apply_board_scope(scope)
        |> Repo.all()
        |> Enum.map(& &1.id)
      end

      joined_ids = fn scope ->
        Task
        |> BoardScope.apply_board_scope_with_column_join(scope)
        |> Repo.all()
        |> Enum.map(& &1.id)
      end

      expected = Enum.sort([ctx.task.id, ctx.goal.id, ctx.child.id])
      admin_scope = Scope.for_user(ctx.org_admin)

      member_scope = Scope.for_user(ctx.member)
      assert admin_scope |> scoped_ids.() |> Enum.sort() == expected
      assert admin_scope |> joined_ids.() |> Enum.sort() == expected
      assert scoped_ids.(member_scope) == []
      assert joined_ids.(member_scope) == []
    end

    test "My Work lists an org-admin's assigned task on a board they hold no row on, as owner",
         ctx do
      {:ok, _} = Tasks.update_task(ctx.task, %{assigned_to_id: ctx.org_admin.id})

      assert [listed] = ctx.org_admin |> Scope.for_user() |> Tasks.list_assigned_tasks()
      assert listed.id == ctx.task.id
      assert listed.column.board.user_access == :owner
    end

    test "My Work keeps explicit access for a read-only member", ctx do
      %BoardUser{}
      |> BoardUser.changeset(%{
        board_id: ctx.board.id,
        user_id: ctx.member.id,
        access: :read_only
      })
      |> Repo.insert!()

      {:ok, _} = Tasks.update_task(ctx.task, %{assigned_to_id: ctx.member.id})

      assert [listed] = ctx.member |> Scope.for_user() |> Tasks.list_assigned_tasks()
      assert listed.column.board.user_access == :read_only
    end
  end

  describe "list_boards/1" do
    test "includes the Organization's boards for an org-admin, once each, owner first", %{
      workspace: workspace,
      org_admin: org_admin
    } do
      derived = org_board(workspace)
      explicit_reader = board_fixture(user_fixture())

      %BoardUser{}
      |> BoardUser.changeset(%{
        board_id: explicit_reader.id,
        user_id: org_admin.id,
        access: :read_only
      })
      |> Repo.insert!()

      own = board_fixture(org_admin)

      boards = Boards.list_boards(org_admin)

      assert Enum.map(boards, & &1.id) |> Enum.sort() ==
               Enum.sort([derived.id, explicit_reader.id, own.id])

      assert List.last(boards).id == explicit_reader.id
      assert Enum.uniq_by(boards, & &1.id) == boards
    end

    test "never lists a backfilled personal-workspace board to that workspace's owner" do
      site_admin = user_fixture() |> Ecto.Changeset.change(type: :admin) |> Repo.update!()
      board = site_admin |> personal_workspace_fixture() |> place_board_in_workspace()

      refute site_admin |> Boards.list_boards() |> Enum.any?(&(&1.id == board.id))
      assert Boards.get_board(board.id, site_admin) == {:error, :not_found}
    end
  end

  describe "create_board/3" do
    test "creates in the workspace for its org-admin", %{
      workspace: workspace,
      org_admin: org_admin
    } do
      assert {:ok, board} =
               Boards.create_board(org_admin, %{name: "Org board"}, workspace: workspace)

      assert board.workspace_id == workspace.id
      assert Boards.get_user_access(board.id, org_admin.id) == :owner
    end

    test "creates in the workspace for a workspace member, by id too", %{
      organization: organization,
      workspace: workspace
    } do
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)

      assert {:ok, board} =
               Boards.create_board(member, %{name: "Member board"}, workspace: workspace.id)

      assert board.workspace_id == workspace.id
    end

    test "falls back to the personal workspace for a guest, an outsider, an archived or foreign workspace",
         %{organization: organization, workspace: workspace} do
      guest = user_fixture()
      organization_member_fixture(organization, guest, :member)
      workspace_member_fixture(workspace, guest, :guest)
      outsider = user_fixture()
      archived = org_workspace_fixture(organization, archived_at: DateTime.utc_now(:second))
      archived_admin = user_fixture()
      organization_member_fixture(organization, archived_admin, :member)
      foreign_admin = user_fixture()
      organization_member_fixture(organization_fixture(), foreign_admin, :org_admin)

      for {user, target} <- [
            {guest, workspace},
            {outsider, workspace},
            {archived_admin, archived},
            {foreign_admin, workspace}
          ] do
        assert {:ok, board} =
                 Boards.create_board(user, %{name: "Fallback board"}, workspace: target)

        assert board.workspace_id == Workspaces.get_personal_workspace(user).id
      end
    end

    test "ignores a workspace_id in the attributes", %{workspace: workspace} do
      user = user_fixture()

      assert {:ok, board} =
               Boards.create_board(user, %{"name" => "Attr board", "workspace_id" => workspace.id})

      assert board.workspace_id == Workspaces.get_personal_workspace(user).id
    end

    test "create_ai_optimized_board/3 targets the workspace as well", %{
      workspace: workspace,
      org_admin: org_admin
    } do
      assert {:ok, board} =
               Boards.create_ai_optimized_board(org_admin, %{name: "AI board"},
                 workspace: workspace
               )

      assert board.workspace_id == workspace.id
      assert length(board.columns) == 5
    end
  end
end
