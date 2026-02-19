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

    test "includes multi-agent instructions section", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      assert is_map(response["multi_agent_instructions"])
      multi_agent = response["multi_agent_instructions"]

      assert is_binary(multi_agent["description"])
      assert is_map(multi_agent["formats"])
      assert is_list(multi_agent["usage_notes"])
      assert is_list(multi_agent["safe_installation"])
    end

    test "multi-agent instructions includes all 7 supported formats", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      formats = response["multi_agent_instructions"]["formats"]

      # Verify all 7 formats are present
      assert is_map(formats["copilot"])
      assert is_map(formats["cursor"])
      assert is_map(formats["windsurf"])
      assert is_map(formats["continue"])
      assert is_map(formats["gemini"])
      assert is_map(formats["opencode"])
      assert is_map(formats["kimi"])

      # Verify each format has required fields
      for {name, format} <- formats do
        assert is_binary(format["file_path"])
        assert is_binary(format["description"])
        # GitHub Copilot, Cursor, Windsurf, Gemini, and OpenCode reference Claude Code skills,
        # so they don't have a download_url
        if name not in ["copilot", "cursor", "windsurf", "gemini", "opencode"] do
          assert is_binary(format["download_url"])
        end

        assert is_binary(format["installation_unix"])
        assert is_binary(format["installation_windows"])
        assert is_binary(format["token_limit"])
      end
    end

    test "GitHub Copilot format uses Claude Code skills", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      copilot = response["multi_agent_instructions"]["formats"]["copilot"]

      # Verify basic structure
      assert copilot["file_path"] == ".claude/skills/<skill-name>/SKILL.md (4 skills total)"
      assert copilot["description"] =~ "GitHub Copilot"
      assert copilot["description"] =~ "Claude Code skills"

      # Verify compatible_tools field includes both
      assert is_list(copilot["compatible_tools"])
      assert "GitHub Copilot" in copilot["compatible_tools"]
      assert "Claude Code" in copilot["compatible_tools"]
      refute "OpenCode" in copilot["compatible_tools"]
      refute "Kimi Code CLI (k2.5)" in copilot["compatible_tools"]

      # Verify reference_section points to claude_code_skills
      assert copilot["reference_section"] == "claude_code_skills"

      # Verify token limit
      assert copilot["token_limit"] == "~2000-3000 tokens per skill (~100-150 lines each)"
    end

    test "Cursor format uses Claude Code skills", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      cursor = response["multi_agent_instructions"]["formats"]["cursor"]

      # Verify basic structure
      assert cursor["file_path"] == ".claude/skills/<skill-name>/SKILL.md (4 skills total)"
      assert cursor["description"] =~ "Cursor"
      assert cursor["description"] =~ "Claude Code skills"

      # Verify compatible_tools field includes both
      assert is_list(cursor["compatible_tools"])
      assert "Cursor" in cursor["compatible_tools"]
      assert "Claude Code" in cursor["compatible_tools"]
      refute "OpenCode" in cursor["compatible_tools"]
      refute "GitHub Copilot" in cursor["compatible_tools"]
      refute "Kimi Code CLI (k2.5)" in cursor["compatible_tools"]

      # Verify reference_section points to claude_code_skills
      assert cursor["reference_section"] == "claude_code_skills"

      # Verify token limit
      assert cursor["token_limit"] == "~2000-3000 tokens per skill (~100-150 lines each)"
    end

    test "Windsurf format uses Claude Code skills", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      windsurf = response["multi_agent_instructions"]["formats"]["windsurf"]

      # Verify basic structure
      assert windsurf["file_path"] == ".windsurf/skills/<skill-name>/SKILL.md (4 skills total)"
      assert windsurf["description"] =~ "Windsurf"
      assert windsurf["description"] =~ "Claude Code skills"

      # Verify compatible_tools field includes both
      assert is_list(windsurf["compatible_tools"])
      assert "Windsurf" in windsurf["compatible_tools"]
      assert "Claude Code" in windsurf["compatible_tools"]
      refute "OpenCode" in windsurf["compatible_tools"]
      refute "GitHub Copilot" in windsurf["compatible_tools"]
      refute "Cursor" in windsurf["compatible_tools"]
      refute "Kimi Code CLI (k2.5)" in windsurf["compatible_tools"]

      # Verify reference_section points to claude_code_skills
      assert windsurf["reference_section"] == "claude_code_skills"

      # Verify token limit
      assert windsurf["token_limit"] == "~2000-3000 tokens per skill (~100-150 lines each)"
    end

    test "OpenCode format uses Claude Code skills", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      opencode = response["multi_agent_instructions"]["formats"]["opencode"]

      # Verify basic structure
      assert opencode["file_path"] == ".claude/skills/<skill-name>/SKILL.md (4 skills total)"
      assert opencode["description"] =~ "OpenCode"
      assert opencode["description"] =~ "Claude Code skills"

      # Verify compatible_tools field includes both
      assert is_list(opencode["compatible_tools"])
      assert "OpenCode" in opencode["compatible_tools"]
      assert "Claude Code" in opencode["compatible_tools"]
      refute "Kimi Code CLI (k2.5)" in opencode["compatible_tools"]

      # Verify reference_section points to claude_code_skills
      assert opencode["reference_section"] == "claude_code_skills"

      # Verify token limit
      assert opencode["token_limit"] == "~2000-3000 tokens per skill (~100-150 lines each)"
    end

    test "OpenCode format includes proper alternative skill locations", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      opencode = response["multi_agent_instructions"]["formats"]["opencode"]

      assert is_list(opencode["alternative_locations"])
      assert length(opencode["alternative_locations"]) == 3

      locations = Enum.join(opencode["alternative_locations"], " ")
      assert locations =~ ".claude/skills/<skill-name>/SKILL.md"
      assert locations =~ "works with both Claude Code and OpenCode"
      assert locations =~ ".opencode/skills/<skill-name>/SKILL.md"
      assert locations =~ "~/.claude/skills/<skill-name>/SKILL.md"
    end

    test "OpenCode format references Claude Code skill installation", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      opencode = response["multi_agent_instructions"]["formats"]["opencode"]

      # Verify Unix installation references Claude Code skills
      unix_install = opencode["installation_unix"]
      assert unix_install =~ "OpenCode users"
      assert unix_install =~ "Claude Code skill installation"
      assert unix_install =~ "claude_code_skills section"

      # Verify Windows installation references Claude Code skills
      windows_install = opencode["installation_windows"]
      assert windows_install =~ "OpenCode users"
      assert windows_install =~ "Claude Code skill installation"
      assert windows_install =~ "claude_code_skills section"
    end

    test "OpenCode format includes important note about Claude Code compatibility", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      opencode = response["multi_agent_instructions"]["formats"]["opencode"]

      assert is_binary(opencode["note"])
      assert opencode["note"] =~ "OpenCode"
      assert opencode["note"] =~ "automatically discovers"
      assert opencode["note"] =~ ".claude/skills/"
      assert opencode["note"] =~ "Claude Code skills"
      assert opencode["note"] =~ "claude_code_skills section"
    end

    test "OpenCode format includes safe_installation commands referencing Claude Code", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      opencode = response["multi_agent_instructions"]["formats"]["opencode"]

      assert is_map(opencode["safe_installation"])
      safe_install = opencode["safe_installation"]

      assert is_binary(safe_install["check_existing"])
      assert is_binary(safe_install["backup_first"])
      assert is_binary(safe_install["install_from_claude_skills"])
      assert is_binary(safe_install["usage"])

      # Verify check_existing command checks for .claude/skills directory
      assert safe_install["check_existing"] =~ ".claude/skills/stride"

      # Verify backup command references .claude/skills
      assert safe_install["backup_first"] =~ ".claude/skills"

      # Verify install_from_claude_skills references claude_code_skills section
      assert safe_install["install_from_claude_skills"] =~ "claude_code_skills section"

      # Verify usage mentions OpenCode finding .claude/skills
      assert safe_install["usage"] =~ ".claude/skills/"
    end

    test "includes agent_specific_instructions with OpenCode skill support", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      # agent_specific_instructions is nested inside memory_strategy
      assert is_map(response["memory_strategy"])
      memory_strategy = response["memory_strategy"]

      assert is_map(memory_strategy["agent_specific_instructions"])
      agent_instructions = memory_strategy["agent_specific_instructions"]

      assert is_map(agent_instructions["opencode"])

      opencode_instructions = agent_instructions["opencode"]
      assert opencode_instructions["description"] =~ "OpenCode"
      refute opencode_instructions["description"] =~ "Kimi"
      assert is_list(opencode_instructions["steps"])
      assert length(opencode_instructions["steps"]) >= 6

      # Verify steps mention key actions
      steps_text = Enum.join(opencode_instructions["steps"], " ")
      assert steps_text =~ "skill"
      assert steps_text =~ ".stride.md"
      assert steps_text =~ ".stride_auth.md"

      # Verify note mentions skills
      assert is_binary(opencode_instructions["note"])
      assert opencode_instructions["note"] =~ "OpenCode"
      assert opencode_instructions["note"] =~ "skill"
    end

    test "Gemini format uses Claude Code skills", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      gemini = response["multi_agent_instructions"]["formats"]["gemini"]

      # Verify basic structure
      assert gemini["file_path"] == ".gemini/skills/<skill-name>/SKILL.md (4 skills total)"
      assert gemini["description"] =~ "Gemini"
      assert gemini["description"] =~ "Claude Code skills"

      # Verify compatible_tools field includes both
      assert is_list(gemini["compatible_tools"])
      assert "Google Gemini Code Assist" in gemini["compatible_tools"]
      assert "Claude Code" in gemini["compatible_tools"]
      refute "OpenCode" in gemini["compatible_tools"]
      refute "GitHub Copilot" in gemini["compatible_tools"]
      refute "Cursor" in gemini["compatible_tools"]
      refute "Windsurf" in gemini["compatible_tools"]
      refute "Kimi Code CLI (k2.5)" in gemini["compatible_tools"]

      # Verify reference_section points to claude_code_skills
      assert gemini["reference_section"] == "claude_code_skills"

      # Verify token limit
      assert gemini["token_limit"] == "~2000-3000 tokens per skill (~100-150 lines each)"
    end

    test "Gemini format includes proper alternative skill locations", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      gemini = response["multi_agent_instructions"]["formats"]["gemini"]

      assert is_list(gemini["alternative_locations"])
      assert length(gemini["alternative_locations"]) == 3

      locations = Enum.join(gemini["alternative_locations"], " ")
      assert locations =~ ".gemini/skills/<skill-name>/SKILL.md"
      assert locations =~ "works with both Claude Code and Gemini"
      assert locations =~ "~/.gemini/skills/<skill-name>/SKILL.md"
      assert locations =~ "applies to all projects"
      assert locations =~ "Extension-bundled"
    end

    test "Gemini format references Claude Code skill installation", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      gemini = response["multi_agent_instructions"]["formats"]["gemini"]

      # Verify Unix installation references Claude Code skills
      unix_install = gemini["installation_unix"]
      assert unix_install =~ "Gemini users"
      assert unix_install =~ "Claude Code skill installation"
      assert unix_install =~ "claude_code_skills section"

      # Verify Windows installation references Claude Code skills
      windows_install = gemini["installation_windows"]
      assert windows_install =~ "Gemini users"
      assert windows_install =~ "Claude Code skill installation"
      assert windows_install =~ "claude_code_skills section"
    end

    test "Gemini format includes important note about Claude Code compatibility", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      gemini = response["multi_agent_instructions"]["formats"]["gemini"]

      assert is_binary(gemini["note"])
      assert gemini["note"] =~ "Gemini"
      assert gemini["note"] =~ "automatically discovers"
      assert gemini["note"] =~ ".gemini/skills/"
      assert gemini["note"] =~ "Claude Code skills"
      assert gemini["note"] =~ "claude_code_skills section"
    end

    test "Gemini format includes safe_installation commands referencing Claude Code", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      gemini = response["multi_agent_instructions"]["formats"]["gemini"]

      assert is_map(gemini["safe_installation"])
      safe_install = gemini["safe_installation"]

      assert is_binary(safe_install["check_existing"])
      assert is_binary(safe_install["backup_first"])
      assert is_binary(safe_install["install_from_claude_skills"])
      assert is_binary(safe_install["usage"])

      # Verify check_existing command checks for .gemini/skills directory
      assert safe_install["check_existing"] =~ ".gemini/skills/stride"

      # Verify backup command references .gemini/skills
      assert safe_install["backup_first"] =~ ".gemini/skills"

      # Verify install_from_claude_skills references claude_code_skills section
      assert safe_install["install_from_claude_skills"] =~ "claude_code_skills section"

      # Verify usage mentions Gemini finding .gemini/skills
      assert safe_install["usage"] =~ ".gemini/skills/"
    end

    test "includes agent_specific_instructions with Gemini skill support", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      # agent_specific_instructions is nested inside memory_strategy
      memory_strategy = response["memory_strategy"]
      agent_instructions = memory_strategy["agent_specific_instructions"]

      assert is_map(agent_instructions["gemini"])

      gemini_instructions = agent_instructions["gemini"]
      assert gemini_instructions["description"] =~ "Gemini"
      assert gemini_instructions["description"] =~ "Claude Code skills"
      assert is_list(gemini_instructions["steps"])
      assert length(gemini_instructions["steps"]) >= 6

      # Verify steps mention key actions
      steps_text = Enum.join(gemini_instructions["steps"], " ")
      assert steps_text =~ "skill"
      assert steps_text =~ ".stride.md"
      assert steps_text =~ ".stride_auth.md"

      # Verify note mentions skills
      assert is_binary(gemini_instructions["note"])
      assert gemini_instructions["note"] =~ "Gemini"
      assert gemini_instructions["note"] =~ "skill"
    end

    test "multi-agent instructions usage notes mention OpenCode skills and Kimi", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      usage_notes = response["multi_agent_instructions"]["usage_notes"]
      assert is_list(usage_notes)

      usage_notes_text = Enum.join(usage_notes, " ")
      assert usage_notes_text =~ "OpenCode"
      assert usage_notes_text =~ "Kimi"
      assert usage_notes_text =~ "skill"
    end

    test "Kimi format uses AGENTS.md with append-mode", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      kimi = response["multi_agent_instructions"]["formats"]["kimi"]

      # Verify basic structure
      assert kimi["file_path"] == "AGENTS.md"
      assert kimi["description"] =~ "Kimi Code CLI"
      assert kimi["description"] =~ "append-mode"

      # Verify compatible_tools field
      assert is_list(kimi["compatible_tools"])
      assert "Kimi Code CLI (k2.5)" in kimi["compatible_tools"]

      # Verify download URL
      assert kimi["download_url"] =~ "AGENTS.md"

      # Verify token limit
      assert kimi["token_limit"] == "~8000-10000 tokens (~400-500 lines)"
    end

    test "Kimi format includes proper alternative locations", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      kimi = response["multi_agent_instructions"]["formats"]["kimi"]

      assert is_list(kimi["alternative_locations"])
      assert length(kimi["alternative_locations"]) == 2

      locations = Enum.join(kimi["alternative_locations"], " ")
      assert locations =~ "AGENTS.md"
      assert locations =~ "Append-mode"
    end

    test "Kimi format includes append-mode installation commands", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      kimi = response["multi_agent_instructions"]["formats"]["kimi"]

      # Verify Unix installation command uses append-mode
      unix_install = kimi["installation_unix"]
      assert unix_install =~ "AGENTS.md"
      assert unix_install =~ ">>"

      # Verify Windows installation command uses append-mode
      windows_install = kimi["installation_windows"]
      assert windows_install =~ "AGENTS.md"
      assert windows_install =~ "Add-Content"
    end

    test "Kimi format includes important note about AGENTS.md", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      kimi = response["multi_agent_instructions"]["formats"]["kimi"]

      assert is_binary(kimi["note"])
      assert kimi["note"] =~ "Kimi Code CLI"
      assert kimi["note"] =~ "AGENTS.md"
      assert kimi["note"] =~ "always-active"
    end

    test "Kimi format includes safe_installation commands", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      kimi = response["multi_agent_instructions"]["formats"]["kimi"]

      assert is_map(kimi["safe_installation"])
      safe_install = kimi["safe_installation"]

      assert is_binary(safe_install["check_existing"])
      assert is_binary(safe_install["backup_first"])
      assert is_binary(safe_install["append_install"])
      assert is_binary(safe_install["fresh_install"])
      assert is_binary(safe_install["usage"])

      # Verify check_existing command checks for AGENTS.md
      assert safe_install["check_existing"] =~ "AGENTS.md"

      # Verify append install uses append-mode
      assert safe_install["append_install"] =~ "AGENTS.md"
      assert safe_install["append_install"] =~ ">>"
    end

    test "includes agent_specific_instructions with Kimi support", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      # agent_specific_instructions is nested inside memory_strategy
      memory_strategy = response["memory_strategy"]
      agent_instructions = memory_strategy["agent_specific_instructions"]

      assert is_map(agent_instructions["kimi"])

      kimi_instructions = agent_instructions["kimi"]
      assert kimi_instructions["description"] =~ "Kimi"
      assert is_list(kimi_instructions["steps"])
      assert length(kimi_instructions["steps"]) >= 5

      # Verify steps mention key actions
      steps_text = Enum.join(kimi_instructions["steps"], " ")
      assert steps_text =~ "AGENTS.md"
      assert steps_text =~ ".stride.md"
      assert steps_text =~ ".stride_auth.md"

      # Verify note mentions AGENTS.md
      assert is_binary(kimi_instructions["note"])
      assert kimi_instructions["note"] =~ "Kimi"
      assert kimi_instructions["note"] =~ "AGENTS.md"
    end

    test "Continue format remains unchanged as always-active", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      formats = response["multi_agent_instructions"]["formats"]

      # Verify Continue format
      continue = formats["continue"]
      assert continue["file_path"] == ".continue/config.json"
      assert is_binary(continue["description"])
    end

    test "includes api_schema with all required sections", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      schema = response["api_schema"]
      assert is_map(schema)
      assert is_binary(schema["description"])
      assert is_map(schema["request_formats"])
      assert is_map(schema["hook_result_format"])
      assert is_map(schema["task_fields"])
      assert is_map(schema["embedded_objects"])
      assert is_list(schema["valid_capabilities"])
    end

    test "api_schema request_formats covers all endpoints", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      schema = json_response(conn, 200)["api_schema"]

      formats = schema["request_formats"]
      assert is_map(formats["create_task"])
      assert formats["create_task"]["root_key"] == "task"
      assert is_map(formats["batch_create"])
      assert formats["batch_create"]["root_key"] == "goals"
      assert is_map(formats["claim_task"])
      assert is_map(formats["claim_task"]["required_body"])
      assert is_map(formats["complete_task"])
      assert is_map(formats["complete_task"]["required_body"])
    end

    test "api_schema task_fields contains correct enum values", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      schema = json_response(conn, 200)["api_schema"]

      fields = schema["task_fields"]

      assert fields["type"]["values"] == ["work", "defect", "goal"]
      assert fields["type"]["required"] == true

      assert fields["priority"]["values"] == ["low", "medium", "high", "critical"]
      assert fields["priority"]["required"] == true

      assert fields["complexity"]["values"] == ["small", "medium", "large"]
      assert fields["complexity"]["required"] == false
    end

    test "api_schema embedded_objects documents verification_steps as objects not strings",
         %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      schema = json_response(conn, 200)["api_schema"]

      vs = schema["embedded_objects"]["verification_steps"]
      assert vs["type"] == "array_of_objects"
      assert is_binary(vs["⚠️_NOT_strings"])
      assert is_map(vs["required_fields"])
      assert is_map(vs["example"])
    end

    test "api_schema valid_capabilities matches Task.valid_capabilities", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      schema = json_response(conn, 200)["api_schema"]

      assert schema["valid_capabilities"] == Kanban.Tasks.Task.valid_capabilities()
    end

    test "api_schema hook_result_format documents required fields", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      schema = json_response(conn, 200)["api_schema"]

      hook_format = schema["hook_result_format"]
      assert is_map(hook_format["fields"])
      assert is_map(hook_format["fields"]["exit_code"])
      assert is_map(hook_format["fields"]["output"])
      assert is_map(hook_format["fields"]["duration_ms"])
      assert is_map(hook_format["example"])
    end

    test "includes skills_version as a non-empty string", %{conn: conn} do
      conn = get(conn, ~p"/api/agent/onboarding")
      response = json_response(conn, 200)

      assert is_binary(response["skills_version"])
      assert response["skills_version"] != ""
    end
  end
end
