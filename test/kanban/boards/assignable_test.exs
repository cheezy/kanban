defmodule Kanban.Boards.AssignableTest do
  @moduledoc """
  Who a board's tasks may be newly assigned to (`Kanban.Boards.Assignable`):
  enabled members with a row, and enabled org-admins of the board's
  Organization, who reach it through derived access and can already claim its
  tasks.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Assignable
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.BulkActions
  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.OptionBuilders

  setup do
    organization = organization_fixture()
    workspace = org_workspace_fixture(organization)
    owner = user_fixture()
    organization_member_fixture(organization, owner)
    board = board_fixture(owner)

    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)

    %{
      organization: organization,
      owner: owner,
      board: Repo.get!(Board, board.id),
      org_admin: org_admin
    }
  end

  defp disable!(user),
    do: user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()

  describe "member?/3" do
    test "accepts a member with a row and an org-admin with none", ctx do
      assert Assignable.member?(ctx.board.id, ctx.owner.id)
      assert Assignable.member?(ctx.board.id, ctx.org_admin.id)
    end

    test "refuses an ordinary Organization member with no row, and an outsider", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)

      refute Assignable.member?(ctx.board.id, member.id)
      refute Assignable.member?(ctx.board.id, user_fixture().id)
    end

    test "refuses an org-admin of another Organization", ctx do
      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      refute Assignable.member?(ctx.board.id, other_admin.id)
    end

    test "refuses disabled accounts, with or without a row", ctx do
      refute Assignable.member?(ctx.board.id, disable!(ctx.org_admin).id)
      refute Assignable.member?(ctx.board.id, disable!(ctx.owner).id)
    end
  end

  describe "list_derived_assignees/1" do
    test "lists the enabled org-admins who hold no row", ctx do
      assert [%{id: id}] = Assignable.list_derived_assignees(ctx.board.id)
      assert id == ctx.org_admin.id
    end

    test "leaves out an org-admin who already holds a row, and disabled ones", ctx do
      {:ok, _} = Boards.add_user_to_board(ctx.board, ctx.org_admin, :read_only, ctx.owner)
      second_admin = user_fixture()
      organization_member_fixture(ctx.organization, second_admin, :org_admin)
      disable!(second_admin)

      assert Assignable.list_derived_assignees(ctx.board.id) == []
    end

    test "is empty for a personal-workspace board" do
      assert Assignable.list_derived_assignees(board_fixture(user_fixture()).id) == []
    end
  end

  describe "the assignee lists" do
    test "list_assignable_board_members/1 offers the org-admin after the members", ctx do
      user_ids = ctx.board.id |> Boards.list_assignable_board_members() |> Enum.map(& &1.user_id)

      assert user_ids == [ctx.owner.id, ctx.org_admin.id]
    end

    test "the task form's assignee options include the org-admin", ctx do
      options =
        ctx.board
        |> OptionBuilders.assignable_board_users()
        |> OptionBuilders.build_assignable_users_options()

      assert Enum.any?(options, fn {_label, id} -> id == ctx.org_admin.id end)
    end
  end

  describe "assigning work to a derived-only org-admin" do
    test "BulkActions.assign/4 accepts them", ctx do
      task = task_fixture(column_fixture(ctx.board))
      scope = Scope.for_user(ctx.owner)

      assert {:ok, %{count: 1}} =
               BulkActions.assign(scope, ctx.board, [task.id], ctx.org_admin.id)

      assert Repo.get!(Task, task.id).assigned_to_id == ctx.org_admin.id
    end
  end
end
