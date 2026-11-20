defmodule KanbanWeb.API.OpenApiContractTest do
  @moduledoc """
  Keeps `priv/openapi/stride-api.json` honest (W2225).

  The router is the source of truth: every `/api` route and verb, and every
  route behind the `:oauth` pipeline (`POST /oauth/token` and
  `POST /oauth/revoke`, W2746), must be documented, nothing may be documented
  that is not routed, every route behind the authenticated `:api` pipeline
  must require `bearerAuth` while `:api_public` and `:oauth` routes declare
  none, every route behind the `:device_api` pipeline (`/api/me/*`, W2747)
  must require exactly `deviceAuth` and nothing else, and the schemas must
  carry exactly the keys `KanbanWeb.API.TaskJSON` and
  `KanbanWeb.API.Me.MeJSON` render. The browser-scoped `/oauth/authorize` page is not part of the API.

  When this test fails after you added a route, add the operation to the spec
  — see docs/api/get_openapi_json.md, "Adding a new /api route".
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.Reviews.ApprovalChallenge
  alias Kanban.Reviews.DiffHighlighter
  alias Kanban.Reviews.MobileReview
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.Me
  alias KanbanWeb.API.Me.BoardJSON
  alias KanbanWeb.API.Me.DecisionJSON
  alias KanbanWeb.API.Me.DeviceJSON
  alias KanbanWeb.API.Me.FallbackController
  alias KanbanWeb.API.Me.MeJSON
  alias KanbanWeb.API.Me.NotificationSettingsController
  alias KanbanWeb.API.Me.NotificationSettingsJSON
  alias KanbanWeb.API.Me.ReviewJSON
  alias KanbanWeb.API.OpenApiSpec
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskJSON

  @http_methods ~w(get put post delete patch head options trace)
  @spec_file "priv/openapi/stride-api.json"

  # W2231: routed only so that they can answer 405 Method Not Allowed.
  @method_not_allowed_only [{"get", "/api/mcp"}, {"delete", "/api/mcp"}]

  setup_all do
    raw = File.read!(OpenApiSpec.path())
    %{raw: raw, spec: Jason.decode!(raw)}
  end

  # Every /api route, plus the routes behind the :oauth pipeline (W2746).
  defp api_routes do
    for %{path: path, verb: verb} <- KanbanWeb.Router.__routes__(), spec_route?(verb, path) do
      {verb, path}
    end
  end

  defp spec_route?(_verb, "/api" <> _path), do: true

  defp spec_route?(verb, "/oauth/" <> _ = path),
    do: route_pipelines(Atom.to_string(verb), path) |> List.wrap() |> Enum.member?(:oauth)

  defp spec_route?(_verb, _path), do: false

  defp oauth_path?(path), do: String.starts_with?(path, "/oauth/")

  defp expected_400(path) do
    if oauth_path?(path),
      do: %{"$ref" => "#/components/responses/OAuthError"},
      else: %{"$ref" => "#/components/responses/BadRequest"}
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

    test "declares a deviceAuth http security scheme", %{spec: spec} do
      assert %{"type" => "http", "scheme" => "bearer", "description" => description} =
               get_in(spec, ["components", "securitySchemes", "deviceAuth"])

      assert description =~ "/api/me/*"
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

    test "every /api/me route requires deviceAuth and every agent route bearerAuth", %{
      spec: spec
    } do
      routes =
        for {verb, path} <- api_routes(),
            do: {verb, path, route_pipelines(Atom.to_string(verb), path)}

      me_routes = for {verb, "/api/me" <> _ = path, pipes} <- routes, do: {verb, path, pipes}

      assert me_routes != [], "expected at least one /api/me route"

      for {verb, path, pipes} <- me_routes do
        assert :device_api in pipes and :api not in pipes,
               "#{verb} #{path} must be behind :device_api, never :api"

        op = get_in(spec, ["paths", to_spec_path(path), Atom.to_string(verb)])
        assert op["security"] == [%{"deviceAuth" => []}]
      end

      for {verb, path, pipes} <- routes, is_list(pipes), :api in pipes do
        refute String.starts_with?(path, "/api/me"), "#{verb} #{path} is under :api"
        op = get_in(spec, ["paths", to_spec_path(path), Atom.to_string(verb)])
        effective = Map.get(op, "security", spec["security"])

        assert %{"bearerAuth" => []} in effective
        refute Enum.any?(effective, &Map.has_key?(&1, "deviceAuth"))
      end

      # The check above fails each way a spec could go wrong.
      device_op = %{"security" => [%{"deviceAuth" => []}]}
      assert check_security([:api_json, :device_api], device_op, spec["security"], "x") == nil

      for bad <- [
            %{},
            %{"security" => [%{"bearerAuth" => []}]},
            %{"security" => [%{"deviceAuth" => []}, %{"bearerAuth" => []}]}
          ] do
        assert check_security([:api_json, :device_api], bad, spec["security"], "x")
      end

      assert check_security([:api_json, :api], device_op, spec["security"], "x")

      assert check_security(
               [:api_json, :api],
               %{"security" => [%{"bearerAuth" => []}, %{"deviceAuth" => []}]},
               spec["security"],
               "x"
             )

      for alternative <- [%{}, %{"basicAuth" => []}] do
        op = %{"security" => [%{"bearerAuth" => []}, alternative]}
        assert check_security([:api_json, :api], op, spec["security"], "x")
        assert check_security([:api_json, :api], %{}, [%{"bearerAuth" => []}, alternative], "x")
      end
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
    case pipeline_kind(pipes) do
      :device_api ->
        device_security_failure(op, label)

      :api ->
        agent_security_failure(Map.get(op, "security", default_security) || [], label)

      :api_public ->
        unless op["security"] == [], do: "#{label} is public but does not declare security: []"

      :oauth ->
        unless op["security"] == [],
          do: "#{label} takes no bearer token but does not declare security: []"

      :unknown ->
        "classify pipeline #{inspect(pipes)} for #{label} in the contract test"
    end
  end

  # Checked in this order, so a route is classified by the first pipeline it
  # pipes through that the contract knows.
  defp pipeline_kind(pipes),
    do: Enum.find([:device_api, :api, :api_public, :oauth], :unknown, &(&1 in pipes))

  # W2747: exactly deviceAuth. Inheriting the bearerAuth default, or listing
  # bearerAuth as an alternative, would tell a client an agent token works here.
  defp device_security_failure(op, label) do
    unless op["security"] == [%{"deviceAuth" => []}],
      do: "#{label} is a person-API route but does not require exactly deviceAuth"
  end

  # Every alternative must be bearerAuth alone: an anonymous `{}`, another
  # scheme or deviceAuth beside it would tell a client that something other
  # than an agent token works here.
  defp agent_security_failure(effective, label) do
    cond do
      %{"bearerAuth" => []} not in effective ->
        "#{label} is authenticated but does not require bearerAuth"

      Enum.any?(effective, &Map.has_key?(&1, "deviceAuth")) ->
        "#{label} is an agent route but accepts deviceAuth"

      Enum.any?(effective, &(&1 != %{"bearerAuth" => []})) ->
        "#{label} is authenticated but accepts an alternative to bearerAuth"

      true ->
        nil
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
            {method, path} not in @method_not_allowed_only,
            not (op |> Map.get("responses", %{}) |> Map.keys() |> Enum.any?(&success_code?/1)) do
          "#{String.upcase(method)} #{path}"
        end

      assert without_2xx == []
    end

    # W2231: GET and DELETE /api/mcp are routed only to answer 405 (no SSE
    # stream, no session), so they are the one documented exception to the
    # 2xx rule above — and must document exactly that.
    test "the 405-only MCP operations document a 405 and no 2xx", %{spec: spec} do
      for {method, path} <- @method_not_allowed_only do
        responses = get_in(spec, ["paths", path, method, "responses"])

        assert Map.has_key?(responses, "405"), "#{method} #{path} must document its 405"
        refute responses |> Map.keys() |> Enum.any?(&success_code?/1)
      end
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

    # D353: a malformed query string or body is rejected by Plug.Parsers before
    # routing, so every operation can return 400 and must say so through the
    # shared component: BadRequest for /api, the RFC 6749 OAuthError for the
    # /oauth token endpoints (W2746).
    test "every operation documents a 400 response", %{spec: spec} do
      missing =
        for {method, path, op} <- spec_operations(spec),
            get_in(op, ["responses", "400"]) != expected_400(path) do
          "#{String.upcase(method)} #{path}"
        end

      assert missing == [],
             "Operations without a 400 $ref to BadRequest (OAuthError on /oauth):\n" <>
               Enum.join(missing, "\n")
    end

    test "the OAuthError example matches what ErrorJSON renders for an /oauth 400", %{
      spec: spec
    } do
      example = get_in(spec, ~w(components responses OAuthError content application/json example))

      conn = Phoenix.ConnTest.build_conn(:post, "/oauth/token")

      rendered =
        "400.json"
        |> KanbanWeb.ErrorJSON.render(%{conn: conn})
        |> Jason.encode!()
        |> Jason.decode!()

      assert example == rendered
    end

    test "the /oauth operations are documented, public and rate limited", %{spec: spec} do
      for path <- ["/oauth/token", "/oauth/revoke"] do
        op = get_in(spec, ["paths", path, "post"])

        assert op["security"] == []

        assert op["responses"]["429"] == %{
                 "$ref" => "#/components/responses/OAuthTooManyRequests"
               }
      end

      refute get_in(spec, ["paths", "/oauth/authorize"])
    end

    test "the BadRequest example matches what ErrorJSON renders for an /api 400", %{spec: spec} do
      example = get_in(spec, ~w(components responses BadRequest content application/json example))

      conn = Phoenix.ConnTest.build_conn(:get, "/api/openapi.json")

      rendered =
        "400.json"
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
        ~w(limit cursor status type priority assigned_to_id parent updated_since column_id
           response_view label)

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
      rendered = TaskJSON.show(%{task: task, attachments: []}).data
      assert rendered_keys(rendered) == schema_keys(spec, "Task")
    end

    test "TaskAttachment lists exactly the keys of TaskAttachmentJSON.attachment/1 (W2516)", %{
      spec: spec,
      task: task
    } do
      attachment = %Kanban.Attachments.TaskAttachment{
        id: 1,
        task_id: task.id,
        inserted_at: ~N[2026-11-01 12:00:00]
      }

      assert rendered_keys(KanbanWeb.API.TaskAttachmentJSON.attachment(attachment)) ==
               schema_keys(spec, "TaskAttachment")

      assert spec["components"]["schemas"]["TaskAttachment"]["required"] |> MapSet.new() ==
               schema_keys(spec, "TaskAttachment")

      task_schema = spec["components"]["schemas"]["Task"]

      assert task_schema["properties"]["attachments"]["items"] ==
               %{"$ref" => "#/components/schemas/TaskAttachment"}

      refute "attachments" in task_schema["required"]
    end

    test "TaskLabel matches the rendered label shape and the label colours (W2239)", %{
      spec: spec
    } do
      schema = spec["components"]["schemas"]["TaskLabel"]
      assert schema["properties"] |> Map.keys() |> Enum.sort() == ["color", "name"]

      assert schema["properties"]["color"]["enum"] ==
               Enum.map(Kanban.Labels.Label.colors(), &Atom.to_string/1)

      assert spec["components"]["schemas"]["Task"]["properties"]["labels"]["items"] ==
               %{"$ref" => "#/components/schemas/TaskLabel"}
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
      board = ai_optimized_board_fixture(user)

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

    test "TaskComment lists exactly the keys of TaskCommentJSON.comment/1", %{
      spec: spec,
      task: task
    } do
      comment = %Kanban.Tasks.TaskComment{id: 1, task_id: task.id, content: "x"}

      assert rendered_keys(KanbanWeb.API.TaskCommentJSON.comment(comment)) ==
               schema_keys(spec, "TaskComment")
    end

    test "Board lists exactly the keys of BoardJSON.board/1", %{spec: spec} do
      board = %Kanban.Boards.Board{id: 1, name: "Board", description: nil, workspace_id: nil}

      assert rendered_keys(KanbanWeb.API.BoardJSON.board(board)) == schema_keys(spec, "Board")
    end

    test "BoardList lists exactly the keys of BoardJSON.index/1", %{spec: spec} do
      rendered = KanbanWeb.API.BoardJSON.index(%{boards: [], token_scope: "board"})

      assert rendered_keys(rendered) == schema_keys(spec, "BoardList")
    end

    test "TaskCommentListMeta lists exactly the keys of a real comment list meta", %{
      conn: conn,
      spec: spec
    } do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      task = board |> column_fixture() |> task_fixture()

      {:ok, {_token, plain_token}} =
        ApiTokens.create_api_token(user, board, %{"name" => "OpenAPI contract"})

      body =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer " <> plain_token)
        |> get(~p"/api/tasks/#{task.id}/comments")
        |> json_response(200)

      assert rendered_keys(body["meta"]) == schema_keys(spec, "TaskCommentListMeta")
    end

    test "stride_add_comment takes the POST /api/tasks/{id}/comments body, plus id", %{
      spec: spec
    } do
      body =
        get_in(spec, [
          "paths",
          "/api/tasks/{id}/comments",
          "post",
          "requestBody",
          "content",
          "application/json",
          "schema"
        ])

      tool = KanbanWeb.MCP.ToolSchemas.fetch("stride_add_comment")["inputSchema"]
      tool_props = Map.delete(tool["properties"], "id")

      assert Map.keys(tool_props) |> Enum.sort() == Map.keys(body["properties"]) |> Enum.sort()

      for {name, prop} <- body["properties"] do
        assert Map.take(tool_props[name], ["type", "minLength", "maxLength"]) ==
                 Map.take(prop, ["type", "minLength", "maxLength"]),
               "#{name} drifted between the MCP inputSchema and the OpenAPI request body"
      end

      assert tool["required"] -- ["id"] == body["required"]
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

  describe "schema parity with MeJSON (W2747)" do
    setup do
      user = user_fixture()
      organization = Kanban.OrganizationsFixtures.organization_fixture()
      Kanban.OrganizationsFixtures.organization_member_fixture(organization, user)
      membership = Kanban.Organizations.get_membership(user)
      workspace = Kanban.WorkspacesFixtures.org_workspace_fixture(organization)

      device =
        user
        |> user_scope_fixture()
        |> Kanban.DevicesFixtures.device_fixture()

      %{
        rendered:
          MeJSON.show(%{
            user: user,
            membership: membership,
            workspaces: [workspace],
            app_unlocked: true,
            min_versions: Kanban.Devices.AppPolicy.min_versions(),
            limits: Kanban.Devices.AppPolicy.phone_limits(),
            device: Kanban.Devices.touch_last_seen(device)
          }).data
      }
    end

    test "Me and its parts list exactly the keys MeJSON renders", %{spec: spec, rendered: me} do
      assert rendered_keys(me) == schema_keys(spec, "Me")
      assert rendered_keys(me.user) == schema_keys(spec, "MeUser")
      assert rendered_keys(me.organization) == schema_keys(spec, "MeOrganization")
      assert rendered_keys(hd(me.workspaces)) == schema_keys(spec, "MeWorkspace")
      assert rendered_keys(me.limits) == schema_keys(spec, "MeLimits")
      assert rendered_keys(me.min_app_versions.ios) == schema_keys(spec, "MeMinVersion")
      assert rendered_keys(me.device) == schema_keys(spec, "MeDevice")

      for name <- ~w(Me MeUser MeOrganization MeWorkspace MeLimits MeMinVersion MeDevice) do
        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end
    end

    test "the AppUpdateRequired example matches what AppVersion renders", %{spec: spec} do
      example =
        get_in(spec, ~w(components responses AppUpdateRequired content application/json example))

      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/me")
        |> Plug.Conn.put_req_header("x-stride-app", "ios/0.0.1 (1)")
        |> KanbanWeb.Plugs.AppVersion.call([])

      assert conn.status == 426
      assert Jason.decode!(conn.resp_body) == example
    end
  end

  describe "schema parity with DeviceJSON (W2748)" do
    setup do
      device =
        user_fixture()
        |> user_scope_fixture()
        |> Kanban.DevicesFixtures.device_fixture(%{push_token: "fixture-push-token-spec"})

      %{device: device}
    end

    test "UserDevice lists exactly the keys DeviceJSON renders, and requires them all", %{
      spec: spec,
      device: device
    } do
      %{data: [listed]} = DeviceJSON.index(%{devices: [device], current_id: device.id})
      %{data: shown} = DeviceJSON.show(%{device: device, current_id: device.id})

      assert rendered_keys(listed) == schema_keys(spec, "UserDevice")
      assert rendered_keys(shown) == schema_keys(spec, "UserDevice")

      assert spec["components"]["schemas"]["UserDevice"]["required"] |> MapSet.new() ==
               schema_keys(spec, "UserDevice")

      # Everything MeDevice has, the device list has too.
      user_device_keys = schema_keys(spec, "UserDevice")

      assert spec |> schema_keys("MeDevice") |> MapSet.subset?(user_device_keys)
      refute Enum.any?(user_device_keys, &(&1 =~ ~r/hash|approval|push_token/))
    end

    test "UserDeviceUpdate documents exactly the fields the controller takes", %{spec: spec} do
      assert schema_keys(spec, "UserDeviceUpdate") ==
               MapSet.new(~w(push_token push_environment locale time_zone app_version))
    end

    test "the push_environment enums match the Ecto schema", %{spec: spec} do
      values =
        Kanban.Devices.Device |> Ecto.Enum.values(:push_environment) |> Enum.map(&to_string/1)

      documented =
        get_in(spec, ~w(components schemas UserDevice properties push_environment enum))

      assert Enum.reject(documented, &is_nil/1) == values
    end

    test "the device routes document their 404 and 422 bodies", %{spec: spec} do
      revoke = get_in(spec, ["paths", "/api/me/devices/{id}", "delete", "responses"])
      update = get_in(spec, ["paths", "/api/me/devices/current", "put", "responses"])

      assert get_in(revoke, ~w(404 content application/json example)) == %{"error" => "Not Found"}

      assert get_in(update, ~w(422 content application/json schema)) == %{
               "$ref" => "#/components/schemas/ValidationError"
             }
    end
  end

  describe "schema parity with ReviewJSON.file_diff/1 (W2753)" do
    setup do
      task = %Task{
        id: 1,
        changed_files: [%{"path" => "lib/a.ex", "diff" => "@@ -1 +1 @@\n+def a, do: 1"}],
        reviewer_result: %{
          "issues" => [%{"severity" => "minor", "file" => "lib/a.ex", "line" => 1}]
        }
      }

      highlight = fn _task_id, _index, diff, path -> DiffHighlighter.lines(diff, path) end
      {:ok, file} = MobileReview.file(task, 0, highlight)

      %{body: ReviewJSON.file_diff(%{file: file})}
    end

    test "ReviewFileDiff and its parts list exactly the keys ReviewJSON renders, and require them all",
         %{spec: spec, body: body} do
      line = Enum.find(body.data.lines, &(&1.kind == "add"))

      pairs = [
        {body, "ReviewFileDiffResponse"},
        {body.data, "ReviewFileDiff"},
        {line, "ReviewDiffLine"},
        {hd(line.spans), "ReviewDiffSpan"},
        {hd(body.data.notes), "ReviewFileNote"}
      ]

      for {rendered, name} <- pairs do
        assert rendered_keys(rendered) == schema_keys(spec, name), "#{name} keys differ"

        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end
    end

    test "the kinds, classes and languages are the documented enums", %{spec: spec} do
      schemas = spec["components"]["schemas"]

      assert schemas["ReviewDiffLine"]["properties"]["kind"]["enum"] == ~w(add del ctx hunk)

      assert schemas["ReviewDiffSpan"]["properties"]["class"]["enum"] ==
               Enum.map(DiffHighlighter.classes(), &Atom.to_string/1)

      assert schemas["ReviewFileDiff"]["properties"]["language"]["enum"] ==
               ~w(elixir heex erlang plain)
    end
  end

  describe "schema parity with ReviewJSON (W2751)" do
    setup do
      user = user_fixture()
      column = user |> board_fixture() |> column_fixture(%{name: "Review"})
      goal = task_fixture(column, %{title: "The goal"})

      task =
        column
        |> task_fixture()
        |> Kanban.Repo.preload([:parent, column: :board])
        |> Map.merge(%{
          parent: goal,
          acceptance_criteria: "One",
          security_considerations: ["Scope"],
          changed_files: [%{"path" => "lib/a.ex", "diff" => "+a", "diff_url" => nil}],
          reviewer_result: %{
            "patterns" => %{"status" => "passed"},
            "issues" => [%{"category" => "pattern", "severity" => "minor", "file" => "lib/a.ex"}],
            "acceptance_criteria" => [%{"criterion" => "One", "status" => "met"}],
            "behaviour_test_matrix" => %{
              "rows" => [%{"category" => "Happy path", "behaviour" => "Works"}]
            }
          }
        })

      dependent = %Task{id: 2, identifier: "W2", title: "Waits", status: :open}

      %{data: ReviewJSON.show(%{review: MobileReview.build(task, [dependent], :phone)}).data}
    end

    test "ReviewDetail and its parts list exactly the keys ReviewJSON renders, and require them all",
         %{spec: spec, data: data} do
      pairs = [
        {data, "ReviewDetail"},
        {data.task, "ReviewTask"},
        {data.task.board, "ReviewBoard"},
        {data.task.goal, "ReviewGoal"},
        {hd(data.verdicts), "ReviewVerdict"},
        {hd(data.acceptance_criteria), "ReviewAcceptanceCriterion"},
        {hd(data.security_considerations), "ReviewSecurityConsideration"},
        {data.security_findings, "ReviewSeverityCounts"},
        {data.project_checks, "ReviewProjectChecks"},
        {data.exploratory, "ReviewExploratory"},
        {hd(data.behaviour_matrix), "ReviewBehaviourRow"},
        {hd(data.files), "ReviewFile"},
        {data.size, "ReviewSize"},
        {hd(data.holds_up), "ReviewHeldTask"}
      ]

      for {rendered, name} <- pairs do
        assert rendered_keys(rendered) == schema_keys(spec, name), "#{name} keys differ"

        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end

      assert spec["components"]["schemas"]["PlanRequired"]["required"] |> MapSet.new() ==
               schema_keys(spec, "PlanRequired")
    end

    test "the verdict sections and flag reasons are the documented enums", %{spec: spec} do
      schemas = spec["components"]["schemas"]

      assert schemas["ReviewVerdict"]["properties"]["section"]["enum"] ==
               ~w(acceptance_criteria testing_strategy patterns pitfalls security_considerations)

      assert schemas["ReviewFile"]["properties"]["flag_reason"]["enum"] == [
               "issue",
               "security",
               nil
             ]

      assert schemas["ReviewDetail"]["properties"]["approvable_here_reason"]["enum"] ==
               ["too_large_for_phone", nil]
    end

    test "the 403 example matches what the person-API fallback renders", %{spec: spec} do
      example =
        get_in(spec, [
          "paths",
          "/api/me/reviews/{task_id}",
          "get",
          "responses",
          "403",
          "content",
          "application/json",
          "example"
        ])

      conn =
        FallbackController.call(
          Phoenix.ConnTest.build_conn(),
          {:error, {:plan_required, :mobile_app}}
        )

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == example
    end
  end

  describe "schema parity with the approval endpoints (W2754)" do
    defp example(spec, path, status, name \\ nil) do
      content =
        get_in(spec, ["paths", path, "post", "responses", status, "content", "application/json"])

      if name, do: content["examples"][name]["value"], else: content["example"]
    end

    defp fallback_body(error) do
      conn = FallbackController.call(Phoenix.ConnTest.build_conn(), {:error, error})
      {conn.status, Jason.decode!(conn.resp_body)}
    end

    @challenge_path "/api/me/reviews/{task_id}/approval_challenge"
    @approve_path "/api/me/reviews/{task_id}/approve"
    @request_changes_path "/api/me/reviews/{task_id}/request_changes"

    test "the rendered bodies list exactly the documented keys, and require them all",
         %{spec: spec} do
      task = %Task{
        id: 4812,
        identifier: "W2701",
        review_status: :approved,
        review_requested_at: ~U[2026-11-18 09:30:00Z],
        reviewed_at: ~U[2026-11-18 09:39:02Z],
        reviewed_by: %User{name: "Sam Rivera"}
      }

      challenge = %ApprovalChallenge{
        nonce: "sdan_EXAMPLE0nonce0value0only0for0documentation0",
        expires_at: ~U[2026-11-18 09:42:00Z],
        review_requested_at: ~U[2026-11-18 09:30:00Z]
      }

      %{data: challenge_data} = ReviewJSON.challenge(%{challenge: challenge, task: task})
      %{data: approved_data} = ReviewJSON.approved(%{task: task})

      %{data: changes_data} =
        ReviewJSON.changes_requested(%{task: %{task | review_status: :changes_requested}})

      for {rendered, name} <- [
            {challenge_data, "ApprovalChallenge"},
            {approved_data, "ApprovedReview"},
            {changes_data, "ChangesRequestedReview"},
            {ReviewJSON.review_state(task), "ReviewState"}
          ] do
        assert rendered_keys(rendered) == schema_keys(spec, name), "#{name} keys differ"

        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end

      assert challenge_data |> Jason.encode!() |> Jason.decode!() ==
               example(spec, @challenge_path, "201")["data"]

      # The documented nonce has the shape the server issues and accepts.
      assert ApprovalChallenge.valid_nonce?(challenge.nonce)
    end

    test "the 403, 409 and 422 examples match what the person-API fallback renders",
         %{spec: spec} do
      decided = %Task{
        id: 4812,
        identifier: "W2701",
        review_status: :approved,
        review_requested_at: ~U[2026-11-18 09:30:00Z],
        reviewed_at: ~U[2026-11-18 09:39:02Z],
        reviewed_by: %User{name: "Sam Rivera"}
      }

      resubmitted = %Task{
        id: 4812,
        identifier: "W2701",
        review_status: nil,
        review_requested_at: ~U[2026-11-18 10:00:00Z],
        reviewed_by: nil
      }

      size = %{files: 14, changed_lines: 652, truncated: false}

      for path <- [@challenge_path, @approve_path, @request_changes_path] do
        assert fallback_body({:plan_required, :mobile_app}) == {403, example(spec, path, "403")}

        assert fallback_body({:conflict, :already_decided, decided}) ==
                 {409, example(spec, path, "409", "already_decided")}

        assert fallback_body({:conflict, :resubmitted, resubmitted}) ==
                 {409, example(spec, path, "409", "resubmitted")}
      end

      assert fallback_body({:too_large_for_phone, size}) ==
               {422, example(spec, @challenge_path, "422")}

      assert fallback_body({:too_large_for_phone, size}) ==
               {422, example(spec, @approve_path, "422", "too_large_for_phone")}

      assert fallback_body({:signature_rejected, :expired}) ==
               {422, example(spec, @approve_path, "422", "signature_rejected")}

      assert fallback_body(:invalid_column) ==
               {422, example(spec, @approve_path, "422", "approval_failed")}

      assert fallback_body(:review_notes_required) ==
               {422, example(spec, @request_changes_path, "422")}

      assert {400, %{"error" => "Bad Request", "message" => message}} =
               fallback_body(
                 {:bad_request,
                  "review_requested_at is required: the ISO 8601 extended-format timestamp the challenge returned, such as 2026-11-18T09:30:00Z, or null or an empty string for a task that has none."}
               )

      assert get_in(spec, ["paths", @approve_path, "post", "description"]) =~ message
    end

    test "approve and request_changes document the Idempotency-Key header (W2755)",
         %{spec: spec} do
      header = spec["components"]["parameters"]["IdempotencyKey"]

      assert header["name"] == "Idempotency-Key"
      assert header["in"] == "header"
      assert header["required"] == false
      assert header["description"] =~ KanbanWeb.API.Me.Idempotent.bad_key_message()
      assert header["description"] =~ "24 hours"
      assert Kanban.Devices.Nonces.valid_key?(header["example"])

      for path <- [@approve_path, @request_changes_path] do
        assert %{"$ref" => "#/components/parameters/IdempotencyKey"} in get_in(spec, [
                 "paths",
                 path,
                 "post",
                 "parameters"
               ])
      end

      request = spec["components"]["schemas"]["RequestReviewChangesRequest"]
      assert request["required"] == ["review_requested_at", "notes"]

      assert example(spec, @request_changes_path, "200")["data"]["review_status"] ==
               "changes_requested"
    end

    test "the approve description documents the canonical signing string", %{spec: spec} do
      description = get_in(spec, ["paths", @approve_path, "post", "description"])

      for fragment <- ["stride-approval-v1", "line feed", "DER", "P-256", "SHA-256", "`approve`"] do
        assert description =~ fragment
      end

      assert spec["components"]["schemas"]["SignatureRejected"]["properties"]["reason"]["enum"] ==
               ~w(missing invalid expired reused)
    end
  end

  describe "schema parity with DecisionJSON (W2758)" do
    setup do
      now = ~U[2026-11-19 12:00:00Z]
      board = %{id: 1, name: "Board"}
      task_summary = %{identifier: "W1", title: "T", priority: :high, agent: "A", board: board}

      base = %{
        since: now,
        task_id: 9,
        board_id: 1,
        summary: task_summary,
        actions: [:open_on_web],
        web_url: "https://example.test/boards/1/tasks/9",
        holds_up: 0,
        held_identifiers: []
      }

      details = %{
        review: %{
          verdicts: [%{section: :patterns, status: "passed"}],
          first_failed_note: nil
        },
        released: %{reason: "Blocked", notification_id: 3},
        claim_expired: %{claimed_at: now, expired_at: now},
        hook_failed: %{exit_code: 1, duration_ms: 20},
        ready_empty: %{idle_agents: 1, backlog_count: 2}
      }

      items =
        for {kind, kind_details} <- details do
          Map.merge(base, %{id: "#{kind}:task:9", kind: kind, details: kind_details})
        end

      decisions = %{items: items, summary: %{waiting: 5, held_up: 0, agents_working: 1}}

      %{
        data: DecisionJSON.index(%{decisions: decisions}).data,
        queue: ReviewJSON.index(%{items: items}).data
      }
    end

    test "DecisionList and its parts list exactly the keys DecisionJSON renders, and require them all",
         %{spec: spec, data: data, queue: queue} do
      by_kind = Map.new(data.items, &{&1.kind, &1})
      item = by_kind["review"]

      pairs = [
        {data, "DecisionList"},
        {data.summary, "DecisionSummary"},
        {item, "DecisionItem"},
        {item.summary, "DecisionTaskSummary"},
        {item.summary.board, "DecisionBoard"},
        {hd(item.details.verdicts), "DecisionVerdict"},
        {item.details, "DecisionReviewDetails"},
        {by_kind["released"].details, "DecisionReleasedDetails"},
        {by_kind["claim_expired"].details, "DecisionClaimExpiredDetails"},
        {by_kind["hook_failed"].details, "DecisionHookFailedDetails"},
        {by_kind["ready_empty"].details, "DecisionReadyEmptyDetails"}
      ]

      for {rendered, name} <- pairs do
        assert rendered_keys(rendered) == schema_keys(spec, name), "#{name} keys differ"

        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end

      assert queue == data.items
      assert schema_keys(spec, "DecisionListResponse") == MapSet.new(["data"])
      assert schema_keys(spec, "ReviewQueueResponse") == MapSet.new(["data"])
    end

    test "the kinds, actions, sections and priorities are the documented enums", %{spec: spec} do
      schemas = spec["components"]["schemas"]

      assert schemas["DecisionItem"]["properties"]["kind"]["enum"] ==
               ~w(review released claim_expired hook_failed ready_empty)

      assert schemas["DecisionItem"]["properties"]["actions"]["items"]["enum"] ==
               ~w(open_review approve request_changes open_on_web reply move_to_backlog view_attempt open_backlog)

      assert schemas["DecisionVerdict"]["properties"]["section"]["enum"] ==
               ~w(acceptance_criteria testing_strategy patterns security_considerations)

      assert schemas["DecisionTaskSummary"]["properties"]["priority"]["enum"] ==
               ecto_enum(:priority) ++ [nil]
    end

    test "both 403 examples match what the person-API fallback renders", %{spec: spec} do
      conn =
        FallbackController.call(
          Phoenix.ConnTest.build_conn(),
          {:error, {:plan_required, :mobile_app}}
        )

      for path <- ["/api/me/decisions", "/api/me/reviews"] do
        example =
          get_in(spec, ["paths", path, "get", "responses", "403", "content", "application/json"])

        assert Jason.decode!(conn.resp_body) == example["example"]
        assert example["schema"] == %{"$ref" => "#/components/schemas/PlanRequired"}
      end
    end
  end

  describe "schema parity with BoardJSON (W2759)" do
    setup do
      label = %Kanban.Labels.Label{id: 7, name: "mobile", color: :blue}

      task = %Task{
        id: 9,
        identifier: "W1",
        title: "T",
        type: :work,
        priority: :high,
        status: :open,
        needs_review: false,
        position: 0,
        labels: [label],
        acceptance_criteria: "a\nb",
        key_files: [],
        security_considerations: ["s"]
      }

      entry = %{
        board: %Kanban.Boards.Board{id: 1, name: "Board"},
        access: :owner,
        group: :workspace,
        workspace: %Kanban.Workspaces.Workspace{id: 3, name: "W", slug: "w"},
        counts: %{backlog: 1, ready: 0, doing: 0, review: 0, done: 0},
        idle_agents: 1
      }

      page = %{tasks: [task], total: 1, page: 1, per_page: 100, next_page: nil}
      column = %Kanban.Columns.Column{id: 81, name: "Backlog"}

      %{
        list: BoardJSON.index(%{boards: [entry]}),
        column: BoardJSON.column(%{board_id: 1, column: column, page: page}),
        promoted: BoardJSON.promoted(%{result: %{promoted: [task], already_ready: [5]}})
      }
    end

    test "the board schemas list exactly the keys BoardJSON renders, and require them all",
         %{spec: spec, list: list, column: column, promoted: promoted} do
      board = hd(list.data)
      card = hd(column.data.tasks)

      pairs = [
        {list, "MeBoardListResponse"},
        {board, "MeBoard"},
        {board.counts, "MeBoardCounts"},
        {column, "MeColumnPageResponse"},
        {column.data, "MeColumnPage"},
        {column.data.column, "MeColumnRef"},
        {card, "MeTaskCard"},
        {card.label, "MeCardLabel"},
        {promoted, "MePromoteResponse"},
        {promoted.data, "MePromoteResult"}
      ]

      for {rendered, name} <- pairs do
        assert rendered_keys(rendered) == schema_keys(spec, name), "#{name} keys differ"

        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end

      assert schema_keys(spec, "MePromoteRequest") == MapSet.new(["task_ids", "needs_review"])
      assert spec["components"]["schemas"]["MePromoteRequest"]["required"] == ["task_ids"]
    end

    test "the enums are the values the app can receive", %{spec: spec} do
      schemas = spec["components"]["schemas"]

      assert schemas["MeTaskCard"]["properties"]["priority"]["enum"] == ecto_enum(:priority)
      assert schemas["MeTaskCard"]["properties"]["status"]["enum"] == ecto_enum(:status)
      assert schemas["MeTaskCard"]["properties"]["type"]["enum"] == ecto_enum(:type) -- ["goal"]

      assert schemas["MeCardLabel"]["properties"]["color"]["enum"] ==
               Kanban.Labels.Label |> Ecto.Enum.values(:color) |> Enum.map(&Atom.to_string/1)

      assert schemas["MeBoard"]["properties"]["access"]["enum"] ==
               ~w(owner modify read_only)

      assert Kanban.Boards.BoardUser |> Ecto.Enum.values(:access) |> Enum.sort() ==
               Enum.sort([:owner, :modify, :read_only])

      assert schemas["MeBoard"]["properties"]["group"]["enum"] == ~w(workspace personal shared)
    end

    test "the refusal examples match what the person-API fallback renders", %{spec: spec} do
      promote = get_in(spec, ["paths", "/api/me/boards/{id}/promote", "post", "responses"])

      rendered = fn error ->
        Phoenix.ConnTest.build_conn() |> FallbackController.call(error) |> Map.get(:resp_body)
      end

      examples = [
        {["403", "forbidden"], {:error, :forbidden}},
        {["403", "planRequired"], {:error, {:plan_required, :mobile_app}}},
        {["422", "emptyTaskIds"], {:error, :empty_selection}},
        {["422", "notPromotable"], {:error, {:not_promotable, [4813]}}},
        {["422", "wipLimitReached"], {:error, :wip_limit_reached}},
        {["422", "noReadyColumn"], {:error, :no_ready_column}}
      ]

      for {[status, name], error} <- examples do
        example =
          get_in(promote, [status, "content", "application/json", "examples", name, "value"])

        assert error |> rendered.() |> Jason.decode!() == example, "#{status} #{name} differs"
      end

      conflict = get_in(promote, ["409", "content", "application/json", "example"])
      assert {:error, :conflict} |> rendered.() |> Jason.decode!() == conflict

      for path <- ["/api/me/boards", "/api/me/boards/{id}/columns/{name}"] do
        example =
          get_in(spec, ["paths", path, "get", "responses", "403", "content", "application/json"])

        plan_required = {:error, {:plan_required, :mobile_app}}
        assert plan_required |> rendered.() |> Jason.decode!() == example["example"]
      end
    end
  end

  describe "schema parity with Me.TaskJSON (W2760)" do
    setup do
      column = %Kanban.Columns.Column{id: 81, name: "Ready", board_id: 1}

      task = %Task{
        id: 9,
        identifier: "W1",
        title: "T",
        type: :work,
        priority: :high,
        status: :open,
        needs_review: false,
        position: 0,
        labels: [],
        column: column,
        description: "d",
        acceptance_criteria: "a\nb",
        key_files: [%Kanban.Schemas.Task.KeyFile{file_path: "lib/a.ex", note: "n", position: 0}],
        security_considerations: ["s"],
        created_via: :mobile,
        archived_at: nil
      }

      comment = %Kanban.Tasks.TaskComment{
        id: 3,
        task_id: 9,
        content: "c",
        author: nil,
        author_agent_name: nil,
        mentioned_user_ids: [],
        inserted_at: ~U[2026-11-20 09:00:00Z],
        updated_at: ~U[2026-11-20 09:00:00Z]
      }

      %{
        show: Me.TaskJSON.show(%{task: task, comments: [comment], has_more: true}),
        comment: Me.TaskJSON.comment(%{comment: comment}),
        moved: Me.TaskJSON.moved(%{result: %{task: task, moved: true}})
      }
    end

    test "the task schemas list exactly the keys Me.TaskJSON renders, and require them all",
         %{spec: spec, show: show, comment: comment, moved: moved} do
      pairs = [
        {show, "MeTaskDetailResponse"},
        {show.data, "MeTaskDetail"},
        {show.data.column, "MeColumnRef"},
        {hd(show.data.key_files), "MeKeyFile"},
        {hd(show.data.comments), "TaskComment"},
        {comment, "TaskCommentEnvelope"},
        {moved, "MeMoveToBacklogResponse"},
        {moved.data, "MeMoveToBacklogResult"},
        {moved.data.task, "MeTaskCard"}
      ]

      for {rendered, name} <- pairs do
        assert rendered_keys(rendered) == schema_keys(spec, name), "#{name} keys differ"

        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end

      assert schema_keys(spec, "MeCommentRequest") == MapSet.new(["content"])

      assert schema_keys(spec, "MeCaptureRequest") ==
               MapSet.new(["board_id", "type", "title", "description"])

      assert spec["components"]["schemas"]["MeCaptureRequest"]["required"] ==
               ["board_id", "type", "title"]
    end

    test "the enums are the values the app can receive", %{spec: spec} do
      schemas = spec["components"]["schemas"]
      detail = schemas["MeTaskDetail"]["properties"]

      assert detail["priority"]["enum"] == ecto_enum(:priority)
      assert detail["status"]["enum"] == ecto_enum(:status)
      assert detail["type"]["enum"] == ecto_enum(:type)
      assert detail["created_via"]["enum"] == ecto_enum(:created_via) ++ [nil]

      assert schemas["MeCaptureRequest"]["properties"]["type"]["enum"] ==
               ecto_enum(:type) -- ["goal"]

      assert schemas["MeTaskRefusal"]["properties"]["error"]["enum"] ==
               ~w(not_movable no_backlog_column wip_limit_reached move_failed)
    end

    test "the refusal examples match what the person-API fallback renders", %{spec: spec} do
      rendered = fn error ->
        Phoenix.ConnTest.build_conn() |> FallbackController.call(error) |> Map.get(:resp_body)
      end

      example = fn path, method, status, name ->
        content = ["paths", path, method, "responses", status, "content", "application/json"]

        case name do
          nil -> get_in(spec, content ++ ["example"])
          name -> get_in(spec, content ++ ["examples", name, "value"])
        end
      end

      move = "/api/me/tasks/{id}/move_to_backlog"
      capture = "/api/me/tasks"
      blank = {%{}, %{t: :string}} |> Ecto.Changeset.cast(%{}, [:t])

      examples = [
        {{move, "post", "403", "forbidden"}, {:error, :forbidden}},
        {{move, "post", "403", "planRequired"}, {:error, {:plan_required, :mobile_app}}},
        {{move, "post", "409", nil}, {:error, :conflict}},
        {{move, "post", "422", "notMovable"}, {:error, :not_movable}},
        {{move, "post", "422", "noBacklogColumn"}, {:error, :no_backlog_column}},
        {{move, "post", "422", "wipLimitReached"}, {:error, :backlog_wip_limit_reached}},
        {{move, "post", "422", "moveFailed"}, {:error, :move_failed}},
        {{capture, "post", "403", "forbidden"}, {:error, :forbidden}},
        {{capture, "post", "422", "noBacklogColumn"}, {:error, :no_backlog_column}},
        {{capture, "post", "422", "wipLimitReached"}, {:error, :backlog_wip_limit_reached}},
        {{capture, "post", "422", "goalRefused"},
         {:error,
          {:in_device_locale,
           Ecto.Changeset.add_error(blank, :type, "is invalid", validation: :inclusion)}}},
        {{capture, "post", "422", "blankTitle"},
         {:error, {:in_device_locale, Ecto.Changeset.add_error(blank, :title, "can't be blank")}}},
        {{"/api/me/tasks/{id}", "get", "403", nil}, {:error, {:plan_required, :mobile_app}}},
        {{"/api/me/tasks/{id}", "get", "404", nil}, {:error, :not_found}},
        {{"/api/me/tasks/{id}/comments", "post", "403", nil},
         {:error, {:plan_required, :mobile_app}}},
        {{"/api/me/tasks/{id}/comments", "post", "422", nil},
         {:error,
          {:in_device_locale,
           Ecto.Changeset.add_error(blank, :content, "can't be blank", validation: :required)}}}
      ]

      for {{path, method, status, name} = where, error} <- examples do
        assert error |> rendered.() |> Jason.decode!() == example.(path, method, status, name),
               "#{inspect(where)} differs"
      end
    end
  end

  describe "schema parity with NotificationSettingsJSON (W2767)" do
    setup do
      settings = %{
        mode: :decisions,
        switches: Map.new(Kanban.Notifications.PushSettings.push_events(), &{&1, false}),
        quiet_hours_enabled: true,
        quiet_start: ~T[22:00:00],
        quiet_end: ~T[07:00:00],
        time_zone: "Europe/London"
      }

      %{rendered: NotificationSettingsJSON.show(%{settings: settings})}
    end

    test "NotificationSettings and PushSwitches list exactly the rendered keys, and require them all",
         %{spec: spec, rendered: rendered} do
      for {value, name} <- [
            {rendered, "NotificationSettingsResponse"},
            {rendered.data, "NotificationSettings"},
            {rendered.data.switches, "PushSwitches"}
          ] do
        assert rendered_keys(value) == schema_keys(spec, name), "#{name} keys differ"

        assert spec["components"]["schemas"][name]["required"] |> MapSet.new() ==
                 schema_keys(spec, name),
               "#{name} must require every key it lists"
      end

      assert schema_keys(spec, "PushSwitches") ==
               MapSet.new(Kanban.Notifications.PushSettings.push_events(), &Atom.to_string/1)
    end

    test "NotificationSettingsUpdate documents exactly the fields the controller takes", %{
      spec: spec
    } do
      assert schema_keys(spec, "NotificationSettingsUpdate") ==
               MapSet.new(NotificationSettingsController.update_params())
    end

    test "the mode enums match the schema", %{spec: spec} do
      modes = Enum.map(Kanban.Notifications.PushSettings.modes(), &Atom.to_string/1)
      schemas = spec["components"]["schemas"]

      assert schemas["NotificationSettings"]["properties"]["mode"]["enum"] == modes
      assert schemas["NotificationSettingsUpdate"]["properties"]["mode"]["enum"] == modes
    end

    test "both 403 examples match what the person-API fallback renders, and PUT documents 422",
         %{spec: spec} do
      conn =
        FallbackController.call(
          Phoenix.ConnTest.build_conn(),
          {:error, {:plan_required, :mobile_app}}
        )

      operations = get_in(spec, ["paths", "/api/me/notification_settings"])

      for verb <- ["get", "put"] do
        example = get_in(operations, [verb, "responses", "403", "content", "application/json"])
        assert Jason.decode!(conn.resp_body) == example["example"]
      end

      assert get_in(operations, ~w(put responses 422 content application/json schema)) == %{
               "$ref" => "#/components/schemas/ValidationError"
             }
    end
  end
end
