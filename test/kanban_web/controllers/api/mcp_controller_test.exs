defmodule KanbanWeb.API.McpControllerTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks

  @moduletag capture_log: true

  @content_type_error "Content-Type must be application/json"

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {token_struct, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "MCP Token",
        "agent_capabilities" => ["code_generation", "testing"]
      })

    columns = Columns.list_columns(board)

    %{
      conn: authed(conn, plain_token),
      user: user,
      board: board,
      token: plain_token,
      token_struct: token_struct,
      ready_column: Enum.find(columns, &(&1.name == "Ready")),
      doing_column: Enum.find(columns, &(&1.name == "Doing")),
      review_column: Enum.find(columns, &(&1.name == "Review"))
    }
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp post_mcp(conn, body) when is_binary(body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp", body)
  end

  defp post_mcp(conn, body), do: post_mcp(conn, Jason.encode!(body))

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    post_mcp(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  # Calls a tool and returns {isError, decoded text body}.
  defp call_tool(conn, name, args) do
    result =
      conn
      |> rpc("tools/call", %{"name" => name, "arguments" => args})
      |> json_response(200)
      |> Map.fetch!("result")

    [%{"type" => "text", "text" => text}] = result["content"]
    {result["isError"], Jason.decode!(text)}
  end

  defp hook_result(output),
    do: %{"exit_code" => 0, "output" => output, "duration_ms" => 100}

  defp valid_reviewer_result do
    %{
      "dispatched" => true,
      "summary" => "Reviewed the diff against all acceptance criteria and pitfalls",
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 1,
      "issues_found" => 0,
      "status" => "approved",
      "issue_counts" => %{"critical" => 0, "important" => 0, "minor" => 0},
      "issues" => [],
      "acceptance_criteria" => [%{"criterion" => "It works", "status" => "met"}],
      "project_checks" => [%{"check" => "check 1", "status" => "met"}],
      "testing_strategy" => %{"status" => "passed"},
      "patterns" => %{"status" => "passed"},
      "pitfalls" => %{"status" => "passed"},
      "security_considerations" => %{"status" => "passed"},
      "schema_version" => "1.0"
    }
  end

  defp completion_args(id) do
    %{
      "id" => id,
      "agent_name" => "MCP Agent",
      "completion_summary" => "Implemented the change and verified it.",
      "actual_complexity" => "small",
      "actual_files_changed" => "lib/a.ex",
      "time_spent_minutes" => 10,
      "after_doing_result" => hook_result("tests passed"),
      "before_review_result" => hook_result("pr created"),
      "explorer_result" => %{
        "dispatched" => true,
        "summary" => "Explored the 3 key files and identified the existing pattern to mirror",
        "duration_ms" => 12_000
      },
      "reviewer_result" => valid_reviewer_result()
    }
  end

  defp ready_task(ready_column, user, title \\ "MCP task") do
    {:ok, task} =
      Tasks.create_task(ready_column, %{
        "title" => title,
        "status" => "open",
        "created_by_id" => user.id
      })

    task
  end

  defp sized_task(ready_column, user, title, description_bytes) do
    {:ok, task} =
      Tasks.create_task(ready_column, %{
        "title" => title,
        "status" => "open",
        "created_by_id" => user.id,
        "description" => String.duplicate("x", description_bytes)
      })

    task
  end

  defp claimed_task(doing_column, user) do
    {:ok, task} =
      Tasks.create_task(doing_column, %{
        "title" => "Claimed task",
        "status" => "in_progress",
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "created_by_id" => user.id,
        "needs_review" => true
      })

    task
  end

  defp reader_conn(board, owner) do
    reader = user_fixture()
    {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)
    {:ok, {_t, token}} = ApiTokens.create_api_token(reader, board, %{"name" => "Reader"})
    {authed(build_conn(), token), reader}
  end

  # A token whose user holds no membership row on the board. Token creation
  # does not itself check membership, which is what lets this case exist.
  defp non_member_conn(board) do
    stranger = user_fixture()
    {:ok, {_t, token}} = ApiTokens.create_api_token(stranger, board, %{"name" => "Stranger"})
    authed(build_conn(), token)
  end

  describe "authentication" do
    test "a request without a token gets 401 before any JSON-RPC handling" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> rpc("initialize")

      body = json_response(conn, 401)
      refute Map.has_key?(body, "jsonrpc")
    end

    test "an invalid token gets 401" do
      conn = build_conn() |> authed("stride_dev_not_a_real_token") |> rpc("ping")
      assert json_response(conn, 401)
    end

    test "malformed JSON without a token is a 401, not a parse error" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post_mcp("{not json")

      refute conn |> json_response(401) |> Map.has_key?("jsonrpc")
    end

    test "a token revoked mid-session gets 401", %{conn: conn, token_struct: token_struct} do
      assert conn |> rpc("initialize") |> json_response(200)

      {:ok, _} = ApiTokens.revoke_api_token(token_struct)

      assert conn |> rpc("ping") |> json_response(401)
    end
  end

  describe "initialize and protocol methods" do
    test "initialize echoes a supported protocol version and advertises tools", %{conn: conn} do
      body =
        conn
        |> rpc("initialize", %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        })
        |> json_response(200)

      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2025-03-26"
      assert body["result"]["serverInfo"]["name"] == "stride"
      assert is_binary(body["result"]["serverInfo"]["version"])
      assert body["result"]["capabilities"]["tools"] == %{"listChanged" => false}
    end

    test "initialize offers the latest version for an unsupported one", %{conn: conn} do
      body = conn |> rpc("initialize", %{"protocolVersion" => "1999-01-01"}) |> json_response(200)
      assert body["result"]["protocolVersion"] == "2025-11-25"
    end

    test "the response is application/json even with no Accept header", %{token: token} do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> rpc("ping")

      assert json_response(conn, 200)["result"] == %{}
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "notifications/initialized is accepted with 202 and no body", %{conn: conn} do
      conn = post_mcp(conn, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert response(conn, 202) == ""
    end

    test "tools/list returns the six tools with JSON Schema inputs", %{conn: conn} do
      tools = conn |> rpc("tools/list") |> json_response(200) |> get_in(["result", "tools"])

      assert Enum.map(tools, & &1["name"]) == [
               "stride_next_task",
               "stride_claim_task",
               "stride_complete_task",
               "stride_get_task",
               "stride_list_tasks",
               "stride_add_comment"
             ]

      for tool <- tools do
        assert tool["inputSchema"]["type"] == "object"
        assert is_map(tool["inputSchema"]["properties"])
        assert is_binary(tool["description"])
      end
    end

    test "an unknown method is -32601 and never echoes the method name", %{conn: conn} do
      body = conn |> rpc("resources/list<script>") |> json_response(200)

      assert body["error"]["code"] == -32_601
      assert body["id"] == 1
      refute Jason.encode!(body) =~ "script"
    end

    test "malformed JSON is -32700 with a null id", %{conn: conn} do
      body = conn |> post_mcp(~s({"jsonrpc": "2.0", )) |> json_response(400)

      assert body == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_700, "message" => "Parse error"}
             }
    end

    test "a message that is not a JSON-RPC request is -32600", %{conn: conn} do
      for body <- [
            %{"id" => 1, "method" => "ping"},
            %{"jsonrpc" => "2.0", "id" => nil, "method" => "ping"},
            %{}
          ] do
        assert %{"error" => %{"code" => -32_600}} = conn |> post_mcp(body) |> json_response(400)
      end
    end

    test "a non-JSON content type is -32600, even one Plug.Parsers can decode", %{conn: conn} do
      for {content_type, body} <- [
            {"text/plain", "ping"},
            {"application/x-www-form-urlencoded", "jsonrpc=2.0&id=1&method=ping"}
          ] do
        conn =
          conn
          |> put_req_header("content-type", content_type)
          |> post(~p"/api/mcp", body)

        assert %{"error" => %{"code" => -32_600, "message" => @content_type_error}} =
                 json_response(conn, 400)
      end
    end

    test "a request with no Content-Type is -32600", %{conn: conn} do
      # nil params: Phoenix.ConnTest sends no body and no content-type header.
      conn = post(conn, ~p"/api/mcp")
      assert get_req_header(conn, "content-type") == []

      assert %{"error" => %{"code" => -32_600, "message" => @content_type_error}} =
               json_response(conn, 400)
    end

    test "a JSON content type with parameters is accepted", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "Application/JSON; charset=utf-8")
        |> post(~p"/api/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"ping"}))

      assert json_response(conn, 200)["result"] == %{}
    end

    test "tools/call with bad params is -32602", %{conn: conn} do
      body = conn |> rpc("tools/call", %{"arguments" => %{}}) |> json_response(200)
      assert body["error"]["code"] == -32_602

      body =
        conn
        |> rpc("tools/call", %{"name" => "stride_next_task", "arguments" => [1]})
        |> json_response(200)

      assert body["error"]["code"] == -32_602

      body =
        conn |> rpc("tools/call", %{"name" => "nope", "arguments" => %{}}) |> json_response(200)

      assert body["error"]["code"] == -32_602

      body =
        conn
        |> rpc("tools/call", %{"name" => "stride_get_task", "arguments" => %{"id" => true}})
        |> json_response(200)

      assert body["error"]["code"] == -32_602
      assert body["error"]["data"]["errors"] == ["arguments.id must be of type string or integer"]
    end
  end

  describe "batches" do
    test "responses are returned only for requests with ids", %{conn: conn} do
      body =
        conn
        |> post_mcp([
          %{"jsonrpc" => "2.0", "id" => "a", "method" => "ping"},
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "nope"}
        ])
        |> json_response(200)

      assert [%{"id" => "a", "result" => %{}}, %{"id" => 2, "error" => %{"code" => -32_601}}] =
               body
    end

    test "a batch of only notifications is 202 with no body", %{conn: conn} do
      conn =
        post_mcp(conn, [
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{}}
        ])

      assert response(conn, 202) == ""
    end

    test "an empty or oversized batch is -32600", %{conn: conn} do
      assert %{"error" => %{"code" => -32_600}} = conn |> post_mcp([]) |> json_response(400)

      batch = for i <- 1..51, do: %{"jsonrpc" => "2.0", "id" => i, "method" => "ping"}
      assert %{"error" => %{"code" => -32_600}} = conn |> post_mcp(batch) |> json_response(400)
    end
  end

  describe "transport rules" do
    test "an SSE probe (Accept: text/event-stream) gets the 405, not a 406", %{conn: conn} do
      for method <- [:get, :delete] do
        conn =
          conn
          |> put_req_header("accept", "text/event-stream")
          |> dispatch(@endpoint, method, ~p"/api/mcp", nil)

        assert json_response(conn, 405)["error"]["message"] == "Method not allowed"
      end
    end

    test "an SSE probe without a token still gets 401" do
      conn =
        build_conn()
        |> put_req_header("accept", "text/event-stream")
        |> get(~p"/api/mcp")

      assert json_response(conn, 401)
    end

    test "GET and DELETE answer 405 with Allow: POST", %{conn: conn} do
      for method <- [:get, :delete] do
        conn = dispatch(conn, @endpoint, method, ~p"/api/mcp", nil)
        assert json_response(conn, 405)["error"]["message"] == "Method not allowed"
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end

    test "a foreign or null Origin is refused with 403", %{conn: conn} do
      for origin <- ["https://evil.example", "null", "http://localhost:9999"] do
        body = conn |> put_req_header("origin", origin) |> rpc("ping") |> json_response(403)
        assert body["error"]["message"] == "Forbidden origin"
      end
    end

    test "the server's own Origin is allowed", %{conn: conn} do
      origin = KanbanWeb.Endpoint.struct_url() |> URI.to_string()
      assert conn |> put_req_header("origin", origin) |> rpc("ping") |> json_response(200)
    end

    test "an unsupported MCP-Protocol-Version header is a 400", %{conn: conn} do
      bad = conn |> put_req_header("mcp-protocol-version", "1999-01-01") |> rpc("ping")
      assert %{"error" => %{"code" => -32_600}} = json_response(bad, 400)

      good = conn |> put_req_header("mcp-protocol-version", "2025-06-18") |> rpc("ping")
      assert json_response(good, 200)["result"] == %{}

      for version <- ["2025-11-25", " 2025-03-26 "] do
        ok = conn |> put_req_header("mcp-protocol-version", version) |> rpc("ping")
        assert json_response(ok, 200)["result"] == %{}
      end
    end
  end

  describe "full flow over POST /api/mcp" do
    test "initialize, tools/list, next, claim, complete", %{
      conn: conn,
      user: user,
      board: board,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      assert conn |> rpc("initialize", %{"protocolVersion" => "2025-06-18"}) |> json_response(200)

      assert conn
             |> post_mcp(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
             |> response(202)

      assert conn |> rpc("tools/list") |> json_response(200)

      {false, next} = call_tool(conn, "stride_next_task", %{})
      assert next["data"]["id"] == task.id

      {false, claimed} =
        call_tool(conn, "stride_claim_task", %{
          "identifier" => task.identifier,
          "agent_name" => "MCP Agent",
          "before_doing_result" => hook_result("pulled")
        })

      assert claimed["data"]["status"] == "in_progress"
      assert claimed["data"]["assigned_to_id"] == user.id
      assert claimed["hook"]["name"] == "before_doing"

      {false, completed} =
        call_tool(conn, "stride_complete_task", completion_args(task.identifier))

      assert completed["data"]["id"] == task.id
      assert is_list(completed["hooks"])
      # The default is the compact ack, not the whole task.
      refute Map.has_key?(completed["data"], "description")

      stored = Tasks.get_task!(task.id)
      # needs_review is false, so the completion goes straight to Done.
      done = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Done"))
      assert stored.column_id == done.id
      assert stored.status == :completed
      assert stored.completed_by_agent == "MCP Agent"
    end
  end

  describe "parity with the REST endpoints" do
    test "an MCP claim leaves the same task state as a REST claim", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      mcp_task = ready_task(ready_column, user, "Via MCP")
      rest_task = ready_task(ready_column, user, "Via REST")

      {false, _} =
        call_tool(conn, "stride_claim_task", %{
          "identifier" => mcp_task.identifier,
          "agent_name" => "Agent",
          "before_doing_result" => hook_result("ok")
        })

      conn
      |> post(~p"/api/tasks/claim", %{
        "identifier" => rest_task.identifier,
        "agent_name" => "Agent",
        "before_doing_result" => hook_result("ok")
      })
      |> json_response(200)

      fields = ~w(status column_id assigned_to_id created_by_agent completed_by_agent)

      [mcp, rest] =
        for task <- [mcp_task, rest_task] do
          conn
          |> get(~p"/api/tasks/#{task.id}")
          |> json_response(200)
          |> Map.fetch!("data")
          |> Map.take(fields)
        end

      assert mcp == rest
      assert mcp["status"] == "in_progress"
    end

    test "claim and complete reject what REST rejects, with the same body", %{
      conn: conn,
      user: user,
      doing_column: doing_column
    } do
      task = claimed_task(doing_column, user)

      bad =
        task.id
        |> completion_args()
        |> Map.put("after_doing_result", %{
          "exit_code" => 1,
          "output" => "fail",
          "duration_ms" => 1
        })

      {true, mcp_body} = call_tool(conn, "stride_complete_task", bad)

      rest_body =
        conn
        |> patch(~p"/api/tasks/#{task.id}/complete", Map.delete(bad, "id"))
        |> json_response(422)

      assert Map.drop(mcp_body, ["error_code", "http_status"]) == rest_body
      assert mcp_body["error_code"] == "hook_validation_failed"
      assert mcp_body["http_status"] == 422
      assert Tasks.get_task!(task.id).status == :in_progress

      {true, claim_body} =
        call_tool(conn, "stride_claim_task", %{"before_doing_result" => hook_result("ok")})

      assert claim_body["error_code"] == "no_tasks_available"
      assert claim_body["http_status"] == 409
    end

    test "stride_get_task returns the REST GET body", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      {false, body} = call_tool(conn, "stride_get_task", %{"id" => task.identifier})
      rest = conn |> get(~p"/api/tasks/#{task.identifier}") |> json_response(200)
      assert body == rest

      {false, by_id} = call_tool(conn, "stride_get_task", %{"id" => task.id})
      assert by_id == rest
    end

    test "stride_list_tasks filters by label like GET /api/tasks (W2239)", %{
      conn: conn,
      user: user,
      board: board,
      ready_column: ready_column
    } do
      bug = Kanban.LabelsFixtures.label_fixture(board, %{name: "Bug"})
      tagged = ready_task(ready_column, user, "Tagged")
      _other = ready_task(ready_column, user, "Untagged")

      {:ok, _} =
        user
        |> Kanban.Accounts.Scope.for_user()
        |> Kanban.Labels.set_task_labels(tagged, [bug.id])

      {false, page} = call_tool(conn, "stride_list_tasks", %{"label" => "bug"})

      rest =
        conn |> get(~p"/api/tasks?label=bug&limit=50&response_view=slim") |> json_response(200)

      assert page == rest
      assert Enum.map(page["data"], & &1["id"]) == [tagged.id]

      {false, none} = call_tool(conn, "stride_list_tasks", %{"label" => "Nope"})
      assert none["data"] == []
    end

    test "stride_list_tasks pages like GET /api/tasks and returns next_cursor", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      for i <- 1..3, do: ready_task(ready_column, user, "Task #{i}")

      {false, page} = call_tool(conn, "stride_list_tasks", %{"limit" => 2, "status" => "open"})

      rest =
        conn
        |> get(~p"/api/tasks?limit=2&status=open&response_view=slim")
        |> json_response(200)

      assert page == rest
      assert length(page["data"]) == 2
      assert is_binary(page["meta"]["next_cursor"])

      {false, page2} =
        call_tool(conn, "stride_list_tasks", %{
          "limit" => 2,
          "cursor" => page["meta"]["next_cursor"]
        })

      assert length(page2["data"]) == 1
      assert page2["meta"]["next_cursor"] == nil
    end

    test "stride_list_tasks rejects a bad filter like REST", %{conn: conn} do
      {true, body} = call_tool(conn, "stride_list_tasks", %{"cursor" => "!!!"})
      assert body["error_code"] == "invalid_param"
      assert body["http_status"] == 400
    end

    test "stride_list_tasks full view over POST /api/mcp is cut by the byte budget", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      budget = KanbanWeb.MCP.Tools.full_view_byte_budget()

      tasks =
        for i <- 1..3, do: sized_task(ready_column, user, "Big #{i}", div(budget, 2) - 5_000)

      args = %{"response_view" => "full", "limit" => 200}

      {false, page} = call_tool(conn, "stride_list_tasks", args)

      assert page["meta"]["truncated"] == true
      assert length(page["data"]) == 2
      assert is_binary(page["meta"]["next_cursor"])

      {false, page2} =
        call_tool(conn, "stride_list_tasks", Map.put(args, "cursor", page["meta"]["next_cursor"]))

      assert page2["meta"] == %{"next_cursor" => nil, "limit" => 200, "truncated" => false}

      assert Enum.map(page["data"] ++ page2["data"], & &1["id"]) == Enum.map(tasks, & &1.id)
    end

    test "GET /api/tasks in full view is not truncated by the MCP guard", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      budget = KanbanWeb.MCP.Tools.full_view_byte_budget()

      tasks =
        for i <- 1..3, do: sized_task(ready_column, user, "Big #{i}", div(budget, 2) - 5_000)

      rest = conn |> get(~p"/api/tasks?limit=200&response_view=full") |> json_response(200)

      assert Enum.map(rest["data"], & &1["id"]) == Enum.map(tasks, & &1.id)
      assert rest["meta"] == %{"next_cursor" => nil, "limit" => 200}
    end

    test "a full-view page under the budget is the REST full body plus truncated false", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      for i <- 1..3, do: ready_task(ready_column, user, "Task #{i}")

      {false, page} =
        call_tool(conn, "stride_list_tasks", %{"response_view" => "full", "limit" => 2})

      rest = conn |> get(~p"/api/tasks?limit=2&response_view=full") |> json_response(200)

      assert page == put_in(rest, ["meta", "truncated"], false)
    end

    test "a cross-board identifier is the same not-found as REST", %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = other_board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))
      other_task = ready_task(other_column, other_user)

      {true, body} = call_tool(conn, "stride_get_task", %{"id" => other_task.identifier})
      rest = conn |> get(~p"/api/tasks/#{other_task.identifier}") |> json_response(404)

      assert Map.drop(body, ["error_code", "http_status"]) == rest
      assert body["http_status"] == 404

      {true, comment} =
        call_tool(conn, "stride_add_comment", %{"id" => other_task.id, "content" => "hi"})

      assert comment["http_status"] == 404
    end
  end

  describe "read-only members" do
    test "cannot claim or complete, but can comment as themselves", %{
      board: board,
      user: owner,
      ready_column: ready_column,
      doing_column: doing_column
    } do
      {conn, reader} = reader_conn(board, owner)
      ready = ready_task(ready_column, owner)
      claimed = claimed_task(doing_column, owner)

      {true, claim} =
        call_tool(conn, "stride_claim_task", %{
          "identifier" => ready.identifier,
          "before_doing_result" => hook_result("ok")
        })

      assert claim["http_status"] == 403
      assert claim["error_code"] == "not_authorized_to_claim"

      {true, complete} = call_tool(conn, "stride_complete_task", completion_args(claimed.id))
      assert complete["http_status"] == 403
      assert complete["error_code"] == "not_authorized_to_complete"

      {false, comment} =
        call_tool(conn, "stride_add_comment", %{"id" => ready.id, "content" => "hi"})

      assert comment["data"]["task_id"] == ready.id

      assert Tasks.get_task!(ready.id).status == :open
      assert Tasks.get_task!(claimed.id).column_id == doing_column.id

      assert [%{content: "hi", author_user_id: author_id}] =
               Tasks.get_task_with_comments!(ready.id).comments

      assert author_id == reader.id
    end
  end

  describe "stride_add_comment" do
    test "adds a comment for a modify/owner member", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      {false, body} =
        call_tool(conn, "stride_add_comment", %{
          "id" => task.identifier,
          "content" => "Looks good"
        })

      assert body["data"]["task_id"] == task.id
      assert body["data"]["content"] == "Looks good"
      assert [%{content: "Looks good"}] = Tasks.get_task_with_comments!(task.id).comments
    end

    test "stores the token's user as the author", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      {false, _body} =
        call_tool(conn, "stride_add_comment", %{"id" => task.identifier, "content" => "Mine"})

      assert [%{author_user_id: author_id}] = Tasks.get_task_with_comments!(task.id).comments
      assert author_id == user.id
    end

    test "a token user with no board membership is refused with not_authorized", %{
      board: board,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      {true, body} =
        call_tool(non_member_conn(board), "stride_add_comment", %{
          "id" => task.identifier,
          "content" => "Let me in"
        })

      assert body["error_code"] == "not_authorized"
      assert body["http_status"] == 403
      assert Tasks.get_task_with_comments!(task.id).comments == []
    end

    test "attributes the comment to agent_name and returns the REST comment shape", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      {false, body} =
        call_tool(conn, "stride_add_comment", %{
          "id" => task.identifier,
          "content" => "Signed",
          "agent_name" => "MCP Agent"
        })

      assert body["data"]["author_agent_name"] == "MCP Agent"

      assert Map.keys(body["data"]) |> Enum.sort() ==
               ~w(author_agent_name author_name content edited_at id inserted_at mentioned_user_ids task_id updated_at)

      assert [%{author_agent_name: "MCP Agent"}] = Tasks.get_task_with_comments!(task.id).comments
    end

    test "without agent_name it resolves the same name a REST POST from the token does", %{
      conn: conn,
      token_struct: token_struct,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)
      ApiTokens.stamp_last_agent_name(token_struct, "Remembered")

      {false, mcp} =
        call_tool(conn, "stride_add_comment", %{"id" => task.identifier, "content" => "via MCP"})

      rest =
        conn
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/api/tasks/#{task.identifier}/comments",
          Jason.encode!(%{"content" => "via REST"})
        )
        |> json_response(201)

      assert mcp["data"]["author_agent_name"] == "Remembered"
      assert rest["data"]["author_agent_name"] == mcp["data"]["author_agent_name"]
    end

    test "the token's agent_model wins over agent_name, as over REST", %{
      board: board,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      {:ok, {_t, token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "Model", "agent_model" => "claude-x"})

      {false, body} =
        call_tool(authed(build_conn(), token), "stride_add_comment", %{
          "id" => task.identifier,
          "content" => "x",
          "agent_name" => "Param"
        })

      assert body["data"]["author_agent_name"] == "ai_agent:claude-x"
    end

    test "an agent_name over 255 characters is rejected by the schema", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      body =
        conn
        |> rpc("tools/call", %{
          "name" => "stride_add_comment",
          "arguments" => %{
            "id" => task.identifier,
            "content" => "x",
            "agent_name" => String.duplicate("a", 256)
          }
        })
        |> json_response(200)

      assert body["error"]["code"] == -32_602
      assert Tasks.get_task_with_comments!(task.id).comments == []
    end

    test "content with a NUL character is a validation error, not a crash", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      {true, body} =
        call_tool(conn, "stride_add_comment", %{"id" => task.identifier, "content" => "a\u0000b"})

      assert body["http_status"] == 422
      assert body["errors"]["content"] == ["is invalid"]
      assert Tasks.get_task_with_comments!(task.id).comments == []
    end

    test "tools/list advertises the optional agent_name argument", %{conn: conn} do
      tools = conn |> rpc("tools/list") |> json_response(200) |> get_in(["result", "tools"])
      schema = Enum.find(tools, &(&1["name"] == "stride_add_comment"))["inputSchema"]

      assert schema["properties"]["agent_name"]["maxLength"] == 255
      refute "agent_name" in schema["required"]
    end

    test "an empty comment is rejected by the schema", %{
      conn: conn,
      user: user,
      ready_column: ready_column
    } do
      task = ready_task(ready_column, user)

      body =
        conn
        |> rpc("tools/call", %{
          "name" => "stride_add_comment",
          "arguments" => %{"id" => task.id, "content" => ""}
        })
        |> json_response(200)

      assert body["error"]["code"] == -32_602
    end
  end
end
