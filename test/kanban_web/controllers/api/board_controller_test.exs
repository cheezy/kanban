defmodule KanbanWeb.API.BoardControllerTest do
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias KanbanWeb.API.BoardJSON

  describe "GET /api/boards" do
    test "a board token sees its one board", %{conn: conn} do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      {:ok, {_, plain}} = ApiTokens.create_api_token(user, board, %{name: "Board"})

      body = conn |> authorize(plain) |> get(~p"/api/boards") |> json_response(200)

      assert body == %{
               "data" => [
                 %{
                   "id" => board.id,
                   "name" => board.name,
                   "description" => board.description,
                   "workspace_id" => board.workspace_id
                 }
               ],
               "meta" => %{"token_scope" => "board"}
             }
    end

    test "a workspace token sees only the boards it can use, sorted by name", %{conn: conn} do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)

      zulu = workspace_board(workspace, "Zulu board")
      alpha = workspace_board(workspace, "Alpha board")
      _not_ai = place_board_in_workspace(workspace)
      _other_workspace = workspace_board(org_workspace_fixture(organization), "Other")
      _foreign = workspace_board(org_workspace_fixture(organization_fixture()), "Foreign")

      {:ok, {_, plain}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "WS"})

      body = conn |> authorize(plain) |> get(~p"/api/boards") |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [alpha.id, zulu.id]
      assert Enum.all?(body["data"], &(&1["workspace_id"] == workspace.id))
      assert body["meta"] == %{"token_scope" => "workspace"}
    end

    test "a workspace token of a demoted org-admin lists only boards they can modify", %{
      conn: conn
    } do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)
      editable = workspace_board(workspace, "Editable")
      readable = workspace_board(workspace, "Readable")
      _hidden = workspace_board(workspace, "Hidden")

      Repo.insert!(%BoardUser{board_id: editable.id, user_id: admin.id, access: :modify})
      Repo.insert!(%BoardUser{board_id: readable.id, user_id: admin.id, access: :read_only})

      {:ok, {_, plain}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "WS"})

      from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^admin.id)
      |> Repo.update_all(set: [role: :member])

      body = conn |> authorize(plain) |> get(~p"/api/boards") |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [editable.id]
    end

    test "a workspace token of an archived workspace lists no boards", %{conn: conn} do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)
      workspace_board(workspace, "Board")
      {:ok, {_, plain}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "WS"})

      from(w in Kanban.Workspaces.Workspace, where: w.id == ^workspace.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      body = conn |> authorize(plain) |> get(~p"/api/boards") |> json_response(200)

      assert body["data"] == []
    end

    test "needs a valid token", %{conn: conn} do
      conn = get(conn, ~p"/api/boards")
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end
  end

  describe "BoardJSON.board/1" do
    test "renders the public fields of a board" do
      board = %Board{id: 7, name: "B", description: "D", workspace_id: 3}

      assert BoardJSON.board(board) == %{id: 7, name: "B", description: "D", workspace_id: 3}
    end
  end

  defp authorize(conn, plain) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{plain}")
  end

  defp workspace_board(workspace, name) do
    board = ai_optimized_board_fixture(user_fixture(), %{name: name})

    {1, _} =
      from(b in Board, where: b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.reload!(board)
  end
end
