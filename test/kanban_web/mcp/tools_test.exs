defmodule KanbanWeb.MCP.ToolsTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.OpenApiSpec
  alias KanbanWeb.MCP.Tools
  alias KanbanWeb.MCP.ToolSchemas

  @moduletag capture_log: true

  setup do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {api_token, _plain}} =
      ApiTokens.create_api_token(user, board, %{"name" => "Tools", "agent_capabilities" => []})

    conn =
      :post
      |> Phoenix.ConnTest.build_conn("/api/mcp")
      |> Plug.Conn.assign(:current_user, user)
      |> Plug.Conn.assign(:current_board, board)
      |> Plug.Conn.assign(:api_token, api_token)

    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))
    %{conn: conn, user: user, board: board, ready: ready}
  end

  defp spec, do: OpenApiSpec.path() |> File.read!() |> Jason.decode!()

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()

  defp text_body(%{content: [%{type: "text", text: text}]}), do: Jason.decode!(text)

  describe "definitions/0" do
    test "every tool has a name, description and an object inputSchema" do
      for tool <- Tools.definitions() do
        assert tool["name"] =~ ~r/^stride_[a-z_]+$/
        assert is_binary(tool["description"]) and tool["description"] != ""
        assert tool["inputSchema"]["type"] == "object"
        assert is_map(tool["inputSchema"]["properties"])

        for key <- Map.get(tool["inputSchema"], "required", []) do
          assert Map.has_key?(tool["inputSchema"]["properties"], key)
        end
      end
    end

    test "the definitions encode as JSON" do
      assert {:ok, _} = Jason.encode(Tools.definitions())
    end

    test "the list tool's arguments are the GET /api/tasks parameters" do
      spec = spec()

      rest_params =
        for %{"$ref" => "#/components/parameters/" <> name} <-
              spec["paths"]["/api/tasks"]["get"]["parameters"],
            do: spec["components"]["parameters"][name]["name"]

      list_args =
        ToolSchemas.fetch("stride_list_tasks")["inputSchema"]["properties"] |> Map.keys()

      assert Enum.sort(list_args) == Enum.sort(rest_params)
    end

    test "claim and complete arguments are the REST request-body properties" do
      spec = spec()

      claim_body =
        spec["paths"]["/api/tasks/claim"]["post"]["requestBody"]["content"]["application/json"][
          "schema"
        ]["properties"]

      complete_body =
        spec["paths"]["/api/tasks/{id}/complete"]["patch"]["requestBody"]["content"][
          "application/json"
        ]["schema"]["properties"]

      claim_args = ToolSchemas.fetch("stride_claim_task")["inputSchema"]["properties"]
      complete_args = ToolSchemas.fetch("stride_complete_task")["inputSchema"]["properties"]

      assert sorted_keys(claim_args) == sorted_keys(claim_body)
      assert sorted_keys(complete_args) -- ["id", "response_view"] == sorted_keys(complete_body)
    end

    test "the list filter enums match the Task schema" do
      props = ToolSchemas.fetch("stride_list_tasks")["inputSchema"]["properties"]

      assert props["status"]["enum"] == ["open", "in_progress", "completed", "blocked"]
      assert props["type"]["enum"] == ["work", "defect", "goal"]
      assert props["priority"]["enum"] == ["low", "medium", "high", "critical"]
    end

    test "stride_complete_task documents slim as its default view" do
      description =
        ToolSchemas.fetch("stride_complete_task")["inputSchema"]["properties"]["response_view"][
          "description"
        ]

      assert description =~ "slim (the default here)"
    end

    test "fetch/1 matches names as strings only" do
      assert ToolSchemas.fetch("stride_get_task")["name"] == "stride_get_task"
      assert ToolSchemas.fetch("nope") == nil
      assert ToolSchemas.fetch(:stride_get_task) == nil
    end
  end

  describe "call/3 argument validation" do
    test "an unknown tool", %{conn: conn} do
      assert Tools.call("stride_delete_everything", %{}, conn) == {:error, :unknown_tool}
    end

    test "a missing required argument", %{conn: conn} do
      assert {:error, {:invalid_params, ["arguments.id is required"]}} =
               Tools.call("stride_get_task", %{}, conn)
    end

    test "a wrong type and an unknown property on a closed schema", %{conn: conn} do
      assert {:error, {:invalid_params, messages}} =
               Tools.call("stride_list_tasks", %{"limit" => "10", "bogus" => 1}, conn)

      assert "arguments.limit must be of type integer" in messages
      assert Enum.any?(messages, &(&1 =~ "unknown property"))
    end

    test "out-of-range and bad enum values", %{conn: conn} do
      assert {:error, {:invalid_params, messages}} =
               Tools.call("stride_list_tasks", %{"limit" => 500, "status" => "done"}, conn)

      assert "arguments.limit must be at most 200" in messages
      assert Enum.any?(messages, &(&1 =~ "arguments.status must be one of"))
    end
  end

  describe "call/3 results" do
    test "integer ids are accepted and resolve like REST string ids", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})

      assert {:ok, %{isError: false} = result} =
               Tools.call("stride_get_task", %{"id" => task.id}, conn)

      assert text_body(result)["data"]["identifier"] == task.identifier
    end

    test "integral float arguments are used as integers", %{conn: conn, user: user, ready: ready} do
      for i <- 1..3,
          do:
            {:ok, _} = Tasks.create_task(ready, %{"title" => "T#{i}", "created_by_id" => user.id})

      assert {:ok, %{isError: false} = result} =
               Tools.call("stride_list_tasks", %{"limit" => 2.0}, conn)

      assert text_body(result)["meta"]["limit"] == 2
      assert length(text_body(result)["data"]) == 2
    end

    test "a domain failure is an isError result with the API error code", %{conn: conn} do
      assert {:ok, %{isError: true} = result} =
               Tools.call("stride_get_task", %{"id" => "W999999"}, conn)

      assert text_body(result) == %{
               "error" => "Task not found",
               "error_code" => "not_found",
               "http_status" => 404
             }
    end

    test "the list tool defaults to slim summaries", %{conn: conn, user: user, ready: ready} do
      {:ok, _} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})

      {:ok, result} = Tools.call("stride_list_tasks", %{}, conn)
      [row] = text_body(result)["data"]

      refute Map.has_key?(row, "description")
      assert Map.has_key?(text_body(result)["meta"], "next_cursor")

      {:ok, full} = Tools.call("stride_list_tasks", %{"response_view" => "full"}, conn)
      assert full |> text_body() |> Map.fetch!("data") |> hd() |> Map.has_key?("description")
    end

    test "next_task with nothing ready is an isError 404", %{conn: conn} do
      {:ok, result} = Tools.call("stride_next_task", %{}, conn)

      assert result.isError
      assert text_body(result)["error_code"] == "no_tasks_available"
      assert text_body(result)["http_status"] == 404
    end
  end

  describe "failure/1 and success/1" do
    test "failure merges error_code and http_status into the REST body" do
      result = Tools.failure(:not_authorized_write)

      assert result.isError
      body = text_body(result)
      assert body["error_code"] == "not_authorized_write"
      assert body["http_status"] == 403
      assert body["error"] =~ "write access"
    end

    test "success wraps the body as JSON text" do
      assert Tools.success(%{a: 1}) == %{
               content: [%{type: "text", text: ~s({"a":1})}],
               isError: false
             }
    end
  end
end
