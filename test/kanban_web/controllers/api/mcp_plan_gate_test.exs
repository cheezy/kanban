defmodule KanbanWeb.API.McpPlanGateTest do
  @moduledoc """
  `POST /api/mcp` while paid plans are enforced: a free board's token gets a
  JSON-RPC `plan_required` error for every request and no tool runs, while a
  paid board, enforcement off and the REST API are unaffected.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias KanbanWeb.MCP.JsonRpc

  @moduletag capture_log: true

  @refused [:kanban, :plan, :feature_refused]
  @mcp_stop [:kanban, :mcp, :request, :stop]
  @tool_called [:kanban, :api, :mcp_tool_called]
  @message "MCP is available to boards in an Organization. The REST API keeps working for this board."

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "MCP gate token",
        "agent_capabilities" => ["code_generation"]
      })

    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

    {:ok, task} =
      Tasks.create_task(ready, %{
        "title" => "Gate task",
        "status" => "open",
        "created_by_id" => user.id
      })

    conn =
      conn
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer #{plain_token}")

    %{conn: conn, board: board, task: task, token: plain_token}
  end

  defp make_paid(%Board{id: id}) do
    workspace = org_workspace_fixture(organization_fixture())

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    :ok
  end

  defp post_mcp(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp", Jason.encode!(body))
  end

  defp request(method, id, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp claim(task) do
    request("tools/call", 7, %{
      "name" => "stride_claim_task",
      "arguments" => %{
        "identifier" => task.identifier,
        "agent_name" => "Gate agent",
        "before_doing_result" => %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}
      }
    })
  end

  defp assert_plan_required(body, id) do
    assert body == %{
             "jsonrpc" => "2.0",
             "id" => id,
             "error" => %{
               "code" => JsonRpc.plan_required(),
               "message" => @message,
               "data" => %{"feature" => "mcp"}
             }
           }
  end

  defp mcp_outcome do
    assert_receive {:telemetry_event, @mcp_stop, %{duration: _}, metadata}
    Map.delete(metadata, :telemetry_span_context)
  end

  describe "a free board under enforcement" do
    setup :enforce_plans

    test "initialize, ping and tools/list each get the plan_required error", %{conn: conn} do
      for {method, id} <- [{"initialize", 1}, {"ping", "p"}, {"tools/list", 3}] do
        conn |> post_mcp(request(method, id)) |> json_response(200) |> assert_plan_required(id)
      end
    end

    test "tools/call runs no tool and leaves the task unclaimed", %{conn: conn, task: task} do
      attach_telemetry([@tool_called, @refused])

      conn |> post_mcp(claim(task)) |> json_response(200) |> assert_plan_required(7)

      assert Repo.get!(Task, task.id).status == :open
      refute_received {:telemetry_event, @tool_called, _, _}

      assert_received {:telemetry_event, @refused, %{count: 1}, %{feature: :mcp, surface: :mcp}}
    end

    test "the error never echoes the method or tool name the client sent", %{conn: conn} do
      raw =
        conn
        |> post_mcp(
          request("tools/call", 1, %{"name" => "<script>evil_tool</script>", "arguments" => %{}})
        )
        |> response(200)

      refute raw =~ "evil_tool"
      refute raw =~ "tools/call"

      unknown = conn |> post_mcp(request("x-injected-method", 2)) |> response(200)
      refute unknown =~ "x-injected-method"
    end

    test "a batch returns one error per request and nothing for notifications",
         %{conn: conn} do
      attach_telemetry(@refused)

      body =
        conn
        |> post_mcp([
          request("ping", "a"),
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          request("tools/list", 2),
          request("initialize", 3)
        ])
        |> json_response(200)

      assert [a, b, c] = body
      assert_plan_required(a, "a")
      assert_plan_required(b, 2)
      assert_plan_required(c, 3)

      for _ <- 1..3, do: assert_received({:telemetry_event, @refused, _, %{surface: :mcp}})
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "a payload of only notifications still gets 202 with no body", %{conn: conn} do
      conn = post_mcp(conn, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert response(conn, 202) == ""
    end

    test "each refused message is one span with outcome plan_required", %{conn: conn} do
      attach_telemetry(@mcp_stop)

      conn |> post_mcp([request("ping", 1), request("tools/list", 2)]) |> json_response(200)

      assert mcp_outcome() == %{method: :ping, outcome: :plan_required}
      assert mcp_outcome() == %{method: :tools_list, outcome: :plan_required}
    end

    test "malformed bodies and messages are still rejected before the plan check",
         %{conn: conn} do
      attach_telemetry(@refused)

      parse =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp", ~s({"jsonrpc": "2.0", ))
        |> json_response(400)

      assert parse["error"]["code"] == JsonRpc.parse_error()

      invalid = conn |> post_mcp(%{"jsonrpc" => "2.0", "id" => 1}) |> json_response(400)
      assert invalid["error"]["code"] == JsonRpc.invalid_request()
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "GET and DELETE still get 405", %{conn: conn} do
      assert conn |> get(~p"/api/mcp") |> response(405)
      assert conn |> delete(~p"/api/mcp") |> response(405)
    end

    test "an unauthenticated request gets 401 before any plan check" do
      attach_telemetry(@refused)

      body = "ping" |> request(1) |> Jason.encode!()

      conn =
        build_conn()
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp", body)

      assert response(conn, 401)
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "the REST API keeps working for the same token", %{conn: conn, task: task} do
      body = conn |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

      assert body["data"]["id"] == task.id
    end

    test "the next request works once the board moves into an Organization",
         %{conn: conn, board: board} do
      conn |> post_mcp(request("ping", 1)) |> json_response(200) |> assert_plan_required(1)

      :ok = make_paid(board)

      assert %{"id" => 1, "result" => %{}} =
               conn |> post_mcp(request("ping", 1)) |> json_response(200)
    end
  end

  describe "a paid board or no enforcement" do
    test "a paid board under enforcement runs tools as before", %{conn: conn} = ctx do
      enforce_plans()
      :ok = make_paid(ctx.board)
      attach_telemetry(@mcp_stop)

      body = conn |> post_mcp(claim(ctx.task)) |> json_response(200)

      refute body["result"]["isError"]
      assert Repo.get!(Task, ctx.task.id).status == :in_progress
      assert mcp_outcome() == %{method: :tools_call, outcome: :ok}
    end

    test "a free board without enforcement runs tools as before", %{conn: conn, task: task} do
      attach_telemetry(@refused)

      init = conn |> post_mcp(request("initialize", 1)) |> json_response(200)
      assert init["result"]["serverInfo"]

      body = conn |> post_mcp(claim(task)) |> json_response(200)
      refute body["result"]["isError"]
      refute_received {:telemetry_event, @refused, _, _}
    end
  end

  describe "discovery without a board" do
    setup :enforce_plans

    test "a workspace token's initialize and tools/list work under enforcement" do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)
      {:ok, {_, plain}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})
      attach_telemetry(@refused)

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain}")

      assert %{"result" => %{"serverInfo" => _}} =
               conn |> post_mcp(request("initialize", 1)) |> json_response(200)

      assert %{"result" => %{"tools" => [_ | _]}} =
               conn |> post_mcp(request("tools/list", 2)) |> json_response(200)

      refute_received {:telemetry_event, @refused, _, _}
    end

    test "a free board's token still gets plan_required, and a foreign selector still 400s",
         %{conn: conn, board: board} do
      conn |> post_mcp(request("tools/list", 1)) |> json_response(200) |> assert_plan_required(1)

      other = ai_optimized_board_fixture(user_fixture())

      assert %{"error" => "Board selector does not match token"} =
               conn
               |> put_req_header("x-stride-board", Integer.to_string(other.id))
               |> post_mcp(request("tools/list", 1))
               |> json_response(400)

      refute other.id == board.id
    end
  end
end
