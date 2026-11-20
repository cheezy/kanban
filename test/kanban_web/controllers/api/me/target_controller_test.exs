defmodule KanbanWeb.API.Me.TargetControllerTest do
  @moduledoc """
  Tests for `GET /api/me/targets` and `GET /api/me/targets/:id`
  (`KanbanWeb.API.Me.TargetController`), W2763.

  A controller test cannot inject `now`, so every date here is relative to
  today in UTC and chosen far enough from a status boundary that the time of
  day cannot change the answer.
  """
  # async: false - some tests switch the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Devices.Device
  alias Kanban.Repo
  alias Kanban.Targets.AppTargets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks

  @plan_required %{
    "error" => "plan_required",
    "feature" => "mobile_app",
    "message" => "The Stride app is available to boards in an Organization."
  }
  @not_found %{"error" => "Not Found"}
  @statuses ~w(on_track at_risk missed complete)

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {device, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})
    board = ai_optimized_board_fixture(user)

    %{
      user: user,
      scope: scope,
      device: device,
      board: board,
      cols: columns(board),
      phone: phone.access_token
    }
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp api_get(token, path), do: token |> authed() |> get(path)

  defp today, do: Date.utc_today()

  defp goal_on_target(column, target) do
    goal = task_fixture(column, %{type: :goal})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
    goal
  end

  defp completed_child!(column, goal) do
    column
    |> task_fixture(%{parent_id: goal.id})
    |> Ecto.Changeset.change(status: :completed, completed_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  # Created long before its date, with no work done, so it is at risk.
  defp backdate_target!(%DeliveryTarget{id: id}, days) do
    at = NaiveDateTime.utc_now(:second) |> NaiveDateTime.add(-days * 86_400)
    from(t in DeliveryTarget, where: t.id == ^id) |> Repo.update_all(set: [inserted_at: at])
  end

  defp stuck_agent_task!(column, goal) do
    claimed_at = DateTime.utc_now(:second) |> DateTime.add(-90 * 60)

    {:ok, task} =
      column
      |> task_fixture(%{parent_id: goal.id})
      |> Tasks.update_task(%{
        status: :in_progress,
        created_by_agent: "Stalled",
        claimed_at: claimed_at
      })

    task
  end

  defp at_risk_target!(ctx) do
    target = delivery_target_fixture(ctx.user, %{target_date: Date.add(today(), 20)})
    backdate_target!(target, 80)
    target
  end

  defp into_org_workspace!(user, board) do
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, user)
    board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
    workspace
  end

  defp set_time_zone!(%Device{id: id}, zone) do
    from(d in Device, where: d.id == ^id) |> Repo.update_all(set: [time_zone: zone])
  end

  describe "GET /api/me/targets" do
    test "lists non-archived targets with counts and owner", ctx do
      mine =
        delivery_target_fixture(ctx.user, %{name: "Mine", target_date: Date.add(today(), 300)})

      goal = goal_on_target(ctx.cols["Doing"], mine)
      other_goal = goal_on_target(ctx.cols["Doing"], mine)
      completed_child!(ctx.cols["Done"], goal)
      task_fixture(ctx.cols["Doing"], %{parent_id: goal.id})
      task_fixture(ctx.cols["Backlog"], %{parent_id: other_goal.id})

      # Someone else's target with a goal on a board the person sees.
      theirs =
        delivery_target_fixture(user_fixture(), %{
          name: "Theirs",
          target_date: Date.add(today(), 360)
        })

      goal_on_target(ctx.cols["Backlog"], theirs)

      archived = delivery_target_fixture(ctx.user, %{name: "Archived"})
      goal_on_target(ctx.cols["Backlog"], archived)
      archived |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()

      assert %{"data" => %{"targets" => [first, second]}} =
               ctx.phone |> api_get("/api/me/targets") |> json_response(200)

      assert first == %{
               "id" => mine.id,
               "name" => "Mine",
               "status" => first["status"],
               "target_date" => Date.to_iso8601(mine.target_date),
               "estimated_completion_date" => first["estimated_completion_date"],
               "goal_count" => 2,
               "completed" => 1,
               "total" => 3,
               "owner" => true
             }

      assert first["status"] in @statuses

      assert %{"id" => id, "goal_count" => 1, "completed" => 0, "total" => 0, "owner" => false} =
               second

      assert id == theirs.id
    end

    test "a target's status is the web's, as an enum", ctx do
      target = delivery_target_fixture(ctx.user, %{target_date: Date.add(today(), -5)})
      goal = goal_on_target(ctx.cols["Doing"], target)
      task_fixture(ctx.cols["Doing"], %{parent_id: goal.id})

      assert %{"data" => %{"targets" => [%{"status" => "missed"}]}} =
               ctx.phone |> api_get("/api/me/targets") |> json_response(200)

      [web] = Kanban.Targets.list_targets_with_status(ctx.scope)
      assert web.status == :missed
    end

    test "a target with no member goals the person can see is not listed", ctx do
      delivery_target_fixture(ctx.user)

      assert ctx.phone |> api_get("/api/me/targets") |> json_response(200) ==
               %{"data" => %{"targets" => []}}
    end

    test "a device with no time zone uses UTC", ctx do
      # A zone that is on another calendar day than UTC right now, so the
      # same target is missed in one and still due in the other.
      {target_date, far_zone} =
        if DateTime.utc_now().hour >= 12,
          do: {today(), "Etc/GMT-14"},
          else: {Date.add(today(), -1), "Etc/GMT+12"}

      target = delivery_target_fixture(ctx.user, %{target_date: target_date})
      backdate_target!(target, 30)
      goal = goal_on_target(ctx.cols["Doing"], target)
      task_fixture(ctx.cols["Doing"], %{parent_id: goal.id})

      set_time_zone!(ctx.device, nil)

      assert %{"data" => %{"targets" => [%{"status" => status}]}} =
               ctx.phone |> api_get("/api/me/targets") |> json_response(200)

      [utc] = AppTargets.list(ctx.scope, timezone: "Etc/UTC")
      [far] = AppTargets.list(ctx.scope, timezone: far_zone)

      assert status == Atom.to_string(utc.status)
      assert utc.status != far.status

      # The device's own zone is used once it has one.
      set_time_zone!(ctx.device, far_zone)

      assert %{"data" => %{"targets" => [%{"status" => far_status}]}} =
               ctx.phone |> api_get("/api/me/targets") |> json_response(200)

      assert far_status == Atom.to_string(far.status)
    end

    test "a free person gets plan_required while plans are enforced", ctx do
      enforce_plans()

      assert ctx.phone |> api_get("/api/me/targets") |> json_response(403) == @plan_required
    end

    test "goals on boards outside the plan are left out", ctx do
      enforce_plans()
      org_board = ai_optimized_board_fixture(ctx.user)
      into_org_workspace!(ctx.user, org_board)
      org_cols = columns(org_board)

      split = delivery_target_fixture(ctx.user, %{name: "Split"})
      org_goal = goal_on_target(org_cols["Doing"], split)
      free_goal = goal_on_target(ctx.cols["Doing"], split)
      task_fixture(org_cols["Doing"], %{parent_id: org_goal.id})
      task_fixture(ctx.cols["Doing"], %{parent_id: free_goal.id})

      free_only = delivery_target_fixture(ctx.user, %{name: "Free only"})
      goal_on_target(ctx.cols["Doing"], free_only)

      assert %{"data" => %{"targets" => [row]}} =
               ctx.phone |> api_get("/api/me/targets") |> json_response(200)

      # The goal count leaves the free board out; the task counts stay the web's.
      assert %{"name" => "Split", "goal_count" => 1, "completed" => 0, "total" => 2} = row

      assert %{"data" => %{"goals" => [%{"id" => goal_id}], "target" => %{"goal_count" => 1}}} =
               ctx.phone |> api_get("/api/me/targets/#{split.id}") |> json_response(200)

      assert goal_id == org_goal.id
    end

    test "is sent private, no-store", ctx do
      conn = api_get(ctx.phone, "/api/me/targets")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "refuses an agent API token and no token", ctx do
      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ctx.board, %{"name" => "Agent"})

      for path <- ["/api/me/targets", "/api/me/targets/1"] do
        assert agent_token |> api_get(path) |> json_response(401)
        assert build_conn() |> get(path) |> json_response(401)
      end
    end
  end

  describe "GET /api/me/targets/:id" do
    test "target detail for the owner has structured risk when at risk", ctx do
      target = at_risk_target!(ctx)
      goal = goal_on_target(ctx.cols["Doing"], target)
      stuck_agent_task!(ctx.cols["Doing"], goal)
      healthy = goal_on_target(ctx.cols["Backlog"], target)

      assert %{"data" => data} =
               ctx.phone |> api_get("/api/me/targets/#{target.id}") |> json_response(200)

      assert %{
               "target" => %{
                 "id" => id,
                 "status" => "at_risk",
                 "owner" => true,
                 "goal_count" => 2,
                 "completed" => 0,
                 "total" => 1
               },
               "goals" => goals,
               "risk" => %{"slipped" => nil, "stalled" => [stalled]}
             } = data

      assert id == target.id
      assert goals |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort([goal.id, healthy.id])

      assert stalled == %{
               "id" => goal.id,
               "identifier" => goal.identifier,
               "title" => goal.title,
               "agents" => [%{"name" => "Stalled", "reasons" => ["stuck"]}]
             }
    end

    test "a non-owner gets 404", ctx do
      other = user_fixture()
      theirs = delivery_target_fixture(other)
      goal_on_target(ctx.cols["Backlog"], theirs)

      # Listed, since its goal is on a board the person sees, but not theirs to open.
      assert %{"data" => %{"targets" => [%{"owner" => false}]}} =
               ctx.phone |> api_get("/api/me/targets") |> json_response(200)

      assert ctx.phone |> api_get("/api/me/targets/#{theirs.id}") |> json_response(404) ==
               @not_found

      mine = delivery_target_fixture(ctx.user)
      goal_on_target(ctx.cols["Backlog"], mine)
      ctx.phone |> api_get("/api/me/targets/#{mine.id}") |> json_response(200)

      # Ownership moves away: the detail turns 404.
      from(t in DeliveryTarget, where: t.id == ^mine.id)
      |> Repo.update_all(set: [owner_id: other.id])

      assert ctx.phone |> api_get("/api/me/targets/#{mine.id}") |> json_response(404) ==
               @not_found

      for id <- ["0", "abc", "99999999999999999999"] do
        assert ctx.phone |> api_get("/api/me/targets/#{id}") |> json_response(404) == @not_found
      end
    end

    test "an on-track target has no risk", ctx do
      target = delivery_target_fixture(ctx.user, %{target_date: Date.add(today(), 365)})
      goal = goal_on_target(ctx.cols["Doing"], target)
      stuck_agent_task!(ctx.cols["Doing"], goal)

      assert %{"data" => %{"target" => %{"status" => "on_track"}, "risk" => nil}} =
               ctx.phone |> api_get("/api/me/targets/#{target.id}") |> json_response(200)
    end

    test "a missed target has no risk", ctx do
      target = delivery_target_fixture(ctx.user, %{target_date: Date.add(today(), -5)})
      goal = goal_on_target(ctx.cols["Doing"], target)
      stuck_agent_task!(ctx.cols["Doing"], goal)

      assert %{"data" => %{"target" => %{"status" => "missed"}, "risk" => nil}} =
               ctx.phone |> api_get("/api/me/targets/#{target.id}") |> json_response(200)
    end

    test "an owned target with no member goals answers with no goals and no risk", ctx do
      target = delivery_target_fixture(ctx.user)

      assert %{
               "data" => %{
                 "target" => %{"goal_count" => 0, "completed" => 0, "total" => 0},
                 "goals" => [],
                 "risk" => nil
               }
             } = ctx.phone |> api_get("/api/me/targets/#{target.id}") |> json_response(200)
    end

    test "a free person gets plan_required before the target is looked up", ctx do
      enforce_plans()
      target = delivery_target_fixture(ctx.user)

      for path <- ["/api/me/targets/#{target.id}", "/api/me/targets/0"] do
        assert ctx.phone |> api_get(path) |> json_response(403) == @plan_required
      end
    end

    test "is sent private, no-store", ctx do
      target = delivery_target_fixture(ctx.user)
      conn = api_get(ctx.phone, "/api/me/targets/#{target.id}")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      conn = api_get(ctx.phone, "/api/me/targets/0")
      assert conn.status == 404
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  describe "telemetry" do
    test "emits status viewed with surface and via", ctx do
      attach_telemetry([[:kanban, :status, :viewed]])
      target = delivery_target_fixture(ctx.user)

      ctx.phone |> api_get("/api/me/targets") |> json_response(200)

      assert_receive {:telemetry_event, [:kanban, :status, :viewed], %{count: 1},
                      %{surface: :targets, via: :ios} = metadata}

      assert Map.keys(metadata) |> Enum.sort() == [:surface, :via]

      ctx.phone |> api_get("/api/me/targets/#{target.id}") |> json_response(200)

      assert_receive {:telemetry_event, [:kanban, :status, :viewed], %{count: 1},
                      %{surface: :target, via: :ios}}

      # A refused read emits nothing.
      theirs = delivery_target_fixture(user_fixture())
      ctx.phone |> api_get("/api/me/targets/#{theirs.id}") |> json_response(404)
      ctx.phone |> api_get("/api/me/targets/abc") |> json_response(404)

      refute_receive {:telemetry_event, [:kanban, :status, :viewed], _, _}
    end
  end

  describe "contract" do
    test "matches the documented schemas", ctx do
      target = at_risk_target!(ctx)
      goal = goal_on_target(ctx.cols["Doing"], target)
      stuck_agent_task!(ctx.cols["Doing"], goal)

      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      list = ctx.phone |> api_get("/api/me/targets") |> json_response(200)
      assert_schema(spec, list, "MeTargetListResponse")
      assert_schema(spec, list["data"], "MeTargetList")
      assert [row] = list["data"]["targets"]
      assert_schema(spec, row, "MeTarget")

      detail = ctx.phone |> api_get("/api/me/targets/#{target.id}") |> json_response(200)
      assert_schema(spec, detail, "MeTargetDetailResponse")
      assert_schema(spec, detail["data"], "MeTargetDetail")
      assert_schema(spec, detail["data"]["target"], "MeTarget")

      for goal_row <- detail["data"]["goals"] do
        assert_schema(spec, goal_row, "MeGoal")
        assert_schema(spec, goal_row["board"], "MeGoalBoard")
        assert_schema(spec, goal_row["counts"], "MeAgentGoalCounts")
      end

      risk = detail["data"]["risk"]
      assert_schema(spec, risk, "MeTargetRisk")
      assert [stalled] = risk["stalled"]
      assert_schema(spec, stalled, "MeTargetStalledGoal")

      for agent <- stalled["agents"] do
        assert_schema(spec, agent, "MeTargetStalledAgent")
        assert agent["reasons"] |> Enum.all?(&(&1 in ~w(stuck dormant)))
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
