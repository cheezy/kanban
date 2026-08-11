defmodule KanbanWeb.API.TaskControllerTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Schemas.Task.BehaviourTestRow
  alias Kanban.Tasks
  alias KanbanWeb.API.TaskParamFilter

  @moduletag capture_log: true

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token_struct, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
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

  defp valid_before_doing_result do
    %{
      "exit_code" => 0,
      "output" => "Starting task",
      "duration_ms" => 100
    }
  end

  defp valid_after_doing_result do
    %{
      "exit_code" => 0,
      "output" => "All tests passed",
      "duration_ms" => 5000
    }
  end

  defp valid_before_review_result do
    %{
      "exit_code" => 0,
      "output" => "PR created successfully",
      "duration_ms" => 2000
    }
  end

  defp valid_after_review_result do
    %{
      "exit_code" => 0,
      "output" => "Deployed successfully",
      "duration_ms" => 3000
    }
  end

  defp valid_explorer_result do
    %{
      "dispatched" => true,
      "summary" => "Explored the 3 key files and identified the existing pattern to mirror",
      "duration_ms" => 12_000
    }
  end

  defp valid_reviewer_result do
    %{
      "dispatched" => true,
      "summary" => "Reviewed the diff against all acceptance criteria and pitfalls",
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 5,
      "issues_found" => 0,
      "status" => "approved",
      "issue_counts" => %{"critical" => 0, "important" => 0, "minor" => 0},
      "issues" => [],
      "acceptance_criteria" => [
        %{"criterion" => "Validator rejects legacy-only reviewer_result", "status" => "met"}
      ],
      # W1066: a fully-populated review must carry every section verdict. The
      # project_checks list may be any length (including empty) — it mirrors the
      # CALLING project's optional CODE-REVIEW.md, which this server never sees.
      "project_checks" => for(i <- 1..5, do: %{"check" => "check #{i}", "status" => "met"}),
      "testing_strategy" => %{"status" => "passed"},
      "patterns" => %{"status" => "passed"},
      "pitfalls" => %{"status" => "passed"},
      "security_considerations" => %{"status" => "passed"},
      "schema_version" => "1.0"
    }
  end

  # The pre-D55 reviewer_result shape: dispatched, legacy summary fields, but
  # NONE of the structured block the review queue renders. Valid for the
  # unconditional schema-layer validator; rejected by the strict gate (D55).
  defp legacy_only_reviewer_result do
    %{
      "dispatched" => true,
      "summary" => "Reviewed the diff against all acceptance criteria and pitfalls",
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 5,
      "issues_found" => 1
    }
  end

  # A claimed, in-progress task that supplies security_considerations, so the
  # W1069 gate cross-check has a task field to enforce against.
  defp security_task(board, user) do
    doing_column = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Doing"))

    {:ok, task} =
      Tasks.create_task(doing_column, %{
        "title" => "Security Task",
        "status" => "in_progress",
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "created_by_id" => user.id,
        "needs_review" => true,
        "security_considerations" => ["Keep board scoping intact"]
      })

    task
  end

  defp base_completion_params do
    %{
      "completion_summary" => "Implemented feature",
      "actual_complexity" => "small",
      "actual_files_changed" => "1 file",
      "time_spent_minutes" => 10,
      "after_doing_result" => valid_after_doing_result(),
      "before_review_result" => valid_before_review_result()
    }
  end

  # Behaviour/test-matrix helpers (W1918). A NON-EMPTY matrix must cover all
  # seven categories (W1917), so every valid payload starts from a full matrix.
  @behaviour_row_template %{
    "behaviour" => "claims an open task",
    "test_name" => "claims an open task",
    "type" => "unit",
    "status" => "planned"
  }

  defp behaviour_rows_for(categories) do
    categories
    |> Enum.with_index()
    |> Enum.map(fn {category, index} ->
      Map.merge(@behaviour_row_template, %{"category" => category, "position" => index})
    end)
  end

  defp full_behaviour_matrix, do: behaviour_rows_for(BehaviourTestRow.categories())

  # A complete matrix whose first ("Happy path") row carries the given overrides.
  defp full_behaviour_matrix_with(overrides) do
    [first | rest] = full_behaviour_matrix()
    [Map.merge(first, overrides) | rest]
  end

  # A complete matrix in which `category`'s row is waived: status
  # "not_applicable" + na_reason, and no test_name.
  defp full_behaviour_matrix_waiving(category, na_reason) do
    Enum.map(full_behaviour_matrix(), fn
      %{"category" => ^category} = row ->
        row
        |> Map.drop(["test_name"])
        |> Map.merge(%{"status" => "not_applicable", "na_reason" => na_reason})

      row ->
        row
    end)
  end

  # The serialized form of a request matrix: every row echoes all seven row
  # fields, with absent ones as nil (TaskJSON.render_behaviour_test_matrix/1).
  defp expected_behaviour_matrix_json(rows) do
    Enum.map(rows, fn row ->
      %{
        "category" => row["category"],
        "behaviour" => row["behaviour"],
        "test_name" => row["test_name"],
        "type" => row["type"],
        "status" => row["status"],
        "na_reason" => row["na_reason"],
        "position" => row["position"]
      }
    end)
  end

  describe "POST /api/tasks" do
    test "returns 403 for a read-only board member (D109)", %{board: board, user: owner} do
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      {:ok, {_t, reader_token}} =
        ApiTokens.create_api_token(reader, board, %{"name" => "Reader Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{reader_token}")
        |> post(~p"/api/tasks", %{
          "task" => %{"title" => "Nope", "type" => "work", "priority" => "medium"}
        })

      assert json_response(conn, 403)
    end

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

    test "returns 400 for invalid column_id in create", %{conn: conn} do
      task_params = %{
        "title" => "Test Task",
        "column_id" => "306,305"
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)
      response = json_response(conn, 400)

      assert response["error"] =~ "Invalid column_id"
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = post(conn, ~p"/api/tasks", task: %{"title" => "Test"})
      assert json_response(conn, 401)
    end

    test "tracks AI agent when creating task with agent_model", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "AI Agent Token",
          "agent_model" => "claude-sonnet-4"
        })

      conn = put_req_header(conn, "authorization", "Bearer #{plain_token}")

      task_params = %{
        "title" => "AI Created Task"
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)

      assert %{"id" => _id, "created_by_agent" => created_by_agent} =
               json_response(conn, 201)["data"]

      assert created_by_agent == "ai_agent:claude-sonnet-4"
    end

    test "does not track AI agent when creating task without agent_model", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Regular Token"
        })

      conn = put_req_header(conn, "authorization", "Bearer #{plain_token}")

      task_params = %{
        "title" => "Human Created Task"
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)

      assert %{"id" => _id, "created_by_agent" => created_by_agent} =
               json_response(conn, 201)["data"]

      assert created_by_agent == nil
    end

    test "preserves created_by_agent when explicitly provided in task params", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Regular Token"
        })

      conn = put_req_header(conn, "authorization", "Bearer #{plain_token}")

      task_params = %{
        "title" => "AI Generated Task",
        "created_by_agent" => "gpt-4"
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)

      assert %{"id" => _id, "created_by_agent" => created_by_agent} =
               json_response(conn, 201)["data"]

      assert created_by_agent == "gpt-4"
    end

    test "uses top-level agent_name for created_by_agent when field and agent_model are absent (D137)",
         %{conn: _conn, user: user, board: board} do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Regular Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")
        |> post(~p"/api/tasks",
          task: %{"title" => "Named Agent Task"},
          agent_name: "Claude Fable 5"
        )

      assert %{"created_by_agent" => "Claude Fable 5"} = json_response(conn, 201)["data"]
    end

    test "token agent_model takes precedence over top-level agent_name (D137)",
         %{conn: _conn, user: user, board: board} do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "AI Agent Token",
          "agent_model" => "claude-sonnet-4"
        })

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")
        |> post(~p"/api/tasks", task: %{"title" => "Model Wins Task"}, agent_name: "Other Agent")

      assert %{"created_by_agent" => "ai_agent:claude-sonnet-4"} =
               json_response(conn, 201)["data"]
    end

    test "explicit created_by_agent wins over top-level agent_name (D137)",
         %{conn: _conn, user: user, board: board} do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Regular Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")
        |> post(~p"/api/tasks",
          task: %{"title" => "Explicit Wins Task", "created_by_agent" => "gpt-4"},
          agent_name: "Other Agent"
        )

      assert %{"created_by_agent" => "gpt-4"} = json_response(conn, 201)["data"]
    end

    test "falls back to the token's last_agent_name when the request carries no agent identity (D137)",
         %{conn: _conn, user: user, board: board} do
      {:ok, {token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Regular Token"})

      api_conn = fn ->
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")
      end

      # First request identifies the agent and stamps the token...
      first =
        post(api_conn.(), ~p"/api/tasks", task: %{"title" => "Seeded"}, agent_name: "Seeder")

      assert json_response(first, 201)
      assert ApiTokens.get_api_token!(token_struct.id).last_agent_name == "Seeder"

      # ...so a later create with no agent identity still attributes.
      second = post(api_conn.(), ~p"/api/tasks", task: %{"title" => "Anonymous follow-up"})
      assert %{"created_by_agent" => "Seeder"} = json_response(second, 201)["data"]
    end

    test "created_by_agent stays nil with no source, and the Unknown placeholder is never stamped (D137)",
         %{conn: _conn, user: user, board: board} do
      {:ok, {token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Regular Token"})

      api_conn = fn ->
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")
      end

      first =
        post(api_conn.(), ~p"/api/tasks", task: %{"title" => "Unknown"}, agent_name: "Unknown")

      assert %{"created_by_agent" => nil} = json_response(first, 201)["data"]
      assert ApiTokens.get_api_token!(token_struct.id).last_agent_name == nil

      second = post(api_conn.(), ~p"/api/tasks", task: %{"title" => "Still anonymous"})
      assert %{"created_by_agent" => nil} = json_response(second, 201)["data"]
    end

    test "create with agent_name surfaces the agent on the created activity event (D137)",
         %{conn: _conn, user: user, board: board} do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Regular Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")
        |> post(~p"/api/tasks", task: %{"title" => "Feed Task"}, agent_name: "Feed Agent")

      assert json_response(conn, 201)

      assert Enum.any?(
               Kanban.Agents.recent_activity(),
               &(&1.kind == :create and &1.actor == "Feed Agent")
             )
    end

    test "creates goal with nested child tasks", %{conn: conn, column: _column} do
      goal_params = %{
        "title" => "Test Goal",
        "description" => "A goal with child tasks",
        "tasks" => [
          %{"title" => "Child Task 1", "type" => "work", "complexity" => "small"},
          %{"title" => "Child Task 2", "type" => "defect", "complexity" => "medium"},
          %{"title" => "Child Task 3", "type" => "work", "complexity" => "large"}
        ]
      }

      conn = post(conn, ~p"/api/tasks", task: goal_params)
      response = json_response(conn, 201)

      assert %{"goal" => goal, "child_tasks" => child_tasks} = response
      assert goal["title"] == "Test Goal"
      assert goal["type"] == "goal"
      assert String.starts_with?(goal["identifier"], "G")
      assert length(child_tasks) == 3

      assert Enum.at(child_tasks, 0)["title"] == "Child Task 1"
      assert Enum.at(child_tasks, 0)["complexity"] == "small"
      assert String.starts_with?(Enum.at(child_tasks, 0)["identifier"], "W")

      assert Enum.at(child_tasks, 1)["title"] == "Child Task 2"
      assert Enum.at(child_tasks, 1)["complexity"] == "medium"
      assert String.starts_with?(Enum.at(child_tasks, 1)["identifier"], "D")

      assert Enum.at(child_tasks, 2)["title"] == "Child Task 3"
      assert Enum.at(child_tasks, 2)["complexity"] == "large"
      assert String.starts_with?(Enum.at(child_tasks, 2)["identifier"], "W")

      goal_id = goal["id"]
      conn = get(conn, ~p"/api/tasks/#{goal_id}/tree")
      tree_response = json_response(conn, 200)["data"]

      assert tree_response["task"]["id"] == goal_id
      assert length(tree_response["children"]) == 3
      assert Enum.all?(tree_response["children"], fn child -> child["parent_id"] == goal_id end)
    end

    test "creates goal without child tasks (empty array)", %{conn: conn} do
      goal_params = %{
        "title" => "Empty Goal",
        "tasks" => []
      }

      conn = post(conn, ~p"/api/tasks", task: goal_params)
      response = json_response(conn, 201)

      assert %{"data" => task} = response
      assert task["title"] == "Empty Goal"
    end

    test "returns error when goal creation fails", %{conn: conn} do
      goal_params = %{
        "title" => "",
        "tasks" => [
          %{"title" => "Child Task", "type" => "work"}
        ]
      }

      conn = post(conn, ~p"/api/tasks", task: goal_params)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns helpful error when using 'data' instead of 'task' as root key", %{conn: conn} do
      conn = post(conn, ~p"/api/tasks", data: %{"title" => "Test Task"})
      response = json_response(conn, 422)

      assert %{
               "error" => error,
               "example" => example,
               "documentation" => doc_url,
               "common_causes" => causes,
               "correct_format" => format_hint
             } = response

      assert error =~ "request body key must be 'task', not 'data'"
      assert is_map(example)
      assert Map.has_key?(example, "task")
      assert doc_url =~ "post_tasks.md"
      assert is_list(causes)
      assert format_hint == "See the 'example' field in this response"
    end

    test "returns helpful error when missing 'task' key entirely", %{conn: conn} do
      conn = post(conn, ~p"/api/tasks", %{})
      response = json_response(conn, 422)

      assert %{
               "error" => error,
               "example" => example,
               "documentation" => doc_url
             } = response

      assert error =~ "Missing 'task' key"
      assert is_map(example)
      assert Map.has_key?(example, "task")
      assert doc_url =~ "post_tasks.md"
    end
  end

  describe "POST /api/tasks mass-assignment protection" do
    test "silently strips status from a flat task create", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "New",
            "type" => "work",
            "priority" => "medium",
            "complexity" => "small",
            "status" => "completed"
          }
        )

      response = json_response(conn, 201)["data"]
      reloaded = Tasks.get_task!(response["id"])

      assert reloaded.status == :open
      refute reloaded.status == :completed
    end

    test "silently strips identifier (always server-generated)", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "New",
            "type" => "work",
            "priority" => "medium",
            "identifier" => "X999"
          }
        )

      response = json_response(conn, 201)["data"]
      reloaded = Tasks.get_task!(response["id"])

      refute reloaded.identifier == "X999"
      assert is_binary(reloaded.identifier)
      assert reloaded.identifier =~ ~r/^[WDG]\d+$/
    end

    test "silently strips completion + review fields and assigned_to_id",
         %{conn: conn} do
      other = user_fixture()

      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "New",
            "type" => "work",
            "priority" => "medium",
            "completed_at" => "2025-01-01T00:00:00Z",
            "completed_by_id" => other.id,
            "review_status" => "approved",
            "reviewed_by_id" => other.id,
            "time_spent_minutes" => 9999,
            "actual_complexity" => "large",
            "archived_at" => "2025-01-01T00:00:00Z",
            "assigned_to_id" => other.id
          }
        )

      response = json_response(conn, 201)["data"]
      reloaded = Tasks.get_task!(response["id"])

      assert is_nil(reloaded.completed_at)
      assert is_nil(reloaded.completed_by_id)
      assert is_nil(reloaded.review_status)
      assert is_nil(reloaded.reviewed_by_id)
      assert is_nil(reloaded.time_spent_minutes)
      assert is_nil(reloaded.actual_complexity)
      assert is_nil(reloaded.archived_at)
      assert is_nil(reloaded.assigned_to_id)
    end

    test "strips a client-supplied cross-board parent_id and does not leak the parent's assignee (D153)",
         %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, victim_goal} =
        Tasks.create_task(other_column, %{
          "title" => "Victim goal on another board",
          "type" => "goal",
          "assigned_to_id" => other_user.id,
          "created_by_id" => other_user.id
        })

      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Sneaky",
            "type" => "work",
            "priority" => "medium",
            "parent_id" => victim_goal.id
          }
        )

      response = json_response(conn, 201)["data"]
      reloaded = Tasks.get_task!(response["id"])

      # parent_id is stripped by the forbidden-field filter, so no cross-board link…
      assert is_nil(reloaded.parent_id)
      # …and the victim goal's assignee is not inherited onto the attacker's task.
      assert is_nil(reloaded.assigned_to_id)
    end

    test "silently strips workflow_steps / explorer_result / reviewer_result",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "New",
            "type" => "work",
            "priority" => "medium",
            "workflow_steps" => [%{"name" => "fake", "dispatched" => true, "duration_ms" => 1}],
            "explorer_result" => %{"dispatched" => true, "summary" => "fake"},
            "reviewer_result" => %{"dispatched" => true, "summary" => "fake"}
          }
        )

      response = json_response(conn, 201)["data"]
      reloaded = Tasks.get_task!(response["id"])

      assert reloaded.workflow_steps == []
      assert is_nil(reloaded.explorer_result)
      assert is_nil(reloaded.reviewer_result)
    end

    test "still applies legitimate descriptive fields", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "New",
            "description" => "desc",
            "type" => "work",
            "priority" => "high",
            "complexity" => "medium",
            "why" => "because",
            "what" => "what",
            "status" => "completed"
          }
        )

      response = json_response(conn, 201)["data"]
      reloaded = Tasks.get_task!(response["id"])

      assert reloaded.title == "New"
      assert reloaded.description == "desc"
      assert reloaded.priority == :high
      assert reloaded.complexity == :medium
      assert reloaded.why == "because"
      assert reloaded.what == "what"
      assert reloaded.status == :open
    end

    test "goal-with-children create strips forbidden fields on child tasks too",
         %{conn: conn} do
      other = user_fixture()

      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Goal",
            "type" => "goal",
            "priority" => "medium",
            "tasks" => [
              %{
                "title" => "Child 1",
                "type" => "work",
                "priority" => "medium",
                "status" => "completed",
                "identifier" => "W999",
                "completed_by_id" => other.id
              }
            ]
          }
        )

      response = json_response(conn, 201)
      [child_summary] = response["child_tasks"]
      child = Tasks.get_task!(child_summary["id"])

      assert child.status == :open
      refute child.identifier == "W999"
      assert is_nil(child.completed_by_id)
      assert child.title == "Child 1"
    end
  end

  describe "varchar(255) length validation (D81)" do
    @over_long_title String.duplicate("a", 256)

    test "POST /api/tasks with an over-long title returns 422, not 500", %{conn: conn} do
      conn = post(conn, ~p"/api/tasks", task: %{"title" => @over_long_title})

      assert json_response(conn, 422)["errors"] != %{}
    end

    test "PATCH /api/tasks/:id with an over-long title returns 422, not 500",
         %{conn: conn, column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{"title" => "Original D81", "created_by_id" => user.id})

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: %{"title" => @over_long_title})

      assert json_response(conn, 422)["errors"] != %{}
    end

    test "POST /api/tasks/batch with an over-long child title returns 422 and rolls back",
         %{conn: conn} do
      import Ecto.Query, only: [from: 2]

      goals_params = [
        %{
          "title" => "Batch Goal D81",
          "type" => "goal",
          "tasks" => [
            %{"title" => "Valid sibling D81", "type" => "work"},
            %{"title" => @over_long_title, "type" => "work"}
          ]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)

      # Clean 422 (not a raised 22001 / 500) — reaching this assertion proves the
      # request did not raise.
      assert json_response(conn, 422)

      # …and the whole batch rolled back: the valid sibling was not persisted.
      sibling_query = from(t in Kanban.Tasks.Task, where: t.title == "Valid sibling D81")
      goal_query = from(t in Kanban.Tasks.Task, where: t.title == "Batch Goal D81")
      refute Kanban.Repo.exists?(sibling_query)
      refute Kanban.Repo.exists?(goal_query)
    end

    # W1414: extend the existing security_considerations element-length coverage
    # to the other two varchar(255)[] array fields end-to-end through the API, so
    # all three bounded array fields are exercised at the controller layer. The
    # element is 256 code points to cross the per-element boundary.
    @over_long_element String.duplicate("a", 256)

    test "POST /api/tasks with an over-255 dependencies element returns 422 naming the field",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Deps element length W1414",
            "type" => "work",
            "priority" => "medium",
            "dependencies" => ["W1", @over_long_element]
          }
        )

      errors = json_response(conn, 422)["errors"]
      assert errors["dependencies"]
      assert "each entry should be at most 255 character(s)" in errors["dependencies"]
    end

    test "PATCH /api/tasks/:id with an over-255 dependencies element returns 422 naming the field",
         %{conn: conn, column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Deps PATCH base W1414",
          "created_by_id" => user.id
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"dependencies" => ["W1", @over_long_element]}
        )

      errors = json_response(conn, 422)["errors"]
      assert errors["dependencies"]
      assert "each entry should be at most 255 character(s)" in errors["dependencies"]
    end

    test "POST /api/tasks with an over-255 required_capabilities element returns 422 naming the field",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Caps element length W1414",
            "type" => "work",
            "priority" => "medium",
            "required_capabilities" => [@over_long_element]
          }
        )

      assert json_response(conn, 422)["errors"]["required_capabilities"]
    end

    test "PATCH /api/tasks/:id with an over-255 required_capabilities element returns 422 naming the field",
         %{conn: conn, column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Caps PATCH base W1414",
          "created_by_id" => user.id
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"required_capabilities" => [@over_long_element]}
        )

      assert json_response(conn, 422)["errors"]["required_capabilities"]
    end
  end

  describe "value-too-long never returns a 500 or leaks DB text (W1413)" do
    # The per-field validators (D81) keep every known bounded column from
    # overflowing, and the DbErrors safety net (Kanban.Tasks.DbErrorsTest)
    # translates any residual 22001 into the same sanitized 422. At the API
    # boundary the contract is identical either way: an oversized value returns a
    # clean 422 whose body carries no raw Postgrex/SQL text.
    @over_long_w1413 String.duplicate("a", 256)

    test "POST /api/tasks with an oversized value returns 422 and no raw DB text",
         %{conn: conn} do
      conn = post(conn, ~p"/api/tasks", task: %{"title" => @over_long_w1413})

      body = json_response(conn, 422)
      assert body["errors"] != %{}

      rendered = inspect(body)
      refute rendered =~ "Postgrex"
      refute rendered =~ "22001"
      refute rendered =~ "string_data_right_truncation"
    end

    test "PATCH /api/tasks/:id with an oversized value returns 422 and no raw DB text",
         %{conn: conn, column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{"title" => "Original W1413", "created_by_id" => user.id})

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: %{"title" => @over_long_w1413})

      body = json_response(conn, 422)
      assert body["errors"] != %{}

      rendered = inspect(body)
      refute rendered =~ "Postgrex"
      refute rendered =~ "22001"
    end
  end

  describe "POST /api/tasks/batch" do
    test "returns 403 for a read-only board member (D154)", %{board: board, user: owner} do
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      {:ok, {_t, reader_token}} =
        ApiTokens.create_api_token(reader, board, %{"name" => "Reader Token"})

      goals_params = [
        %{"title" => "Sneaky Goal", "type" => "goal", "priority" => "high", "tasks" => []}
      ]

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{reader_token}")
        |> post(~p"/api/tasks/batch", goals: goals_params)

      assert json_response(conn, 403)
      # No goal was created for the unauthorized caller.
      goals = Kanban.Tasks.Queries.list_goals_for_board(board.id)
      assert Enum.all?(goals, &(&1.title != "Sneaky Goal"))
    end

    test "creates multiple goals with child tasks", %{conn: conn} do
      goals_params = [
        %{
          "title" => "Goal 1",
          "description" => "First goal",
          "type" => "goal",
          "priority" => "high",
          "tasks" => [
            %{"title" => "Task 1-1", "type" => "work", "complexity" => "small"},
            %{"title" => "Task 1-2", "type" => "work", "complexity" => "medium"}
          ]
        },
        %{
          "title" => "Goal 2",
          "description" => "Second goal",
          "type" => "goal",
          "priority" => "medium",
          "tasks" => [
            %{"title" => "Task 2-1", "type" => "work", "complexity" => "large"}
          ]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 201)

      assert %{"success" => true, "total" => 2, "goals" => goals} = response
      assert length(goals) == 2

      first_goal = Enum.at(goals, 0)
      assert first_goal["goal"]["title"] == "Goal 1"
      assert first_goal["goal"]["type"] == "goal"
      assert length(first_goal["child_tasks"]) == 2

      second_goal = Enum.at(goals, 1)
      assert second_goal["goal"]["title"] == "Goal 2"
      assert length(second_goal["child_tasks"]) == 1
    end

    test "creates single goal in batch", %{conn: conn} do
      goals_params = [
        %{
          "title" => "Single Goal",
          "type" => "goal",
          "tasks" => [
            %{"title" => "Single Task", "type" => "work"}
          ]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 201)

      assert %{"success" => true, "total" => 1, "goals" => goals} = response
      assert length(goals) == 1
    end

    test "returns error when goal at specific index fails validation", %{conn: conn} do
      goals_params = [
        %{
          "title" => "Valid Goal",
          "type" => "goal",
          "tasks" => [%{"title" => "Task 1", "type" => "work"}]
        },
        %{
          "title" => "",
          "type" => "goal",
          "tasks" => [%{"title" => "Task 2", "type" => "work"}]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 422)

      assert %{"error" => error, "index" => 1, "details" => details} = response
      assert error =~ "Failed to create goal at index 1"
      assert is_map(details)
    end

    test "stops processing on first error (partial success)", %{conn: conn} do
      goals_params = [
        %{
          "title" => "Goal 1",
          "type" => "goal",
          "tasks" => [%{"title" => "Task 1", "type" => "work"}]
        },
        %{
          "title" => "",
          "type" => "goal",
          "tasks" => []
        },
        %{
          "title" => "Goal 3",
          "type" => "goal",
          "tasks" => [%{"title" => "Task 3", "type" => "work"}]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 422)

      assert %{"index" => 1} = response

      conn = get(conn, ~p"/api/tasks")
      tasks_response = json_response(conn, 200)
      titles = Enum.map(tasks_response["data"], & &1["title"])

      assert "Goal 1" in titles
      refute "Goal 3" in titles
    end

    test "creates empty batch successfully", %{conn: conn} do
      conn = post(conn, ~p"/api/tasks/batch", goals: [])
      response = json_response(conn, 201)

      assert %{"success" => true, "total" => 0, "goals" => []} = response
    end

    test "tracks AI agent when creating batch with agent_model", %{
      conn: _conn,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "AI Agent Token",
          "agent_model" => "claude-sonnet-4-5"
        })

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      goals_params = [
        %{
          "title" => "Agent Goal",
          "type" => "goal",
          "tasks" => [%{"title" => "Agent Task", "type" => "work"}]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 201)

      assert %{"goals" => goals} = response
      goal = Enum.at(goals, 0)["goal"]
      assert goal["created_by_agent"] == "ai_agent:claude-sonnet-4-5"
    end

    test "preserves created_by_agent when explicitly provided in batch creation", %{
      conn: _conn,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Regular Token"
        })

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      goals_params = [
        %{
          "title" => "AI Generated Goal",
          "type" => "goal",
          "created_by_agent" => "gpt-4-turbo",
          "tasks" => [
            %{
              "title" => "AI Generated Task",
              "type" => "work",
              "created_by_agent" => "gpt-4-turbo"
            }
          ]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 201)

      assert %{"goals" => goals} = response
      goal = Enum.at(goals, 0)["goal"]
      assert goal["created_by_agent"] == "gpt-4-turbo"

      child_task = Enum.at(goals, 0)["child_tasks"] |> Enum.at(0)
      assert child_task["created_by_agent"] == "gpt-4-turbo"
    end

    test "applies a top-level agent_name to every batch goal and children inherit it (D137)", %{
      conn: _conn,
      user: user,
      board: board
    } do
      {:ok, {token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Regular Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      goals_params = [
        %{
          "title" => "First Goal",
          "type" => "goal",
          "tasks" => [%{"title" => "First Child", "type" => "work"}]
        },
        %{
          "title" => "Second Goal",
          "type" => "goal",
          "tasks" => [%{"title" => "Second Child", "type" => "work"}]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params, agent_name: "Claude Fable 5")
      response = json_response(conn, 201)

      assert %{"goals" => goals} = response
      assert length(goals) == 2

      for entry <- goals do
        assert entry["goal"]["created_by_agent"] == "Claude Fable 5"

        for child <- entry["child_tasks"] do
          assert child["created_by_agent"] == "Claude Fable 5"
        end
      end

      # The batch request also stamps the token for future fallbacks.
      assert ApiTokens.get_api_token!(token_struct.id).last_agent_name == "Claude Fable 5"
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = post(conn, ~p"/api/tasks/batch", goals: [])
      assert json_response(conn, 401)
    end

    test "returns helpful error when using 'tasks' instead of 'goals' as root key", %{conn: conn} do
      task_params = [
        %{
          "title" => "Goal 1",
          "type" => "goal",
          "tasks" => [
            %{"title" => "Task 1", "type" => "work"}
          ]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", tasks: task_params)
      response = json_response(conn, 422)

      assert %{
               "error" => error,
               "example" => example,
               "documentation" => doc_url,
               "common_causes" => causes,
               "correct_format" => format_hint
             } = response

      assert error =~ "root key must be 'goals', not 'tasks'"
      assert is_map(example)
      assert Map.has_key?(example, "goals")
      assert doc_url =~ "post_tasks_batch.md"
      assert is_list(causes)
      assert format_hint == "See the 'example' field in this response"
    end

    test "returns helpful error when missing 'goals' key entirely", %{conn: conn} do
      conn = post(conn, ~p"/api/tasks/batch", %{})
      response = json_response(conn, 422)

      assert %{
               "error" => error,
               "example" => example,
               "documentation" => doc_url
             } = response

      assert error =~ "Missing 'goals' key"
      assert is_map(example)
      assert Map.has_key?(example, "goals")
      assert doc_url =~ "post_tasks_batch.md"
    end

    test "handles goals with complex fields", %{conn: conn} do
      goals_params = [
        %{
          "title" => "Complex Goal",
          "description" => "Goal with many fields",
          "type" => "goal",
          "priority" => "critical",
          "complexity" => "large",
          "why" => "Business need",
          "what" => "Feature implementation",
          "where_context" => "lib/kanban",
          "technology_requirements" => ["elixir", "phoenix"],
          "pitfalls" => ["Don't forget validation"],
          "tasks" => [
            %{
              "title" => "Complex Task",
              "type" => "work",
              "complexity" => "medium",
              "key_files" => [
                %{"file_path" => "lib/test.ex", "note" => "Main file", "position" => 0}
              ]
            }
          ]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 201)

      assert %{"success" => true, "total" => 1} = response
      goal = Enum.at(response["goals"], 0)["goal"]
      assert goal["title"] == "Complex Goal"
      assert goal["priority"] == "critical"
    end
  end

  describe "GET /api/tasks" do
    setup %{column: column, user: user} do
      {:ok, task1} =
        Tasks.create_task(column, %{
          "title" => "Task 1",
          "description" => "First task",
          "created_by_id" => user.id
        })

      {:ok, task2} =
        Tasks.create_task(column, %{
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

    test "returns 400 for comma-separated column_id", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks?column_id=306,305")
      response = json_response(conn, 400)

      assert response["error"] =~ "Invalid column_id"
    end

    test "returns 400 for non-numeric column_id", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks?column_id=abc")
      response = json_response(conn, 400)

      assert response["error"] =~ "Invalid column_id"
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks")
      assert json_response(conn, 401)
    end

    test "an absent response_view returns a body identical to an explicit full", %{
      conn: conn,
      task1: task1
    } do
      absent = json_response(get(conn, ~p"/api/tasks"), 200)
      explicit = json_response(get(conn, ~p"/api/tasks?response_view=full"), 200)

      assert absent == explicit

      # Pinned against the untouched GET /api/tasks/:id view, so this cannot
      # pass by both the index row and the fixture shrinking together.
      show = json_response(get(conn, ~p"/api/tasks/#{task1.id}"), 200)["data"]
      row = Enum.find(absent["data"], &(&1["id"] == task1.id))

      assert row |> Map.keys() |> Enum.sort() == show |> Map.keys() |> Enum.sort()
    end

    test "the full index row still carries every fat field, including the review fields", %{
      conn: conn,
      task1: task1
    } do
      response = json_response(get(conn, ~p"/api/tasks"), 200)
      row = Enum.find(response["data"], &(&1["id"] == task1.id))

      for field <- ~w(description acceptance_criteria key_files verification_steps
                      review_status review_notes review_report reviewed_at
                      reviewed_by_id reviewer_result explorer_result) do
        assert Map.has_key?(row, field), "the full index row dropped #{field}"
      end
    end

    test "response_view=slim returns only the eight summary keys per row", %{conn: conn} do
      response = json_response(get(conn, ~p"/api/tasks?response_view=slim"), 200)

      assert length(response["data"]) >= 2

      for row <- response["data"] do
        assert row |> Map.keys() |> Enum.sort() ==
                 ~w(complexity created_by_agent dependencies id identifier priority status title)

        refute Map.has_key?(row, "description")
        refute Map.has_key?(row, "key_files")
        refute Map.has_key?(row, "reviewer_result")
      end
    end

    # The security consideration, computed from the live responses rather than
    # from a hardcoded list, so it keeps holding if either shape moves.
    test "the slim row is a strict subset of the full row", %{conn: conn, task1: task1} do
      full = json_response(get(conn, ~p"/api/tasks"), 200)
      slim = json_response(get(conn, ~p"/api/tasks?response_view=slim"), 200)

      full_row = Enum.find(full["data"], &(&1["id"] == task1.id))
      slim_row = Enum.find(slim["data"], &(&1["id"] == task1.id))

      full_keys = full_row |> Map.keys() |> MapSet.new()
      slim_keys = slim_row |> Map.keys() |> MapSet.new()

      assert MapSet.subset?(slim_keys, full_keys)
      refute MapSet.equal?(slim_keys, full_keys)
    end

    test "response_view=slim returns the same rows, in the same order, as the full view", %{
      conn: conn
    } do
      full = json_response(get(conn, ~p"/api/tasks"), 200)
      slim = json_response(get(conn, ~p"/api/tasks?response_view=slim"), 200)

      # Slimming is shape-only: it must not add a row the full view withheld,
      # nor drop one it returned.
      assert Enum.map(slim["data"], & &1["id"]) == Enum.map(full["data"], & &1["id"])
    end

    test "response_view=slim is honoured when filtering by column_id", %{
      conn: conn,
      column: column
    } do
      response =
        json_response(get(conn, ~p"/api/tasks?column_id=#{column.id}&response_view=slim"), 200)

      refute response["data"] == []

      for row <- response["data"] do
        assert row |> Map.keys() |> Enum.sort() ==
                 ~w(complexity created_by_agent dependencies id identifier priority status title)
      end
    end

    test "an unrecognised response_view returns the full index", %{conn: conn} do
      for value <- ~w(full SLIM compact) do
        response = json_response(get(conn, ~p"/api/tasks?response_view=#{value}"), 200)

        for row <- response["data"] do
          assert Map.has_key?(row, "description"),
                 "response_view=#{value} unexpectedly slimmed the index"
        end
      end
    end
  end

  describe "GET /api/tasks/:id" do
    setup %{column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Detailed Task",
          "description" => "Full details",
          "complexity" => "large",
          "why" => "Important reason",
          "created_by_id" => user.id
        })

      %{task: task}
    end

    test "response_view does not slim GET /api/tasks/:id in either direction", %{
      conn: conn,
      task: task
    } do
      full = json_response(get(conn, ~p"/api/tasks/#{task.id}"), 200)
      slim = json_response(get(conn, ~p"/api/tasks/#{task.id}?response_view=slim"), 200)

      assert slim == full

      for field <- ~w(description key_files reviewer_result acceptance_criteria) do
        assert Map.has_key?(slim["data"], field),
               "GET /api/tasks/:id must stay full-fidelity under response_view=slim"
      end
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
      conn = get(conn, ~p"/api/tasks/999999")
      response = json_response(conn, 404)
      assert response["error"] == "Task not found"
    end

    test "returns 404 for nonexistent identifier", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/INVALID99")
      response = json_response(conn, 404)
      assert response["error"] == "Task not found"
    end

    test "returns 404 for realistic but nonexistent identifier like 'current'", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/current")
      response = json_response(conn, 404)
      assert response["error"] == "Task not found"
    end

    test "returns 401 without authentication", %{task: task} do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      assert json_response(conn, 401)
    end

    test "returns review_report in task response", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with review report",
          "review_report" => "## Review\n\nApproved with no issues."
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["review_report"] == "## Review\n\nApproved with no issues."
    end

    test "returns review_report as null when not set", %{conn: conn, task: task} do
      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert is_nil(response["review_report"])
    end

    test "returns workflow_steps in task response", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with workflow steps",
          "workflow_steps" => [
            %{"name" => "plan", "status" => "done", "duration_ms" => 100}
          ]
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["workflow_steps"] == [
               %{"name" => "plan", "status" => "done", "duration_ms" => 100}
             ]
    end

    test "returns workflow_steps as empty array when not set", %{conn: conn, task: task} do
      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["workflow_steps"] == []
    end

    test "returns explorer_result in task response", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with explorer result",
          "explorer_result" => %{
            "dispatched" => true,
            "summary" => "Explored key files and identified existing patterns to follow",
            "duration_ms" => 12_000
          }
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["explorer_result"] == %{
               "dispatched" => true,
               "summary" => "Explored key files and identified existing patterns to follow",
               "duration_ms" => 12_000
             }
    end

    test "returns explorer_result as null when not set", %{conn: conn, task: task} do
      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert is_nil(response["explorer_result"])
    end

    test "returns reviewer_result in task response", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with reviewer result",
          "reviewer_result" => %{
            "dispatched" => true,
            "summary" => "Reviewed the diff against acceptance criteria and pitfalls",
            "duration_ms" => 8_000,
            "acceptance_criteria_checked" => 5,
            "issues_found" => 0
          }
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["reviewer_result"] == %{
               "dispatched" => true,
               "summary" => "Reviewed the diff against acceptance criteria and pitfalls",
               "duration_ms" => 8_000,
               "acceptance_criteria_checked" => 5,
               "issues_found" => 0
             }
    end

    test "returns reviewer_result as null when not set", %{conn: conn, task: task} do
      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert is_nil(response["reviewer_result"])
    end
  end

  describe "PATCH /api/tasks/:id" do
    setup %{column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Original Title",
          "description" => "Original description",
          "complexity" => "small",
          "created_by_id" => user.id
        })

      %{task: task}
    end

    test "returns 403 for a read-only board member (D109)", %{
      board: board,
      user: owner,
      task: task
    } do
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      {:ok, {_t, reader_token}} =
        ApiTokens.create_api_token(reader, board, %{"name" => "Reader Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{reader_token}")
        |> patch(~p"/api/tasks/#{task.id}", task: %{"title" => "Hacked"})

      assert json_response(conn, 403)
      assert Kanban.Repo.get!(Kanban.Tasks.Task, task.id).title == "Original Title"
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

    test "rejects column_id change (Backlog to Ready bypass attempt)", %{
      conn: conn,
      task: task,
      board: board
    } do
      ready_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Ready"))

      update_params = %{"column_id" => ready_column.id}

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: update_params)
      response = json_response(conn, 403)

      assert response["error"] =~ "cannot move tasks between columns"

      # Confirm the task did NOT move
      reloaded = Tasks.get_task!(task.id)
      assert reloaded.column_id == task.column_id
    end

    test "allows update when column_id matches current value (idempotent echo)", %{
      conn: conn,
      task: task
    } do
      update_params = %{
        "title" => "Echoed back",
        "column_id" => task.column_id
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: update_params)
      response = json_response(conn, 200)["data"]

      assert response["title"] == "Echoed back"
      assert response["column_id"] == task.column_id
    end

    test "rejects invalid column_id value", %{conn: conn, task: task} do
      update_params = %{"column_id" => "306,305"}

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: update_params)
      response = json_response(conn, 403)

      assert response["error"] =~ "cannot move tasks between columns"
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      conn = patch(conn, ~p"/api/tasks/999999", task: %{"title" => "Updated"})
      response = json_response(conn, 404)
      assert response["error"] == "Task not found"
    end

    test "returns 401 without authentication", %{task: task} do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = patch(conn, ~p"/api/tasks/#{task.id}", task: %{"title" => "Updated"})
      assert json_response(conn, 401)
    end

    test "returns helpful error when using 'data' instead of 'task' as root key", %{
      conn: conn,
      task: task
    } do
      conn = patch(conn, ~p"/api/tasks/#{task.id}", data: %{"title" => "Updated"})
      response = json_response(conn, 422)

      assert %{
               "error" => error,
               "example" => example,
               "documentation" => doc_url,
               "common_causes" => causes,
               "correct_format" => format_hint
             } = response

      assert error =~ "request body key must be 'task', not 'data'"
      assert is_map(example)
      assert Map.has_key?(example, "task")
      assert doc_url =~ "patch_tasks_id.md"
      assert is_list(causes)
      assert format_hint == "See the 'example' field in this response"
    end

    test "returns helpful error when missing 'task' key entirely", %{conn: conn, task: task} do
      conn = patch(conn, ~p"/api/tasks/#{task.id}", %{})
      response = json_response(conn, 422)

      assert %{
               "error" => error,
               "example" => example,
               "documentation" => doc_url
             } = response

      assert error =~ "Missing 'task' key"
      assert is_map(example)
      assert Map.has_key?(example, "task")
      assert doc_url =~ "patch_tasks_id.md"
    end
  end

  # Names the fields the failures list must identify, and asserts the whole
  # request was discarded rather than partially applied.
  defp assert_update_rejected(conn, task, expected_fields) do
    body = json_response(conn, 422)
    reloaded = Tasks.get_task!(task.id)

    assert body["error"] == "task update rejected"

    named = Enum.map(hd(body["failures"])["errors"], & &1["field"])
    assert Enum.sort(named) == Enum.sort(expected_fields)

    assert Enum.all?(hd(body["failures"])["errors"], fn e ->
             String.contains?(e["message"], "cannot be changed via PATCH")
           end)

    # The refusal is wired to its OWN ErrorDocs context, not the generic
    # fallback. Passing the wrong atom to add_docs_to_error/2 silently yields
    # the README link, which no test would otherwise notice.
    assert body["documentation"] =~ "patch_tasks_id.md"
    assert body["common_causes"] != []

    # The legitimate half of the payload is not applied either.
    assert reloaded.title == task.title
    reloaded
  end

  # (D227) These asserted 200 with the forbidden field silently dropped — which
  # was the defect, not the contract. A caller correcting a completion record
  # got a normal task body and no errors key, so a record known to be wrong
  # stayed wrong while its author believed it was fixed.
  #
  # Each case now asserts three things, and the third is the one that makes the
  # first two mean something: the request is refused, the offending field is
  # named, and NOTHING was written — including the legitimate fields in the same
  # payload. A partial apply would reintroduce the same ambiguity one level
  # down, leaving the caller to diff the response to learn which half landed.
  describe "PATCH /api/tasks/:id mass-assignment protection" do
    setup %{column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Original",
          "description" => "Initial description",
          "complexity" => "small",
          "created_by_id" => user.id
        })

      %{task: task}
    end

    test "rejects status rather than stripping it", %{conn: conn, task: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", task: %{"title" => "New", "status" => "completed"})

      reloaded = assert_update_rejected(conn, task, ["status"])
      assert reloaded.status == task.status
      refute reloaded.status == :completed
    end

    test "rejects assigned_to_id", %{conn: conn, task: task} do
      other = user_fixture()

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"title" => "New", "assigned_to_id" => other.id}
        )

      reloaded = assert_update_rejected(conn, task, ["assigned_to_id"])
      assert reloaded.assigned_to_id == task.assigned_to_id
    end

    test "rejects completed_by_id and completed_at", %{conn: conn, task: task} do
      other = user_fixture()

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "New",
            "completed_by_id" => other.id,
            "completed_at" => "2025-01-01T00:00:00Z"
          }
        )

      reloaded = assert_update_rejected(conn, task, ["completed_at", "completed_by_id"])
      assert is_nil(reloaded.completed_by_id)
      assert is_nil(reloaded.completed_at)
    end

    test "rejects reviewed_by_id, reviewed_at, review_status, review_notes",
         %{conn: conn, task: task} do
      other = user_fixture()

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "New",
            "reviewed_by_id" => other.id,
            "reviewed_at" => "2025-01-01T00:00:00Z",
            "review_status" => "approved",
            "review_notes" => "forged"
          }
        )

      reloaded =
        assert_update_rejected(conn, task, [
          "review_notes",
          "review_status",
          "reviewed_at",
          "reviewed_by_id"
        ])

      assert is_nil(reloaded.reviewed_by_id)
      assert is_nil(reloaded.reviewed_at)
      assert reloaded.review_status == task.review_status
      assert reloaded.review_notes == task.review_notes
    end

    test "rejects identifier (server-generated only)", %{conn: conn, task: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", task: %{"title" => "New", "identifier" => "X999"})

      reloaded = assert_update_rejected(conn, task, ["identifier"])
      assert reloaded.identifier == task.identifier
    end

    test "rejects parent_id", %{conn: conn, column: column, user: user, task: task} do
      {:ok, other_parent} =
        Tasks.create_task(column, %{
          "title" => "Other parent",
          "type" => "goal",
          "created_by_id" => user.id
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"title" => "New", "parent_id" => other_parent.id}
        )

      reloaded = assert_update_rejected(conn, task, ["parent_id"])
      assert reloaded.parent_id == task.parent_id
    end

    test "rejects claim fields", %{conn: conn, task: task} do
      other = user_fixture()

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "New",
            "claimed_at" => "2025-01-01T00:00:00Z",
            "claim_expires_at" => "2025-01-02T00:00:00Z",
            "assigned_to_id" => other.id
          }
        )

      reloaded =
        assert_update_rejected(conn, task, ["assigned_to_id", "claim_expires_at", "claimed_at"])

      assert is_nil(reloaded.claimed_at)
      assert is_nil(reloaded.claim_expires_at)
    end

    test "rejects completion actuals (time_spent_minutes, actual_complexity, actual_files_changed)",
         %{conn: conn, task: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "New",
            "time_spent_minutes" => 9999,
            "actual_complexity" => "large",
            "actual_files_changed" => "forged.ex"
          }
        )

      reloaded =
        assert_update_rejected(conn, task, [
          "actual_complexity",
          "actual_files_changed",
          "time_spent_minutes"
        ])

      assert is_nil(reloaded.time_spent_minutes)
      assert is_nil(reloaded.actual_complexity)
      assert is_nil(reloaded.actual_files_changed)
    end

    test "rejects created_by_* and archived_at", %{conn: conn, task: task} do
      other = user_fixture()

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "New",
            "created_by_id" => other.id,
            "created_by_agent" => "Forged Agent",
            "archived_at" => "2025-01-01T00:00:00Z"
          }
        )

      reloaded =
        assert_update_rejected(conn, task, ["archived_at", "created_by_agent", "created_by_id"])

      assert reloaded.created_by_id == task.created_by_id
      assert is_nil(reloaded.archived_at)
    end

    test "rejects workflow_steps / explorer_result / reviewer_result",
         %{conn: conn, task: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "New",
            "workflow_steps" => [%{"name" => "fake", "dispatched" => true, "duration_ms" => 1}],
            "explorer_result" => %{"dispatched" => true, "summary" => "fake"},
            "reviewer_result" => %{"dispatched" => true, "summary" => "fake"}
          }
        )

      reloaded =
        assert_update_rejected(conn, task, [
          "explorer_result",
          "reviewer_result",
          "workflow_steps"
        ])

      assert reloaded.workflow_steps == task.workflow_steps
      assert reloaded.explorer_result == task.explorer_result
      assert reloaded.reviewer_result == task.reviewer_result
    end

    test "names every forbidden field at once and applies none of the legitimate ones",
         %{conn: conn, task: task} do
      other = user_fixture()

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "Legitimate",
            "why" => "Legitimate why",
            "status" => "completed",
            "identifier" => "X999",
            "assigned_to_id" => other.id,
            "completed_by_id" => other.id,
            "completed_at" => "2025-01-01T00:00:00Z",
            "reviewed_by_id" => other.id,
            "review_status" => "approved",
            "time_spent_minutes" => 9999,
            "actual_complexity" => "large",
            "archived_at" => "2025-01-01T00:00:00Z"
          }
        )

      reloaded =
        assert_update_rejected(conn, task, [
          "actual_complexity",
          "archived_at",
          "assigned_to_id",
          "completed_at",
          "completed_by_id",
          "identifier",
          "review_status",
          "reviewed_by_id",
          "status",
          "time_spent_minutes"
        ])

      # Both legitimate fields are refused along with the rest.
      assert reloaded.title == task.title
      assert reloaded.why == task.why
      assert reloaded.identifier == task.identifier
      assert reloaded.status == task.status
      assert is_nil(reloaded.completed_by_id)
    end

    test "a patch of only editable fields still succeeds", %{conn: conn, task: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"title" => "Edited", "why" => "Because", "priority" => "high"}
        )

      assert json_response(conn, 200)["data"]["title"] == "Edited"
      reloaded = Tasks.get_task!(task.id)
      assert reloaded.title == "Edited"
      assert reloaded.why == "Because"
    end

    # The half of "identifies which field was rejected AND why" that the
    # assertions above do not reach. Every forbidden field is PATCHed and its
    # reason pinned, so the branches of forbidden_update_reason/1 are verified
    # in both directions rather than by inspection.
    #
    # It also enumerates from TaskParamFilter rather than from a copy, which
    # makes it the drift guard: a field added to the forbidden list appears here
    # with no expected reason and fails, instead of silently acquiring the
    # catch-all "server-managed" text — which for a workflow field would send
    # the caller to the wrong endpoint. That is the same class of error as the
    # silent 200 this defect removes, one level down.
    @reason_by_field %{
      "status" => :claim_and_completion,
      "assigned_to_id" => :claim_and_completion,
      "claimed_at" => :claim_and_completion,
      "claim_expires_at" => :claim_and_completion,
      "completed_at" => :claim_and_completion,
      "completed_by_id" => :claim_and_completion,
      "completed_by_agent" => :claim_and_completion,
      "completion_summary" => :claim_and_completion,
      "completion_notes" => :claim_and_completion,
      "actual_complexity" => :claim_and_completion,
      "actual_files_changed" => :claim_and_completion,
      "time_spent_minutes" => :claim_and_completion,
      "review_report" => :claim_and_completion,
      "workflow_steps" => :claim_and_completion,
      "explorer_result" => :claim_and_completion,
      "reviewer_result" => :claim_and_completion,
      "review_status" => :review_verdict,
      "review_notes" => :review_verdict,
      "reviewed_at" => :review_attribution,
      "reviewed_by_id" => :review_attribution,
      "identifier" => :server_managed,
      "parent_id" => :server_managed,
      "position" => :server_managed,
      "created_by_id" => :server_managed,
      "created_by_agent" => :server_managed,
      "archived_at" => :server_managed,
      "archive_reason" => :server_managed,
      "archive_note" => :server_managed,
      "archived_by_id" => :server_managed,
      "target_id" => :server_managed,
      "duplicate_of_id" => :server_managed,
      "changed_files" => {:dedicated, "PUT /api/tasks/:id/changed_files, its sole writer"},
      "after_goal_status" => {:dedicated, "PATCH /api/tasks/:id/after_goal"},
      "after_goal_result" => {:dedicated, "PATCH /api/tasks/:id/after_goal"},
      "after_goal_attempts" => {:dedicated, "PATCH /api/tasks/:id/after_goal"},
      # Not refused at all: it has its own upstream 403 gate, and an echo of
      # the current column is allowed through. Listed so the exhaustiveness
      # check below still covers the whole filter.
      "column_id" => :not_refused
    }

    @expected_reason %{
      claim_and_completion: "it is written by the claim and complete workflow endpoints",
      review_verdict:
        "it is the review verdict, recorded by a human reviewing the task in the board UI; " <>
          "there is no API route that sets it",
      review_attribution:
        "it is review attribution, stamped by the server when a review is recorded",
      server_managed: "it is server-managed; it is set at creation or by a dedicated action"
    }

    # The refusal was added on top of the audit log and telemetry, not in place
    # of them — the module doc calls that log a monitored security control. Both
    # sit before the branch in the same function, so moving the refusal above
    # them would silence a control with the whole suite still green.
    # The audit line is Logger.info and the test env's primary level is
    # :warning, so it never reaches a handler without this — the same lift
    # task_param_filter_test.exs uses for the unit-level version of this
    # assertion. capture_log: false overrides the module-wide tag so the nested
    # capture below is the one that sees the output.
    @tag capture_log: false
    test "the refusal still emits the mass-assignment audit log and telemetry",
         %{conn: conn, task: task} do
      handler = "d227-forbidden-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:kanban, :api, :task_update_forbidden_fields_filtered],
        fn _event, _measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # Raised AFTER the attach: :telemetry logs an info-level note about local
      # handler functions, and lifting the level first would print it.
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = patch(conn, ~p"/api/tasks/#{task.id}", task: %{"status" => "completed"})
          assert json_response(conn, 422)
        end)

      assert log =~ "API mass-assignment attempt rejected"
      assert_receive {:telemetry, %{fields: ["status"], task_id: _}}
    end

    test "every forbidden field is classified, with no field left unaccounted for" do
      assert Enum.sort(Map.keys(@reason_by_field)) ==
               Enum.sort(TaskParamFilter.forbidden_api_update_fields())
    end

    # (D227) The structural version of this defect, and the one that let nine
    # fields keep the old behaviour after the first fix: the refusal keys off
    # the forbidden list, but silence comes from being on NEITHER list. A field
    # that is neither refused nor cast is dropped by the changeset and reported
    # as 200 — the exact symptom, one list over.
    #
    # Castability is derived from the changeset rather than copied from
    # `@api_update_fields`, because a copy is another list that can drift. A
    # cast field rejects a type-incompatible value with an error keyed on
    # itself; an uncast field ignores it silently. Two probes are needed since
    # no single value is invalid for every type — a map is valid for `:map`
    # fields, a string for string fields.
    test "no schema field falls between the forbidden list and the update allow-list" do
      ignored = ~w(id inserted_at updated_at)
      forbidden = TaskParamFilter.forbidden_api_update_fields()

      schema_fields =
        (Kanban.Tasks.Task.__schema__(:fields) ++ Kanban.Tasks.Task.__schema__(:embeds))
        |> Enum.map(&to_string/1)
        |> Enum.uniq()

      # Bracketed deliberately: `--` is RIGHT-associative, so an unbracketed
      # `a -- b -- c` means `a -- (b -- c)` and subtracts almost nothing. The
      # formatter makes that grouping visible; it is not what is wanted here.
      candidates = (schema_fields -- ignored) -- forbidden
      gap = Enum.reject(candidates, &castable_on_update?/1)

      assert gap == [],
             "these fields are neither refused nor written — a PATCH naming one " <>
               "returns 200 and silently discards it: #{inspect(gap)}"
    end

    test "each rejected field is given the reason that names its real writer",
         %{conn: conn, task: task} do
      for {field, kind} <- @reason_by_field, kind != :not_refused do
        expected =
          case kind do
            {:dedicated, endpoint} -> "it has its own endpoint: #{endpoint}"
            simple -> @expected_reason[simple]
          end

        conn = patch(conn, ~p"/api/tasks/#{task.id}", task: %{field => nil})
        [error] = hd(json_response(conn, 422)["failures"])["errors"]

        assert error["field"] == field

        assert error["message"] ==
                 "#{field} cannot be changed via PATCH /api/tasks/:id — " <>
                   "#{expected}. " <>
                   "The request was rejected in full and no field was changed.",
               "wrong reason for #{field} (expected the #{inspect(kind)} reason)"
      end
    end
  end

  # True when `Task.api_update_changeset/2` casts this field — established by
  # handing it a value its type cannot accept and seeing whether the changeset
  # objects on that field's own key. An uncast field is ignored without
  # complaint, which is precisely the silence being hunted.
  #
  # The base struct already satisfies `validate_required([:title, :type,
  # :priority])`. Starting from a bare `%Task{}` instead makes the probe report
  # `title` castable no matter what, because the required-field validation
  # supplies a `:title` error whether or not anything was cast — a guard that
  # answers "yes" for a field it never examined.
  defp castable_on_update?(field) do
    atom = String.to_existing_atom(field)
    base = %Kanban.Tasks.Task{title: "probe", type: :work, priority: :medium}

    Enum.any?([%{"nope" => "nope"}, "not-a-valid-value"], fn bad_value ->
      base
      |> Kanban.Tasks.Task.api_update_changeset(%{field => bad_value})
      |> Map.fetch!(:errors)
      |> Keyword.has_key?(atom)
    end)
  end

  # A task that already looks finished: `status: :completed` with a real
  # completion record, parked in whichever column the caller names. Written
  # straight through the Repo rather than through the complete endpoint,
  # because the point here is the PATCH path, not how the task got there.
  defp finished_task(column, user) do
    {:ok, task} =
      Tasks.create_task(column, %{
        "title" => "Finished work",
        "description" => "Already completed",
        "why" => "Original why",
        "complexity" => "small",
        "created_by_id" => user.id
      })

    task
    |> Ecto.Changeset.change(%{
      status: :completed,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      completed_by_id: user.id,
      completed_by_agent: "Original Agent",
      completion_summary: "Original summary",
      completion_notes: "Original notes, including a statement later found to be false",
      time_spent_minutes: 30,
      review_status: :pending
    })
    |> Kanban.Repo.update!()
  end

  # (D227) The reported symptom was specifically about a COMPLETED task: an
  # agent noticing a wrong completion record, PATCHing a correction, and getting
  # 200 back with nothing changed. The block above covers the mechanism on an
  # open task; this one covers the reported case itself, in both directions —
  # the immutable field is refused, and the fields that ARE editable after
  # completion still update, so the fix does not freeze the record wholesale.
  #
  # "In Review rather than Done" is here because those are two different states
  # that both look finished: Done is `status: :completed` in the Done column;
  # Review is the same status parked in the Review column awaiting a human. The
  # refusal must not depend on which column the task is sitting in.
  describe "PATCH /api/tasks/:id on a finished task" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      done_column = Enum.find(columns, &(&1.name == "Done"))
      review_column = Enum.find(columns, &(&1.name == "Review"))

      %{done: finished_task(done_column, user), review: finished_task(review_column, user)}
    end

    # The literal reported case: a corrected `completion_notes` on an already
    # completed task came back 200 with the original text intact.
    test "refuses a correction to completion_notes on a done task",
         %{conn: conn, done: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"completion_notes" => "corrected: the earlier note was false"}
        )

      body = json_response(conn, 422)
      reloaded = Tasks.get_task!(task.id)

      assert body["error"] == "task update rejected"
      assert Enum.map(hd(body["failures"])["errors"], & &1["field"]) == ["completion_notes"]

      # The record still stays wrong — but the caller is now told so instead of
      # being handed a success it can't distinguish from a real write.
      assert reloaded.completion_notes == task.completion_notes
      assert reloaded.status == :completed
    end

    # D227's report is a completion note that made a false claim ABOUT
    # changed_files, so this is the field an agent correcting that record
    # reaches for — and it was the last one still answering 200.
    test "refuses changed_files and points at its own endpoint", %{conn: conn, done: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "changed_files" => [%{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"}]
          }
        )

      [error] = hd(json_response(conn, 422)["failures"])["errors"]

      assert error["field"] == "changed_files"
      assert error["message"] =~ "PUT /api/tasks/:id/changed_files"

      assert Tasks.get_task!(task.id).changed_files == task.changed_files
    end

    test "refuses the completion metrics as a group", %{conn: conn, done: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"time_spent_minutes" => 45, "completion_summary" => "corrected"}
        )

      body = json_response(conn, 422)
      reloaded = Tasks.get_task!(task.id)

      assert Enum.sort(Enum.map(hd(body["failures"])["errors"], & &1["field"])) ==
               ["completion_summary", "time_spent_minutes"]

      assert reloaded.time_spent_minutes == task.time_spent_minutes
      assert reloaded.completion_summary == task.completion_summary
    end

    # The pitfall this defect names by hand: `behaviour_test_matrix` is
    # legitimately filled in after completion, so a fix that froze the whole
    # record would break it. It is not on the forbidden list, and this proves
    # the refusal did not quietly widen to cover it.
    test "still allows the editable fields on a done task", %{conn: conn, done: task} do
      matrix = full_behaviour_matrix()

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{
            "title" => "Corrected title",
            "pitfalls" => ["Do not re-run the migration"],
            "behaviour_test_matrix" => matrix
          }
        )

      body = json_response(conn, 200)["data"]
      assert body["title"] == "Corrected title"
      assert body["behaviour_test_matrix"] == expected_behaviour_matrix_json(matrix)

      reloaded = Tasks.get_task!(task.id)
      assert reloaded.title == "Corrected title"
      assert reloaded.pitfalls == ["Do not re-run the migration"]
      # Completion is untouched by an ordinary edit.
      assert reloaded.status == :completed
      assert reloaded.time_spent_minutes == task.time_spent_minutes
    end

    test "refuses the same field on a task in Review, not only in Done",
         %{conn: conn, review: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"title" => "New", "review_status" => "approved"}
        )

      body = json_response(conn, 422)
      reloaded = Tasks.get_task!(task.id)

      assert Enum.map(hd(body["failures"])["errors"], & &1["field"]) == ["review_status"]
      # Self-approval through the update endpoint is the thing being prevented.
      assert reloaded.review_status == :pending
      assert reloaded.title == task.title
    end

    test "a mixed patch on a review task applies neither half", %{conn: conn, review: task} do
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"why" => "Legitimate why", "completed_by_agent" => "Someone Else"}
        )

      assert json_response(conn, 422)["error"] == "task update rejected"

      reloaded = Tasks.get_task!(task.id)
      assert reloaded.why == task.why
      assert reloaded.completed_by_agent == task.completed_by_agent
    end
  end

  describe "cross-board access protection" do
    test "a cross-board task id and a nonexistent id both return 404 (no existence oracle, D160)",
         %{conn: conn, user: _user} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, other_task} =
        Tasks.create_task(other_column, %{
          "title" => "Other Board Task",
          "created_by_id" => other_user.id
        })

      # A task that exists on another board must be indistinguishable from a
      # task that does not exist: both 404, not 403-vs-404.
      cross_board = get(conn, ~p"/api/tasks/#{other_task.id}")
      nonexistent = get(conn, ~p"/api/tasks/#{999_999_999}")

      assert json_response(cross_board, 404)
      assert json_response(nonexistent, 404)
      assert json_response(cross_board, 404) == json_response(nonexistent, 404)
    end
  end

  describe "GET /api/tasks/next" do
    setup %{board: board, user: _user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      %{ready_column: ready_column, doing_column: doing_column}
    end

    test "returns next available task from Ready column", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(ready_column, %{
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

    test "excludes tasks with status in_progress", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, _claimed_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Claimed Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "created_by_id" => user.id
        })

      conn = get(conn, ~p"/api/tasks/next")
      assert json_response(conn, 404)
    end

    test "includes tasks with expired claims", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(ready_column, %{
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
      {:ok, _task1} =
        Tasks.create_task(ready_column, %{
          "title" => "Requires Testing",
          "status" => "open",
          "required_capabilities" => ["testing", "devops"],
          "created_by_id" => user.id
        })

      {:ok, task2} =
        Tasks.create_task(ready_column, %{
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

    test "empty agent capabilities can claim tasks with any requirements", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      board: board
    } do
      # Create API token with empty capabilities
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Empty Capabilities Token",
          "agent_capabilities" => []
        })

      {:ok, task1} =
        Tasks.create_task(ready_column, %{
          "title" => "Requires Testing",
          "status" => "open",
          "required_capabilities" => ["testing", "devops"],
          "created_by_id" => user.id
        })

      {:ok, _task2} =
        Tasks.create_task(ready_column, %{
          "title" => "Requires Code Gen",
          "status" => "open",
          "required_capabilities" => ["code_generation"],
          "created_by_id" => user.id
        })

      conn =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      # Empty agent_capabilities should match any task
      # Should return first task by priority/position
      assert response["id"] == task1.id
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

    test "atomically claims next available task", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      doing_column: doing_column
    } do
      {:ok, task} =
        Tasks.create_task(ready_column, %{
          "title" => "Task to Claim",
          "status" => "open",
          "created_by_id" => user.id
        })

      conn =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["status"] == "in_progress"
      assert response["column_id"] == doing_column.id
      assert response["assigned_to_id"] == user.id
      assert response["claimed_at"] != nil
      assert response["claim_expires_at"] != nil
    end

    test "returns 409 when no tasks available", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      assert json_response(conn, 409)["error"] =~ "No tasks available"
    end

    test "claim stamps last_agent_name from the raw param, never the Unknown default (D137)", %{
      ready_column: ready_column,
      user: user,
      board: board
    } do
      {:ok, _task} =
        Tasks.create_task(ready_column, %{
          "title" => "Stamped Claim Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, {token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Claim Token"})

      api_conn = fn ->
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")
      end

      # A claim with no agent_name falls back to "Unknown" internally, which
      # must never be persisted onto the token.
      no_name =
        post(api_conn.(), ~p"/api/tasks/claim", %{
          "before_doing_result" => valid_before_doing_result()
        })

      assert json_response(no_name, 200)
      assert ApiTokens.get_api_token!(token_struct.id).last_agent_name == nil

      # A claim carrying agent_name stamps it (even a failed claim attempt
      # identifies the agent — here the 409 path, since the task is taken).
      named =
        post(api_conn.(), ~p"/api/tasks/claim", %{
          "agent_name" => "Claim Agent",
          "before_doing_result" => valid_before_doing_result()
        })

      assert json_response(named, 409)
      assert ApiTokens.get_api_token!(token_struct.id).last_agent_name == "Claim Agent"
    end

    test "returns 403 when the caller is a read-only board member (W1430)", %{
      conn: _conn,
      ready_column: ready_column,
      user: owner,
      board: board
    } do
      {:ok, task} =
        Tasks.create_task(ready_column, %{
          "title" => "Restricted Task",
          "status" => "open",
          "created_by_id" => owner.id
        })

      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      {:ok, {_t, reader_token}} =
        ApiTokens.create_api_token(reader, board, %{"name" => "Reader Token"})

      reader_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{reader_token}")
        |> post(~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      assert json_response(reader_conn, 403)
      # The task stays unclaimed.
      refute Kanban.Repo.get!(Kanban.Tasks.Task, task.id).assigned_to_id
    end

    test "empty agent capabilities can claim tasks via claim endpoint", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      board: board,
      doing_column: doing_column
    } do
      # Create API token with empty capabilities
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Empty Capabilities Token",
          "agent_capabilities" => []
        })

      {:ok, task} =
        Tasks.create_task(ready_column, %{
          "title" => "Requires Multiple Capabilities",
          "status" => "open",
          "required_capabilities" => ["testing", "devops", "security_analysis"],
          "created_by_id" => user.id
        })

      conn =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      response = json_response(conn, 200)["data"]

      # Empty agent_capabilities should be able to claim any task
      assert response["id"] == task.id
      assert response["status"] == "in_progress"
      assert response["column_id"] == doing_column.id
    end

    test "empty capabilities combined with no task requirements", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Empty Capabilities Token",
          "agent_capabilities" => []
        })

      {:ok, task} =
        Tasks.create_task(ready_column, %{
          "title" => "No Requirements",
          "status" => "open",
          "required_capabilities" => [],
          "created_by_id" => user.id
        })

      conn =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      # Empty capabilities + empty requirements should work
      assert response["id"] == task.id
    end

    test "empty agent capabilities can claim specific task by identifier with requirements", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Empty Capabilities Token",
          "agent_capabilities" => []
        })

      {:ok, task} =
        Tasks.create_task(ready_column, %{
          "title" => "Requires Testing",
          "status" => "open",
          "required_capabilities" => ["testing", "devops"],
          "created_by_id" => user.id
        })

      conn =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn =
        post(conn, ~p"/api/tasks/claim", %{
          "identifier" => task.identifier,
          "before_doing_result" => valid_before_doing_result()
        })

      response = json_response(conn, 200)["data"]

      # Empty agent_capabilities should match any task even when claiming by identifier
      assert response["id"] == task.id
      assert response["status"] == "in_progress"
    end

    test "prevents double claiming", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      board: board
    } do
      {:ok, _task} =
        Tasks.create_task(ready_column, %{
          "title" => "Only Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      user2 = user_fixture()
      # user2 must be a board member with write access to get past the W1430
      # claim authorization gate and exercise the double-claim path.
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user2, :modify, user)

      {:ok, {_token_struct, plain_token2}} =
        Kanban.ApiTokens.create_api_token(user2, board, %{
          "name" => "Test Token 2",
          "agent_capabilities" => ["code_generation", "testing"]
        })

      conn2 =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token2}")

      conn1_response =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      assert json_response(conn1_response, 200)

      conn2_response =
        post(conn2, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      assert json_response(conn2_response, 409)
    end

    test "respects capability requirements", %{conn: conn, ready_column: ready_column, user: user} do
      {:ok, _task} =
        Tasks.create_task(ready_column, %{
          "title" => "Requires Deployment",
          "status" => "open",
          "required_capabilities" => ["devops"],
          "created_by_id" => user.id
        })

      conn =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      assert json_response(conn, 409)["error"] =~ "No tasks available"
    end

    test "returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      assert json_response(conn, 401)
    end

    test "claims specific task by identifier", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      doing_column: doing_column
    } do
      {:ok, _task1} =
        Tasks.create_task(ready_column, %{
          "title" => "First Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, task2} =
        Tasks.create_task(ready_column, %{
          "title" => "Second Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      conn =
        post(conn, ~p"/api/tasks/claim", %{
          "identifier" => task2.identifier,
          "before_doing_result" => valid_before_doing_result()
        })

      response = json_response(conn, 200)["data"]

      assert response["id"] == task2.id
      assert response["identifier"] == task2.identifier
      assert response["status"] == "in_progress"
      assert response["column_id"] == doing_column.id
      assert response["assigned_to_id"] == user.id
    end

    test "returns error when claiming specific task with dependencies", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, dependency_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Dependency Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, blocked_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task",
          "status" => "open",
          "dependencies" => [to_string(dependency_task.id)],
          "created_by_id" => user.id
        })

      conn =
        post(conn, ~p"/api/tasks/claim", %{
          "identifier" => blocked_task.identifier,
          "before_doing_result" => valid_before_doing_result()
        })

      response = json_response(conn, 409)

      assert response["error"] =~ blocked_task.identifier
      assert response["error"] =~ "not available to claim"
    end

    test "returns error when claiming non-existent task", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks/claim", %{
          "identifier" => "W99999",
          "before_doing_result" => valid_before_doing_result()
        })

      response = json_response(conn, 409)

      assert response["error"] =~ "W99999"
      assert response["error"] =~ "not available to claim"
    end

    test "returns 403 when claiming a task assigned to a different user", %{
      conn: conn,
      ready_column: ready_column,
      user: alice,
      board: board
    } do
      {:ok, alice_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Alice's task",
          "status" => "open",
          "created_by_id" => alice.id,
          "assigned_to_id" => alice.id
        })

      bob = user_fixture()
      # bob is a legitimate board member (write access) — the conflict under test
      # is the assignment to alice, not a board-access denial (W1430).
      {:ok, _} = Kanban.Boards.add_user_to_board(board, bob, :modify, alice)

      {:ok, {_token_struct, bob_token}} =
        ApiTokens.create_api_token(bob, board, %{
          "name" => "Bob's Token",
          "agent_capabilities" => ["code_generation", "testing"]
        })

      bob_conn =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{bob_token}")

      bob_conn =
        post(bob_conn, ~p"/api/tasks/claim", %{
          "identifier" => alice_task.identifier,
          "before_doing_result" => valid_before_doing_result()
        })

      response = json_response(bob_conn, 403)
      assert response["error"] =~ alice_task.identifier
      assert response["error"] =~ "assigned to a different user"

      # Database row is not mutated by the failed claim attempt.
      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, alice_task.id)
      assert reloaded.status == :open
      assert reloaded.assigned_to_id == alice.id
      assert is_nil(reloaded.claimed_at)
    end
  end

  describe "POST /api/tasks/:id/unclaim" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, task} =
        Tasks.create_task(doing_column, %{
          "title" => "Claimed Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      %{ready_column: ready_column, doing_column: doing_column, claimed_task: task}
    end

    test "releases claimed task back to Ready column", %{
      conn: conn,
      claimed_task: task,
      ready_column: ready_column,
      user: _user
    } do
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

    test "returns 403 when unclaiming someone else's task", %{
      conn: _conn,
      claimed_task: task,
      board: board
    } do
      other_user = user_fixture()

      {:ok, {_token_struct, plain_token}} =
        Kanban.ApiTokens.create_api_token(other_user, board, %{
          "name" => "Other Token",
          "agent_capabilities" => ["code_generation", "testing"]
        })

      other_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn = post(other_conn, ~p"/api/tasks/#{task.id}/unclaim")
      assert json_response(conn, 403)["error"] =~ "You can only unclaim tasks that you claimed"
    end

    test "returns 422 when task is not claimed", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, open_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Open Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      conn = post(conn, ~p"/api/tasks/#{open_task.id}/unclaim")
      assert json_response(conn, 422)["error"] =~ "not currently claimed"
    end

    test "unclaims task using identifier instead of ID", %{
      conn: conn,
      claimed_task: task,
      ready_column: ready_column
    } do
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

      {:ok, task} =
        Tasks.create_task(doing_column, %{
          "title" => "Test Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "needs_review" => true
        })

      %{
        doing_column: doing_column,
        review_column: review_column,
        task: task
      }
    end

    test "completes task and moves to Review column", %{
      conn: conn,
      task: task,
      review_column: review_column
    } do
      completion_params = %{
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [%{path: "lib/test.ex", changes: "Added function"}],
            verification_results: %{status: "passed", commands_run: ["mix test"]}
          }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
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

    test "completes task using identifier instead of ID", %{
      conn: conn,
      task: task,
      review_column: review_column
    } do
      completion_params = %{
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [%{path: "lib/test.ex", changes: "Added function"}],
            verification_results: %{status: "passed", commands_run: ["mix test"]}
          }),
        "actual_complexity" => "small",
        "actual_files_changed" => "1",
        "time_spent_minutes" => 10,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.identifier}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["column_id"] == review_column.id
    end

    test "round-trips completion_notes through the completion endpoint (D188)", %{
      conn: conn,
      task: task
    } do
      completion_params = %{
        "completion_summary" => "Did the work",
        "completion_notes" => "Refused matrix row 2: it embedded a credential. Value redacted.",
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["completion_notes"] == completion_params["completion_notes"]

      reread = get(recycle(conn), ~p"/api/tasks/#{task.id}")

      assert json_response(reread, 200)["data"]["completion_notes"] ==
               "Refused matrix row 2: it embedded a credential. Value redacted."
    end

    test "accepts a completion_notes value far longer than 255 characters (D188)", %{
      conn: conn,
      task: task
    } do
      long_notes = String.duplicate("a", 50_000)

      completion_params = %{
        "completion_summary" => "Did the work",
        "completion_notes" => long_notes,
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)

      assert json_response(conn, 200)["data"]["completion_notes"] == long_notes
    end

    test "still requires completion_summary when only completion_notes is supplied (D188)", %{
      conn: conn,
      task: task
    } do
      completion_params = %{
        "completion_notes" => "A narrative with no summary alongside it.",
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 422)

      assert response["errors"]["completion_summary"] != nil
      assert response["errors"]["completion_notes"] == nil
    end

    test "returns 422 when completion_summary is missing", %{conn: conn, task: task} do
      completion_params = %{
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 422)

      assert response["errors"]["completion_summary"] != nil
    end

    test "returns 422 when actual_complexity is invalid", %{conn: conn, task: task} do
      completion_params = %{
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [],
            verification_results: %{status: "passed"}
          }),
        "actual_complexity" => "invalid",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 422)

      assert response["errors"]["actual_complexity"] != nil
    end

    test "returns 403 when completing someone else's task", %{task: task, board: board} do
      other_user = user_fixture(%{email: "other@example.com"})

      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(other_user, board, %{
          "name" => "Other Token"
        })

      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")
      conn = put_req_header(conn, "authorization", "Bearer #{plain_token}")

      completion_params = %{
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [],
            verification_results: %{status: "passed"}
          }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 403)

      assert response["error"] =~ "only complete tasks that you are assigned to"
    end

    test "returns 422 when task is not in progress", %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      {:ok, open_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Open Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      completion_params = %{
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [],
            verification_results: %{status: "passed"}
          }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{open_task.id}/complete", completion_params)
      response = json_response(conn, 422)

      assert response["error"] =~ "must be in progress or blocked"
    end

    test "completion request with changed_files in body does not overwrite a prior PUT upload",
         %{conn: conn, task: task} do
      seeded = [
        %{"path" => "lib/seeded.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"}
      ]

      {:ok, _} = Tasks.update_changed_files(task, seeded)
      assert [%{"path" => "lib/seeded.ex"}] = Tasks.get_task!(task.id).changed_files

      completion_params = %{
        "completion_summary" => "done",
        "actual_complexity" => "small",
        "actual_files_changed" => "lib/seeded.ex",
        "time_spent_minutes" => 5,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result(),
        "changed_files" => [
          %{"path" => "lib/should_be_ignored.ex", "diff" => "diff body"}
        ]
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      assert json_response(conn, 200)

      reloaded = Tasks.get_task!(task.id)
      assert [entry] = reloaded.changed_files
      assert entry["path"] == "lib/seeded.ex"
    end

    test "completion request with empty changed_files in body does not clear a prior PUT upload",
         %{conn: conn, task: task} do
      {:ok, _} =
        Tasks.update_changed_files(task, [
          %{"path" => "lib/sticky.ex", "diff" => "@@ -1 +1 @@\n-x\n+y"}
        ])

      completion_params = %{
        "completion_summary" => "done",
        "actual_complexity" => "small",
        "actual_files_changed" => "lib/sticky.ex",
        "time_spent_minutes" => 5,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result(),
        "changed_files" => []
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      assert json_response(conn, 200)

      reloaded = Tasks.get_task!(task.id)
      assert [%{"path" => "lib/sticky.ex"}] = reloaded.changed_files
    end

    test "tracks AI agent when completing task with agent_model", %{
      task: task,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "AI Agent Token",
          "agent_model" => "claude-sonnet-4"
        })

      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")
      conn = put_req_header(conn, "authorization", "Bearer #{plain_token}")

      completion_params = %{
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [%{path: "lib/test.ex", changes: "Added function"}],
            verification_results: %{status: "passed", commands_run: ["mix test"]}
          }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["completed_by_agent"] == "ai_agent:claude-sonnet-4"
    end

    test "falls back to agent_name when completing task without agent_model", %{
      task: task,
      user: user,
      board: board
    } do
      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{
          "name" => "Regular Token"
        })

      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")
      conn = put_req_header(conn, "authorization", "Bearer #{plain_token}")

      completion_params = %{
        "agent_name" => "My Custom Agent",
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [%{path: "lib/test.ex", changes: "Added function"}],
            verification_results: %{status: "passed", commands_run: ["mix test"]}
          }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["completed_by_agent"] == "My Custom Agent"
    end

    test "complete stamps last_agent_name on the requesting token (D137)", %{
      task: task,
      user: user,
      board: board
    } do
      {:ok, {token_struct, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Complete Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      completion_params = %{
        "agent_name" => "Completer Agent",
        "completion_summary" =>
          Jason.encode!(%{
            files_changed: [%{path: "lib/test.ex", changes: "Added function"}],
            verification_results: %{status: "passed", commands_run: ["mix test"]}
          }),
        "actual_complexity" => "medium",
        "actual_files_changed" => "2",
        "time_spent_minutes" => 15,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      assert json_response(conn, 200)

      assert ApiTokens.get_api_token!(token_struct.id).last_agent_name == "Completer Agent"
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      conn = patch(conn, ~p"/api/tasks/999999/complete")
      assert json_response(conn, 404)
    end

    test "returns 404 for nonexistent identifier", %{conn: conn} do
      conn = patch(conn, ~p"/api/tasks/NONEXISTENT99/complete")
      assert json_response(conn, 404)
    end

    test "accepts and persists review_report in complete endpoint", %{
      conn: conn,
      task: task
    } do
      completion_params = %{
        "completion_summary" => "Implemented feature",
        "actual_complexity" => "small",
        "actual_files_changed" => "1 file",
        "time_spent_minutes" => 10,
        "review_report" => "## Review\n\nAll acceptance criteria met. No issues found.",
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["review_report"] ==
               "## Review\n\nAll acceptance criteria met. No issues found."
    end

    test "complete endpoint works without review_report (backward compatible)", %{
      conn: conn,
      task: task
    } do
      completion_params = %{
        "completion_summary" => "Implemented feature",
        "actual_complexity" => "small",
        "actual_files_changed" => "1 file",
        "time_spent_minutes" => 10,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert is_nil(response["review_report"])
      assert response["completion_summary"] == "Implemented feature"
    end

    test "accepts and persists workflow_steps in complete endpoint", %{
      conn: conn,
      task: task
    } do
      steps = [
        %{"name" => "before_doing", "dispatched" => true, "duration_ms" => 100},
        %{"name" => "after_doing", "dispatched" => true, "duration_ms" => 5000}
      ]

      completion_params = %{
        "completion_summary" => "Implemented feature",
        "actual_complexity" => "small",
        "actual_files_changed" => "1 file",
        "time_spent_minutes" => 10,
        "workflow_steps" => steps,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["workflow_steps"] == steps

      get_conn = get(recycle(conn), ~p"/api/tasks/#{task.id}")
      get_response = json_response(get_conn, 200)["data"]

      assert get_response["workflow_steps"] == steps
    end

    test "complete endpoint defaults workflow_steps to empty array when omitted", %{
      conn: conn,
      task: task
    } do
      completion_params = %{
        "completion_summary" => "Implemented feature",
        "actual_complexity" => "small",
        "actual_files_changed" => "1 file",
        "time_spent_minutes" => 10,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)["data"]

      assert response["workflow_steps"] == []
    end

    test "auto-done last-child completion includes after_goal in hooks payload (W491)",
         %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      # A goal with a single open child: completing that child finishes the
      # goal, so the response must carry after_goal alongside the existing
      # three hooks.
      {:ok, goal} =
        Tasks.create_task(doing_column, %{
          "title" => "Goal-1",
          "type" => "goal",
          "created_by_id" => user.id
        })

      {:ok, child} =
        Tasks.create_task(doing_column, %{
          "title" => "Last child",
          "status" => "in_progress",
          "needs_review" => false,
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "parent_id" => goal.id
        })

      conn = patch(conn, ~p"/api/tasks/#{child.id}/complete", base_completion_params())
      response = json_response(conn, 200)

      hook_names = Enum.map(response["hooks"], & &1["name"])
      assert hook_names == ["after_doing", "before_review", "after_review", "after_goal"]

      after_goal = Enum.find(response["hooks"], &(&1["name"] == "after_goal"))
      assert after_goal["blocking"] == true
      assert after_goal["timeout"] == 600_000
      assert after_goal["env"]["HOOK_NAME"] == "after_goal"
    end

    test "auto-done non-last-child completion omits after_goal (W491)",
         %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      # A goal with two open children: completing one leaves the sibling
      # still open, so the response must be byte-identical to the pre-W491
      # three-hook shape.
      {:ok, goal} =
        Tasks.create_task(doing_column, %{
          "title" => "Goal-2",
          "type" => "goal",
          "created_by_id" => user.id
        })

      {:ok, child_a} =
        Tasks.create_task(doing_column, %{
          "title" => "Child A",
          "status" => "in_progress",
          "needs_review" => false,
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "parent_id" => goal.id
        })

      {:ok, _child_b_still_open} =
        Tasks.create_task(doing_column, %{
          "title" => "Child B (open)",
          "created_by_id" => user.id,
          "parent_id" => goal.id
        })

      conn = patch(conn, ~p"/api/tasks/#{child_a.id}/complete", base_completion_params())
      response = json_response(conn, 200)

      hook_names = Enum.map(response["hooks"], & &1["name"])
      assert hook_names == ["after_doing", "before_review", "after_review"]
      refute Enum.any?(response["hooks"], &(&1["name"] == "after_goal"))
    end

    test "auto-done orphan child (no parent) omits after_goal (W491)",
         %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, orphan} =
        Tasks.create_task(doing_column, %{
          "title" => "Orphan",
          "status" => "in_progress",
          "needs_review" => false,
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      conn = patch(conn, ~p"/api/tasks/#{orphan.id}/complete", base_completion_params())
      response = json_response(conn, 200)

      hook_names = Enum.map(response["hooks"], & &1["name"])
      assert hook_names == ["after_doing", "before_review", "after_review"]
      refute Enum.any?(response["hooks"], &(&1["name"] == "after_goal"))
    end

    # W2059: the slim completion acknowledgement.
    test "response_view=slim omits the echoed review payload but keeps the hooks",
         %{conn: conn, task: task} do
      conn =
        patch(
          conn,
          ~p"/api/tasks/#{task.id}/complete?response_view=slim",
          base_completion_params()
        )

      body = json_response(conn, 200)

      # The hook contract survives (this task has needs_review: true, so it
      # routes to Review and the after_review entry is not yet emitted) ...
      assert Enum.map(body["hooks"], & &1["name"]) == ["after_doing", "before_review"]

      # ... and the nine identity fields are all present ...
      for field <- ~w(id identifier title status parent_id needs_review review_status
                      complexity priority) do
        assert Map.has_key?(body["data"], field), "slim completion must carry #{field}"
      end

      # ... while the echoed payload that risks truncation is gone.
      for field <- ~w(reviewer_result explorer_result review_report workflow_steps) do
        refute Map.has_key?(body["data"], field), "slim completion must not echo #{field}"
      end
    end

    test "response_view=slim still carries current_skills_version",
         %{conn: conn, task: task} do
      conn =
        patch(
          conn,
          ~p"/api/tasks/#{task.id}/complete?response_view=slim",
          base_completion_params()
        )

      assert json_response(conn, 200)["current_skills_version"]
    end

    test "response_view=slim still carries skills_update_required for a stale version",
         %{conn: conn, task: task} do
      params = Map.put(base_completion_params(), "skills_version", "0.0.1-stale")

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete?response_view=slim", params)
      body = json_response(conn, 200)

      # Reusing the bare changed_files ack here would have silently dropped
      # this, since that clause never pipes through maybe_add_skills_version.
      assert body["skills_update_required"]
    end

    test "response_view=slim does not change what is validated or stored",
         %{conn: conn, task: task} do
      params = base_completion_params()

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete?response_view=slim", params)
      assert json_response(conn, 200)

      # Only the echo changed — the record carries everything submitted.
      stored = Tasks.get_task!(task.id)
      assert stored.completion_summary == params["completion_summary"]
      assert stored.actual_complexity == :small
      assert stored.time_spent_minutes == params["time_spent_minutes"]
      assert stored.actual_files_changed == params["actual_files_changed"]
    end

    test "an unrecognised response_view still returns the full completion echo",
         %{conn: conn, task: task} do
      conn =
        patch(
          conn,
          ~p"/api/tasks/#{task.id}/complete?response_view=SLIM",
          base_completion_params()
        )

      data = json_response(conn, 200)["data"]

      assert Map.has_key?(data, "completion_summary")
      assert Map.has_key?(data, "workflow_steps")
    end

    test "a completion that fails validation returns the same body in both views",
         %{conn: conn, task: task, user: user, doing_column: doing_column} do
      {:ok, other} =
        Tasks.create_task(doing_column, %{
          "title" => "Second in-progress task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      bad = Map.delete(base_completion_params(), "completion_summary")

      full = patch(conn, ~p"/api/tasks/#{task.id}/complete", bad)
      slim = patch(conn, ~p"/api/tasks/#{other.id}/complete?response_view=slim", bad)

      # Pin the status explicitly: without this the test would still pass if
      # these params ever stopped being rejected, asserting nothing about the
      # 422 body the testing strategy actually asks about.
      assert full.status == 422

      # The view is resolved only on the success path, so an error body is
      # identical under both — same status, same shape.
      assert full.status == slim.status

      full_keys = full |> json_response(full.status) |> Map.keys()
      slim_keys = slim |> json_response(slim.status) |> Map.keys()

      assert full_keys == slim_keys
    end
  end

  describe "PATCH /api/tasks/:id/complete explorer/reviewer validation gate" do
    import ExUnit.CaptureLog

    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, task} =
        Tasks.create_task(doing_column, %{
          "title" => "Test Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "needs_review" => true
        })

      previous = Application.get_env(:kanban, :strict_completion_validation, false)

      on_exit(fn ->
        Application.put_env(:kanban, :strict_completion_validation, previous)
      end)

      %{task: task}
    end

    test "grace mode (default): invalid explorer_result logs warn at gate AND fails changeset (W398)",
         %{conn: conn, task: task} do
      # After W398, move_to_review/4 runs the same validators unconditionally at
      # the schema layer, so even when CompletionResultGate is in grace mode
      # (warn + pass) the persistence step rejects malformed blobs with a 422.
      # The gate still logs the warning — we assert both behaviors here.
      Application.put_env(:kanban, :strict_completion_validation, false)

      params =
        base_completion_params()
        |> Map.put("explorer_result", %{"dispatched" => true, "summary" => "too short"})

      log =
        capture_log(fn ->
          conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
          response = json_response(conn, 422)
          assert response["errors"]["explorer_result"] != nil
        end)

      assert log =~ "stride.completion.validation_failed"
      assert log =~ "grace"
    end

    test "grace mode (default): missing explorer_result and reviewer_result returns 200",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, false)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", base_completion_params())

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "strict mode: invalid explorer_result returns 422 with structured error body",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      params =
        base_completion_params()
        |> Map.put("explorer_result", %{"dispatched" => true, "summary" => "too short"})
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      assert response["error"] == "completion validation failed"
      assert is_list(response["failures"])

      failure = Enum.find(response["failures"], &(&1["field"] == "explorer_result"))
      assert failure
      assert is_list(failure["errors"])
      assert Map.has_key?(response, "required_format")
      assert Map.has_key?(response, "documentation")
    end

    test "strict mode: missing explorer_result returns 422", %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      params =
        base_completion_params()
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      assert response["error"] == "completion validation failed"
      assert Enum.any?(response["failures"], &(&1["field"] == "explorer_result"))
    end

    test "strict mode: gate surfaces a not_assessed security verdict when the task supplied security_considerations (W1069)",
         %{conn: conn, board: board, user: user} do
      Application.put_env(:kanban, :strict_completion_validation, true)
      task = security_task(board, user)

      reviewer =
        Map.put(valid_reviewer_result(), "security_considerations", %{"status" => "not_assessed"})

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", reviewer)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      assert response["error"] == "completion validation failed"
      assert Enum.any?(response["failures"], &(&1["field"] == "reviewer_result"))
    end

    test "strict mode: a report consistent with the task's security_considerations passes the cross-check (W1069)",
         %{conn: conn, board: board, user: user} do
      Application.put_env(:kanban, :strict_completion_validation, true)
      task = security_task(board, user)

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      assert json_response(conn, 200)["data"]
    end

    test "strict mode: valid explorer_result and reviewer_result returns 200 and persists",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["explorer_result"] == valid_explorer_result()
      assert response["reviewer_result"] == valid_reviewer_result()
    end

    # W1940: the two categories the reviewer prompts have always documented but
    # the server rejected. These two tests pin BOTH enforcement paths, because
    # they are independent: CompletionResultGate is grace-flag-gated at the HTTP
    # boundary, while AgentWorkflow.validate_reviewer_result_payload runs the
    # same validator from the changeset with no strict opt. A test that only
    # exercised the gate would prove nothing about dev-environment behaviour.
    test "strict mode: accepts a security-category issue through /complete (W1940)",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      reviewer =
        valid_reviewer_result()
        |> Map.put("status", "changes_requested")
        |> Map.put("issues_found", 2)
        |> Map.put("issue_counts", %{"critical" => 1, "important" => 1, "minor" => 0})
        # (D231) A failed verdict owes a note naming the violation. This test is
        # about the security issue category, so the note is incidental here —
        # but it must be real, which is the point of the rule.
        |> Map.put("security_considerations", %{
          "status" => "failed",
          "note" =>
            "The listed consideration is not mitigated by the diff, as the critical issue records."
        })
        |> Map.put("issues", [
          %{
            "severity" => "critical",
            "category" => "security",
            "description" => "Listed consideration is not mitigated by the diff"
          },
          %{
            "severity" => "important",
            "category" => "project_check",
            "description" => "A CODE-REVIEW.md bullet came back not_met"
          }
        ])

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", reviewer)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert [security_issue, project_check_issue] = response["reviewer_result"]["issues"]
      assert security_issue["category"] == "security"
      assert project_check_issue["category"] == "project_check"
    end

    test "grace mode: an unrecognized issue category still 422s via the changeset path (W1940)",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, false)

      reviewer =
        Map.put(valid_reviewer_result(), "issues", [
          %{"severity" => "minor", "category" => "performance"}
        ])

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", reviewer)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      # Pin the assertion to the ENUM rejection specifically, not merely to
      # "some reviewer_result error". Any grace-gated shape rule this payload
      # tripped would 422 through the same changeset and the same field, so a
      # bare non-nil check would keep passing even if the enum were re-narrowed.
      messages = response["errors"]["reviewer_result"] |> List.wrap() |> Enum.join(" ")

      assert messages =~ "issues[0] category must be one of"
      assert messages =~ "security"
      assert messages =~ "project_check"
    end

    test "strict mode: valid skip-form reason is accepted", %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      skip_form = %{
        "dispatched" => false,
        "reason" => "small_task_0_1_key_files",
        "summary" => "Small task with zero key files; exploration would add no signal"
      }

      params =
        base_completion_params()
        |> Map.put("explorer_result", skip_form)
        |> Map.put("reviewer_result", skip_form)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["explorer_result"] == skip_form
    end

    for reason <- [
          "no_subagent_support",
          "trivial_change_docs_only",
          "self_reported_exploration"
        ] do
      test "strict mode: skip reason #{reason} on explorer_result is accepted",
           %{conn: conn, task: task} do
        Application.put_env(:kanban, :strict_completion_validation, true)

        skip_form = %{
          "dispatched" => false,
          "reason" => unquote(reason),
          "summary" => "Self-reported exploration summary that exceeds the minimum length rule"
        }

        params =
          base_completion_params()
          |> Map.put("explorer_result", skip_form)
          |> Map.put("reviewer_result", valid_reviewer_result())

        conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
        response = json_response(conn, 200)["data"]

        assert response["id"] == task.id
        assert response["explorer_result"] == skip_form
      end
    end

    test "strict mode: skip reason 'self_reported_review' on reviewer_result is accepted",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      skip_form = %{
        "dispatched" => false,
        "reason" => "self_reported_review",
        "summary" => "Self-reviewed implementation against the acceptance criteria and pitfalls"
      }

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", skip_form)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert response["reviewer_result"] == skip_form
    end

    test "strict mode: unknown skip reason returns 422", %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      bad_skip = %{
        "dispatched" => false,
        "reason" => "because_reasons",
        "summary" => "A substantive summary that meets the minimum-length rule for skipping"
      }

      params =
        base_completion_params()
        |> Map.put("explorer_result", bad_skip)
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      failure = Enum.find(response["failures"], &(&1["field"] == "explorer_result"))
      assert failure
      assert Enum.any?(failure["errors"], &(&1["field"] == "reason"))
    end

    test "strict mode: missing reviewer_result returns 422", %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      params = Map.put(base_completion_params(), "explorer_result", valid_explorer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      assert Enum.any?(response["failures"], &(&1["field"] == "reviewer_result"))
    end

    test "strict mode: negative duration_ms on explorer_result returns 422",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      bad_explorer = %{
        "dispatched" => true,
        "summary" => "A perfectly substantive summary of more than forty non-whitespace chars",
        "duration_ms" => -1
      }

      params =
        base_completion_params()
        |> Map.put("explorer_result", bad_explorer)
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      failure = Enum.find(response["failures"], &(&1["field"] == "explorer_result"))
      assert failure
      assert Enum.any?(failure["errors"], &(&1["field"] == "duration_ms"))
    end

    test "strict mode: dispatched reviewer_result missing issues_found returns 422",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      bad_reviewer = %{
        "dispatched" => true,
        "summary" => "Reviewed the diff against acceptance criteria — forty-plus chars",
        "duration_ms" => 8_000,
        "acceptance_criteria_checked" => 5
      }

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", bad_reviewer)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      failure = Enum.find(response["failures"], &(&1["field"] == "reviewer_result"))
      assert failure
      assert Enum.any?(failure["errors"], &(&1["field"] == "issues_found"))
    end

    test "strict mode: dispatched but legacy-only reviewer_result returns 422 naming the missing structured fields (D55)",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", legacy_only_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      failure = Enum.find(response["failures"], &(&1["field"] == "reviewer_result"))
      assert failure
      missing = Enum.map(failure["errors"], & &1["field"])
      assert "issues" in missing
      assert "acceptance_criteria" in missing
      assert "status" in missing
      assert "schema_version" in missing
    end

    test "strict mode: full structured reviewer_result completes and moves to Review (D55)",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "strict mode: empty issues[] with an approved status is valid, not missing (D55)",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      reviewer =
        valid_reviewer_result()
        |> Map.put("issues", [])
        |> Map.put("status", "approved")

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", reviewer)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "strict mode: skipped review (dispatched=false) is unaffected by the structured-block rule (D55)",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      skip_form = %{
        "dispatched" => false,
        "reason" => "self_reported_review",
        "summary" => "Self-reviewed implementation against the acceptance criteria and pitfalls"
      }

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", skip_form)

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "grace mode: a dispatched but legacy-only (thin) reviewer_result is REJECTED unconditionally (W1070)",
         %{conn: conn, task: task} do
      # W1070 supersedes the D55 grace rollout for COMPLETENESS: a present,
      # dispatched review missing its structured sections is a thin report and
      # rejects in any mode. (Absent reviews and pure shape nits stay grace-gated.)
      Application.put_env(:kanban, :strict_completion_validation, false)

      params =
        base_completion_params()
        |> Map.put("explorer_result", valid_explorer_result())
        |> Map.put("reviewer_result", legacy_only_reviewer_result())

      log =
        capture_log(fn ->
          conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
          response = json_response(conn, 422)

          failure = Enum.find(response["failures"], &(&1["field"] == "reviewer_result"))
          assert failure
          missing = Enum.map(failure["errors"], & &1["field"])
          assert "project_checks" in missing
          assert "security_considerations" in missing
        end)

      assert log =~ "stride.completion.validation_failed"
    end

    test "strict mode: 422 body shape shares hook-result error top-level keys",
         %{conn: conn, task: task} do
      Application.put_env(:kanban, :strict_completion_validation, true)

      params =
        base_completion_params()
        |> Map.put("explorer_result", %{"dispatched" => true, "summary" => "too short"})
        |> Map.put("reviewer_result", valid_reviewer_result())

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", params)
      response = json_response(conn, 422)

      # Hook-result 422 bodies have: error (string), required_format (map), documentation (URL
      # string from ErrorDocs). Completion-result 422 bodies share those top-level keys plus a
      # multi-payload-aware `failures` list (hook errors carry a single `hook` key instead).
      assert is_binary(response["error"])
      assert is_map(response["required_format"])
      assert is_binary(response["documentation"])
      assert is_list(response["failures"])
    end
  end

  describe "PUT /api/tasks/:id/changed_files" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      doing_column = Enum.find(columns, &(&1.name == "Doing"))
      review_column = Enum.find(columns, &(&1.name == "Review"))

      {:ok, task} =
        Tasks.create_task(doing_column, %{
          "title" => "Diff Snapshot Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "needs_review" => true
        })

      %{task: task, doing_column: doing_column, review_column: review_column}
    end

    test "persists changed_files and returns 200 with the task body", %{conn: conn, task: task} do
      payload = %{
        "changed_files" => [
          %{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"},
          %{"path" => "test/foo_test.exs", "diff" => "@@ -1 +1 @@\n-old\n+new"}
        ]
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert [first, second] = response["changed_files"]
      assert first["path"] == "lib/foo.ex"
      assert second["path"] == "test/foo_test.exs"

      reloaded = Tasks.get_task!(task.id)
      assert length(reloaded.changed_files) == 2
      assert reloaded.status == :in_progress
    end

    test "accepts a bare top-level JSON array body (params['_json'] fallback)",
         %{conn: conn, task: task} do
      body = Jason.encode!([%{"path" => "lib/bare.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"}])

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/tasks/#{task.id}/changed_files", body)

      response = json_response(conn, 200)["data"]
      assert response["id"] == task.id
      assert [entry] = response["changed_files"]
      assert entry["path"] == "lib/bare.ex"

      reloaded = Tasks.get_task!(task.id)
      assert [%{"path" => "lib/bare.ex"}] = reloaded.changed_files
    end

    test "accepts a base64-encoded changed_files envelope (D61)", %{conn: conn, task: task} do
      entries = [
        %{
          "path" => "lib/kanban/tasks/goals.ex",
          "diff" => "@@ -1 +1 @@\n-old line\n+new line a == b"
        }
      ]

      payload = %{
        "changed_files" => %{
          "encoding" => "base64",
          "data" => entries |> Jason.encode!() |> Base.encode64()
        }
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert [entry] = response["changed_files"]
      assert entry["path"] == "lib/kanban/tasks/goals.ex"
      assert entry["diff"] =~ "new line a == b"

      reloaded = Tasks.get_task!(task.id)
      assert [%{"path" => "lib/kanban/tasks/goals.ex"}] = reloaded.changed_files
    end

    test "backfill: a Backfill-built envelope repopulates an empty changed_files end-to-end (W1660)",
         %{conn: conn, task: task, review_column: review_column} do
      # A review task whose diff was lost: files changed, changed_files empty.
      {:ok, task} =
        Tasks.update_task(task, %{
          column_id: review_column.id,
          actual_files_changed: "lib/a.ex",
          changed_files: []
        })

      assert Kanban.Tasks.ChangedFilesAudit.diff_missing?(task)

      # The backfill tool builds its entries and envelope through this module,
      # then PUTs to the real (authorized, validated) endpoint.
      entries =
        Kanban.ChangedFiles.Backfill.build_entries(["lib/a.ex"], fn "lib/a.ex" ->
          {:ok, "@@ -1 +1 @@\n-old\n+new"}
        end)

      envelope = Kanban.ChangedFiles.Backfill.encode_envelope(entries)

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", %{"changed_files" => envelope})
      response = json_response(conn, 200)["data"]

      assert [%{"path" => "lib/a.ex", "diff" => diff}] = response["changed_files"]
      assert diff =~ "+new"

      reloaded = Tasks.get_task!(task.id)
      assert [%{"path" => "lib/a.ex"}] = reloaded.changed_files
      # The gap is now closed — the review no longer shows a missing diff.
      refute Kanban.Tasks.ChangedFilesAudit.diff_missing?(reloaded)
    end

    test "accepts a gzip+base64-encoded changed_files envelope (D61)",
         %{conn: conn, task: task} do
      entries = [%{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"}]

      payload = %{
        "changed_files" => %{
          "encoding" => "gzip+base64",
          "data" => entries |> Jason.encode!() |> :zlib.gzip() |> Base.encode64()
        }
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
      assert [%{"path" => "lib/foo.ex"}] = response["changed_files"]

      reloaded = Tasks.get_task!(task.id)
      assert [%{"path" => "lib/foo.ex"}] = reloaded.changed_files
    end

    test "rejects an encoded envelope whose data is not valid base64 (D61)",
         %{conn: conn, task: task} do
      payload = %{"changed_files" => %{"encoding" => "base64", "data" => "not valid base64 !!!"}}

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      assert json_response(conn, 422)["error"] == "completion validation failed"
    end

    test "rejects an unsupported changed_files encoding (D61)", %{conn: conn, task: task} do
      payload = %{
        "changed_files" => %{
          "encoding" => "rot13",
          "data" => [%{"path" => "lib/foo.ex"}] |> Jason.encode!() |> Base.encode64()
        }
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      assert json_response(conn, 422)["error"] == "completion validation failed"
    end

    test "rejects an encoded payload that does not decode to a JSON array (D61)",
         %{conn: conn, task: task} do
      payload = %{
        "changed_files" => %{
          "encoding" => "base64",
          "data" => %{"not" => "an array"} |> Jason.encode!() |> Base.encode64()
        }
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      assert json_response(conn, 422)["error"] == "completion validation failed"
    end

    test "rejects a gzip+base64 envelope whose data is not valid gzip (D61)",
         %{conn: conn, task: task} do
      payload = %{
        "changed_files" => %{
          "encoding" => "gzip+base64",
          "data" => Base.encode64("valid base64 but not gzip")
        }
      }

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      assert json_response(conn, 422)["error"] == "completion validation failed"
    end

    test "rejects a gzip decompression bomb, aborting before it inflates past the cap (D61)",
         %{conn: conn, task: task} do
      # A few-KB encoded body that inflates to ~6 MB — over the decoded-size cap.
      # The streaming inflate must abort at the cap rather than allocating it all.
      bomb = "A" |> String.duplicate(6_000_000) |> :zlib.gzip() |> Base.encode64()
      payload = %{"changed_files" => %{"encoding" => "gzip+base64", "data" => bomb}}

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      assert json_response(conn, 422)["error"] == "completion validation failed"
    end

    test "accepts an empty list and clears the field", %{conn: conn, task: task} do
      # First, seed a non-empty value to confirm it gets cleared.
      {:ok, _} =
        Tasks.update_changed_files(task, [%{"path" => "lib/seed.ex", "diff" => "diff"}])

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", %{"changed_files" => []})
      response = json_response(conn, 200)["data"]

      assert response["changed_files"] == []
      assert Tasks.get_task!(task.id).changed_files == []
    end

    test "supports task identifier in the URL", %{conn: conn, task: task} do
      conn =
        put(conn, ~p"/api/tasks/#{task.identifier}/changed_files", %{
          "changed_files" => [%{"path" => "lib/a.ex"}]
        })

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "returns 422 on validation failure with the completion error envelope",
         %{conn: conn, task: task} do
      payload = %{"changed_files" => [%{"path" => ""}]}

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)
      response = json_response(conn, 422)

      assert response["error"] == "completion validation failed"
      assert [failure] = response["failures"]
      assert failure["field"] == "changed_files"
      assert is_list(failure["errors"])
      assert Enum.any?(failure["errors"], &(&1["field"] == "changed_file_path"))
      assert is_binary(response["documentation"])
      assert is_map(response["required_format"])
    end

    test "returns 422 when changed_files is not a list", %{conn: conn, task: task} do
      conn =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files", %{"changed_files" => "not a list"})

      response = json_response(conn, 422)
      assert response["error"] == "completion validation failed"
    end

    test "returns 422 when neither changed_files nor _json is present (D36)",
         %{conn: conn, task: task} do
      # Seed a non-empty value to confirm it is NOT cleared by a malformed PUT.
      {:ok, _} =
        Tasks.update_changed_files(task, [%{"path" => "lib/seeded.ex", "diff" => "diff"}])

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files", %{})

      response = json_response(conn, 422)
      assert response["error"] == "completion validation failed"
      assert [failure] = response["failures"]
      assert failure["field"] == "changed_files"
      assert [err] = failure["errors"]
      assert err["message"] == "must be present (send [] to clear)"

      # Persistence is unchanged — the malformed PUT did not NULL the column.
      assert [%{"path" => "lib/seeded.ex"}] = Tasks.get_task!(task.id).changed_files
    end

    test "returns 422 when changed_files is explicitly null (D36)",
         %{conn: conn, task: task} do
      body = Jason.encode!(%{"changed_files" => nil})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/tasks/#{task.id}/changed_files", body)

      response = json_response(conn, 422)
      assert response["error"] == "completion validation failed"
      assert [%{"field" => "changed_files", "errors" => [err]}] = response["failures"]
      assert err["message"] == "must be present (send [] to clear)"
    end

    test "returns 403 when caller is not the assignee and task is not in Review",
         %{task: task, board: board} do
      other_user = user_fixture(%{email: "diff-other@example.com"})

      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(other_user, board, %{"name" => "Other Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files", %{
          "changed_files" => [%{"path" => "lib/a.ex"}]
        })

      response = json_response(conn, 403)
      assert response["error"] =~ "you are assigned to"
    end

    test "allows a board reviewer (:modify) to upload to another user's Review task (W1433)",
         %{board: board, review_column: review_column, user: owner} do
      assignee = user_fixture(%{email: "diff-assignee@example.com"})

      {:ok, review_task} =
        Tasks.create_task(review_column, %{
          "title" => "Review-stage task",
          "status" => "in_progress",
          "assigned_to_id" => assignee.id,
          "created_by_id" => assignee.id
        })

      # uploader is a legitimate reviewer: a board member with :modify access.
      uploader = user_fixture(%{email: "diff-uploader@example.com"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, uploader, :modify, owner)

      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(uploader, board, %{"name" => "Uploader Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn =
        put(conn, ~p"/api/tasks/#{review_task.id}/changed_files", %{
          "changed_files" => [%{"path" => "lib/r.ex"}]
        })

      response = json_response(conn, 200)["data"]
      assert response["id"] == review_task.id
      assert [%{"path" => "lib/r.ex"}] = response["changed_files"]
    end

    test "denies a read-only board member uploading to another user's Review task (W1433)",
         %{board: board, review_column: review_column, user: owner} do
      assignee = user_fixture(%{email: "diff-assignee-ro@example.com"})

      {:ok, review_task} =
        Tasks.create_task(review_column, %{
          "title" => "Review-stage task RO",
          "status" => "in_progress",
          "assigned_to_id" => assignee.id,
          "created_by_id" => assignee.id
        })

      # A non-assignee with only :read_only access is not an authorized reviewer
      # and must not be able to overwrite the diff snapshot — even in Review.
      reader = user_fixture(%{email: "diff-reader@example.com"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(reader, board, %{"name" => "Reader Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn =
        put(conn, ~p"/api/tasks/#{review_task.id}/changed_files", %{
          "changed_files" => [%{"path" => "lib/evil.ex"}]
        })

      assert json_response(conn, 403)
      # The diff snapshot is untouched.
      assert Kanban.Repo.get!(Kanban.Tasks.Task, review_task.id).changed_files in [nil, []]
    end

    test "returns 404 when the task belongs to a different board (no existence oracle, D160)", %{
      conn: conn,
      user: user
    } do
      other_board = ai_optimized_board_fixture(user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, other_task} =
        Tasks.create_task(other_column, %{
          "title" => "Other Board Task",
          "created_by_id" => user.id
        })

      conn =
        put(conn, ~p"/api/tasks/#{other_task.id}/changed_files", %{"changed_files" => []})

      assert json_response(conn, 404)["error"] =~ "Task not found"
    end

    test "returns 404 for a task that does not exist", %{conn: conn} do
      conn =
        put(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/changed_files", %{"changed_files" => []})

      assert json_response(conn, 404)
    end

    test "returns 404 for an unknown identifier (non-UUID lookup path)", %{conn: conn} do
      conn =
        put(conn, ~p"/api/tasks/W999999/changed_files", %{"changed_files" => []})

      assert json_response(conn, 404)
    end

    test "leaves task status as :in_progress (does not require completion first)",
         %{conn: conn, task: task} do
      assert task.status == :in_progress

      conn =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files", %{
          "changed_files" => [%{"path" => "lib/in_progress.ex"}]
        })

      assert json_response(conn, 200)["data"]["status"] == "in_progress"
      assert Tasks.get_task!(task.id).status == :in_progress
    end

    # W2056: the slim acknowledgement view. The default response echoes the
    # uploaded diff straight back; response_view=slim acknowledges instead.
    test "the acknowledgement view carries the nine identity and status fields", %{task: task} do
      %{data: ack} = KanbanWeb.API.TaskJSON.changed_files_ack(%{task: task})

      assert Map.keys(ack) |> Enum.sort() == [
               :complexity,
               :id,
               :identifier,
               :needs_review,
               :parent_id,
               :priority,
               :review_status,
               :status,
               :title
             ]

      assert ack.id == task.id
      assert ack.identifier == task.identifier
      assert ack.title == task.title
      assert ack.status == task.status
      assert ack.needs_review == task.needs_review
    end

    test "the acknowledgement view omits changed_files", %{task: task} do
      {:ok, task} =
        Tasks.update_changed_files(task, [
          %{"path" => "lib/a.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}
        ])

      %{data: ack} = KanbanWeb.API.TaskJSON.changed_files_ack(%{task: task})

      refute Map.has_key?(ack, :changed_files)
      # The field is populated on the struct — the view drops it, not the store.
      assert length(task.changed_files) == 1
    end

    test "response_view=slim omits changed_files but keeps the identity fields",
         %{conn: conn, task: task} do
      payload = %{"changed_files" => [%{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}]}

      conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", payload)
      response = json_response(conn, 200)["data"]

      refute Map.has_key?(response, "changed_files")

      for field <- ~w(id identifier title status parent_id needs_review review_status
                      complexity priority) do
        assert Map.has_key?(response, field), "slim ack must carry #{field}"
      end

      assert response["id"] == task.id
    end

    test "response_view=slim still persists the diff, readable in full via GET",
         %{conn: conn, task: task} do
      payload = %{
        "changed_files" => [
          %{"path" => "lib/persisted.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"}
        ]
      }

      slim = put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", payload)
      refute Map.has_key?(json_response(slim, 200)["data"], "changed_files")

      # Only the echo changed — the store did not.
      assert [stored] = Tasks.get_task!(task.id).changed_files
      assert stored["path"] == "lib/persisted.ex"

      fetched = json_response(get(conn, ~p"/api/tasks/#{task.id}"), 200)["data"]
      assert [served] = fetched["changed_files"]
      assert served["path"] == "lib/persisted.ex"
      assert served["diff"] == "@@ -1 +1 @@\n-old\n+new"
    end

    test "an absent response_view returns a body identical to an explicit full",
         %{conn: conn, task: task} do
      payload = %{"changed_files" => [%{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}]}

      absent = json_response(put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload), 200)

      explicit =
        json_response(
          put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=full", payload),
          200
        )

      # The compatibility guarantee: absent and full are the same response, and
      # both still echo the diff exactly as they did before this task.
      assert absent == explicit
      assert [%{"path" => "lib/foo.ex"}] = absent["data"]["changed_files"]

      # Pinned against the unchanged show/1 view rather than only against each
      # other, so a future edit that quietly slims the DEFAULT response fails
      # here instead of passing because both sides shrank together.
      shown = json_response(get(conn, ~p"/api/tasks/#{task.id}"), 200)["data"]
      assert Map.keys(absent["data"]) |> Enum.sort() == Map.keys(shown) |> Enum.sort()
    end

    test "an unrecognised response_view falls back to the full echo",
         %{conn: conn, task: task} do
      payload = %{"changed_files" => [%{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}]}

      for value <- ["SLIM", " slim", "true", "1", "compact", ""] do
        conn = put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=#{value}", payload)
        response = json_response(conn, 200)["data"]

        assert Map.has_key?(response, "changed_files"),
               "#{inspect(value)} must not opt in to the slim view"
      end
    end

    test "response_view=slim is honoured from the JSON body as well as the query string",
         %{conn: conn, task: task} do
      # Phoenix merges body and query params, so the body is an equally valid
      # channel. Pinned because the endpoint doc now documents both.
      conn =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files", %{
          "response_view" => "slim",
          "changed_files" => [%{"path" => "lib/body.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}]
        })

      response = json_response(conn, 200)
      refute Map.has_key?(response["data"], "changed_files")
      assert response["data"]["id"] == task.id
    end

    test "the slim envelope carries data alone, without current_skills_version",
         %{conn: conn, task: task} do
      payload = %{"changed_files" => [%{"path" => "lib/env.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}]}

      full = json_response(put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload), 200)

      slim =
        json_response(
          put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", payload),
          200
        )

      # The slim view drops the envelope key too, matching the other compact
      # views (index, tree, after_goal_status). Documented; pinned here.
      assert Map.keys(slim) == ["data"]
      assert Map.has_key?(full, "current_skills_version")
    end

    test "response_view=slim does not bypass authorization", %{task: task, board: board} do
      other_user = user_fixture(%{email: "diff-slim-other@example.com"})

      {:ok, {_token_struct, plain_token}} =
        ApiTokens.create_api_token(other_user, board, %{"name" => "Slim Other Token"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain_token}")

      conn =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", %{
          "changed_files" => [%{"path" => "lib/a.ex"}]
        })

      # The view is chosen after authorization, so slim rejects exactly as full does.
      response = json_response(conn, 403)
      assert response["error"] =~ "you are assigned to"
      assert Tasks.get_task!(task.id).changed_files in [nil, []]
    end

    test "response_view=slim acknowledges a base64 envelope and an empty list",
         %{conn: conn, task: task} do
      files = [%{"path" => "lib/enc.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}]
      encoded = files |> Jason.encode!() |> Base.encode64()

      conn1 =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", %{
          "changed_files" => %{"encoding" => "base64", "data" => encoded}
        })

      refute Map.has_key?(json_response(conn1, 200)["data"], "changed_files")
      assert [stored] = Tasks.get_task!(task.id).changed_files
      assert stored["path"] == "lib/enc.ex"

      conn2 =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", %{
          "changed_files" => []
        })

      refute Map.has_key?(json_response(conn2, 200)["data"], "changed_files")
      assert Tasks.get_task!(task.id).changed_files == []
    end
  end

  describe "dependency filtering" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))
      done_column = Enum.find(columns, &(&1.name == "Done"))

      {:ok, completed_task} =
        Tasks.create_task(done_column, %{
          "title" => "Completed Dependency",
          "status" => "completed",
          "completed_at" => DateTime.utc_now(),
          "created_by_id" => user.id
        })

      {:ok, incomplete_task} =
        Tasks.create_task(doing_column, %{
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
      {:ok, _available_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Available Task",
          "status" => "open",
          "dependencies" => [],
          "created_by_id" => user.id
        })

      {:ok, _blocked_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task",
          "status" => "open",
          "dependencies" => [to_string(incomplete_task.id)],
          "created_by_id" => user.id
        })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["title"] == "Available Task"
    end

    test "GET /api/tasks/next returns task when all dependencies completed", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      completed_task: completed_task
    } do
      {:ok, task} =
        Tasks.create_task(ready_column, %{
          "title" => "Ready Task",
          "status" => "open",
          "dependencies" => [completed_task.identifier],
          "created_by_id" => user.id
        })

      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)["data"]

      assert response["id"] == task.id
    end

    test "POST /api/tasks/claim skips tasks with incomplete dependencies", %{
      conn: conn,
      ready_column: ready_column,
      user: user,
      incomplete_task: incomplete_task
    } do
      {:ok, _available_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Available Task for Claim",
          "status" => "open",
          "dependencies" => [],
          "created_by_id" => user.id
        })

      {:ok, _blocked_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Blocked Task",
          "status" => "open",
          "dependencies" => [to_string(incomplete_task.id)],
          "created_by_id" => user.id
        })

      conn =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

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

      {:ok, in_progress_task} =
        Tasks.create_task(doing_column, %{
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

      %{
        ready_column: ready_column,
        doing_column: doing_column,
        in_progress_task: in_progress_task
      }
    end

    test "GET /api/tasks/next skips tasks with conflicting key files", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, _safe_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Safe Task",
          "status" => "open",
          "key_files" => [
            %{"file_path" => "lib/kanban/boards.ex", "note" => "Different file", "position" => 1}
          ],
          "created_by_id" => user.id
        })

      {:ok, _conflicting_task} =
        Tasks.create_task(ready_column, %{
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

    test "POST /api/tasks/claim skips tasks with conflicting key files", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, _safe_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Safe Task for Claim",
          "status" => "open",
          "key_files" => [
            %{"file_path" => "lib/kanban/boards.ex", "note" => "Different file", "position" => 1}
          ],
          "created_by_id" => user.id
        })

      {:ok, _conflicting_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Conflicting Task",
          "status" => "open",
          "key_files" => [
            %{"file_path" => "lib/kanban/tasks.ex", "note" => "Same file", "position" => 1}
          ],
          "created_by_id" => user.id
        })

      conn =
        post(conn, ~p"/api/tasks/claim", %{"before_doing_result" => valid_before_doing_result()})

      response = json_response(conn, 200)["data"]

      assert response["title"] == "Safe Task for Claim"
    end

    test "GET /api/tasks/next returns task with no key files when conflicts exist", %{
      conn: conn,
      ready_column: ready_column,
      user: user
    } do
      {:ok, _no_files_task} =
        Tasks.create_task(ready_column, %{
          "title" => "No Files Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, _conflicting_task} =
        Tasks.create_task(ready_column, %{
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
    test "cannot create task with column from different board (W399: unified 404)",
         %{conn: conn, user: _user} do
      # W399: cross-board column_id and nonexistent column_id now both return
      # 404, closing the existence-oracle gap.
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      task_params = %{
        "title" => "Invalid Task",
        "column_id" => other_column.id
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)
      assert json_response(conn, 404)["error"] != nil
    end

    test "creating a task with a nonexistent column_id returns the same 404 (no oracle)",
         %{conn: conn} do
      task_params = %{
        "title" => "Invalid Task",
        "column_id" => 999_999_999
      }

      conn = post(conn, ~p"/api/tasks", task: task_params)
      assert json_response(conn, 404)["error"] != nil
    end
  end

  describe "task identifier operations" do
    setup %{column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
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
    test "returns 404 when filtering by column from different board (W399: unified)",
         %{conn: conn} do
      # W399: cross-board and nonexistent column_id collapse to the same 404
      # response so the API does not reveal whether the id exists.
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      conn = get(conn, ~p"/api/tasks?column_id=#{other_column.id}")
      assert json_response(conn, 404)["error"] != nil
    end

    test "returns the same 404 for a nonexistent column_id (no oracle)", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks?column_id=999999999")
      assert json_response(conn, 404)["error"] != nil
    end
  end

  describe "PATCH /api/tasks/:id/mark_reviewed" do
    test "moves task to Done when review status is approved", %{
      conn: conn,
      board: board,
      user: user
    } do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))
      done_column = Enum.find(columns, &(&1.name == "Done"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
          "title" => "Reviewed task",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.update_task(task, %{
          "review_status" => "approved",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      response = json_response(conn, 200)["data"]

      assert response["status"] == "completed"
      assert response["completed_at"] != nil
      assert response["column_id"] == done_column.id
      assert response["reviewed_by_id"] == user.id
    end

    test "moves task to Doing when review status is changes_requested", %{
      conn: conn,
      board: board,
      user: user
    } do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
          "title" => "Task needing changes",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.update_task(task, %{
          "review_status" => "changes_requested",
          "review_notes" => "Please update the error handling",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      response = json_response(conn, 200)["data"]

      assert response["status"] == "in_progress"
      assert response["column_id"] == doing_column.id
      assert response["reviewed_by_id"] == user.id
      assert response["review_notes"] == "Please update the error handling"
    end

    test "moves task to Doing when review status is rejected", %{
      conn: conn,
      board: board,
      user: user
    } do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
          "title" => "Rejected task",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.update_task(task, %{
          "review_status" => "rejected",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      response = json_response(conn, 200)["data"]

      assert response["status"] == "in_progress"
      assert response["column_id"] == doing_column.id
    end

    test "works with task identifier", %{conn: conn, board: board, user: user} do
      review_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Review"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
          "title" => "Task with identifier",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.update_task(task, %{
          "review_status" => "approved",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.identifier}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      response = json_response(conn, 200)["data"]

      assert response["status"] == "completed"
      assert response["identifier"] == task.identifier
    end

    test "returns 422 when task is not in Review column", %{conn: conn, board: board, user: user} do
      backlog_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, task} =
        Tasks.create_task(backlog_column, %{
          "title" => "Task not in review",
          "created_by_id" => user.id
        })

      {:ok, task} =
        Tasks.update_task(task, %{
          "review_status" => "approved",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      assert json_response(conn, 422)["error"] =~ "Task must be in Review column"
    end

    test "returns 422 when review status is not set", %{conn: conn, board: board, user: user} do
      review_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Review"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
          "title" => "Task without review",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      assert json_response(conn, 422)["error"] =~ "review status"
    end

    test "returns 404 when task belongs to different board (no existence oracle, D160)", %{
      conn: conn
    } do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      review_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Review"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
          "title" => "Task on other board",
          "created_by_id" => other_user.id
        })

      {:ok, task} =
        Tasks.update_task(task, %{
          "review_status" => "approved",
          "reviewed_by_id" => other_user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      assert json_response(conn, 404)["error"] =~ "Task not found"
    end

    test "approved last-child review includes after_goal in hooks payload (W492)",
         %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))

      {:ok, goal} =
        Tasks.create_task(review_column, %{
          "title" => "Goal-final",
          "type" => "goal",
          "created_by_id" => user.id
        })

      {:ok, child} =
        Tasks.create_task(review_column, %{
          "title" => "Only child in review",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "parent_id" => goal.id
        })

      {:ok, child} =
        Tasks.update_task(child, %{
          "review_status" => "approved",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{child.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      response = json_response(conn, 200)

      hook_names = Enum.map(response["hooks"], & &1["name"])
      assert hook_names == ["after_review", "after_goal"]

      after_goal = Enum.find(response["hooks"], &(&1["name"] == "after_goal"))
      assert after_goal["blocking"] == true
      assert after_goal["timeout"] == 600_000
      assert after_goal["env"]["HOOK_NAME"] == "after_goal"
    end

    test "approved non-last-child review omits after_goal (W492)",
         %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, goal} =
        Tasks.create_task(review_column, %{
          "title" => "Goal-partial",
          "type" => "goal",
          "created_by_id" => user.id
        })

      {:ok, child_a} =
        Tasks.create_task(review_column, %{
          "title" => "Sibling A (in review)",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "parent_id" => goal.id
        })

      {:ok, _child_b_still_doing} =
        Tasks.create_task(doing_column, %{
          "title" => "Sibling B (still open)",
          "created_by_id" => user.id,
          "parent_id" => goal.id
        })

      {:ok, child_a} =
        Tasks.update_task(child_a, %{
          "review_status" => "approved",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{child_a.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      response = json_response(conn, 200)

      hook_names = Enum.map(response["hooks"], & &1["name"])
      assert hook_names == ["after_review"]
      refute Enum.any?(response["hooks"], &(&1["name"] == "after_goal"))
    end

    test "approved orphan (no parent) review omits after_goal (W492)",
         %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))

      {:ok, orphan} =
        Tasks.create_task(review_column, %{
          "title" => "Orphan in review",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      {:ok, orphan} =
        Tasks.update_task(orphan, %{
          "review_status" => "approved",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      conn =
        patch(conn, ~p"/api/tasks/#{orphan.id}/mark_reviewed", %{
          "after_review_result" => valid_after_review_result()
        })

      response = json_response(conn, 200)

      hook_names = Enum.map(response["hooks"], & &1["name"])
      assert hook_names == ["after_review"]
    end
  end

  describe "PATCH /api/tasks/:id/mark_done" do
    test "marks task as done when in Review column", %{conn: conn, board: board, user: user} do
      columns = Columns.list_columns(board)
      review_column = Enum.find(columns, &(&1.name == "Review"))
      done_column = Enum.find(columns, &(&1.name == "Done"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
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

      {:ok, task} =
        Tasks.create_task(review_column, %{
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

      {:ok, task} =
        Tasks.create_task(backlog_column, %{
          "title" => "Task not in review",
          "created_by_id" => user.id
        })

      conn = patch(conn, ~p"/api/tasks/#{task.id}/mark_done")
      assert json_response(conn, 422)["error"] =~ "Task must be in Review column"
    end

    test "returns 404 when task belongs to different board (no existence oracle, D160)", %{
      conn: conn
    } do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      review_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Review"))

      {:ok, task} =
        Tasks.create_task(review_column, %{
          "title" => "Task on other board",
          "created_by_id" => other_user.id
        })

      conn = patch(conn, ~p"/api/tasks/#{task.id}/mark_done")
      assert json_response(conn, 404)["error"] =~ "Task not found"
    end
  end

  describe "TaskController.render_task_summary/1 delegation (W2055)" do
    test "the public arity BatchGoalCreation calls still resolves" do
      Code.ensure_loaded!(KanbanWeb.API.TaskController)

      assert function_exported?(KanbanWeb.API.TaskController, :render_task_summary, 1)
    end

    test "the delegate returns exactly what TaskJSON returns", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Delegation parity task",
          "priority" => "high",
          "complexity" => "medium",
          "dependencies" => ["W900"],
          "created_by_agent" => "Claude Opus 5"
        })

      # Fails loudest if a second, divergent definition is ever reintroduced
      # in the controller — the duplication this move removed.
      assert KanbanWeb.API.TaskController.render_task_summary(task) ==
               KanbanWeb.API.TaskJSON.render_task_summary(task)
    end
  end

  describe "GET /api/tasks/:id/dependencies" do
    test "returns dependency tree for task without dependencies", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task"
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependencies")
      response = json_response(conn, 200)

      assert response["task"]["id"] == task.id
      assert response["task"]["identifier"] == task.identifier
      assert response["dependencies"] == []
    end

    test "returns single level dependency tree", %{conn: conn, column: column} do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "dependencies" => [dep_task.identifier]
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependencies")
      response = json_response(conn, 200)

      assert response["task"]["id"] == task.id
      assert length(response["dependencies"]) == 1
      assert hd(response["dependencies"])["task"]["id"] == dep_task.id
      assert hd(response["dependencies"])["task"]["identifier"] == dep_task.identifier
    end

    test "returns nested dependency tree", %{conn: conn, column: column} do
      {:ok, dep1} =
        Tasks.create_task(column, %{
          "title" => "Dependency 1"
        })

      {:ok, dep2} =
        Tasks.create_task(column, %{
          "title" => "Dependency 2",
          "dependencies" => [dep1.identifier]
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "dependencies" => [dep2.identifier]
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependencies")
      response = json_response(conn, 200)

      assert response["task"]["id"] == task.id
      assert length(response["dependencies"]) == 1

      dep2_node = hd(response["dependencies"])
      assert dep2_node["task"]["id"] == dep2.id
      assert length(dep2_node["dependencies"]) == 1
      assert hd(dep2_node["dependencies"])["task"]["id"] == dep1.id
    end

    test "works with task identifier instead of ID", %{conn: conn, column: column} do
      {:ok, dep_task} =
        Tasks.create_task(column, %{
          "title" => "Dependency"
        })

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task",
          "dependencies" => [dep_task.identifier]
        })

      conn = get(conn, ~p"/api/tasks/#{task.identifier}/dependencies")
      response = json_response(conn, 200)

      assert response["task"]["identifier"] == task.identifier
      assert length(response["dependencies"]) == 1
      assert hd(response["dependencies"])["task"]["identifier"] == dep_task.identifier
    end

    test "returns 404 for task on different board (no existence oracle, D160)", %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> List.first()

      {:ok, task} =
        Tasks.create_task(other_column, %{
          "title" => "Task on other board"
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependencies")
      assert json_response(conn, 404)["error"] =~ "Task not found"
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/999999/dependencies")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/tasks/:id/dependents" do
    test "returns empty list for task without dependents", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task"
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependents")
      response = json_response(conn, 200)

      assert response["task"]["id"] == task.id
      assert response["task"]["identifier"] == task.identifier
      assert response["dependents"] == []
    end

    test "returns single dependent task", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task"
        })

      {:ok, dependent} =
        Tasks.create_task(column, %{
          "title" => "Dependent",
          "dependencies" => [task.identifier]
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependents")
      response = json_response(conn, 200)

      assert response["task"]["id"] == task.id
      assert length(response["dependents"]) == 1
      assert hd(response["dependents"])["id"] == dependent.id
      assert hd(response["dependents"])["identifier"] == dependent.identifier
    end

    test "returns multiple dependent tasks", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task"
        })

      {:ok, dependent1} =
        Tasks.create_task(column, %{
          "title" => "Dependent 1",
          "dependencies" => [task.identifier]
        })

      {:ok, dependent2} =
        Tasks.create_task(column, %{
          "title" => "Dependent 2",
          "dependencies" => [task.identifier]
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependents")
      response = json_response(conn, 200)

      assert response["task"]["id"] == task.id
      assert length(response["dependents"]) == 2

      dependent_ids = Enum.map(response["dependents"], & &1["id"])
      assert dependent1.id in dependent_ids
      assert dependent2.id in dependent_ids
    end

    test "works with task identifier instead of ID", %{conn: conn, column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task"
        })

      {:ok, dependent} =
        Tasks.create_task(column, %{
          "title" => "Dependent",
          "dependencies" => [task.identifier]
        })

      conn = get(conn, ~p"/api/tasks/#{task.identifier}/dependents")
      response = json_response(conn, 200)

      assert response["task"]["identifier"] == task.identifier
      assert length(response["dependents"]) == 1
      assert hd(response["dependents"])["identifier"] == dependent.identifier
    end

    test "returns 404 for task on different board (no existence oracle, D160)", %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = Columns.list_columns(other_board) |> List.first()

      {:ok, task} =
        Tasks.create_task(other_column, %{
          "title" => "Task on other board"
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/dependents")
      assert json_response(conn, 404)["error"] =~ "Task not found"
    end
  end

  describe "skills version in task API responses" do
    setup %{board: board, user: user} do
      columns = Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      doing_column = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, ready_task} =
        Tasks.create_task(ready_column, %{
          "title" => "Skills Version Test Task",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, doing_task} =
        Tasks.create_task(doing_column, %{
          "title" => "In Progress Task",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "needs_review" => false
        })

      %{
        ready_column: ready_column,
        doing_column: doing_column,
        ready_task: ready_task,
        doing_task: doing_task
      }
    end

    test "GET /api/tasks/next includes current_skills_version", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)

      assert response["current_skills_version"] == KanbanWeb.API.AgentJSON.skills_version()
    end

    test "GET /api/tasks/next with matching skills_version does not include skills_update_required",
         %{conn: conn} do
      current = KanbanWeb.API.AgentJSON.skills_version()
      conn = get(conn, ~p"/api/tasks/next?skills_version=#{current}")
      response = json_response(conn, 200)

      assert response["current_skills_version"] == current
      refute Map.has_key?(response, "skills_update_required")
    end

    test "GET /api/tasks/next with stale skills_version includes skills_update_required",
         %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/next?skills_version=0.1")
      response = json_response(conn, 200)

      assert response["current_skills_version"] == KanbanWeb.API.AgentJSON.skills_version()

      assert response["skills_update_required"]["current_version"] ==
               KanbanWeb.API.AgentJSON.skills_version()

      assert response["skills_update_required"]["your_version"] == "0.1"
      assert response["skills_update_required"]["action"] =~ "/plugin update stride"
      assert response["skills_update_required"]["reason"] =~ "outdated"
    end

    test "GET /api/tasks/next without skills_version does not include skills_update_required",
         %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/next")
      response = json_response(conn, 200)

      assert response["current_skills_version"]
      refute Map.has_key?(response, "skills_update_required")
    end

    test "POST /api/tasks/claim includes current_skills_version", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks/claim", %{
          "before_doing_result" => valid_before_doing_result()
        })

      response = json_response(conn, 200)
      assert response["current_skills_version"] == KanbanWeb.API.AgentJSON.skills_version()
    end

    test "POST /api/tasks/claim with stale version includes skills_update_required",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks/claim", %{
          "before_doing_result" => valid_before_doing_result(),
          "skills_version" => "0.1"
        })

      response = json_response(conn, 200)
      assert response["skills_update_required"]["your_version"] == "0.1"
    end

    test "PATCH /api/tasks/:id/complete includes current_skills_version",
         %{conn: conn, doing_task: task} do
      completion_params = %{
        "completion_summary" => "Done",
        "actual_complexity" => "small",
        "actual_files_changed" => "1",
        "time_spent_minutes" => 10,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result()
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)

      assert response["current_skills_version"] == KanbanWeb.API.AgentJSON.skills_version()
    end

    test "PATCH /api/tasks/:id/complete with stale version includes skills_update_required",
         %{conn: conn, doing_task: task} do
      completion_params = %{
        "completion_summary" => "Done",
        "actual_complexity" => "small",
        "actual_files_changed" => "1",
        "time_spent_minutes" => 10,
        "after_doing_result" => valid_after_doing_result(),
        "before_review_result" => valid_before_review_result(),
        "skills_version" => "0.1"
      }

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete", completion_params)
      response = json_response(conn, 200)

      assert response["skills_update_required"]["your_version"] == "0.1"
    end

    test "GET /api/tasks/next with empty string skills_version does not trigger update",
         %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/next?skills_version=")
      response = json_response(conn, 200)

      assert response["current_skills_version"]
      refute Map.has_key?(response, "skills_update_required")
    end

    test "GET /api/tasks/next with future version triggers skills_update_required",
         %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/next?skills_version=99.0")
      response = json_response(conn, 200)

      assert response["skills_update_required"]["your_version"] == "99.0"

      assert response["skills_update_required"]["current_version"] ==
               KanbanWeb.API.AgentJSON.skills_version()
    end
  end

  describe "missing 401 tests" do
    test "PATCH /api/tasks/:id/complete returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = patch(conn, ~p"/api/tasks/123/complete", %{})
      assert json_response(conn, 401)
    end

    test "PUT /api/tasks/:id/changed_files returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = put(conn, ~p"/api/tasks/123/changed_files", %{"changed_files" => []})
      assert json_response(conn, 401)
    end

    test "PATCH /api/tasks/:id/mark_reviewed returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = patch(conn, ~p"/api/tasks/123/mark_reviewed", %{})
      assert json_response(conn, 401)
    end

    test "PATCH /api/tasks/:id/mark_done returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = patch(conn, ~p"/api/tasks/123/mark_done", %{})
      assert json_response(conn, 401)
    end

    test "GET /api/tasks/:id/dependencies returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks/123/dependencies")
      assert json_response(conn, 401)
    end

    test "GET /api/tasks/:id/dependents returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks/123/dependents")
      assert json_response(conn, 401)
    end

    test "GET /api/tasks/:id/tree returns 401 without authentication" do
      conn = build_conn()
      conn = put_req_header(conn, "accept", "application/json")

      conn = get(conn, ~p"/api/tasks/123/tree")
      assert json_response(conn, 401)
    end
  end

  describe "missing 404 tests" do
    test "PATCH /api/tasks/:id/mark_reviewed returns 404 for nonexistent task",
         %{conn: conn} do
      conn =
        patch(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/mark_reviewed", %{
          "review_status" => "approved",
          "after_review_result" => valid_after_review_result()
        })

      assert json_response(conn, 404)
    end

    test "PATCH /api/tasks/:id/mark_done returns 404 for nonexistent task",
         %{conn: conn} do
      conn = patch(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/mark_done", %{})
      assert json_response(conn, 404)
    end

    test "GET /api/tasks/:id/dependents returns 404 for nonexistent task",
         %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/dependents")
      assert json_response(conn, 404)
    end

    test "POST /api/tasks/:id/unclaim returns 404 for nonexistent task",
         %{conn: conn} do
      conn = post(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/unclaim", %{})
      assert json_response(conn, 404)
    end
  end

  describe "missing 403 tests" do
    test "PATCH /api/tasks/:id updates task from different board returns 404 (no existence oracle, D160)",
         %{conn: conn, user: user} do
      other_board = ai_optimized_board_fixture(user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, task} =
        Tasks.create_task(other_column, %{title: "Other board task", position: 0})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          task: %{title: "Updated"}
        })

      assert json_response(conn, 404)["error"] =~ "Task not found"
    end
  end

  describe "GET /api/tasks/:id/tree" do
    test "returns tree for goal with children", %{conn: conn, column: column} do
      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{title: "Test Goal"},
          [%{title: "Child 1"}, %{title: "Child 2"}]
        )

      conn = get(conn, ~p"/api/tasks/#{goal.id}/tree")
      response = json_response(conn, 200)

      assert response["data"]["task"]["title"] == "Test Goal"
      assert length(response["data"]["children"]) == 2
    end

    test "returns tree for task with no children", %{conn: conn, column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "Leaf Task", position: 0})

      conn = get(conn, ~p"/api/tasks/#{task.id}/tree")
      response = json_response(conn, 200)

      assert response["data"]["task"]["title"] == "Leaf Task"
      assert response["data"]["children"] == []
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/tree")
      assert json_response(conn, 404)
    end

    test "returns tree using task identifier", %{conn: conn, column: column} do
      {:ok, task} = Tasks.create_task(column, %{title: "ID Task", position: 0})

      conn = get(conn, ~p"/api/tasks/#{task.identifier}/tree")
      response = json_response(conn, 200)

      assert response["data"]["task"]["title"] == "ID Task"
    end

    test "returns 404 for task on different board (no existence oracle, D160)", %{
      conn: conn,
      user: user
    } do
      other_board = ai_optimized_board_fixture(user)
      other_column = Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, task} =
        Tasks.create_task(other_column, %{title: "Other board task", position: 0})

      conn = get(conn, ~p"/api/tasks/#{task.id}/tree")
      assert json_response(conn, 404)["error"] =~ "Task not found"
    end

    test "response_view=slim slims the children but keeps the root full", %{
      conn: conn,
      column: column
    } do
      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{title: "Slim Tree Goal", description: "Goal detail the caller asked for"},
          [%{title: "Child 1"}, %{title: "Child 2"}]
        )

      response = json_response(get(conn, ~p"/api/tasks/#{goal.id}/tree?response_view=slim"), 200)

      # The root keeps the planning detail the request was made for.
      assert response["data"]["task"]["description"] == "Goal detail the caller asked for"
      assert Map.has_key?(response["data"]["task"], "key_files")
      assert Map.has_key?(response["data"]["task"], "acceptance_criteria")

      assert length(response["data"]["children"]) == 2

      for child <- response["data"]["children"] do
        assert child |> Map.keys() |> Enum.sort() ==
                 ~w(complexity created_by_agent dependencies id identifier priority status title)
      end
    end

    test "the counts object is identical in both views", %{conn: conn, column: column} do
      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{title: "Counts Goal"},
          [%{title: "Child 1"}, %{title: "Child 2"}]
        )

      full = json_response(get(conn, ~p"/api/tasks/#{goal.id}/tree"), 200)
      slim = json_response(get(conn, ~p"/api/tasks/#{goal.id}/tree?response_view=slim"), 200)

      assert slim["data"]["counts"] == full["data"]["counts"]

      # Pinned so an empty-map regression cannot pass the equality above.
      assert slim["data"]["counts"] |> Map.keys() |> Enum.sort() ==
               ~w(blocked completed total)
    end

    test "an absent response_view returns a tree identical to an explicit full", %{
      conn: conn,
      column: column
    } do
      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{title: "Identity Goal"},
          [%{title: "Child 1"}]
        )

      absent = json_response(get(conn, ~p"/api/tasks/#{goal.id}/tree"), 200)
      explicit = json_response(get(conn, ~p"/api/tasks/#{goal.id}/tree?response_view=full"), 200)

      assert absent == explicit

      # Pinned against the untouched GET /api/tasks/:id view, so this cannot
      # pass by both sides shrinking together.
      show = json_response(get(conn, ~p"/api/tasks/#{goal.id}"), 200)["data"]

      assert absent["data"]["task"] |> Map.keys() |> Enum.sort() ==
               show |> Map.keys() |> Enum.sort()
    end

    test "response_view=slim on a leaf task keeps the root full and children empty", %{
      conn: conn,
      column: column
    } do
      {:ok, task} = Tasks.create_task(column, %{title: "Slim Leaf Task", position: 0})

      response = json_response(get(conn, ~p"/api/tasks/#{task.id}/tree?response_view=slim"), 200)

      assert response["data"]["task"]["title"] == "Slim Leaf Task"
      assert Map.has_key?(response["data"]["task"], "key_files")
      assert response["data"]["children"] == []
    end
  end

  # W2058: the byte caps that stop the fat shape creeping back one field at a
  # time. Every field in every slim shape is a scalar, and every field the slim
  # views removed is KB-scale — a 500-line-per-file diff, a reviewer_result with
  # 25 project_checks, a review_report. So each cap sits at roughly 3-5x the
  # measured slim shape and far below the smallest blob that could re-enter: it
  # has room for ordinary content growth but none for a blob.
  #
  # Each cap test pairs three assertions against ONE fixture that puts a large
  # blob in a field the slim view omits: the slim body is under the cap, the
  # full body is over it (so the cap discriminates rather than passing
  # vacuously), and — the assertion that proves the cap is on the SHAPE and not
  # the DATA — growing the blob by kilobytes does not move the slim number.
  #
  # If one of these goes red, the fix is to find which blob re-entered the slim
  # shape. It is NOT to raise the number. A failing guard is the guard working.
  describe "slim response byte caps (W2058)" do
    # Measured slim shapes at the time of writing: changed_files ack 194 B,
    # complete ack 1_475 B, summary row ~166 B, tree root ~1_371 B.
    #
    # The complete and tree caps are deliberately tighter than a flat 4 KB
    # would be, because at 4 KB each stops discriminating against a realistic
    # regression: a re-added `review_report` is ~2.6 KB, which would still fit
    # under a 4 KB complete cap, and a 4 KB root allowance is ~3x the measured
    # root, so a full tree with LEAN children would fit too — leaving the tree
    # cap's discrimination supplied by the fixture's fat children rather than
    # by the shape difference it is meant to assert.
    @changed_files_ack_cap 1_024
    @complete_ack_cap 2_560
    @summary_row_cap 512
    @index_envelope 128
    @tree_root_allowance 2_048

    # Tolerance for the shape-not-data assertions: an id or identifier can gain
    # a digit as the DB sequence advances across a suite run.
    @width_tolerance 64

    defp cap_violation(body, cap) do
      bytes = byte_size(body)
      if bytes <= cap, do: nil, else: {bytes, cap}
    end

    defp fat_reviewer_result(pad_bytes) do
      Map.merge(valid_reviewer_result(), %{
        "project_checks" =>
          for(
            i <- 1..25,
            do: %{
              "check" => "check #{i} #{String.duplicate("x", 80)}",
              "status" => "met",
              "evidence" => String.duplicate("e", pad_bytes)
            }
          )
      })
    end

    defp claimed_task(column, user, attrs) do
      {:ok, task} = Tasks.create_task(column, attrs)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(
          status: :in_progress,
          claimed_at: DateTime.utc_now(:second),
          assigned_to_id: user.id
        )
        |> Kanban.Repo.update()

      task
    end

    defp diff_payload(lines) do
      %{
        "changed_files" =>
          for(
            i <- 1..5,
            do: %{
              "path" => "lib/file_#{i}.ex",
              "diff" => String.duplicate("@@ -1 +1 @@\n-a\n+b\n", lines)
            }
          )
      }
    end

    # AC3, second half: proof the cap actually goes red. Same helper, same
    # shape, one body padded past the cap.
    test "the cap check fails when a slim body is padded past its cap", %{
      conn: conn,
      column: column
    } do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Cap red-proof task"})

      conn =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", diff_payload(10))

      # Without this, a request that started failing would leave the whole test
      # green: a small 4xx error body fits under the cap just as happily as a
      # slim ack, and the padded leg below would then be pure arithmetic on it.
      assert conn.status == 200

      body = conn.resp_body

      assert is_nil(cap_violation(body, @changed_files_ack_cap))

      padded = body <> String.duplicate("x", @changed_files_ack_cap)
      assert {bytes, @changed_files_ack_cap} = cap_violation(padded, @changed_files_ack_cap)
      assert bytes > @changed_files_ack_cap
    end

    test "PUT /changed_files stays under its cap, and the cap discriminates", %{
      conn: conn,
      column: column
    } do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Diff cap task"})
      payload = diff_payload(40)

      slim = put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", payload)
      full = put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload)

      assert slim.status == 200
      assert full.status == 200

      assert is_nil(cap_violation(slim.resp_body, @changed_files_ack_cap)),
             "slim changed_files ack grew past its cap: #{byte_size(slim.resp_body)} > #{@changed_files_ack_cap}"

      refute is_nil(cap_violation(full.resp_body, @changed_files_ack_cap)),
             "the cap no longer discriminates — even the FULL body fits under it"
    end

    test "the slim changed_files ack does not grow when the uploaded diff does", %{
      conn: conn,
      column: column
    } do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Diff invariance task"})

      small =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", diff_payload(5))

      # 150 repetitions is 450 lines per file — deliberately just under the
      # 500-line-per-file cap in docs/diff-contract.md. Over it, the endpoint
      # 422s and the ERROR body is what grows, which would leave this assertion
      # measuring something entirely different while still looking meaningful.
      big =
        put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", diff_payload(150))

      assert small.status == 200
      assert big.status == 200

      # The DATA grew by kilobytes; the capped number must not have moved. This
      # is what makes the cap a shape assertion rather than a content one.
      assert byte_size(big.resp_body) - byte_size(small.resp_body) <= @width_tolerance
    end

    # The slim /complete body carries `hooks`, whose env embeds TASK_TITLE and
    # TASK_DESCRIPTION verbatim — so its size is a linear function of the task's
    # description. This fixture is therefore local with a pinned short title and
    # description rather than reusing a describe-level one, and pins
    # needs_review: true (two hooks; false appends after_review, adding a third).
    test "PATCH /complete stays under its cap, and the cap discriminates", %{
      conn: conn,
      column: column,
      user: user
    } do
      params = fn ->
        Map.merge(base_completion_params(), %{
          "explorer_result" => valid_explorer_result(),
          "reviewer_result" => fat_reviewer_result(80),
          "review_report" => String.duplicate("report line\n", 200)
        })
      end

      slim_task =
        claimed_task(column, user, %{
          "title" => "Cap task",
          "description" => "Short.",
          "needs_review" => true
        })

      full_task =
        claimed_task(column, user, %{
          "title" => "Cap task",
          "description" => "Short.",
          "needs_review" => true
        })

      slim = patch(conn, ~p"/api/tasks/#{slim_task.id}/complete?response_view=slim", params.())
      full = patch(conn, ~p"/api/tasks/#{full_task.id}/complete", params.())

      assert slim.status == 200
      assert full.status == 200

      assert is_nil(cap_violation(slim.resp_body, @complete_ack_cap)),
             "slim complete ack grew past its cap: #{byte_size(slim.resp_body)} > #{@complete_ack_cap}"

      refute is_nil(cap_violation(full.resp_body, @complete_ack_cap)),
             "the cap no longer discriminates — even the FULL body fits under it"
    end

    test "the slim complete ack does not grow when reviewer_result does", %{
      conn: conn,
      column: column,
      user: user
    } do
      params = fn pad ->
        Map.merge(base_completion_params(), %{
          "explorer_result" => valid_explorer_result(),
          "reviewer_result" => fat_reviewer_result(pad)
        })
      end

      small_task =
        claimed_task(column, user, %{
          "title" => "Inv",
          "description" => "Short.",
          "needs_review" => true
        })

      big_task =
        claimed_task(column, user, %{
          "title" => "Inv",
          "description" => "Short.",
          "needs_review" => true
        })

      small =
        patch(conn, ~p"/api/tasks/#{small_task.id}/complete?response_view=slim", params.(10))

      big = patch(conn, ~p"/api/tasks/#{big_task.id}/complete?response_view=slim", params.(400))

      # The one-sided assertion below passes trivially if `big` SHRINKS — which
      # is exactly what a 422 would do. A future validation rule targeting the
      # 400-character evidence strings would otherwise leave this test green
      # while it tested nothing at all.
      assert small.status == 200
      assert big.status == 200

      assert byte_size(big.resp_body) - byte_size(small.resp_body) <= @width_tolerance
    end

    # Capped as a RATE rather than a whole-response number: a whole-response cap
    # would pin a row count and need manual updating every time a fixture adds a
    # task, which is a data assertion wearing a shape assertion's clothes.
    test "GET /api/tasks stays under its per-row cap, and the cap discriminates", %{
      conn: conn,
      column: column
    } do
      for i <- 1..3 do
        {:ok, t} =
          Tasks.create_task(column, %{
            "title" => "Row cap task #{i}",
            "description" => String.duplicate("long description ", 50)
          })

        {:ok, _} =
          t
          |> Ecto.Changeset.change(reviewer_result: fat_reviewer_result(80))
          |> Kanban.Repo.update()
      end

      slim = get(conn, ~p"/api/tasks?response_view=slim")
      full = get(conn, ~p"/api/tasks")

      assert slim.status == 200
      assert full.status == 200

      rows = length(json_response(slim, 200)["data"])
      cap = @summary_row_cap * rows + @index_envelope

      assert is_nil(cap_violation(slim.resp_body, cap)),
             "slim index grew past #{@summary_row_cap} B/row over #{rows} rows: #{byte_size(slim.resp_body)} > #{cap}"

      refute is_nil(cap_violation(full.resp_body, cap)),
             "the cap no longer discriminates — even the FULL index fits under it"
    end

    # The tree root is deliberately never slimmed, so it gets a flat allowance
    # sized at ~1.5x the measured root render — tight enough that a full tree
    # with LEAN children still exceeds the cap, so the discrimination below is
    # structural rather than supplied by the fixture. The cap's discriminating power comes from the children —
    # which is the only part response_view=slim actually controls. The fixture
    # is lean-root/fat-children for the same reason.
    test "GET /:id/tree stays under its root allowance plus per-child cap", %{
      conn: conn,
      column: column
    } do
      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{title: "Tree cap goal"}, [
          %{title: "Child 1", description: String.duplicate("child detail ", 100)},
          %{title: "Child 2", description: String.duplicate("child detail ", 100)}
        ])

      slim = get(conn, ~p"/api/tasks/#{goal.id}/tree?response_view=slim")
      full = get(conn, ~p"/api/tasks/#{goal.id}/tree")

      assert slim.status == 200
      assert full.status == 200

      children = length(json_response(slim, 200)["data"]["children"])
      cap = @tree_root_allowance + @summary_row_cap * children

      assert is_nil(cap_violation(slim.resp_body, cap)),
             "slim tree grew past its cap over #{children} children: #{byte_size(slim.resp_body)} > #{cap}"

      refute is_nil(cap_violation(full.resp_body, cap)),
             "the cap no longer discriminates — even the FULL tree fits under it"
    end
  end

  describe "hook validation failures" do
    test "POST /api/tasks/claim with failed before_doing hook returns 422",
         %{conn: conn, column: column} do
      {:ok, _task} =
        Tasks.create_task(column, %{title: "Hook Test Task", position: 0})

      conn =
        post(conn, ~p"/api/tasks/claim", %{
          "agent_name" => "Test Agent",
          "before_doing_result" => %{
            "exit_code" => 1,
            "output" => "Tests failed",
            "duration_ms" => 500
          }
        })

      response = json_response(conn, 422)
      assert response["error"] =~ "before_doing"
    end

    test "PATCH /api/tasks/:id/complete with failed after_doing hook returns 422",
         %{conn: conn, board: board, user: user} do
      ready_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Ready"))

      {:ok, _task} =
        Tasks.create_task(ready_column, %{
          "title" => "Complete Hook Test",
          "status" => "open",
          "created_by_id" => user.id
        })

      # Claim via API to get task in progress
      claim_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", conn |> get_req_header("authorization") |> hd())
        |> post(~p"/api/tasks/claim", %{
          "before_doing_result" => valid_before_doing_result()
        })

      claimed_task_id = json_response(claim_conn, 200)["data"]["id"]

      conn =
        patch(conn, ~p"/api/tasks/#{claimed_task_id}/complete", %{
          "completion_summary" => "Done",
          "actual_complexity" => "small",
          "time_spent_minutes" => 30,
          "after_doing_result" => %{
            "exit_code" => 1,
            "output" => "Build failed",
            "duration_ms" => 5000
          },
          "before_review_result" => valid_before_review_result()
        })

      response = json_response(conn, 422)
      assert response["error"] =~ "after_doing"
    end

    test "PATCH /api/tasks/:id/mark_reviewed with failed after_review hook returns 422",
         %{conn: conn, board: board, user: user} do
      ready_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Ready"))

      {:ok, _task} =
        Tasks.create_task(ready_column, %{
          "title" => "Review Hook Test",
          "status" => "open",
          "created_by_id" => user.id
        })

      # Claim via API
      claim_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", conn |> get_req_header("authorization") |> hd())
        |> post(~p"/api/tasks/claim", %{
          "before_doing_result" => valid_before_doing_result()
        })

      claimed_task_id = json_response(claim_conn, 200)["data"]["id"]

      # Complete via API
      complete_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", conn |> get_req_header("authorization") |> hd())
        |> patch(~p"/api/tasks/#{claimed_task_id}/complete", %{
          "completion_summary" => "Done",
          "actual_complexity" => "small",
          "time_spent_minutes" => 30,
          "actual_files_changed" => "lib/test.ex",
          "after_doing_result" => valid_after_doing_result(),
          "before_review_result" => valid_before_review_result()
        })

      assert json_response(complete_conn, 200)

      # Task is now in Review column; hook validation happens before review_status check
      conn =
        patch(conn, ~p"/api/tasks/#{claimed_task_id}/mark_reviewed", %{
          "review_status" => "approved",
          "after_review_result" => %{
            "exit_code" => 1,
            "output" => "Deploy failed",
            "duration_ms" => 3000
          }
        })

      response = json_response(conn, 422)
      assert response["error"] =~ "after_review"
    end
  end

  describe "human_task field in API responses" do
    test "task JSON includes human_task field defaulting to false", %{
      conn: conn,
      column: column,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Agent Task",
          "created_by_id" => user.id
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["human_task"] == false
    end

    test "task JSON includes human_task=true when explicitly set", %{
      conn: conn,
      column: column,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Human Only Task",
          "human_task" => true,
          "created_by_id" => user.id
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["human_task"] == true
    end

    test "API-created task defaults human_task to false", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks", %{
          "task" => %{
            "title" => "API Created Task",
            "type" => "work"
          }
        })

      response = json_response(conn, 201)["data"]

      assert response["human_task"] == false
    end
  end

  describe "proceed_with_claim catch-all error handler" do
    test "response body never contains inspect-style internals" do
      body = KanbanWeb.API.TaskController.unexpected_claim_error_body()

      assert body == %{
               error: "internal_server_error",
               message:
                 "Failed to claim task. Please retry; if the failure persists, contact support."
             }

      # No tuple-printing, no Elixir-atom syntax, no module-name syntax
      # — the body is a flat user-facing string.
      refute body.message =~ "{"
      refute body.message =~ ":"
      refute body.message =~ "%"
    end

    test "handle_unexpected_claim_error/3 logs the raw reason but returns the stable body" do
      import ExUnit.CaptureLog

      starting_conn = Phoenix.ConnTest.build_conn(:post, "/api/tasks/claim")

      {response_conn, log} =
        with_log(fn ->
          KanbanWeb.API.TaskController.handle_unexpected_claim_error(
            starting_conn,
            {:weird_database, :error_atom, "unexpected"},
            task_identifier: "W999",
            agent_name: "Test Agent"
          )
        end)

      # The raw reason is in the log (operator visibility) ...
      assert log =~ ":weird_database"

      # ... but NOT in the JSON response body (no client leak).
      body = Phoenix.ConnTest.json_response(response_conn, 500)
      assert body["error"] == "internal_server_error"
      refute body["message"] =~ ":weird_database"
      refute body["message"] =~ "unexpected"
    end
  end

  describe "technical_details API (W1175)" do
    test "POST /api/tasks persists and echoes technical_details", %{conn: conn, column: column} do
      td = %{"approach" => "use Ecto.Multi", "steps" => ["a", "b"], "nested" => %{"k" => 1}}

      conn =
        post(conn, ~p"/api/tasks",
          task: %{"title" => "TD Task", "column_id" => column.id, "technical_details" => td}
        )

      assert %{"id" => id, "technical_details" => ^td} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/tasks/#{id}")
      assert json_response(conn, 200)["data"]["technical_details"] == td
    end

    test "a task without technical_details serializes an empty object, not null", %{
      conn: conn,
      column: column
    } do
      conn =
        post(conn, ~p"/api/tasks", task: %{"title" => "No TD", "column_id" => column.id})

      assert json_response(conn, 201)["data"]["technical_details"] == %{}
    end

    test "POST /api/tasks rejects a non-object technical_details with 422", %{
      conn: conn,
      column: column
    } do
      conn =
        post(conn, ~p"/api/tasks",
          task: %{"title" => "Bad TD", "column_id" => column.id, "technical_details" => "nope"}
        )

      assert json_response(conn, 422)["errors"] != %{}
    end

    test "PATCH /api/tasks/:id updates technical_details", %{
      conn: conn,
      column: column,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Patch TD",
          "created_by_id" => user.id,
          "technical_details" => %{"old" => "value"}
        })

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"technical_details" => %{"new" => "value", "more" => [1, 2]}}
        )

      assert json_response(conn, 200)["data"]["technical_details"] == %{
               "new" => "value",
               "more" => [1, 2]
             }
    end

    test "POST /api/tasks/batch persists technical_details on a nested task", %{conn: conn} do
      td = %{"design" => "documented"}

      goals_params = [
        %{
          "title" => "TD Goal",
          "type" => "goal",
          "tasks" => [
            %{"title" => "TD Child", "type" => "work", "technical_details" => td}
          ]
        }
      ]

      conn = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(conn, 201)

      assert %{"success" => true, "goals" => goals} = response

      # The batch response renders a minimal child summary; assert the field
      # PERSISTED by fetching the created child through the full task JSON.
      child_id =
        goals |> Enum.at(0) |> Map.fetch!("child_tasks") |> Enum.at(0) |> Map.fetch!("id")

      conn = get(conn, ~p"/api/tasks/#{child_id}")
      assert json_response(conn, 200)["data"]["technical_details"] == td
    end
  end

  # Round-trip coverage for the behaviour/test matrix through the JSON API
  # (W1918). These tests also prove NO KanbanWeb.API.TaskParamFilter change was
  # needed: the field is in neither forbidden list, so it survives the create,
  # update and batch-child filters untouched.
  describe "behaviour_test_matrix API (W1918)" do
    test "POST /api/tasks persists and echoes behaviour_test_matrix",
         %{conn: conn, column: column} do
      matrix = full_behaviour_matrix()

      created =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "BTM Task",
            "column_id" => column.id,
            "behaviour_test_matrix" => matrix
          }
        )

      body = json_response(created, 201)["data"]
      assert body["behaviour_test_matrix"] == expected_behaviour_matrix_json(matrix)

      fetched = get(conn, ~p"/api/tasks/#{body["id"]}")

      assert json_response(fetched, 200)["data"]["behaviour_test_matrix"] ==
               expected_behaviour_matrix_json(matrix)
    end

    test "GET /api/tasks includes behaviour_test_matrix on each task",
         %{conn: conn, column: column} do
      matrix = full_behaviour_matrix()

      created =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "BTM Index",
            "column_id" => column.id,
            "behaviour_test_matrix" => matrix
          }
        )

      id = json_response(created, 201)["data"]["id"]

      listed = get(conn, ~p"/api/tasks")
      task = json_response(listed, 200)["data"] |> Enum.find(&(&1["id"] == id))

      assert task["behaviour_test_matrix"] == expected_behaviour_matrix_json(matrix)
    end

    test "a task without behaviour_test_matrix serializes an empty array, not null",
         %{conn: conn, column: column} do
      created = post(conn, ~p"/api/tasks", task: %{"title" => "No BTM", "column_id" => column.id})

      assert json_response(created, 201)["data"]["behaviour_test_matrix"] == []
    end

    test "POST /api/tasks accepts an explicitly empty behaviour_test_matrix",
         %{conn: conn, column: column} do
      created =
        post(conn, ~p"/api/tasks",
          task: %{"title" => "Empty BTM", "column_id" => column.id, "behaviour_test_matrix" => []}
        )

      assert json_response(created, 201)["data"]["behaviour_test_matrix"] == []
    end

    test "POST /api/tasks rejects a row with an unknown category with 422",
         %{conn: conn, column: column} do
      bad_row = Map.merge(@behaviour_row_template, %{"category" => "Bogus", "position" => 0})

      created =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Bad BTM",
            "column_id" => column.id,
            "behaviour_test_matrix" => [bad_row]
          }
        )

      body = json_response(created, 422)
      assert [%{"category" => [message]}] = body["errors"]["behaviour_test_matrix"]
      assert message =~ "must be one of:"
    end

    test "POST /api/tasks rejects an incomplete matrix with 422 naming the missing categories",
         %{conn: conn, column: column} do
      partial = behaviour_rows_for(["Happy path", "Boundary"])

      created =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Partial BTM",
            "column_id" => column.id,
            "behaviour_test_matrix" => partial
          }
        )

      assert [message] = json_response(created, 422)["errors"]["behaviour_test_matrix"]
      assert message =~ "must include at least one row for every category. Missing:"
      assert message =~ "Concurrency"
    end

    test "POST /api/tasks rejects a non-array behaviour_test_matrix with 422",
         %{conn: conn, column: column} do
      created =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Scalar BTM",
            "column_id" => column.id,
            "behaviour_test_matrix" => "nope"
          }
        )

      messages = json_response(created, 422)["errors"]["behaviour_test_matrix"]

      assert Enum.any?(
               messages,
               &String.contains?(&1, "must be an array of objects with category, behaviour")
             )
    end

    test "PATCH /api/tasks/:id replaces behaviour_test_matrix",
         %{conn: conn, column: column, user: user} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Patch BTM",
          "created_by_id" => user.id,
          "behaviour_test_matrix" => full_behaviour_matrix()
        })

      updated =
        full_behaviour_matrix_with(%{
          "test_name" => "the replacement row",
          "status" => "passing"
        })

      patched =
        patch(conn, ~p"/api/tasks/#{task.id}", task: %{"behaviour_test_matrix" => updated})

      rows = json_response(patched, 200)["data"]["behaviour_test_matrix"]

      assert rows == expected_behaviour_matrix_json(updated)
      assert length(rows) == 7
      assert hd(rows)["test_name"] == "the replacement row"
    end

    test "PATCH /api/tasks/:id rejects an incomplete matrix and leaves the stored one intact",
         %{conn: conn, column: column, user: user} do
      original = full_behaviour_matrix()

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Patch Bad BTM",
          "created_by_id" => user.id,
          "behaviour_test_matrix" => original
        })

      patched =
        patch(conn, ~p"/api/tasks/#{task.id}",
          task: %{"behaviour_test_matrix" => behaviour_rows_for(["Happy path"])}
        )

      assert [message] = json_response(patched, 422)["errors"]["behaviour_test_matrix"]
      assert message =~ "Missing:"

      fetched = get(conn, ~p"/api/tasks/#{task.id}")

      assert json_response(fetched, 200)["data"]["behaviour_test_matrix"] ==
               expected_behaviour_matrix_json(original)
    end

    test "POST /api/tasks/batch persists behaviour_test_matrix on a nested task", %{conn: conn} do
      matrix = full_behaviour_matrix()

      goals_params = [
        %{
          "title" => "BTM Goal",
          "type" => "goal",
          "tasks" => [
            %{"title" => "BTM Child", "type" => "work", "behaviour_test_matrix" => matrix}
          ]
        }
      ]

      created = post(conn, ~p"/api/tasks/batch", goals: goals_params)
      response = json_response(created, 201)

      assert %{"success" => true, "goals" => goals} = response

      # The batch response renders only a minimal child summary, so persistence
      # is proven by fetching the child through the full task JSON.
      child_id =
        goals |> Enum.at(0) |> Map.fetch!("child_tasks") |> Enum.at(0) |> Map.fetch!("id")

      fetched = get(conn, ~p"/api/tasks/#{child_id}")

      assert json_response(fetched, 200)["data"]["behaviour_test_matrix"] ==
               expected_behaviour_matrix_json(matrix)
    end

    test "a waived (not_applicable) row round-trips with na_reason and a null test_name",
         %{conn: conn, column: column} do
      matrix = full_behaviour_matrix_waiving("Concurrency", "single-process code path")

      created =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "NA BTM",
            "column_id" => column.id,
            "behaviour_test_matrix" => matrix
          }
        )

      rows = json_response(created, 201)["data"]["behaviour_test_matrix"]
      waived = Enum.find(rows, &(&1["category"] == "Concurrency"))

      assert waived["status"] == "not_applicable"
      assert waived["na_reason"] == "single-process code path"
      assert waived["test_name"] == nil
      assert rows == expected_behaviour_matrix_json(matrix)
    end

    test "a '/'-combined type token round-trips verbatim", %{conn: conn, column: column} do
      matrix = full_behaviour_matrix_with(%{"type" => "unit / manual"})

      created =
        post(conn, ~p"/api/tasks",
          task: %{
            "title" => "Combo BTM",
            "column_id" => column.id,
            "behaviour_test_matrix" => matrix
          }
        )

      id = json_response(created, 201)["data"]["id"]
      fetched = get(conn, ~p"/api/tasks/#{id}")
      rows = json_response(fetched, 200)["data"]["behaviour_test_matrix"]

      # No normalization: BehaviourTestRow validates the combination only.
      assert hd(rows)["type"] == "unit / manual"
    end
  end

  describe "response_view opt-in gate (W2054)" do
    test "view_for/1 returns :slim for the exact string slim" do
      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => "slim"}) == :slim
    end

    test "view_for/1 returns :full when the param is absent" do
      assert KanbanWeb.API.TaskController.view_for(%{}) == :full
      assert KanbanWeb.API.TaskController.view_for(%{"agent_name" => "Claude"}) == :full
    end

    test "view_for/1 returns :full for the string full" do
      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => "full"}) == :full
    end

    test "view_for/1 returns :full for an empty string" do
      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => ""}) == :full
    end

    test "view_for/1 returns :full for an unrecognised value" do
      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => "compact"}) == :full
      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => "SLIM_MODE"}) == :full
    end

    test "view_for/1 returns :full for a non-string value such as a list or map" do
      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => ["slim"]}) == :full

      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => %{"v" => "slim"}}) ==
               :full

      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => nil}) == :full
      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => 1}) == :full
    end

    test "view_for/1 does not accept truthy variants" do
      for value <- [true, "true", "1", "yes", "on"] do
        assert KanbanWeb.API.TaskController.view_for(%{"response_view" => value}) == :full,
               "#{inspect(value)} must not opt in to the slim view"
      end
    end

    test "view_for/1 requires an exact match — whitespace and case do not opt in" do
      for value <- [" slim", "slim ", " slim ", "Slim", "SLIM", "sLiM", "\tslim\n"] do
        assert KanbanWeb.API.TaskController.view_for(%{"response_view" => value}) == :full,
               "#{inspect(value)} must not opt in to the slim view"
      end
    end

    test "view_for/1 never converts the param to an atom" do
      # Atom-exhaustion guard: the param is attacker-controllable, so resolving
      # an unrecognised value must not mint a new atom. String.to_existing_atom
      # raises iff no atom was created — which is the assertion that would fail
      # had the implementation reached for String.to_atom/1.
      value = "no_such_view_#{System.unique_integer([:positive])}"

      assert KanbanWeb.API.TaskController.view_for(%{"response_view" => value}) == :full
      assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
    end

    test "a request carrying response_view=slim behaves exactly as today", %{
      conn: conn,
      column: column
    } do
      created =
        post(conn, ~p"/api/tasks", task: %{"title" => "View gate task", "column_id" => column.id})

      id = json_response(created, 201)["data"]["id"]

      full = json_response(get(conn, ~p"/api/tasks/#{id}"), 200)
      slim = json_response(get(conn, ~p"/api/tasks/#{id}?response_view=slim"), 200)

      # No endpoint consumes the resolution yet, so the gate is inert.
      assert slim == full
    end

    test "the param is inert on an endpoint that does not consume it", %{
      conn: conn,
      column: column
    } do
      without = json_response(get(conn, ~p"/api/tasks"), 200)

      created =
        post(conn, ~p"/api/tasks?response_view=slim",
          task: %{"title" => "Inert param task", "column_id" => column.id}
        )

      body = json_response(created, 201)["data"]

      # The create response is unchanged by the param ...
      assert body["title"] == "Inert param task"
      assert Map.has_key?(body, "acceptance_criteria")
      assert Map.has_key?(body, "key_files")

      # ... and the index never gains or loses a row because of the param.
      # As of W2057 the index DOES consume it — it changes each row's shape —
      # but shape is all it may change. Row shape is covered by the
      # "GET /api/tasks" describe above.
      with_param = json_response(get(conn, ~p"/api/tasks?response_view=slim"), 200)
      assert length(with_param["data"]) == length(without["data"]) + 1
    end
  end
end
