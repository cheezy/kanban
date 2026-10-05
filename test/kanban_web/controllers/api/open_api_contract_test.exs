defmodule KanbanWeb.API.OpenApiContractTest do
  @moduledoc """
  Keeps `priv/openapi/stride-api.json` honest (W2225).

  The router is the source of truth: every `/api` route and verb must be
  documented, nothing may be documented that is not routed, every route
  behind the authenticated `:api` pipeline must require `bearerAuth`, and the
  schemas must carry exactly the keys `KanbanWeb.API.TaskJSON` renders.

  When this test fails after you added a route, add the operation to the spec
  — see docs/api/get_openapi_json.md, "Adding a new /api route".
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.ApiTokens
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.OpenApiSpec
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskJSON

  @http_methods ~w(get put post delete patch head options trace)
  @spec_file "priv/openapi/stride-api.json"

  setup_all do
    raw = File.read!(OpenApiSpec.path())
    %{raw: raw, spec: Jason.decode!(raw)}
  end

  defp api_routes do
    for %{path: "/api" <> _ = path, verb: verb} <- KanbanWeb.Router.__routes__() do
      {verb, path}
    end
  end

  defp to_spec_path(router_path), do: String.replace(router_path, ~r/:(\w+)/, "{\\1}")

  defp spec_operations(spec) do
    for {path, item} <- spec["paths"], {method, op} <- item, method in @http_methods do
      {method, path, op}
    end
  end

  defp resolve(spec, %{"$ref" => "#/" <> pointer}) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while(spec, fn
      key, %{} = node when is_map_key(node, key) -> {:cont, Map.fetch!(node, key)}
      _key, _node -> {:halt, :unresolved}
    end)
  end

  defp resolve(_spec, node), do: node

  defp collect_refs(%{} = node) do
    own = if is_binary(node["$ref"]), do: [node["$ref"]], else: []
    own ++ (node |> Map.values() |> Enum.flat_map(&collect_refs/1))
  end

  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_), do: []

  defp operation_parameters(spec, path, op) do
    path_level = get_in(spec, ["paths", path, "parameters"]) || []
    Enum.map(path_level ++ (op["parameters"] || []), &resolve(spec, &1))
  end

  defp schema_keys(spec, name) do
    spec |> get_in(["components", "schemas", name, "properties"]) |> Map.keys() |> MapSet.new()
  end

  defp success_code?(code), do: code =~ ~r/^2(\d\d|XX)$/

  defp ecto_enum(field), do: Task |> Ecto.Enum.values(field) |> Enum.map(&Atom.to_string/1)

  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_map(value), do: "object"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(_value), do: "other"

  defp rendered_keys(map), do: map |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

  describe "document header" do
    test "declares OpenAPI 3.1.x", %{spec: spec} do
      assert spec["openapi"] =~ ~r/^3\.1\.\d+$/
    end

    test "declares a bearerAuth http security scheme", %{spec: spec} do
      assert %{"type" => "http", "scheme" => "bearer"} =
               get_in(spec, ["components", "securitySchemes", "bearerAuth"])
    end
  end

  describe "router contract" do
    test "every /api router route and verb is documented", %{spec: spec} do
      documented = MapSet.new(for {method, path, _} <- spec_operations(spec), do: {method, path})

      missing =
        for {verb, router_path} <- api_routes(),
            spec_path = to_spec_path(router_path),
            not MapSet.member?(documented, {Atom.to_string(verb), spec_path}) do
          "#{verb |> Atom.to_string() |> String.upcase()} #{spec_path} " <>
            "(router: #{router_path}) is missing from #{@spec_file}"
        end

      assert missing == [],
             "Undocumented /api routes — add an operation for each " <>
               "(see docs/api/get_openapi_json.md):\n" <> Enum.join(missing, "\n")
    end

    test "every documented operation is routed", %{spec: spec} do
      routed =
        MapSet.new(
          for {verb, path} <- api_routes(), do: {Atom.to_string(verb), to_spec_path(path)}
        )

      extra =
        for {method, path, _} <- spec_operations(spec),
            not MapSet.member?(routed, {method, path}) do
          "#{String.upcase(method)} #{path}"
        end

      assert extra == [], "Documented but not routed:\n" <> Enum.join(extra, "\n")
    end

    test "authenticated routes require bearerAuth and public routes declare none", %{spec: spec} do
      failures =
        for {verb, router_path} <- api_routes(),
            failure = security_failure(spec, verb, router_path),
            do: failure

      assert failures == [], Enum.join(failures, "\n")
    end
  end

  defp security_failure(spec, verb, router_path) do
    method = Atom.to_string(verb)
    spec_path = to_spec_path(router_path)
    op = get_in(spec, ["paths", spec_path, method]) || %{}
    label = "#{String.upcase(method)} #{spec_path}"

    check_security(route_pipelines(method, router_path), op, spec["security"], label)
  end

  # Router-derived classification: route_info/4 exposes the pipe_through list
  # that __routes__/0 does not. The route must resolve to itself, so a
  # shadowing literal route can never be classified by its neighbour.
  defp route_pipelines(method, router_path) do
    concrete = String.replace(router_path, ~r/:\w+/, "1")

    case Phoenix.Router.route_info(KanbanWeb.Router, String.upcase(method), concrete, "localhost") do
      %{route: ^router_path, pipe_through: pipes} -> pipes
      _ -> :unresolved
    end
  end

  defp check_security(:unresolved, _op, _default, label),
    do: "#{label} did not resolve to itself via route_info"

  defp check_security(pipes, op, default_security, label) do
    cond do
      :api in pipes ->
        effective = Map.get(op, "security", default_security) || []

        unless %{"bearerAuth" => []} in effective,
          do: "#{label} is authenticated but does not require bearerAuth"

      :api_public in pipes ->
        unless op["security"] == [],
          do: "#{label} is public but does not declare security: []"

      true ->
        "classify pipeline #{inspect(pipes)} for #{label} in the contract test"
    end
  end

  describe "document integrity" do
    test "every $ref resolves to a defined component", %{spec: spec} do
      unresolved =
        spec
        |> collect_refs()
        |> Enum.uniq()
        |> Enum.reject(fn ref ->
          String.starts_with?(ref, "#/") and resolve(spec, %{"$ref" => ref}) != :unresolved
        end)

      assert unresolved == [], "Unresolved $refs:\n" <> Enum.join(unresolved, "\n")
    end

    test "operationIds are unique", %{spec: spec} do
      ids = for {_, _, op} <- spec_operations(spec), do: op["operationId"]

      refute nil in ids, "every operation needs an operationId"
      assert ids -- Enum.uniq(ids) == []
    end

    test "every operation has at least one 2xx response", %{spec: spec} do
      without_2xx =
        for {method, path, op} <- spec_operations(spec),
            not (op |> Map.get("responses", %{}) |> Map.keys() |> Enum.any?(&success_code?/1)) do
          "#{String.upcase(method)} #{path}"
        end

      assert without_2xx == []
    end

    # D351: every /api route sits behind `plug :accepts, ["json"]`, so every
    # operation can return 406 and must say so through the shared component.
    test "every operation documents a 406 response", %{spec: spec} do
      expected = %{"$ref" => "#/components/responses/NotAcceptable"}

      missing =
        for {method, path, op} <- spec_operations(spec),
            get_in(op, ["responses", "406"]) != expected do
          "#{String.upcase(method)} #{path}"
        end

      assert missing == [],
             "Operations without a 406 $ref to NotAcceptable:\n" <> Enum.join(missing, "\n")

      assert %{"content" => %{"application/json" => %{"schema" => schema}}} =
               resolve(spec, expected)

      assert schema == %{"$ref" => "#/components/schemas/Error"}
    end

    test "the NotAcceptable example matches what ErrorJSON renders for a 406", %{spec: spec} do
      example =
        get_in(spec, ~w(components responses NotAcceptable content application/json example))

      conn = Phoenix.ConnTest.build_conn(:get, "/api/openapi.json")

      rendered =
        "406.json"
        |> KanbanWeb.ErrorJSON.render(%{conn: conn})
        |> Jason.encode!()
        |> Jason.decode!()

      assert example == rendered
    end

    test "every path template variable has a required path parameter", %{spec: spec} do
      missing =
        for {method, path, op} <- spec_operations(spec),
            [_, name] <- Regex.scan(~r/\{(\w+)\}/, path),
            params = operation_parameters(spec, path, op),
            not Enum.any?(
              params,
              &match?(%{"name" => ^name, "in" => "path", "required" => true}, &1)
            ) do
          "#{String.upcase(method)} #{path} is missing path parameter #{name}"
        end

      assert missing == []
    end

    test "GET /api/tasks documents every pagination and filter parameter", %{spec: spec} do
      op = get_in(spec, ["paths", "/api/tasks", "get"])

      names =
        spec |> operation_parameters("/api/tasks", op) |> Enum.map(& &1["name"]) |> MapSet.new()

      expected =
        ~w(limit cursor status type priority assigned_to_id parent updated_since column_id response_view)

      missing = expected |> MapSet.new() |> MapSet.difference(names) |> MapSet.to_list()

      assert missing == [], "GET /api/tasks is missing parameters: #{inspect(missing)}"
    end

    # D352: an unrecognised task type is a 422 on both create operations, and
    # the spec says which values are accepted.
    test "createTask and batchCreateGoals declare a 422 response for an invalid type", %{
      spec: spec
    } do
      ops = for {_, _, op} <- spec_operations(spec), into: %{}, do: {op["operationId"], op}

      for id <- ~w(createTask batchCreateGoals) do
        op = Map.fetch!(ops, id)
        response = resolve(spec, op["responses"]["422"] || %{})

        assert is_map(response) and is_binary(response["description"]),
               "#{id} must declare a 422 response"

        assert get_in(response, ["content", "application/json", "schema"]),
               "#{id}'s 422 must declare a JSON schema"

        for value <- ecto_enum(:type) do
          assert op["description"] =~ "`#{value}`",
                 "#{id}'s description must list the accepted type #{value}"
        end
      end
    end

    test "createTask's invalid-type 422 example matches what TaskJSON.error/1 renders", %{
      spec: spec
    } do
      example =
        get_in(spec, [
          "paths",
          "/api/tasks",
          "post",
          "responses",
          "422",
          "content",
          "application/json",
          "examples",
          "invalidType",
          "value"
        ])

      rendered =
        %Task{}
        |> Task.api_create_changeset(%{"title" => "t", "position" => 0, "type" => "bug"})
        |> then(&TaskJSON.error(%{changeset: &1}))
        |> Jason.encode!()
        |> Jason.decode!()

      assert example["errors"] == rendered["errors"]
    end
  end

  describe "WIP limit 422 example (D356)" do
    test "createTask's WIP 422 example matches what TaskErrors renders", %{spec: spec} do
      example =
        get_in(spec, [
          "paths",
          "/api/tasks",
          "post",
          "responses",
          "422",
          "content",
          "application/json",
          "examples",
          "wipLimitReached",
          "value"
        ])

      rendered =
        Plug.Test.conn(:get, "/")
        |> TaskErrors.handle_task_error({:error, :wip_limit_reached})

      assert rendered.status == 422
      assert example == Jason.decode!(rendered.resp_body)
    end

    test "createTask documents the WIP rejection and batch says it is not WIP-checked",
         %{spec: spec} do
      create = get_in(spec, ~w(paths /api/tasks post))
      batch = get_in(spec, ~w(paths /api/tasks/batch post))

      assert create["description"] =~ "WIP limit"
      assert create["responses"]["422"]["description"] =~ "WIP limit"
      assert batch["description"] =~ "does not check column WIP limits"
    end
  end

  describe "nested-goal 422 examples (D354)" do
    test "spec does not allow goal as a child type", %{spec: spec} do
      [summary, narrowing] =
        get_in(spec, ~w(components schemas GoalCreated properties child_tasks items allOf))

      assert summary == %{"$ref" => "#/components/schemas/TaskSummary"}
      assert narrowing["properties"]["type"]["enum"] == ["work", "defect"]

      for path <- ["/api/tasks", "/api/tasks/batch"] do
        description = get_in(spec, ["paths", path, "post", "description"])

        assert description =~ "a goal cannot contain another goal", path
        refute description =~ "child task `type` must be exactly `work`, `defect` or `goal`", path
      end
    end

    test "both creation operations show the message the server returns for a child goal",
         %{spec: spec} do
      message = Kanban.Tasks.Task.HierarchyValidations.nested_goal_message()

      for {path, errors_key} <- [{"/api/tasks", "errors"}, {"/api/tasks/batch", "details"}] do
        example =
          get_in(spec, [
            "paths",
            path,
            "post",
            "responses",
            "422",
            "content",
            "application/json",
            "examples",
            "nestedGoal",
            "value"
          ])

        assert example[errors_key] == %{"type" => [message]}, "#{path} nestedGoal example"
      end
    end
  end

  describe "public document hygiene" do
    test "contains no token-shaped strings or internal hostnames", %{raw: raw} do
      refute raw =~ ~r/stride_[A-Za-z0-9]/
      refute raw =~ "localhost"
      refute raw =~ "127.0.0.1"
      refute raw =~ "fly.dev"
      refute raw =~ ".internal"
    end

    test "servers are relative", %{spec: spec} do
      assert Enum.map(spec["servers"], & &1["url"]) == ["/"]
    end
  end

  describe "schema parity with TaskJSON" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{task: task_fixture(column)}
    end

    test "Task lists exactly the keys of the full task render", %{spec: spec, task: task} do
      assert rendered_keys(TaskJSON.show(%{task: task}).data) == schema_keys(spec, "Task")
    end

    test "TaskSummary lists exactly the keys of render_task_summary/1", %{spec: spec, task: task} do
      assert rendered_keys(TaskJSON.render_task_summary(task)) == schema_keys(spec, "TaskSummary")
    end

    test "TaskAck lists exactly the keys of the ack view", %{spec: spec, task: task} do
      assert rendered_keys(TaskJSON.ack(%{task: task}).data) == schema_keys(spec, "TaskAck")
    end

    test "GoalSummary lists exactly the keys of render_goal_with_children/1", %{
      spec: spec,
      task: task
    } do
      rendered = KanbanWeb.API.TaskController.render_goal_with_children(task)
      assert rendered_keys(rendered) == schema_keys(spec, "GoalSummary")
    end

    test "PageMeta lists exactly the keys of a real paginated index meta", %{
      conn: conn,
      spec: spec
    } do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, {_token, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "OpenAPI contract"})

      body =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer " <> plain_token)
        |> get(~p"/api/tasks?limit=1")
        |> json_response(200)

      assert rendered_keys(body["meta"]) == schema_keys(spec, "PageMeta")
    end

    test "every task enum matches the Ecto schema", %{spec: spec} do
      schemas = get_in(spec, ["components", "schemas"])
      parameters = get_in(spec, ["components", "parameters"])

      sites = [
        {schemas["Task"]["properties"], [:status, :type, :priority, :complexity]},
        {schemas["TaskSummary"]["properties"], [:status, :type, :priority, :complexity]},
        {schemas["TaskAck"]["properties"], [:status, :priority, :complexity]},
        {schemas["GoalSummary"]["properties"], [:status, :type, :priority, :complexity]},
        {%{
           "status" => parameters["Status"]["schema"],
           "type" => parameters["Type"]["schema"],
           "priority" => parameters["Priority"]["schema"]
         }, [:status, :type, :priority]}
      ]

      drifted =
        for {props, fields} <- sites,
            field <- fields,
            props[Atom.to_string(field)]["enum"] != ecto_enum(field),
            do: field

      assert drifted == [], "enums drifted from Kanban.Tasks.Task: #{inspect(drifted)}"
    end

    test "ValidationError accepts the body TaskJSON.error/1 renders for an invalid embed", %{
      spec: spec
    } do
      changeset =
        Task.changeset(%Task{}, %{
          "title" => "",
          "key_files" => [%{"note" => "missing file_path and position"}]
        })

      body =
        changeset |> then(&TaskJSON.error(%{changeset: &1})) |> Jason.encode!() |> Jason.decode!()

      item_schemas =
        get_in(
          spec,
          ~w(components schemas ValidationError properties errors additionalProperties items anyOf)
        )

      allowed = MapSet.new(item_schemas, & &1["type"])

      assert is_list(body["errors"]["key_files"]), "expected an embed failure in the fixture"

      wrong =
        for {field, values} <- body["errors"],
            value <- values,
            json_type(value) not in allowed,
            do: {field, json_type(value)}

      assert wrong == [], "ValidationError.errors items do not allow: #{inspect(wrong)}"
    end
  end
end
