defmodule KanbanWeb.API.AgentJSONTest do
  @moduledoc """
  Shape guard for the agent onboarding payload after the W1442 split of the
  literals into KanbanWeb.API.Agent.{SchemaDoc, MultiAgentInstructions,
  SetupDocs}. The onboarding endpoint is consumed by external agents, so a
  changed or dropped top-level key silently breaks integrations — these tests
  fail loudly if the composed key set drifts.
  """
  use KanbanWeb.ConnCase, async: true

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
end
