defmodule KanbanWeb.API.NonAiBoardTokenTest do
  @moduledoc """
  D451: a board token whose board is no longer AI optimized is refused by API
  authentication on every surface, with the generic invalid-token body, and
  works again once the board is switched back on (the token is never revoked).
  """
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @moduletag capture_log: true

  @before_doing %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

    {:ok, task} =
      Tasks.create_task(ready, %{"title" => "D451 ready task", "created_by_id" => user.id})

    {:ok, {_token, plain}} = ApiTokens.create_api_token(user, board, %{"name" => "D451"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain}")

    %{conn: conn, board: board, task: task}
  end

  defp set_ai_optimized(board, value) do
    from(b in Board, where: b.id == ^board.id)
    |> Repo.update_all(set: [ai_optimized_board: value])
  end

  defp task_count(board) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([_t, c], c.board_id == ^board.id)
    |> Repo.aggregate(:count)
  end

  defp assert_refused(conn) do
    assert json_response(conn, 401) == %{"error" => "Invalid API token"}
  end

  test "a switched-off board token cannot create or claim a task", %{
    conn: conn,
    board: board,
    task: task
  } do
    set_ai_optimized(board, false)
    before = task_count(board)

    conn
    |> post(~p"/api/tasks", %{"task" => %{"title" => "Should not exist", "type" => "work"}})
    |> assert_refused()

    conn
    |> post(~p"/api/tasks/claim", %{
      "identifier" => task.identifier,
      "before_doing_result" => @before_doing
    })
    |> assert_refused()

    assert task_count(board) == before
    assert Repo.get!(Task, task.id).status == :open
  end

  test "every verb and the MCP endpoint refuse a switched-off board token", %{
    conn: conn,
    board: board,
    task: task
  } do
    set_ai_optimized(board, false)

    conn |> get(~p"/api/tasks/next") |> assert_refused()
    conn |> get(~p"/api/tasks/#{task.id}") |> assert_refused()

    conn
    |> patch(~p"/api/tasks/#{task.id}", %{"task" => %{"title" => "Renamed"}})
    |> assert_refused()

    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> post(
      ~p"/api/mcp",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    )
    |> assert_refused()

    assert Repo.get!(Task, task.id).title == "D451 ready task"
  end

  test "the refusal names neither the board nor its mode", %{conn: conn, board: board} do
    set_ai_optimized(board, false)

    body = conn |> get(~p"/api/tasks/next") |> response(401)

    refute body =~ board.name
    refute body =~ "optimized"
    refute body =~ "AI"
  end

  test "the token works again once the board is switched back on", %{conn: conn, board: board} do
    set_ai_optimized(board, false)
    conn |> get(~p"/api/tasks/next") |> assert_refused()

    set_ai_optimized(board, true)
    assert conn |> get(~p"/api/tasks/next") |> json_response(200)
  end
end
