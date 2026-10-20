defmodule Kanban.Boards.AccessDowngradeTest do
  @moduledoc """
  `Boards.update_user_access/4` to `:read_only` and
  `Boards.remove_user_from_board/3`: when the change ends the user's write
  access it revokes their board tokens and unassigns their open tasks; an
  org-admin keeps owner access through their role, so their tokens and tasks
  stay.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.Archiving
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    %{owner: owner, board: board, column: column_fixture(board)}
  end

  defp token_for(user, board) do
    {:ok, {token, _plain}} = ApiTokens.create_api_token(user, board, %{"name" => "Agent"})
    token
  end

  defp revoked?(%ApiToken{id: id}), do: not is_nil(Repo.get!(ApiToken, id).revoked_at)
  defp assignee(%Task{id: id}), do: Repo.get!(Task, id).assigned_to_id

  describe "an ordinary member lowered to read-only" do
    setup %{board: board, owner: owner} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      %{member: member}
    end

    test "loses their board token and their open tasks", ctx do
      token = token_for(ctx.member, ctx.board)
      open = task_fixture(ctx.column, %{assigned_to_id: ctx.member.id})

      in_progress =
        task_fixture(ctx.column, %{assigned_to_id: ctx.member.id, status: :in_progress})

      assert {:ok, %{access: :read_only}} =
               Boards.update_user_access(ctx.board, ctx.member, :read_only, ctx.owner)

      assert revoked?(token)
      assert assignee(open) == nil
      assert assignee(in_progress) == nil
    end

    test "keeps their assignment on an archived task as a record", ctx do
      {:ok, archived} =
        ctx.column
        |> task_fixture(%{assigned_to_id: ctx.member.id})
        |> Archiving.archive_task()

      {:ok, _} = Boards.update_user_access(ctx.board, ctx.member, :read_only, ctx.owner)

      assert assignee(archived) == ctx.member.id
    end

    test "leaves other people's tasks assigned", ctx do
      owners_task = task_fixture(ctx.column, %{assigned_to_id: ctx.owner.id})

      {:ok, _} = Boards.update_user_access(ctx.board, ctx.member, :read_only, ctx.owner)

      assert assignee(owners_task) == ctx.owner.id
    end

    test "removal from the board revokes their token and unassigns their open tasks", ctx do
      token = token_for(ctx.member, ctx.board)
      open = task_fixture(ctx.column, %{assigned_to_id: ctx.member.id})

      assert {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.member, ctx.owner)

      assert revoked?(token)
      assert assignee(open) == nil
    end

    test "an upgrade back to modify changes neither tokens nor tasks", ctx do
      {:ok, _} = Boards.update_user_access(ctx.board, ctx.member, :read_only, ctx.owner)
      token = token_for(ctx.member, ctx.board)
      task = task_fixture(ctx.column, %{assigned_to_id: ctx.member.id})

      {:ok, _} = Boards.update_user_access(ctx.board, ctx.member, :modify, ctx.owner)

      refute revoked?(token)
      assert assignee(task) == ctx.member.id
    end
  end

  describe "an org-admin's own row lowered to read-only" do
    setup %{board: board, owner: owner} do
      organization = organization_fixture()
      organization_member_fixture(organization, owner)
      workspace = org_workspace_fixture(organization)

      {1, _} =
        Board
        |> where([b], b.id == ^board.id)
        |> Repo.update_all(set: [workspace_id: workspace.id])

      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      board = Repo.get!(Board, board.id)
      {:ok, _} = Boards.add_user_to_board(board, org_admin, :modify, owner)

      %{board: board, org_admin: org_admin}
    end

    test "removing their row keeps their token and their tasks, since their role still gives owner access",
         ctx do
      token = token_for(ctx.org_admin, ctx.board)
      task = task_fixture(ctx.column, %{assigned_to_id: ctx.org_admin.id})

      assert {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.org_admin, ctx.owner)

      refute revoked?(token)
      assert assignee(task) == ctx.org_admin.id
      assert Boards.get_user_access(ctx.board.id, ctx.org_admin.id) == :owner
    end

    test "keeps their token and their tasks, since their role still gives owner access", ctx do
      token = token_for(ctx.org_admin, ctx.board)
      task = task_fixture(ctx.column, %{assigned_to_id: ctx.org_admin.id})

      assert {:ok, %{access: :read_only}} =
               Boards.update_user_access(ctx.board, ctx.org_admin, :read_only, ctx.owner)

      refute revoked?(token)
      assert assignee(task) == ctx.org_admin.id
      assert Boards.get_user_access(ctx.board.id, ctx.org_admin.id) == :owner
    end
  end
end
