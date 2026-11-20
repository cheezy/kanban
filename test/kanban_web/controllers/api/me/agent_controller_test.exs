defmodule KanbanWeb.API.Me.AgentControllerTest do
  @moduledoc """
  Tests for `GET /api/me/agents` and `GET /api/me/goals/:id/after_goal`
  (`KanbanWeb.API.Me.AgentController`), W2761.
  """
  # async: false - some tests switch the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks

  @plan_required %{
    "error" => "plan_required",
    "feature" => "mobile_app",
    "message" => "The Stride app is available to boards in an Organization."
  }
  @not_found %{"error" => "Not Found"}

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {_phone, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})
    board = ai_optimized_board_fixture(user)

    %{user: user, scope: scope, board: board, cols: columns(board), phone: phone.access_token}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp api_get(token, path), do: token |> authed() |> get(path)

  defp agent_task(column, attrs),
    do: task_fixture(column, Map.merge(%{created_by_agent: "Claude"}, attrs))

  defp complete!(task) do
    {:ok, task} =
      Tasks.update_task(task, %{"status" => "completed", "completed_at" => DateTime.utc_now()})

    task
  end

  defp attempted_goal!(column, attempt) do
    goal =
      column
      |> task_fixture(%{type: :goal})
      |> Ecto.Changeset.change(%{after_goal_status: :pending})
      |> Repo.update!()

    {:ok, goal} = Tasks.report_after_goal(goal, attempt)
    goal
  end

  defp failed_goal!(column) do
    attempted_goal!(column, %{
      "exit_code" => 1,
      "output" => "boom: SECRET_TOKEN=abc123 at /home/ci/app",
      "duration_ms" => 4000,
      "reported_at" => "2026-11-18T10:00:00Z"
    })
  end

  defp into_org_workspace!(user, board) do
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, user)
    board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
    workspace
  end

  describe "GET /api/me/agents" do
    test "returns the roster and goal progress", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      agent_task(ctx.cols["Doing"], %{parent_id: goal.id, title: "Implement it"})
      task_fixture(ctx.cols["Ready"], %{parent_id: goal.id})
      agent_task(ctx.cols["Done"], %{created_by_agent: "Codex"}) |> complete!()

      assert %{"data" => %{"agents" => agents, "goals" => [entry]}} =
               ctx.phone |> api_get("/api/me/agents") |> json_response(200)

      by_name = Map.new(agents, &{&1["name"], &1})

      assert %{
               "status" => "working",
               "stuck" => false,
               "dormant" => false,
               "current_task" => %{"title" => "Implement it"},
               "owner" => nil
             } = by_name["Claude"]

      assert %{"status" => "idle", "current_task" => nil, "today" => 1} = by_name["Codex"]
      assert {:ok, _at, 0} = DateTime.from_iso8601(by_name["Codex"]["last_active_at"])

      assert entry == %{
               "id" => goal.id,
               "identifier" => goal.identifier,
               "title" => goal.title,
               "status" => "open",
               "board_id" => ctx.board.id,
               "counts" => %{
                 "total" => 2,
                 "completed" => 0,
                 "doing" => 1,
                 "review" => 0,
                 "blocked" => 0
               },
               "hook_failed" => false
             }
    end

    test "an agent's owner is named without an email", ctx do
      ctx.cols["Doing"] |> task_fixture(%{created_by_agent: "Claude", created_by_id: ctx.user.id})

      assert %{"data" => %{"agents" => [%{"owner" => owner}]}} =
               ctx.phone |> api_get("/api/me/agents") |> json_response(200)

      assert owner == %{"id" => ctx.user.id, "name" => ctx.user.name}
    end

    test "goal counts exclude the goal itself", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      agent_task(ctx.cols["Doing"], %{parent_id: goal.id})
      agent_task(ctx.cols["Review"], %{parent_id: goal.id})
      task_fixture(ctx.cols["Done"], %{parent_id: goal.id}) |> complete!()

      # The goal tree counts the goal as one of its own tasks.
      assert Kanban.Tasks.Goals.get_task_tree(goal.id, ctx.board.id).counts.total == 4

      assert %{"data" => %{"goals" => [%{"counts" => counts}]}} =
               ctx.phone |> api_get("/api/me/agents") |> json_response(200)

      assert counts == %{
               "total" => 3,
               "completed" => 1,
               "doing" => 1,
               "review" => 1,
               "blocked" => 0
             }
    end

    test "a goal whose last after_goal attempt failed is flagged", ctx do
      goal = failed_goal!(ctx.cols["Backlog"])
      agent_task(ctx.cols["Doing"], %{parent_id: goal.id})

      body = ctx.phone |> api_get("/api/me/agents") |> json_response(200)

      assert %{"data" => %{"goals" => [%{"hook_failed" => true}]}} = body
      refute Jason.encode!(body) =~ "boom"
    end

    test "an agent on two boards is one agent, and an unseen board adds nothing", ctx do
      second = ai_optimized_board_fixture(ctx.user)
      agent_task(ctx.cols["Doing"], %{})
      agent_task(columns(second)["Review"], %{})

      stranger = user_fixture()
      foreign = ai_optimized_board_fixture(stranger)
      foreign_goal = task_fixture(columns(foreign)["Backlog"], %{type: :goal})

      agent_task(columns(foreign)["Doing"], %{
        created_by_agent: "Gemini",
        parent_id: foreign_goal.id
      })

      assert %{"data" => %{"agents" => [%{"name" => "Claude"}], "goals" => []}} =
               ctx.phone |> api_get("/api/me/agents") |> json_response(200)
    end

    test "a free person gets plan_required while plans are enforced", ctx do
      enforce_plans()
      conn = api_get(ctx.phone, "/api/me/agents")

      assert json_response(conn, 403) == @plan_required
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "boards outside the plan are left out", ctx do
      enforce_plans()
      org_board = ai_optimized_board_fixture(ctx.user)
      into_org_workspace!(ctx.user, org_board)
      agent_task(columns(org_board)["Doing"], %{})
      agent_task(ctx.cols["Doing"], %{created_by_agent: "Codex"})

      assert %{"data" => %{"agents" => [%{"name" => "Claude"}]}} =
               ctx.phone |> api_get("/api/me/agents") |> json_response(200)
    end

    test "counts today's work in the device's time zone", ctx do
      at = :second |> DateTime.utc_now() |> DateTime.add(-12, :hour)

      {:ok, _task} =
        ctx.cols["Done"]
        |> agent_task(%{})
        |> Tasks.update_task(%{"status" => "completed", "completed_at" => at})

      # Twelve hours ago is "today" in exactly one of two zones twelve hours apart.
      {today_zone, other_zone} =
        if Kanban.Timezone.local_date(at, "Etc/UTC") == Kanban.Timezone.local_today("Etc/UTC"),
          do: {"Etc/UTC", "Etc/GMT-12"},
          else: {"Etc/GMT-12", "Etc/UTC"}

      for {zone, today} <- [{today_zone, 1}, {other_zone, 0}] do
        {_device, issued} =
          device_with_tokens_fixture(ctx.scope, %{device_class: :phone, time_zone: zone})

        assert %{"data" => %{"agents" => [%{"today" => ^today}]}} =
                 issued.access_token |> api_get("/api/me/agents") |> json_response(200)
      end
    end

    test "is sent private, no-store", ctx do
      conn = api_get(ctx.phone, "/api/me/agents")

      assert json_response(conn, 200) == %{"data" => %{"agents" => [], "goals" => []}}
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "refuses an agent API token and no token", ctx do
      {:ok, {_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ctx.board, %{name: "Agent"})

      assert agent_token |> api_get("/api/me/agents") |> json_response(401)
      assert build_conn() |> get("/api/me/agents") |> json_response(401)
    end
  end

  describe "GET /api/me/goals/:id/after_goal" do
    test "after_goal returns exit code and duration", ctx do
      goal = failed_goal!(ctx.cols["Backlog"])
      conn = api_get(ctx.phone, "/api/me/goals/#{goal.id}/after_goal")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "goal_id" => goal.id,
                 "identifier" => goal.identifier,
                 "status" => "pending",
                 "exit_code" => 1,
                 "duration_ms" => 4000,
                 "reported_at" => "2026-11-18T10:00:00Z",
                 "failed" => true
               }
             }

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "after_goal output only when the web shows it", ctx do
      goal = failed_goal!(ctx.cols["Backlog"])
      assert goal.after_goal_result["output"] =~ "boom"

      body = ctx.phone |> api_get("/api/me/goals/#{goal.id}/after_goal") |> json_response(200)

      # No web goal page shows the output (decision 9), so the app never gets it.
      refute Map.has_key?(body["data"], "output")
      refute Jason.encode!(body) =~ "boom"
      refute Jason.encode!(body) =~ "SECRET_TOKEN"
    end

    test "a succeeded attempt has not failed", ctx do
      goal =
        attempted_goal!(ctx.cols["Done"], %{
          "exit_code" => 0,
          "output" => "ok",
          "duration_ms" => 1200,
          "reported_at" => "2026-11-18T11:00:00Z"
        })

      assert %{"data" => %{"status" => "succeeded", "exit_code" => 0, "failed" => false}} =
               ctx.phone |> api_get("/api/me/goals/#{goal.id}/after_goal") |> json_response(200)
    end

    test "a goal with no after_goal attempt returns null fields", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})

      assert ctx.phone |> api_get("/api/me/goals/#{goal.id}/after_goal") |> json_response(200) ==
               %{
                 "data" => %{
                   "goal_id" => goal.id,
                   "identifier" => goal.identifier,
                   "status" => nil,
                   "exit_code" => nil,
                   "duration_ms" => nil,
                   "reported_at" => nil,
                   "failed" => false
                 }
               }
    end

    test "a read-only member may read it", ctx do
      goal = failed_goal!(ctx.cols["Backlog"])
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.user)
      {_device, device} = device_with_tokens_fixture(user_scope_fixture(reader))

      assert %{"data" => %{"failed" => true}} =
               device.access_token
               |> api_get("/api/me/goals/#{goal.id}/after_goal")
               |> json_response(200)
    end

    test "a goal on an unseen board answers 404", ctx do
      stranger = user_fixture()
      foreign = ai_optimized_board_fixture(stranger)
      foreign_goal = failed_goal!(columns(foreign)["Backlog"])
      work = task_fixture(ctx.cols["Ready"])

      for path <- [
            "/api/me/goals/#{foreign_goal.id}/after_goal",
            "/api/me/goals/#{work.id}/after_goal",
            "/api/me/goals/#{foreign_goal.id + 1_000_000}/after_goal",
            "/api/me/goals/abc/after_goal",
            "/api/me/goals/0/after_goal",
            "/api/me/goals/99999999999999999999/after_goal"
          ] do
        conn = api_get(ctx.phone, path)
        assert json_response(conn, 404) == @not_found, path
        assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      end
    end

    test "checks the person's plan, then the goal, then the board's plan", ctx do
      enforce_plans()
      goal = failed_goal!(ctx.cols["Backlog"])

      # A free person: plan_required, whatever the id.
      assert ctx.phone |> api_get("/api/me/goals/#{goal.id}/after_goal") |> json_response(403) ==
               @plan_required

      # In an Organization, a board outside it is plan_required only once seen.
      workspace = into_org_workspace!(ctx.user, ai_optimized_board_fixture(ctx.user))

      assert ctx.phone |> api_get("/api/me/goals/#{goal.id}/after_goal") |> json_response(403) ==
               @plan_required

      stranger = user_fixture()
      foreign_goal = failed_goal!(columns(ai_optimized_board_fixture(stranger))["Backlog"])

      assert ctx.phone
             |> api_get("/api/me/goals/#{foreign_goal.id}/after_goal")
             |> json_response(404) == @not_found

      ctx.board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()

      assert %{"data" => %{"failed" => true}} =
               ctx.phone |> api_get("/api/me/goals/#{goal.id}/after_goal") |> json_response(200)
    end
  end

  describe "contract" do
    test "matches the documented schemas", ctx do
      goal = failed_goal!(ctx.cols["Backlog"])

      ctx.cols["Doing"]
      |> task_fixture(%{
        created_by_agent: "Claude",
        created_by_id: ctx.user.id,
        parent_id: goal.id
      })

      agent_task(ctx.cols["Done"], %{created_by_agent: "Codex"}) |> complete!()
      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      overview = ctx.phone |> api_get("/api/me/agents") |> json_response(200)
      assert_schema(spec, overview, "MeAgentsResponse")
      assert_schema(spec, overview["data"], "MeAgents")
      assert length(overview["data"]["agents"]) == 2

      for agent <- overview["data"]["agents"] do
        assert_schema(spec, agent, "MeAgent")
        if agent["owner"], do: assert_schema(spec, agent["owner"], "MeAgentOwner")

        if agent["current_task"],
          do: assert_schema(spec, agent["current_task"], "MeAgentCurrentTask")
      end

      assert [entry] = overview["data"]["goals"]
      assert_schema(spec, entry, "MeAgentGoal")
      assert_schema(spec, entry["counts"], "MeAgentGoalCounts")

      for id <- [goal.id, task_fixture(ctx.cols["Backlog"], %{type: :goal}).id] do
        attempt = ctx.phone |> api_get("/api/me/goals/#{id}/after_goal") |> json_response(200)
        assert_schema(spec, attempt, "MeAfterGoalResponse")
        assert_schema(spec, attempt["data"], "MeAfterGoalAttempt")
      end
    end
  end

  defp assert_schema(spec, value, schema) do
    properties = get_in(spec, ["components", "schemas", schema, "properties"])

    assert value |> Map.keys() |> MapSet.new() == properties |> Map.keys() |> MapSet.new(),
           "#{schema} does not match the rendered keys"

    for {key, rendered} <- value do
      assert type_allowed?(rendered, properties[key]),
             "#{schema}.#{key} is #{inspect(rendered)}, not #{inspect(properties[key])}"
    end
  end

  # A property with a $ref is checked by its own schema; anyOf allows any branch.
  defp type_allowed?(_value, %{"$ref" => _}), do: true

  defp type_allowed?(value, %{"anyOf" => branches}),
    do: Enum.any?(branches, &type_allowed?(value, &1))

  defp type_allowed?(value, %{"type" => types} = property) do
    types |> List.wrap() |> Enum.any?(&json_type?(value, &1)) and
      (not Map.has_key?(property, "enum") or value in property["enum"])
  end

  defp json_type?(nil, "null"), do: true
  defp json_type?(value, "string"), do: is_binary(value)
  defp json_type?(value, "integer"), do: is_integer(value)
  defp json_type?(value, "boolean"), do: is_boolean(value)
  defp json_type?(value, "array"), do: is_list(value)
  defp json_type?(value, "object"), do: is_map(value)
  defp json_type?(_value, _type), do: false
end
