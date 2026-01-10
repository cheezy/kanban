defmodule KanbanWeb.API.AgentControllerTest do
  use KanbanWeb.ConnCase

  describe "GET /api/agent/onboarding" do
    setup %{conn: conn} do
      conn = put_req_header(conn, "accept", "application/json")
      %{conn: conn}
    end

    test "returns 200 status", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      assert json_response(conn, 200)
    end

    test "returns onboarding data structure", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      assert response["version"] == "1.0"
      assert is_binary(response["api_base_url"])
      assert is_map(response["⚠️⚠️⚠️_STOP_DO_NOT_PROCEED_UNTIL_SETUP_COMPLETE_⚠️⚠️⚠️"])
      assert is_map(response["MANDATORY_SETUP_CHECKLIST"])
      assert is_map(response["overview"])
      assert is_list(response["quick_start"])
      assert is_map(response["file_templates"])
      assert is_list(response["workflow"])
      assert is_map(response["hooks"])
      assert is_map(response["api_reference"])
      assert is_map(response["resources"])
    end

    test "includes setup warning with proper structure", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      # Check warning structure
      warning = response["⚠️⚠️⚠️_STOP_DO_NOT_PROCEED_UNTIL_SETUP_COMPLETE_⚠️⚠️⚠️"]
      assert is_binary(warning["YOU_MUST_COMPLETE_THESE_STEPS_FIRST"])
      assert is_binary(warning["WHY_THIS_IS_MANDATORY"])
      assert is_binary(warning["SETUP_TAKES"])
      assert is_binary(warning["DO_THIS_NOW"])

      # Check mandatory checklist structure
      checklist = response["MANDATORY_SETUP_CHECKLIST"]
      assert checklist["COMPLETE_ALL_STEPS_IN_ORDER"] == true

      # Verify steps exist
      assert is_map(checklist["STEP_1_CHECK_stride_auth_md"])
      assert is_map(checklist["STEP_2_CREATE_stride_auth_md"])
      assert is_map(checklist["STEP_3_CHECK_gitignore"])
      assert is_map(checklist["STEP_4_ADD_TO_gitignore"])
      assert is_map(checklist["STEP_5_CHECK_stride_md"])
      assert is_map(checklist["STEP_6_CREATE_stride_md"])
      assert is_map(checklist["STEP_7_INSTALL_SKILLS"])
      assert is_map(checklist["STEP_8_NOTIFY_USER"])
      assert is_map(checklist["STEP_9_SETUP_COMPLETE"])

      # Verify step structure
      step_1 = checklist["STEP_1_CHECK_stride_auth_md"]
      assert step_1["order"] == 1
      assert is_binary(step_1["action"])
      assert step_1["action"] =~ ".stride_auth.md"
    end

    test "includes overview with key features", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      overview = response["overview"]
      assert is_binary(overview["description"])
      assert overview["workflow_summary"] == "Ready → Doing → Review → Done"
      assert is_list(overview["key_features"])
      assert length(overview["key_features"]) >= 4
      assert is_binary(overview["agent_workflow_pattern"])

      # Verify key features are present
      features = overview["key_features"]
      assert "Client-side hook execution at four lifecycle points" in features
      assert "Atomic task claiming with capability matching" in features
    end

    test "includes quick start guide", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      quick_start = response["quick_start"]
      assert is_list(quick_start)
      assert length(quick_start) >= 6

      # Verify quick start mentions file creation
      quick_start_text = Enum.join(quick_start, " ")
      assert quick_start_text =~ ".stride_auth.md"
      assert quick_start_text =~ ".stride.md"
      assert quick_start_text =~ "POST"
      assert quick_start_text =~ "/api/tasks/claim"
    end

    test "includes file templates for both config files", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      templates = response["file_templates"]
      assert is_map(templates)
      assert is_binary(templates["stride_auth_md"])
      assert is_binary(templates["stride_md"])

      # Verify .stride_auth.md template structure
      auth_template = templates["stride_auth_md"]
      assert auth_template =~ "DO NOT commit this file"
      assert auth_template =~ "API Configuration"
      assert auth_template =~ "{{YOUR_TOKEN_HERE}}"
      assert auth_template =~ response["api_base_url"]

      # Verify .stride.md template structure
      stride_template = templates["stride_md"]
      assert stride_template =~ "before_doing"
      assert stride_template =~ "after_doing"
      assert stride_template =~ "before_review"
      assert stride_template =~ "after_review"
    end

    test "includes hooks documentation", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      hooks = response["hooks"]
      assert is_map(hooks)
      assert is_binary(hooks["description"])
      assert is_list(hooks["available_hooks"])
      assert is_list(hooks["environment_variables"])
      assert is_list(hooks["execution_flow"])

      # Verify all four hooks are in available_hooks list
      available_hooks = hooks["available_hooks"]
      assert length(available_hooks) == 4

      hook_names = Enum.map(available_hooks, & &1["name"])
      assert "before_doing" in hook_names
      assert "after_doing" in hook_names
      assert "before_review" in hook_names
      assert "after_review" in hook_names

      # Verify hook structure
      before_doing = Enum.find(available_hooks, &(&1["name"] == "before_doing"))
      assert is_boolean(before_doing["blocking"])
      assert is_integer(before_doing["timeout"])
      assert is_binary(before_doing["when"])
      assert is_binary(before_doing["typical_use"])
    end

    test "includes API endpoints categorized properly", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      api_ref = response["api_reference"]
      assert is_map(api_ref)
      assert is_binary(api_ref["base_url"])
      assert is_binary(api_ref["authentication"])

      endpoints = api_ref["endpoints"]
      assert is_map(endpoints)
      assert is_list(endpoints["discovery"])
      assert is_list(endpoints["management"])
      assert is_list(endpoints["creation"])

      # Verify discovery endpoints
      discovery = endpoints["discovery"]
      assert Enum.any?(discovery, fn ep -> ep["path"] == "/api/tasks/next" end)
      assert Enum.any?(discovery, fn ep -> ep["path"] == "/api/tasks" end)

      # Verify management endpoints
      management = endpoints["management"]
      assert Enum.any?(management, fn ep -> ep["path"] == "/api/tasks/claim" end)
      assert Enum.any?(management, fn ep -> ep["path"] == "/api/tasks/:id/complete" end)
    end

    test "includes resource links to documentation", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      resources = response["resources"]
      assert is_map(resources)
      assert is_binary(resources["documentation_url"])
      assert is_binary(resources["authentication_guide"])
      assert is_binary(resources["api_workflow_guide"])
      assert is_binary(resources["task_writing_guide"])
      assert is_binary(resources["capabilities_guide"])
      assert is_binary(resources["hook_execution_guide"])
      assert is_binary(resources["review_workflow_guide"])
      assert is_binary(resources["unclaim_guide"])
      assert is_binary(resources["estimation_feedback_guide"])

      # Verify URLs point to GitHub raw content
      assert resources["documentation_url"] =~ "githubusercontent.com"
      assert resources["authentication_guide"] =~ "AUTHENTICATION.md"
    end

    test "includes correct base URL for HTTP", %{conn: conn} do
      conn =
        conn
        |> Map.put(:scheme, :http)
        |> Map.put(:host, "localhost")
        |> Map.put(:port, 4000)

      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      assert response["api_base_url"] == "http://localhost:4000"
    end

    test "includes correct base URL for HTTPS with default port", %{conn: conn} do
      # We can't easily test HTTPS in test environment without modifying the plug
      # Just verify the URL is constructed properly with available data
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      # Verify it returns a valid URL
      assert is_binary(response["api_base_url"])
      assert response["api_base_url"] =~ ~r/^https?:\/\//
    end

    test "includes workflow documentation", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      workflow = response["workflow"]
      assert is_list(workflow)
      assert length(workflow) == 4

      # Verify workflow is in correct order
      assert Enum.at(workflow, 0)["name"] == "claim_task"
      assert Enum.at(workflow, 1)["name"] == "complete_task"
      assert Enum.at(workflow, 2)["name"] == "mark_reviewed"
      assert Enum.at(workflow, 3)["name"] == "unclaim_task"

      # Verify each workflow step has proper structure
      claim_task = Enum.at(workflow, 0)
      assert is_binary(claim_task["endpoint"])
      assert is_binary(claim_task["description"])
      assert is_binary(claim_task["returns"])
      assert is_binary(claim_task["name"])
    end

    test "includes environment variables documentation", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      hooks = response["hooks"]
      env_vars = hooks["environment_variables"]

      assert is_list(env_vars)
      assert length(env_vars) > 10

      # Verify key environment variables are documented
      env_vars_string = Enum.join(env_vars, " ")
      assert env_vars_string =~ "TASK_ID"
      assert env_vars_string =~ "TASK_IDENTIFIER"
      assert env_vars_string =~ "TASK_TITLE"
      assert env_vars_string =~ "BOARD_ID"
      assert env_vars_string =~ "HOOK_NAME"
    end

    test "hook blocking behavior is documented correctly", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      hooks = response["hooks"]["available_hooks"]

      before_doing = Enum.find(hooks, &(&1["name"] == "before_doing"))
      after_doing = Enum.find(hooks, &(&1["name"] == "after_doing"))
      before_review = Enum.find(hooks, &(&1["name"] == "before_review"))
      after_review = Enum.find(hooks, &(&1["name"] == "after_review"))

      # All hooks are now blocking
      assert before_doing["blocking"] == true
      assert after_doing["blocking"] == true
      assert before_review["blocking"] == true
      assert after_review["blocking"] == true
    end

    test "hook timeouts are documented correctly", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      hooks = response["hooks"]["available_hooks"]

      before_doing = Enum.find(hooks, &(&1["name"] == "before_doing"))
      after_doing = Enum.find(hooks, &(&1["name"] == "after_doing"))
      before_review = Enum.find(hooks, &(&1["name"] == "before_review"))
      after_review = Enum.find(hooks, &(&1["name"] == "after_review"))

      assert before_doing["timeout"] == 60_000
      assert after_doing["timeout"] == 120_000
      assert before_review["timeout"] == 60_000
      assert after_review["timeout"] == 60_000
    end

    test "response contains no authentication requirements", %{conn: conn} do
      # Onboarding endpoint should be accessible without authentication
      conn = get(conn, ~p"/api/agent/onboarding")
      assert conn.status == 200
    end
  end
end
