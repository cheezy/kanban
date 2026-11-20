defmodule Kanban.Boards.AppBoardIdsTest do
  @moduledoc """
  Tests for `Kanban.Boards.list_app_board_ids/1`, the boards the app's live
  channels subscribe to (W2766).
  """
  # async: false - one test switches the global :plans_enforced application env on.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards

  setup do
    user = user_fixture()
    %{user: user, scope: user_scope_fixture(user)}
  end

  test "lists the boards the person owns or is a member of, ascending", ctx do
    owner = user_fixture()
    shared = ai_optimized_board_fixture(owner)
    {:ok, _member} = Boards.add_user_to_board(shared, ctx.user, :read_only, owner)
    own = ai_optimized_board_fixture(ctx.user)
    _stranger = ai_optimized_board_fixture(owner)

    assert Boards.list_app_board_ids(ctx.scope) == Enum.sort([own.id, shared.id])
  end

  test "includes the boards an org-admin reaches without a membership row", ctx do
    organization = organization_fixture()
    organization_member_fixture(organization, ctx.user, :org_admin)
    board = organization |> org_workspace_fixture() |> place_board_in_workspace()

    assert Boards.list_app_board_ids(ctx.scope) == [board.id]
  end

  test "leaves out the boards the plan does not unlock", ctx do
    free = ai_optimized_board_fixture(ctx.user)
    organization = organization_fixture()
    organization_member_fixture(organization, ctx.user)
    workspace = org_workspace_fixture(organization)

    paid =
      ctx.user
      |> ai_optimized_board_fixture()
      |> Ecto.Changeset.change(workspace_id: workspace.id)
      |> Repo.update!()

    assert Boards.list_app_board_ids(ctx.scope) == Enum.sort([free.id, paid.id])

    enforce_plans()
    assert Boards.list_app_board_ids(ctx.scope) == [paid.id]
  end

  test "a person with no boards, or a scope with no user, gets none", ctx do
    assert Boards.list_app_board_ids(ctx.scope) == []
    assert Boards.list_app_board_ids(%Scope{user: nil}) == []
    assert Boards.list_app_board_ids(nil) == []
  end
end
