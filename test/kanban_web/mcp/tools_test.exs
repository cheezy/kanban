defmodule KanbanWeb.MCP.ToolsTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.OpenApiSpec
  alias KanbanWeb.API.TaskListParams
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

  describe "stride_list_tasks full-view byte budget" do
    # Two of these rows fit the budget together; a third does not.
    defp half_budget, do: div(Tools.full_view_byte_budget(), 2) - 5_000

    defp sized_task(ready, user, title, description_bytes, attrs \\ %{}) do
      {:ok, task} =
        Tasks.create_task(
          ready,
          Map.merge(
            %{
              "title" => title,
              "created_by_id" => user.id,
              "description" => String.duplicate("x", description_bytes)
            },
            attrs
          )
        )

      task
    end

    defp list_full(conn, args \\ %{}) do
      {:ok, result} =
        Tools.call("stride_list_tasks", Map.put(args, "response_view", "full"), conn)

      refute result.isError
      text_body(result)
    end

    defp row_bytes(rows), do: rows |> Enum.map(&byte_size(Jason.encode!(&1))) |> Enum.sum()

    defp ids(page), do: Enum.map(page["data"], & &1["id"])

    # Follows meta.next_cursor (resending args) until it is null; returns the pages.
    defp page_through(conn, args, cursor \\ nil, pages \\ [], calls \\ 0)

    defp page_through(_conn, _args, _cursor, _pages, 10), do: flunk("paging did not finish")

    defp page_through(conn, args, cursor, pages, calls) do
      args = if cursor, do: Map.put(args, "cursor", cursor), else: args
      page = list_full(conn, args)

      case page["meta"]["next_cursor"] do
        nil -> Enum.reverse([page | pages])
        next -> page_through(conn, args, next, [page | pages], calls + 1)
      end
    end

    test "stride_list_tasks inputSchema documents the full view byte budget" do
      assert Tools.full_view_byte_budget() == 100_000

      tool = ToolSchemas.fetch("stride_list_tasks")
      props = tool["inputSchema"]["properties"]

      for description <- [
            tool["description"],
            props["limit"]["description"],
            props["response_view"]["description"]
          ] do
        assert description =~ "100,000"
        assert description =~ "meta.truncated"
      end

      assert props["cursor"]["description"] =~ "same filters"
      assert props["limit"]["maximum"] == 200
    end

    test "full view under the budget returns every task with truncated false", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      tasks = for i <- 1..3, do: sized_task(ready, user, "T#{i}", 100)

      page = list_full(conn, %{"limit" => 2})

      assert ids(page) == tasks |> Enum.take(2) |> Enum.map(& &1.id)
      assert page["meta"]["truncated"] == false
      assert page["meta"]["next_cursor"] == TaskListParams.encode_cursor(Enum.at(tasks, 1).id)
      assert page["meta"]["limit"] == 2
    end

    test "full view over the budget cuts the page and sets truncated true with a cursor at the last returned task",
         %{conn: conn, user: user, ready: ready} do
      [a, b, c] = for i <- 1..3, do: sized_task(ready, user, "Big #{i}", half_budget())

      page = list_full(conn, %{"limit" => 200})

      assert ids(page) == [a.id, b.id]
      assert row_bytes(page["data"]) <= Tools.full_view_byte_budget()
      assert page["meta"]["truncated"] == true
      # REST would call this the last page; the cut still leaves a real cursor.
      assert page["meta"]["next_cursor"] == TaskListParams.encode_cursor(b.id)

      rest = list_full(conn, %{"limit" => 200, "cursor" => page["meta"]["next_cursor"]})

      assert ids(rest) == [c.id]
      assert rest["meta"] == %{"next_cursor" => nil, "limit" => 200, "truncated" => false}
    end

    test "a single task larger than the budget is still returned alone", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      huge = sized_task(ready, user, "Huge", Tools.full_view_byte_budget() + 1_000)
      small = sized_task(ready, user, "Small", 10)

      page = list_full(conn)

      assert ids(page) == [huge.id]
      assert row_bytes(page["data"]) > Tools.full_view_byte_budget()
      assert page["meta"]["truncated"] == true
      assert page["meta"]["next_cursor"] == TaskListParams.encode_cursor(huge.id)

      rest = list_full(conn, %{"cursor" => page["meta"]["next_cursor"]})
      assert ids(rest) == [small.id]
      assert rest["meta"]["truncated"] == false
    end

    test "full view with limit 1 returns the one fetched task untruncated, even over the budget",
         %{conn: conn, user: user, ready: ready} do
      huge = sized_task(ready, user, "Huge", Tools.full_view_byte_budget() + 1_000)
      small = sized_task(ready, user, "Small", 10)

      page = list_full(conn, %{"limit" => 1})

      assert ids(page) == [huge.id]

      assert page["meta"] == %{
               "next_cursor" => TaskListParams.encode_cursor(huge.id),
               "limit" => 1,
               "truncated" => false
             }

      rest = list_full(conn, %{"limit" => 1, "cursor" => page["meta"]["next_cursor"]})
      assert ids(rest) == [small.id]
      assert rest["meta"] == %{"next_cursor" => nil, "limit" => 1, "truncated" => false}
    end

    test "a bad cursor in full view is still an invalid_param tool error", %{conn: conn} do
      {:ok, result} =
        Tools.call("stride_list_tasks", %{"response_view" => "full", "cursor" => "!!!"}, conn)

      assert result.isError
      body = text_body(result)
      assert body["error_code"] == "invalid_param"
      assert body["http_status"] == 400
      refute Map.has_key?(body, "meta")
    end

    test "full view on an empty board returns an empty page with truncated false", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      assert list_full(conn) == %{
               "data" => [],
               "meta" => %{"next_cursor" => nil, "limit" => 50, "truncated" => false}
             }

      task = sized_task(ready, user, "Only", 10)
      past_last = list_full(conn, %{"cursor" => TaskListParams.encode_cursor(task.id)})

      assert past_last["data"] == []
      assert past_last["meta"]["truncated"] == false
      assert past_last["meta"]["next_cursor"] == nil
    end

    test "paging a truncated full view with next_cursor returns every task exactly once", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      size = div(Tools.full_view_byte_budget(), 3) - 4_000
      work = for i <- 1..5, do: sized_task(ready, user, "Work #{i}", size)
      _defect = sized_task(ready, user, "Defect", size, %{"type" => "defect"})

      pages = page_through(conn, %{"type" => "work", "limit" => 200})

      assert length(pages) >= 2
      assert Enum.any?(pages, &(&1["meta"]["truncated"] == true))
      assert pages |> List.last() |> get_in(["meta", "truncated"]) == false

      for page <- pages do
        assert page["meta"] |> Map.keys() |> Enum.sort() == ["limit", "next_cursor", "truncated"]
        assert page["data"] != []
        assert row_bytes(page["data"]) <= Tools.full_view_byte_budget()
      end

      returned = Enum.flat_map(pages, &ids/1)
      assert returned == Enum.map(work, & &1.id)
      assert returned == Enum.uniq(returned)
    end

    test "slim view is never truncated and carries no truncated key", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      tasks = for i <- 1..3, do: sized_task(ready, user, "Big #{i}", half_budget())

      {:ok, result} = Tools.call("stride_list_tasks", %{"limit" => 200}, conn)
      body = text_body(result)

      assert Enum.map(body["data"], & &1["id"]) == Enum.map(tasks, & &1.id)
      assert body["meta"] == %{"next_cursor" => nil, "limit" => 200}
    end
  end

  describe "fit_page/2" do
    defp rows, do: for(id <- 1..3, do: %{id: id, text: String.duplicate("y", 20)})

    defp page(rows, next_cursor \\ nil),
      do: %{data: rows, meta: %{next_cursor: next_cursor, limit: 50}}

    defp size(row), do: row |> Jason.encode!() |> byte_size()

    test "a page that fits the budget exactly is not cut" do
      budget = rows() |> Enum.map(&size/1) |> Enum.sum()

      assert rows() |> page("abc") |> Tools.fit_page(budget) == %{
               data: rows(),
               meta: %{next_cursor: "abc", limit: 50, truncated: false}
             }
    end

    test "one byte over the budget drops the tail and points the cursor at the last kept row" do
      budget = rows() |> Enum.map(&size/1) |> Enum.sum()
      cut = rows() |> page() |> Tools.fit_page(budget - 1)

      assert Enum.map(cut.data, & &1.id) == [1, 2]

      assert cut.meta == %{
               next_cursor: TaskListParams.encode_cursor(2),
               limit: 50,
               truncated: true
             }
    end

    test "the first row is kept even when it alone exceeds the budget" do
      cut = rows() |> page("abc") |> Tools.fit_page(1)

      assert Enum.map(cut.data, & &1.id) == [1]
      assert cut.meta.truncated
      assert cut.meta.next_cursor == TaskListParams.encode_cursor(1)
    end

    test "an empty page stays empty and is not truncated" do
      assert [] |> page() |> Tools.fit_page(0) == %{
               data: [],
               meta: %{next_cursor: nil, limit: 50, truncated: false}
             }
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
