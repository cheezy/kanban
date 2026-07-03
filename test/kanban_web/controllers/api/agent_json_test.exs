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
  end
end
