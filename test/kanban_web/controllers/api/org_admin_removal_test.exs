defmodule KanbanWeb.API.OrgAdminRemovalTest do
  @moduledoc """
  A removed org-admin's board token stops working through the API at once,
  whether their write access to the Organization's board came from an explicit
  `board_users` row or from derived org-admin access.
  """
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Repo

  @moduletag capture_log: true

  setup do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    organization_member_fixture(organization, user_fixture(), :org_admin)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, org_admin, :member)

    explicit = org_board(workspace)
    grant(explicit, org_admin, :modify)

    %{
      organization: organization,
      org_admin: org_admin,
      explicit: explicit,
      derived: org_board(workspace)
    }
  end

  defp org_board(workspace) do
    board = ai_optimized_board_fixture(user_fixture())

    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.get!(Board, board.id)
  end

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  defp plain_token(user, board) do
    {:ok, {_token, plain}} = ApiTokens.create_api_token(user, board, %{name: "Agent"})
    plain
  end

  defp create_task(conn, plain) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> plain)
    |> post(~p"/api/tasks", task: %{"title" => "After removal"})
  end

  test "refuses writes with the removed org-admin's tokens", %{conn: conn} = ctx do
    explicit_token = plain_token(ctx.org_admin, ctx.explicit)
    derived_token = plain_token(ctx.org_admin, ctx.derived)

    assert %{status: 201} = create_task(conn, explicit_token)
    assert %{status: 201} = create_task(conn, derived_token)

    assert {:ok, _membership} =
             Organizations.remove_org_admin(admin_fixture(), ctx.organization, ctx.org_admin)

    assert %{status: 401} = create_task(conn, explicit_token)
    assert %{status: 401} = create_task(conn, derived_token)
  end
end
