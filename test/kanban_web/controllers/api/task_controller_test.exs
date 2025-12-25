defmodule KanbanWeb.API.TaskControllerTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token_struct, plain_token}} = ApiTokens.create_api_token(user, board, %{
      "name" => "Test Token"
    })

    column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token}")

    %{conn: conn, user: user, board: board, column: column, token: plain_token}
  end

  describe "POST /api/tasks" do
    test "creates task with all fields", %{conn: conn, column: column} do
      task_params = %{
        "title" => "Test Task",
        "description" => "Test description",
        "acceptance_criteria" => "Should work",
        "complexity" => "medium",
        "estimated_files" => "2-3",
        "why" => "Because we need it",
        "what" => "Build a feature",
        "where_context" => "In the main module",
        "column_id" => column.id,
        "key_files" => [
          %{"file_path" => "lib/test.ex", "note" => "Main file", "position" => 1}
        ],
        "verification_steps" => [
          %{"step_type" => "command", "step_text" => "mix test", "position" => 1}
        ]
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/tasks/#{id}")

      assert %{
               "id" => ^id,
               "title" => "Test Task",
               "description" => "Test description",
               "complexity" => "medium",
               "estimated_files" => "2-3",
               "key_files" => [%{"file_path" => "lib/test.ex"}]
             } = json_response(conn, 200)["data"]
    end

    test "creates task without column_id (uses default)", %{conn: conn} do
      task_params = %{
        "title" => "Auto Column Task",
        "description" => "Should go to default column"
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)
      assert %{"id" => _id, "column_id" => column_id} = json_response(conn, 201)["data"]
      assert is_integer(column_id)
    end

    test "returns error for invalid data", %{conn: conn} do
      task_params = %{"description" => "No title"}

      conn = post(conn, ~p"/api/tasks", task: task_params)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = post(conn, ~p"/api/tasks", task: %{"title" => "Test"})
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/tasks" do
    setup %{column: column, user: user} do
      {:ok, task1} = Tasks.create_task(column, %{
        "title" => "Task 1",
        "description" => "First task",
        "created_by_id" => user.id
      })

      {:ok, task2} = Tasks.create_task(column, %{
        "title" => "Task 2",
        "description" => "Second task",
        "created_by_id" => user.id
      })

      %{task1: task1, task2: task2}
    end

    test "lists all tasks", %{conn: conn, task1: _task1, task2: _task2} do
      conn = get(conn, ~p"/api/tasks")
      response = json_response(conn, 200)

      assert is_list(response["data"])
      assert length(response["data"]) >= 2

      titles = Enum.map(response["data"], & &1["title"])
      assert "Task 1" in titles
      assert "Task 2" in titles
    end

    test "filters tasks by column_id", %{conn: conn, column: column, task1: _task1} do
      conn = get(conn, ~p"/api/tasks?column_id=#{column.id}")
      response = json_response(conn, 200)

      assert is_list(response["data"])
      titles = Enum.map(response["data"], & &1["title"])
      assert "Task 1" in titles
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/tasks/:id" do
    setup %{column: column, user: user} do
      {:ok, task} = Tasks.create_task(column, %{
        "title" => "Detailed Task",
        "description" => "Full details",
        "complexity" => "large",
        "why" => "Important reason",
        "created_by_id" => user.id
      })

      %{task: task}
    end

    test "returns single task with all associations", %{conn: conn, task: task} do
      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["title"] == "Detailed Task"
      assert response["description"] == "Full details"
      assert response["complexity"] == "large"
      assert response["why"] == "Important reason"
      assert response["column_id"] == task.column_id
    end

    test "returns single task by identifier", %{conn: conn, task: task} do
      conn = get(conn, ~p"/api/tasks/#{task.identifier}")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["identifier"] == task.identifier
      assert response["title"] == "Detailed Task"
      assert response["description"] == "Full details"
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/api/tasks/999999")
      end
    end

    test "returns 404 for nonexistent identifier", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/api/tasks/INVALID99")
      end
    end

    test "returns 401 without authentication", %{task: task} do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      assert json_response(conn, 401)
    end
  end

  describe "PATCH /api/tasks/:id" do
    setup %{column: column, user: user} do
      {:ok, task} = Tasks.create_task(column, %{
        "title" => "Original Title",
        "description" => "Original description",
        "complexity" => "small",
        "created_by_id" => user.id
      })

      %{task: task}
    end

    test "updates task fields", %{conn: conn, task: task} do
      update_params = %{
        "title" => "Updated Title",
        "complexity" => "large",
        "why" => "New reason"
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: update_params)
      response = json_response(conn, 200)["data"]

      assert response["title"] == "Updated Title"
      assert response["complexity"] == "large"
      assert response["why"] == "New reason"
      assert response["description"] == "Original description"
    end

    test "updates nested associations", %{conn: conn, task: task} do
      update_params = %{
        "key_files" => [
          %{"file_path" => "lib/updated.ex", "note" => "Updated file", "position" => 1}
        ]
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: update_params)
      response = json_response(conn, 200)["data"]

      assert length(response["key_files"]) == 1
      assert hd(response["key_files"])["file_path"] == "lib/updated.ex"
    end

    test "returns error for invalid data", %{conn: conn, task: task} do
      update_params = %{"title" => ""}

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: update_params)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      assert_error_sent 404, fn ->
        patch(conn, ~p"/api/tasks/999999", task: %{"title" => "Updated"})
      end
    end

    test "returns 401 without authentication", %{task: task} do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: %{"title" => "Updated"})
      assert json_response(conn, 401)
    end
  end

  describe "cross-board access protection" do
    test "cannot access tasks from different board", %{conn: conn, user: _user} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, other_task} = Tasks.create_task(other_column, %{
        "title" => "Other Board Task",
        "created_by_id" => other_user.id
      })

      conn = get(conn, ~p"/api/tasks/#{other_task.id}")
      assert json_response(conn, 403)
    end
  end
end
