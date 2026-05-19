defmodule KanbanWeb.API.TaskJSONTest do
  @moduledoc """
  Round-trip tests asserting `reviewer_result` is persisted and serialized
  verbatim — including the W688/W689 structured fields and arbitrary
  unknown forward-compatible fields.

  The `reviewer_result` field is `:map` on `Kanban.Tasks.Task`, cast as
  a JSON blob, rendered by `KanbanWeb.API.TaskJSON` without allowlisting,
  and `KanbanWeb.API.CompletionResultGate` runs the validator without
  mutating the payload. These tests guard against any regression that
  would narrow that contract.
  """

  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks

  @moduletag capture_log: true

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Test Token",
        "agent_capabilities" => ["code_generation", "testing"]
      })

    column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token}")

    %{conn: conn, column: column}
  end

  defp structured_reviewer_result do
    %{
      "dispatched" => true,
      "summary" => "Reviewed the diff against all acceptance criteria and pitfalls.",
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 2,
      "issues_found" => 1,
      "schema_version" => "1.0",
      "status" => "changes_requested",
      "issue_counts" => %{"critical" => 0, "important" => 1, "minor" => 0},
      "issues" => [
        %{
          "severity" => "important",
          "category" => "pattern",
          "file" => "lib/foo.ex",
          "line" => 42,
          "description" => "Deviation from documented pattern",
          "suggested_fix" => "Mirror the existing handler shape."
        }
      ],
      "acceptance_criteria" => [
        %{"criterion" => "Criterion A", "status" => "met", "evidence" => "test/foo_test.exs"},
        %{"criterion" => "Criterion B", "status" => "not_met"}
      ],
      "testing_strategy" => %{
        "status" => "passed",
        "notes" => "All required test cases present."
      },
      "patterns" => %{"status" => "passed"},
      "pitfalls" => %{"status" => "failed", "notes" => "One pitfall violated."}
    }
  end

  describe "reviewer_result round trip via API JSON" do
    test "structured payload survives create + GET unchanged", %{conn: conn, column: column} do
      payload = structured_reviewer_result()

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with structured reviewer result",
          "reviewer_result" => payload
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["reviewer_result"] == payload
    end

    test "unknown forward-compatible fields survive the round trip",
         %{conn: conn, column: column} do
      payload =
        structured_reviewer_result()
        |> Map.put("future_field", "some value")
        |> Map.put("nested_future", %{
          "another_key" => [1, 2, 3],
          "deeper" => %{"and_deeper" => true}
        })
        |> update_in(["issues", Access.at(0)], &Map.put(&1, "future_per_issue_field", :something))

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with future fields",
          "reviewer_result" => payload
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      # Atom values become strings after JSON round-trip; we compare
      # everything else byte-equivalent. The :something atom in the
      # original payload is normalized to "something" in the response.
      assert response["reviewer_result"]["future_field"] == "some value"

      assert response["reviewer_result"]["nested_future"] == %{
               "another_key" => [1, 2, 3],
               "deeper" => %{"and_deeper" => true}
             }

      first_issue = hd(response["reviewer_result"]["issues"])
      assert first_issue["future_per_issue_field"] == "something"
      assert first_issue["severity"] == "important"
      assert first_issue["category"] == "pattern"
    end

    test "empty arrays in structured fields survive the round trip",
         %{conn: conn, column: column} do
      payload =
        structured_reviewer_result()
        |> Map.put("issues", [])
        |> Map.put("acceptance_criteria", [])

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with empty arrays",
          "reviewer_result" => payload
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["reviewer_result"]["issues"] == []
      assert response["reviewer_result"]["acceptance_criteria"] == []
    end

    test "legacy reviewer_result (no structured fields) still round-trips",
         %{conn: conn, column: column} do
      legacy = %{
        "dispatched" => true,
        "summary" => "Reviewed the diff against acceptance criteria and pitfalls.",
        "duration_ms" => 8_000,
        "acceptance_criteria_checked" => 5,
        "issues_found" => 0
      }

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with legacy reviewer result",
          "reviewer_result" => legacy
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["reviewer_result"] == legacy
    end
  end

  describe "reviewer_result persistence at the schema layer" do
    test "Task schema accepts and reloads structured reviewer_result identically",
         %{column: column} do
      payload = structured_reviewer_result()

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task for schema round trip",
          "reviewer_result" => payload
        })

      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, task.id)

      assert reloaded.reviewer_result == payload
    end
  end
end
