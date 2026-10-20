defmodule KanbanWeb.API.WorkspaceTokenFlowTest do
  @moduledoc """
  End to end through the router (W2220): one workspace token works tasks on two
  boards of its workspace by naming each board per request.
  """
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks

  @moduletag capture_log: true

  setup %{conn: conn} do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    workspace = org_workspace_fixture(organization)
    board_a = workspace_board(workspace)
    board_b = workspace_board(workspace)

    {:ok, {_, plain}} =
      ApiTokens.create_workspace_api_token(admin, workspace, %{
        name: "Fleet",
        agent_capabilities: ["code_generation"]
      })

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain}")

    %{conn: conn, admin: admin, organization: organization, board_a: board_a, board_b: board_b}
  end

  test "claims and completes a task on board A, then on board B", ctx do
    task_a = ready_task(ctx.board_a, ctx.admin, "Task A")
    task_b = ready_task(ctx.board_b, ctx.admin, "Task B")

    for {board, task} <- [{ctx.board_a, task_a}, {ctx.board_b, task_b}] do
      claimed =
        ctx.conn
        |> put_req_header("x-stride-board", Integer.to_string(board.id))
        |> post(~p"/api/tasks/claim", %{
          "identifier" => task.identifier,
          "before_doing_result" => hook_result()
        })
        |> json_response(200)

      assert claimed["data"]["id"] == task.id
      assert claimed["data"]["assigned_to_id"] == ctx.admin.id

      completed =
        ctx.conn
        |> patch(~p"/api/tasks/#{task.id}/complete?board_id=#{board.id}", %{
          "completion_summary" => "Done",
          "actual_complexity" => "small",
          "actual_files_changed" => "1",
          "time_spent_minutes" => 5,
          "after_doing_result" => hook_result(),
          "before_review_result" => hook_result()
        })
        |> json_response(200)

      assert completed["data"]["id"] == task.id
      assert completed["data"]["completed_at"]
    end
  end

  test "a task on board B is not reachable while board A is selected", ctx do
    task_b = ready_task(ctx.board_b, ctx.admin, "Task B")

    on_board_a = put_req_header(ctx.conn, "x-stride-board", Integer.to_string(ctx.board_a.id))

    # The same 404 as a task that does not exist, so the response never tells
    # a task on another board apart from a missing one (D160).
    missing = on_board_a |> get(~p"/api/tasks/999999999") |> json_response(404)
    assert on_board_a |> get(~p"/api/tasks/#{task_b.id}") |> json_response(404) == missing
  end

  test "a board-bound route without a selector gets 400", ctx do
    assert %{"error" => "Board selector required"} =
             ctx.conn |> get(~p"/api/tasks/next") |> json_response(400)

    assert %{"error" => "Board selector required"} =
             ctx.conn
             |> put_req_header("content-type", "application/json")
             |> post(
               ~p"/api/mcp",
               Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
             )
             |> json_response(400)
  end

  test "GET and DELETE /api/mcp answer 405 without a selector", ctx do
    assert ctx.conn |> get(~p"/api/mcp") |> response(405)
    assert ctx.conn |> delete(~p"/api/mcp") |> response(405)
  end

  test "a selected board outside the workspace gets 404", ctx do
    stranger_board = ai_optimized_board_fixture(user_fixture())

    # Boards the token's user can modify, but outside the token's workspace:
    # one in another workspace of the same Organization (derived org-admin
    # access) and one of their own.
    sibling_board = ctx.organization |> org_workspace_fixture() |> workspace_board()
    own_board = ai_optimized_board_fixture(ctx.admin)

    for outside <- [stranger_board, sibling_board, own_board] do
      assert ctx.conn
             |> put_req_header("x-stride-board", Integer.to_string(outside.id))
             |> get(~p"/api/tasks/next")
             |> json_response(404) == %{"error" => "Board not found"}
    end
  end

  defp ready_task(board, user, title) do
    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

    {:ok, task} =
      Tasks.create_task(ready, %{
        "title" => title,
        "status" => "open",
        "created_by_id" => user.id,
        "needs_review" => false
      })

    task
  end

  defp hook_result, do: %{"exit_code" => 0, "output" => "ok", "duration_ms" => 10}

  defp workspace_board(workspace) do
    board = ai_optimized_board_fixture(user_fixture())

    {1, _} =
      from(b in Board, where: b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.reload!(board)
  end
end
