defmodule KanbanWeb.API.AgentJSONTest do
  @moduledoc """
  Shape guard for the agent onboarding payload after the W1442 split of the
  literals into KanbanWeb.API.Agent.{SchemaDoc, MultiAgentInstructions,
  SetupDocs}. The onboarding endpoint is consumed by external agents, so a
  changed or dropped top-level key silently breaks integrations — these tests
  fail loudly if the composed key set drifts.

  Not async: the D389 describe turns on strict completion validation, which is
  global Application env.
  """
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.Agent.EndpointDocs

  # The complete top-level key set external agents depend on. Composed from the
  # inline literals plus the extracted SchemaDoc/MultiAgentInstructions/SetupDocs
  # sections. Any addition or removal must be a deliberate, reviewed change.
  @onboarding_keys ~w(
    version skills_version api_schema api_base_url overview quick_start
    file_templates claude_code_skills workflow hooks api_reference
    required_reading task_creation_requirements multi_agent_instructions
    resources memory_strategy session_initialization first_session_vs_returning
    common_mistakes_agents_make quick_reference_card
    MANDATORY_SETUP_CHECKLIST SETUP_COMPLETION_CONFIRMATION
  ) ++ ["⚠️⚠️⚠️_STOP_DO_NOT_PROCEED_UNTIL_SETUP_COMPLETE_⚠️⚠️⚠️"]

  @api_schema_keys ~w(
    description request_formats hook_result_format explorer_result_format
    reviewer_result_format workflow_steps_format task_fields embedded_objects
    plugin_versions validation_modes valid_capabilities
  )

  describe "GET /api/agent/onboarding" do
    setup %{conn: conn} do
      %{conn: get(conn, ~p"/api/agent/onboarding")}
    end

    test "returns 200 with exactly the expected top-level sections", %{conn: conn} do
      body = json_response(conn, 200)
      keys = body |> Map.keys() |> MapSet.new()

      assert keys == MapSet.new(@onboarding_keys),
             "onboarding top-level key set drifted — external agents depend on it"
    end

    test "api_schema exposes exactly the documented key set", %{conn: conn} do
      body = json_response(conn, 200)
      keys = body["api_schema"] |> Map.keys() |> MapSet.new()

      assert keys == MapSet.new(@api_schema_keys),
             "api_schema key set drifted — future edits to the SchemaDoc literal must be deliberate"
    end

    test "the composed sections resolve to non-empty maps from their extracted modules",
         %{conn: conn} do
      body = json_response(conn, 200)

      # SchemaDoc / MultiAgentInstructions / SetupDocs sections are present and
      # non-empty after being lifted out of the AgentJSON literal.
      assert map_size(body["api_schema"]) > 0
      assert map_size(body["multi_agent_instructions"]) > 0
      assert map_size(body["file_templates"]) > 0
      assert map_size(body["memory_strategy"]) > 0
      assert map_size(body["session_initialization"]) > 0
    end

    # D356: agents learn from onboarding that a full column rejects a single
    # work/defect create with 422, and that goals are never WIP-checked.
    test "the POST /api/tasks creation entry describes the WIP limit 422", %{conn: conn} do
      body = json_response(conn, 200)

      create =
        body
        |> get_in(["api_reference", "endpoints", "creation"])
        |> Enum.find(&(&1["method"] == "POST" and &1["path"] == "/api/tasks"))

      assert create["description"] =~ "WIP limit returns 422"
      assert create["description"] =~ "goals are never WIP-checked"
      assert create["description"] =~ "a goal cannot contain a goal"
    end

    # W2220: agents learn how a workspace token names its board.
    test "describes workspace tokens and the board selector", %{conn: conn} do
      section = conn |> json_response(200) |> get_in(["api_reference", "workspace_tokens"])

      assert section["board_selector"]["header"] == "X-Stride-Board"
      assert section["board_selector"]["parameter"] == "board_id"
      assert section["discovery"] =~ "GET /api/boards"
      assert section["expiry_days"] == 90
      assert Map.keys(section["errors"]) |> Enum.sort() == ["400", "404"]
      assert section["documentation_url"] =~ "/docs/api/get_boards.md"
    end

    # W2215: agents discover the comment API from onboarding, so both verbs must
    # be listed, each pointing at its own reference page.
    test "lists GET /api/tasks/:id/comments under discovery", %{conn: conn} do
      body = json_response(conn, 200)

      list =
        body
        |> get_in(["api_reference", "endpoints", "discovery"])
        |> Enum.find(&(&1["method"] == "GET" and &1["path"] == "/api/tasks/:id/comments"))

      assert list, "expected GET /api/tasks/:id/comments in api_reference.endpoints.discovery"
      assert list["auth_required"] == true
      assert list["documentation_url"] =~ "/docs/api/get_tasks_id_comments.md"
      assert list["description"] =~ "oldest first"
      assert list["description"] =~ "comment_count"
    end

    test "lists POST /api/tasks/:id/comments under management", %{conn: conn} do
      body = json_response(conn, 200)

      create =
        body
        |> get_in(["api_reference", "endpoints", "management"])
        |> Enum.find(&(&1["method"] == "POST" and &1["path"] == "/api/tasks/:id/comments"))

      assert create, "expected POST /api/tasks/:id/comments in api_reference.endpoints.management"
      assert create["auth_required"] == true
      assert create["required_parameters"] == ["content"]
      assert create["returns_hooks"] == []
      assert create["documentation_url"] =~ "/docs/api/post_tasks_id_comments.md"
      assert create["description"] =~ "@[Name](user:ID)"
      assert create["description"] =~ "agent_model, then agent_name, then the token's last agent"
      assert create["description"] =~ "never put a secret in one"
    end

    test "the quick reference card names both comment endpoints", %{conn: conn} do
      body = json_response(conn, 200)
      comments = get_in(body, ["quick_reference_card", "key_endpoints", "comments"])

      assert comments =~ "GET /api/tasks/:id/comments"
      assert comments =~ "POST /api/tasks/:id/comments"
    end

    # D358: there is no `review` task status — a task awaiting review keeps
    # `in_progress` and only its column changes — so the hook environment
    # docs must list exactly the Task status enum.
    test "hook environment lists only valid statuses", %{conn: conn} do
      body = json_response(conn, 200)

      entry =
        body
        |> get_in(["hooks", "environment_variables"])
        |> Enum.find(&String.starts_with?(&1, "TASK_STATUS"))

      assert entry, "expected a TASK_STATUS entry in hooks.environment_variables"

      [_, listed] = Regex.run(~r/\(([^)]*)\)/, entry)
      listed = listed |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.sort()

      expected =
        Kanban.Tasks.Task |> Ecto.Enum.values(:status) |> Enum.map(&to_string/1) |> Enum.sort()

      assert listed == expected
      refute "review" in listed
    end
  end

  # D386: the onboarding text stated 60s/120s hook timeouts and a four-hook
  # model while hooks.available_hooks (from Kanban.Hooks) said 600000 ms for
  # five hooks. The text is now read from Kanban.Hooks; these tests fail if a
  # stated timeout or the hook list drifts from it again.
  describe "GET /api/agent/onboarding hook text (D386)" do
    setup %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      %{body: json_response(conn, 200)}
    end

    test "every stated hook timeout matches Kanban.Hooks", %{body: body} do
      expected = Map.new(Kanban.Hooks.list_hooks(), &{elem(&1, 0), elem(&1, 1)})

      template_sections =
        body
        |> get_in(["file_templates", "stride_md"])
        |> String.split("\n## ")
        |> Enum.drop(1)

      lines =
        get_in(body, ["hooks", "execution_flow"]) ++
          get_in(body, ["quick_reference_card", "hook_execution_order"]) ++ template_sections

      stated =
        for line <- lines,
            [_, blocking, seconds] <- Regex.scan(~r/\((non-blocking|blocking), (\d+)s/, line) do
          name = expected |> Map.keys() |> Enum.find(&String.contains?(line, &1))
          assert name, "no hook name in a line stating a timeout: #{line}"
          {name, blocking, String.to_integer(seconds)}
        end

      assert length(stated) >= map_size(expected)

      for {name, blocking, seconds} <- stated do
        assert seconds * 1000 == expected[name].timeout, "#{name} timeout drifted: #{seconds}s"
        assert blocking == if(expected[name].blocking, do: "blocking", else: "non-blocking")
      end

      # Every hook, after_goal included, has its timeout stated in the template.
      stated_names = stated |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert stated_names == expected |> Map.keys() |> Enum.sort()
    end

    test "available_hooks describes every hook, after_goal included", %{body: body} do
      hooks = get_in(body, ["hooks", "available_hooks"])

      assert Enum.map(hooks, & &1["name"]) == Enum.map(Kanban.Hooks.list_hooks(), &elem(&1, 0))

      for hook <- hooks do
        assert is_binary(hook["when"]) and hook["when"] != "Unknown", hook["name"]
        assert is_binary(hook["typical_use"]) and hook["typical_use"] != "Unknown", hook["name"]
      end

      after_goal = Enum.find(hooks, &(&1["name"] == "after_goal"))
      assert after_goal["when"] =~ "goal"
    end

    test "no text describes a four-hook model", %{body: body} do
      texts =
        get_in(body, ["hooks", "execution_flow"]) ++
          (body |> get_in(["common_mistakes_agents_make", "mistakes"]) |> Enum.map(& &1["fix"])) ++
          get_in(body, ["overview", "key_features"])

      for text <- texts, do: refute(text =~ ~r/four (hooks|lifecycle)/i, text)

      assert body |> get_in(["hooks", "execution_flow"]) |> Enum.any?(&(&1 =~ "after_goal"))
      assert get_in(body, ["quick_reference_card", "workflow"]) =~ "after_goal"
      assert get_in(body, ["file_templates", "stride_md"]) =~ "\n## after_goal\n"
    end

    test "complete and mark_reviewed list after_goal among their hooks", %{body: body} do
      management = get_in(body, ["api_reference", "endpoints", "management"])

      for path <- ["/api/tasks/:id/complete", "/api/tasks/:id/mark_reviewed"] do
        entry = Enum.find(management, &(&1["method"] == "PATCH" and &1["path"] == path))
        assert Enum.any?(entry["returns_hooks"], &String.starts_with?(&1, "after_goal")), path
      end
    end

    test "the API reference lists the after_goal and mark_done endpoints", %{body: body} do
      endpoints = body |> get_in(["api_reference", "endpoints"]) |> Map.values() |> List.flatten()

      for {method, path, doc} <- [
            {"PATCH", "/api/tasks/:id/after_goal", "patch_tasks_id_after_goal.md"},
            {"GET", "/api/tasks/:id/after_goal_status", "get_tasks_id_after_goal_status.md"},
            {"PATCH", "/api/tasks/:id/mark_done", "patch_tasks_id_mark_done.md"}
          ] do
        entry = Enum.find(endpoints, &(&1["method"] == method and &1["path"] == path))
        assert entry, "expected #{method} #{path} in api_reference.endpoints"
        assert entry["documentation_url"] =~ "/docs/api/#{doc}"
        assert "docs/api" |> Path.join(doc) |> File.exists?()
      end

      key_endpoints = get_in(body, ["quick_reference_card", "key_endpoints"])
      assert key_endpoints["after_goal"] =~ "PATCH /api/tasks/:id/after_goal"
      assert key_endpoints["after_goal_status"] =~ "GET /api/tasks/:id/after_goal_status"
      assert key_endpoints["mark_done"] =~ "PATCH /api/tasks/:id/mark_done"
    end
  end

  # D389: built only from what the onboarding payload serves, a completion must
  # be accepted, and dropping any parameter it calls required must be rejected.
  # Strict mode is on because it is the production default.
  describe "PATCH /api/tasks/:id/complete built from the onboarding payload (D389)" do
    @describetag :capture_log

    setup %{conn: conn} do
      previous = Application.get_env(:kanban, :strict_completion_validation, false)
      Application.put_env(:kanban, :strict_completion_validation, true)
      on_exit(fn -> Application.put_env(:kanban, :strict_completion_validation, previous) end)

      onboarding = conn |> get(~p"/api/agent/onboarding") |> json_response(200)

      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      {:ok, {_token, plain}} = ApiTokens.create_api_token(user, board, %{"name" => "D389"})
      doing = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Doing"))

      {:ok, task} =
        Tasks.create_task(doing, %{
          "title" => "Completion built from the docs",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "needs_review" => true
        })

      authed =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain}")

      %{onboarding: onboarding, authed: authed, task: task}
    end

    defp documented_complete_parameters(onboarding) do
      onboarding["workflow"]
      |> Enum.find(&(&1["name"] == "complete_task"))
      |> Map.fetch!("required_parameters")
    end

    # A value for each documented parameter, taken from the served examples
    # where the schema has one.
    defp completion_from_docs(onboarding) do
      schema = onboarding["api_schema"]
      hook = schema["hook_result_format"]["example"]

      %{
        "after_doing_result" => hook,
        "before_review_result" => hook,
        "completion_summary" => "Built from the onboarding payload only.",
        "actual_complexity" => "small",
        "actual_files_changed" => "lib/foo.ex",
        "time_spent_minutes" => 5,
        "explorer_result" => schema["explorer_result_format"]["example"],
        "reviewer_result" => schema["reviewer_result_format"]["structured_example"]
      }
    end

    test "complete_task required_parameters match the gate", ctx do
      %{onboarding: onboarding, authed: authed, task: task} = ctx
      documented = documented_complete_parameters(onboarding)
      params = completion_from_docs(onboarding)

      assert documented == EndpointDocs.complete_required_parameters()
      assert params |> Map.keys() |> Enum.sort() == Enum.sort(documented)

      # Every documented parameter is really required ...
      for param <- documented do
        conn = patch(authed, ~p"/api/tasks/#{task.id}/complete", Map.delete(params, param))

        assert conn.status == 422,
               "completion without #{param} returned #{conn.status}, not 422"
      end

      # ... and nothing undocumented is: the documented set alone completes.
      conn = patch(authed, ~p"/api/tasks/#{task.id}/complete", params)
      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "the plain reviewer_result example completes too", ctx do
      %{onboarding: onboarding, authed: authed, task: task} = ctx
      example = onboarding["api_schema"]["reviewer_result_format"]["example"]
      params = onboarding |> completion_from_docs() |> Map.put("reviewer_result", example)

      conn = patch(authed, ~p"/api/tasks/#{task.id}/complete", params)
      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "the quick reference card names the real required parameters", %{onboarding: onboarding} do
      endpoints = onboarding["quick_reference_card"]["key_endpoints"]

      for param <- EndpointDocs.complete_required_parameters() do
        assert endpoints["complete"] =~ param
      end

      assert endpoints["mark_reviewed"] =~ "after_review_result"
      assert onboarding["quick_reference_card"]["critical_requirement"] =~ "after_review_result"
    end
  end
end
