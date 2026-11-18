defmodule KanbanWeb.API.AgentRouteDeviceTokenTest do
  # A device access token is for the person API (/api/me/*) only; every agent
  # route must refuse it (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §9.2).
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  setup do
    scope = user_scope_fixture()
    board = ai_optimized_board_fixture(scope.user)
    column = column_fixture(board, %{name: "Ready"})
    task = task_fixture(column, %{title: "Untouched"})
    {_device, issued} = device_with_tokens_fixture(scope)

    %{task: task, access_token: issued.access_token}
  end

  defp with_device_token(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  test "refuses a device token on claim, complete, mark_reviewed and after_goal", %{
    task: task,
    access_token: token
  } do
    requests = [
      {:post, ~p"/api/tasks/claim", %{identifier: task.identifier}},
      {:patch, ~p"/api/tasks/#{task.id}/complete", %{completion_summary: "x"}},
      {:patch, ~p"/api/tasks/#{task.id}/mark_reviewed", %{}},
      {:patch, ~p"/api/tasks/#{task.id}/after_goal", %{exit_code: 0, output: "", duration_ms: 0}},
      {:get, ~p"/api/tasks/next", nil},
      {:get, ~p"/api/tasks/#{task.id}", nil}
    ]

    for {method, path, body} <- requests do
      conn =
        dispatch(with_device_token(token), @endpoint, method, path, body && Jason.encode!(body))

      assert json_response(conn, 401) == %{"error" => "Invalid API token"},
             "expected #{method} #{path} to refuse a device token"

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :current_device)
    end

    unchanged = Repo.get!(Task, task.id)
    assert unchanged.status == task.status
    assert unchanged.assigned_to_id == task.assigned_to_id
    assert unchanged.column_id == task.column_id
  end
end
