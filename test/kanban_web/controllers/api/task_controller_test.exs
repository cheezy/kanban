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
      "name" => "Test Token",
      "agent_capabilities" => ["code_generation", "testing"]
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

  describe "GET /api/tasks/next" do
    setup %{board: board, user: _user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      %{ready_column: ready_column, doing_column: doing_column}
    end

    test "returns next available task from Ready column", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, task} = Tasks.create_task(ready_column, %{
        "title" => "Next Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["title"] == "Next Task"
      assert response["status"] == "open"
    end

    test "returns 404 when no tasks available", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/next")
      assert json_response(conn, 404)["error"] =~ "No tasks available"
    end

    test "excludes tasks with status in_progress", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, _claimed_task} = Tasks.create_task(ready_column, %{
        "title" => "Claimed Task",
        "status" => "in_progress",
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      assert json_response(conn, 404)
    end

    test "includes tasks with expired claims", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, task} = Tasks.create_task(ready_column, %{
        "title" => "Expired Claim Task",
        "status" => "in_progress",
        "claimed_at" => DateTime.add(DateTime.utc_now(), -3600, :second),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), -60, :second),
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
    end

    test "filters by agent capabilities", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, _task1} = Tasks.create_task(ready_column, %{
        "title" => "Requires Testing",
        "status" => "open",
        "required_capabilities" => ["testing", "deployment"],
        "created_by_id" => user.id
      })

      {:ok, task2} = Tasks.create_task(ready_column, %{
        "title" => "Requires Code Gen",
        "status" => "open",
        "required_capabilities" => [],
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      # Task 1 requires capabilities agent doesn't have (deployment)
      # Task 2 has no capability requirements
      # So task 1 is skipped and task 2 should be returned
      assert response["id"] == task2.id
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks/next")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/tasks/claim" do
    setup %{board: board, user: _user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      %{ready_column: ready_column, doing_column: doing_column}
    end

    test "atomically claims next available task", %{conn: conn, ready_column: ready_column, user: user, doing_column: doing_column} do
      {:ok, task} = Tasks.create_task(ready_column, %{
        "title" => "Task to Claim",
        "status" => "open",
        "created_by_id" => user.id
      })

      conn = post(conn, ~p"/api/tasks/claim")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["status"] == "in_progress"
      assert response["column_id"] == doing_column.id
      assert response["assigned_to_id"] == user.id
      assert response["claimed_at"] != nil
      assert response["claim_expires_at"] != nil
    end

    test "returns 409 when no tasks available", %{conn: conn} do
      conn = post(conn, ~p"/api/tasks/claim")
      assert json_response(conn, 409)["error"] =~ "No tasks available"
    end

    test "prevents double claiming", %{conn: conn, ready_column: ready_column, user: user, board: board} do
      {:ok, _task} = Tasks.create_task(ready_column, %{
        "title" => "Only Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      user2 = user_fixture()
      {:ok, {_token_struct, plain_token2}} = Kanban.ApiTokens.create_api_token(user2, board, %{
        "name" => "Test Token 2",
        "agent_capabilities" => ["code_generation", "testing"]
      })

      conn2 = build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token2}")

      conn1_response = post(conn, ~p"/api/tasks/claim")
      assert json_response(conn1_response, 200)

      conn2_response = post(conn2, ~p"/api/tasks/claim")
      assert json_response(conn2_response, 409)
    end

    test "respects capability requirements", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, _task} = Tasks.create_task(ready_column, %{
        "title" => "Requires Deployment",
        "status" => "open",
        "required_capabilities" => ["deployment"],
        "created_by_id" => user.id
      })

      conn = post(conn, ~p"/api/tasks/claim")
      assert json_response(conn, 409)["error"] =~ "No tasks available"
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = post(conn, ~p"/api/tasks/claim")
      assert json_response(conn, 401)
    end

    test "claims specific task by identifier", %{conn: conn, ready_column: ready_column, user: user, doing_column: doing_column} do
      {:ok, _task1} = Tasks.create_task(ready_column, %{
        "title" => "First Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      {:ok, task2} = Tasks.create_task(ready_column, %{
        "title" => "Second Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      conn = post(conn, ~p"/api/tasks/claim", %{"identifier" => task2.identifier})
      response = json_response(conn, 200)["data"]

      assert response["id"] == task2.id
      assert response["identifier"] == task2.identifier
      assert response["status"] == "in_progress"
      assert response["column_id"] == doing_column.id
      assert response["assigned_to_id"] == user.id
    end

    test "returns error when claiming specific task with dependencies", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, dependency_task} = Tasks.create_task(ready_column, %{
        "title" => "Dependency Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      {:ok, blocked_task} = Tasks.create_task(ready_column, %{
        "title" => "Blocked Task",
        "status" => "open",
        "dependencies" => [to_string(dependency_task.id)],
        "created_by_id" => user.id
      })

      conn = post(conn, ~p"/api/tasks/claim", %{"identifier" => blocked_task.identifier})
      response = json_response(conn, 409)

      assert response["error"] =~ blocked_task.identifier
      assert response["error"] =~ "not available to claim"
    end

    test "returns error when claiming non-existent task", %{conn: conn} do
      conn = post(conn, ~p"/api/tasks/claim", %{"identifier" => "W99999"})
      response = json_response(conn, 409)

      assert response["error"] =~ "W99999"
      assert response["error"] =~ "not available to claim"
    end
  end

  describe "POST /api/tasks/:id/unclaim" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, task} = Tasks.create_task(doing_column, %{
        "title" => "Claimed Task",
        "status" => "in_progress",
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "created_by_id" => user.id
      })

      %{ready_column: ready_column, doing_column: doing_column, claimed_task: task}
    end

    test "releases claimed task back to Ready column", %{conn: conn, claimed_task: task, ready_column: ready_column, user: _user} do
      conn = post(conn, ~p"/api/tasks/#{task.id}/unclaim")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["status"] == "open"
      assert response["column_id"] == ready_column.id
      assert response["assigned_to_id"] == nil
      assert response["claimed_at"] == nil
      assert response["claim_expires_at"] == nil
    end

    test "accepts optional reason parameter", %{conn: conn, claimed_task: task} do
      conn = post(conn, ~p"/api/tasks/#{task.id}/unclaim", %{"reason" => "task too complex"})
      assert json_response(conn, 200)
    end

    test "returns 403 when unclaiming someone else's task", %{conn: _conn, claimed_task: task, board: board} do
      other_user = user_fixture()
      {:ok, {_token_struct, plain_token}} = Kanban.ApiTokens.create_api_token(other_user, board, %{
        "name" => "Other Token",
        "agent_capabilities" => ["code_generation", "testing"]
      })

      other_conn = build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token}")

      conn = post(other_conn, ~p"/api/tasks/#{task.id}/unclaim")
      assert json_response(conn, 403)["error"] =~ "You can only unclaim tasks that you claimed"
    end

    test "returns 422 when task is not claimed", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, open_task} = Tasks.create_task(ready_column, %{
        "title" => "Open Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      conn = post(conn, ~p"/api/tasks/#{open_task.id}/unclaim")
      assert json_response(conn, 422)["error"] =~ "not currently claimed"
    end

    test "unclaims task using identifier instead of ID", %{conn: conn, claimed_task: task, ready_column: ready_column} do
      conn = post(conn, ~p"/api/tasks/#{task.identifier}/unclaim")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["status"] == "open"
      assert response["column_id"] == ready_column.id
    end

    test "returns 401 without authentication", %{claimed_task: task} do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = post(conn, ~p"/api/tasks/#{task.id}/unclaim")
      assert json_response(conn, 401)
    end
  end

  describe "PATCH /api/tasks/:id/complete" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      doing_column = Enum.find(columns, &(&1.name == "Doing"))
      review_column = Enum.find(columns, &(&1.name == "Review"))

      {:ok, task} = Tasks.create_task(doing_column, %{
        "title" => "Test Task",
        "status" => "in_progress",
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "created_by_id" => user.id
      })

      %{
        doing_column: doing_column,
        review_column: review_column,
        task: task
      }
    end

    test "completes task and moves to Review column", %{conn: conn, task: task, review_column: review_column} do
      completion_params = %{
        "completion_summary" => Jason.encode!(%{
          files_changed: [%{path: "lib/test.ex", changes: "Added function"}],
          verification_results: %{status: "passed", commands_run: ["mix test"]}
        }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["status"] == "in_progress"
      assert response["column_id"] == review_column.id
      assert response["completion_summary"] == completion_params["completion_summary"]
      assert response["actual_complexity"] == "medium"
      assert response["actual_files_changed"] == "2"
      assert response["time_spent_minutes"] == 15
    end

    test "completes task using identifier instead of ID", %{conn: conn, task: task, review_column: review_column} do
      completion_params = %{
        "completion_summary" => Jason.encode!(%{
          files_changed: [%{path: "lib/test.ex", changes: "Added function"}],
          verification_results: %{status: "passed", commands_run: ["mix test"]}
        }),
        "actual_complexity" => "small",
        "actual_files_changed" => "1",
        "time_spent_minutes" => 10
      }

      conn = patch(conn, ~p"/api/tasks/#{task.identifier}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["column_id"] == review_column.id
    end

    test "returns 422 when completion_summary is missing", %{conn: conn, task: task} do
      completion_params = %{
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 422)

      assert response["errors"]["completion_summary"] != nil
    end

    test "returns 422 when actual_complexity is invalid", %{conn: conn, task: task} do
      completion_params = %{
        "completion_summary" => Jason.encode!(%{
          files_changed: [],
          verification_results: %{status: "passed"}
        }),
        "actual_complexity" => "invalid",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 422)

      assert response["errors"]["actual_complexity"] != nil
    end

    test "returns 403 when completing someone else's task", %{task: task, board: board} do
      other_user = user_fixture(%{email: "other@example.com"})
      {:ok, {_token_struct, plain_token}} = ApiTokens.create_api_token(other_user, board, %{
        "name" => "Other Token"
      })

      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")
      conn = put_req_header(conn, "authorization", "Bearer #{plain_token}")

      completion_params = %{
        "completion_summary" => Jason.encode!(%{
          files_changed: [],
          verification_results: %{status: "passed"}
        }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 403)

      assert response["error"] =~ "only complete tasks that you are assigned to"
    end

    test "returns 422 when task is not in progress", %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      {:ok, open_task} = Tasks.create_task(ready_column, %{
        "title" => "Open Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      completion_params = %{
        "completion_summary" => Jason.encode!(%{
          files_changed: [],
          verification_results: %{status: "passed"}
        }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15
      }

      conn = patch(conn, ~p"/api/tasks/#{open_task.id}/complete", completion_params)
      response = json_response(conn, 422)

      assert response["error"] =~ "must be in progress or blocked"
    end
  end

  describe "dependency filtering" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))
      done_column = Enum.find(columns, &(&1.name == "Done"))

      {:ok, completed_task} = Tasks.create_task(done_column, %{
        "title" => "Completed Dependency",
        "status" => "completed",
        "completed_at" => DateTime.utc_now(),
        "created_by_id" => user.id
      })

      {:ok, incomplete_task} = Tasks.create_task(doing_column, %{
        "title" => "Incomplete Dependency",
        "status" => "in_progress",
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "created_by_id" => user.id
      })

      %{
        ready_column: ready_column,
        doing_column: doing_column,
        completed_task: completed_task,
        incomplete_task: incomplete_task
      }
    end

    test "GET /api/tasks/next skips tasks with incomplete dependencies", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      incomplete_task: incomplete_task
    } do
      {:ok, _available_task} = Tasks.create_task(ready_column, %{
        "title" => "Available Task",
        "status" => "open",
        "dependencies" => [],
        "created_by_id" => user.id
      })

      {:ok, _blocked_task} = Tasks.create_task(ready_column, %{
        "title" => "Blocked Task",
        "status" => "open",
        "dependencies" => [to_string(incomplete_task.id)],
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["title"] == "Available Task"
    end

    test "GET /api/tasks/next returns task when all dependencies completed", %{conn: conn, ready_column: ready_column, user: user, completed_task: completed_task} do
      {:ok, task} = Tasks.create_task(ready_column, %{
        "title" => "Ready Task",
        "status" => "open",
        "dependencies" => [to_string(completed_task.id)],
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
    end

    test "POST /api/tasks/claim skips tasks with incomplete dependencies", %{conn: conn, ready_column: ready_column, user: user, incomplete_task: incomplete_task} do
      {:ok, _available_task} = Tasks.create_task(ready_column, %{
        "title" => "Available Task for Claim",
        "status" => "open",
        "dependencies" => [],
        "created_by_id" => user.id
      })

      {:ok, _blocked_task} = Tasks.create_task(ready_column, %{
        "title" => "Blocked Task",
        "status" => "open",
        "dependencies" => [to_string(incomplete_task.id)],
        "created_by_id" => user.id
      })

      conn = post(conn, ~p"/api/tasks/claim")
      response = json_response(conn, 200)["data"]

      assert response["title"] == "Available Task for Claim"
      assert response["status"] == "in_progress"
    end
  end

  describe "key file conflict detection" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, in_progress_task} = Tasks.create_task(doing_column, %{
        "title" => "In Progress Task",
        "status" => "in_progress",
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "key_files" => [
          %{"file_path" => "lib/kanban/tasks.ex", "note" => "Core tasks", "position" => 1}
        ],
        "created_by_id" => user.id
      })

      %{ready_column: ready_column, doing_column: doing_column, in_progress_task: in_progress_task}
    end

    test "GET /api/tasks/next skips tasks with conflicting key files", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, _safe_task} = Tasks.create_task(ready_column, %{
        "title" => "Safe Task",
        "status" => "open",
        "key_files" => [
          %{"file_path" => "lib/kanban/boards.ex", "note" => "Different file", "position" => 1}
        ],
        "created_by_id" => user.id
      })

      {:ok, _conflicting_task} = Tasks.create_task(ready_column, %{
        "title" => "Conflicting Task",
        "status" => "open",
        "key_files" => [
          %{"file_path" => "lib/kanban/tasks.ex", "note" => "Same file", "position" => 1}
        ],
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["title"] == "Safe Task"
    end

    test "POST /api/tasks/claim skips tasks with conflicting key files", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, _safe_task} = Tasks.create_task(ready_column, %{
        "title" => "Safe Task for Claim",
        "status" => "open",
        "key_files" => [
          %{"file_path" => "lib/kanban/boards.ex", "note" => "Different file", "position" => 1}
        ],
        "created_by_id" => user.id
      })

      {:ok, _conflicting_task} = Tasks.create_task(ready_column, %{
        "title" => "Conflicting Task",
        "status" => "open",
        "key_files" => [
          %{"file_path" => "lib/kanban/tasks.ex", "note" => "Same file", "position" => 1}
        ],
        "created_by_id" => user.id
      })

      conn = post(conn, ~p"/api/tasks/claim")
      response = json_response(conn, 200)["data"]

      assert response["title"] == "Safe Task for Claim"
    end

    test "GET /api/tasks/next returns task with no key files when conflicts exist", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, _no_files_task} = Tasks.create_task(ready_column, %{
        "title" => "No Files Task",
        "status" => "open",
        "created_by_id" => user.id
      })

      {:ok, _conflicting_task} = Tasks.create_task(ready_column, %{
        "title" => "Conflicting Task",
        "status" => "open",
        "key_files" => [
          %{"file_path" => "lib/kanban/tasks.ex", "note" => "Same file", "position" => 1}
        ],
        "created_by_id" => user.id
      })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["title"] == "No Files Task"
    end
  end

  describe "column access control" do
    test "cannot create task with column from different board", %{conn: conn, user: _user} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      task_params = %{
        "title" => "Invalid Task",
        "column_id" => other_column.id
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)
      assert json_response(conn, 403)["error"] =~ "Column does not belong to this board"
    end
  end

  describe "task identifier operations" do
    setup %{column: column, user: user} do
      {:ok, task} = Tasks.create_task(column, %{
        "title" => "Identifier Test Task",
        "description" => "For testing identifier-based operations",
        "created_by_id" => user.id
      })

      %{task: task}
    end

    test "updates task using identifier instead of ID", %{conn: conn, task: task} do
      update_params = %{"title" => "Updated via Identifier"}

      conn = patch(conn, ~p"/api/tasks/#{task.identifier}", task: update_params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["title"] == "Updated via Identifier"
    end
  end

  describe "filter tasks by column belonging to different board" do
    test "returns 403 when filtering by column from different board", %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      conn = get(conn, ~p"/api/tasks?column_id=#{other_column.id}")
      assert json_response(conn, 403)["error"] =~ "Column does not belong to this board"
    end
  end

  describe "PATCH /api/tasks/:id/mark_done" do
    test "marks task as done when in Review column", %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))
      done_column = Enum.find(columns, &(&1.name == "Done"))

      {:ok, task} = Tasks.create_task(review_column, %{
        "title" => "Task to mark done",
        "status" => "in_progress",
        "assigned_to_id" => user.id,
        "created_by_id" => user.id
      })

      conn = patch(conn, ~p"/api/tasks/#{task.id}/mark_done")
      response = json_response(conn, 200)["data"]

      assert response["status"] == "completed"
      assert response["completed_at"] != nil
      assert response["column_id"] == done_column.id
    end

    test "marks task as done using identifier", %{conn: conn, board: board, user: user} do
      review_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Review"))

      {:ok, task} = Tasks.create_task(review_column, %{
        "title" => "Task to mark done",
        "status" => "in_progress",
        "assigned_to_id" => user.id,
        "created_by_id" => user.id
      })

      conn = patch(conn, ~p"/api/tasks/#{task.identifier}/mark_done")
      response = json_response(conn, 200)["data"]

      assert response["status"] == "completed"
      assert response["identifier"] == task.identifier
    end

    test "returns 422 when task is not in Review column", %{conn: conn, board: board, user: user} do
      backlog_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, task} = Tasks.create_task(backlog_column, %{
        "title" => "Task not in review",
        "created_by_id" => user.id
      })

      conn = patch(conn, ~p"/api/tasks/#{task.id}/mark_done")
      assert json_response(conn, 422)["error"] =~ "Task must be in Review column"
    end

    test "returns 403 when task belongs to different board", %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      review_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Review"))

      {:ok, task} = Tasks.create_task(review_column, %{
        "title" => "Task on other board",
        "created_by_id" => other_user.id
      })

      conn = patch(conn, ~p"/api/tasks/#{task.id}/mark_done")
      assert json_response(conn, 403)["error"] =~ "Task does not belong to this board"
    end
  end
end
