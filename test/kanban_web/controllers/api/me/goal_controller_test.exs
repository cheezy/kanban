defmodule KanbanWeb.API.Me.GoalControllerTest do
  @moduledoc """
  Tests for `GET /api/me/goals` and `GET /api/me/goals/:id`
  (`KanbanWeb.API.Me.GoalController`), W2762.
  """
  # async: false - some tests switch the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

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
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @plan_required %{
    "error" => "plan_required",
    "feature" => "mobile_app",
    "message" => "The Stride app is available to boards in an Organization."
  }
  @not_found %{"error" => "Not Found"}
  @groups ~w(backlog ready doing review done)

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

  defp complete!(task) do
    {:ok, task} =
      Tasks.update_task(task, %{"status" => "completed", "completed_at" => DateTime.utc_now()})

    task
  end

  defp archive!(task), do: task |> Ecto.Changeset.change(archived_at: now()) |> Repo.update!()

  defp now, do: DateTime.utc_now(:second)

  defp pending_review!(column, attrs) do
    column
    |> task_fixture(attrs)
    |> Ecto.Changeset.change(needs_review: true, review_status: :pending)
    |> Repo.update!()
  end

  defp failed_goal!(column) do
    goal =
      column
      |> task_fixture(%{type: :goal})
      |> Ecto.Changeset.change(%{after_goal_status: :pending})
      |> Repo.update!()

    {:ok, goal} =
      Tasks.report_after_goal(goal, %{
        "exit_code" => 1,
        "output" => "boom",
        "duration_ms" => 4000,
        "reported_at" => "2026-11-18T10:00:00Z"
      })

    goal
  end

  defp into_org_workspace!(user, board) do
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, user)
    board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
    workspace
  end

  # Goals inserted directly, each a minute older than the one before, so the
  # page test does not create 101 goals through the full create path.
  defp insert_goals!(column, count) do
    base = NaiveDateTime.utc_now(:second)

    rows =
      for i <- 1..count do
        at = NaiveDateTime.add(base, -i * 60)

        %{
          title: "Paged goal #{i}",
          identifier: "GP#{System.unique_integer([:positive])}",
          type: :goal,
          status: :open,
          priority: :medium,
          position: 1000 + i,
          column_id: column.id,
          inserted_at: at,
          updated_at: at
        }
      end

    Repo.insert_all(Task, rows)
  end

  describe "GET /api/me/goals" do
    test "goal rows carry board, waiting_on_you and hook_failed", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      target = delivery_target_fixture(ctx.user, %{name: "Launch"})
      goal |> Ecto.Changeset.change(target_id: target.id) |> Repo.update!()

      pending_review!(ctx.cols["Review"], %{parent_id: goal.id})
      task_fixture(ctx.cols["Review"], %{parent_id: goal.id, needs_review: false})
      task_fixture(ctx.cols["Doing"], %{parent_id: goal.id})
      task_fixture(ctx.cols["Done"], %{parent_id: goal.id}) |> complete!() |> archive!()
      task_fixture(ctx.cols["Ready"], %{parent_id: goal.id}) |> archive!()

      failed = failed_goal!(ctx.cols["Backlog"])

      assert %{"data" => data} = ctx.phone |> api_get("/api/me/goals") |> json_response(200)
      rows = Map.new(data["goals"], &{&1["id"], &1})

      assert rows[goal.id] == %{
               "id" => goal.id,
               "identifier" => goal.identifier,
               "title" => goal.title,
               "status" => "open",
               "board" => %{"id" => ctx.board.id, "name" => ctx.board.name},
               "target" => %{"id" => target.id, "name" => "Launch"},
               "counts" => %{
                 "total" => 4,
                 "completed" => 1,
                 "doing" => 1,
                 "review" => 2,
                 "blocked" => 0
               },
               "waiting_on_you" => 1,
               "hook_failed" => false
             }

      assert %{"hook_failed" => true, "target" => nil, "waiting_on_you" => 0} = rows[failed.id]

      # hook_failed agrees with the after_goal read.
      assert %{"data" => %{"failed" => true}} =
               ctx.phone |> api_get("/api/me/goals/#{failed.id}/after_goal") |> json_response(200)
    end

    test "lists newest first with every filter's count", ctx do
      older = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      newer = task_fixture(ctx.cols["Backlog"], %{type: :goal})

      newer
      |> Ecto.Changeset.change(inserted_at: NaiveDateTime.add(older.inserted_at, 60))
      |> Repo.update!()

      done = task_fixture(ctx.cols["Done"], %{type: :goal}) |> complete!()
      task_fixture(ctx.cols["Backlog"], %{type: :goal}) |> archive!()

      assert %{"data" => data} = ctx.phone |> api_get("/api/me/goals") |> json_response(200)
      assert Enum.map(data["goals"], & &1["id"]) == [newer.id, older.id]

      assert %{
               "filter" => "open",
               "filters" => %{"open" => 2, "done" => 1, "no_target" => 2},
               "page" => 1,
               "per_page" => 100,
               "total" => 2,
               "next_page" => nil
             } = data

      assert %{"data" => %{"goals" => [%{"id" => id}], "filter" => "done", "total" => 1}} =
               ctx.phone |> api_get("/api/me/goals?filter=done") |> json_response(200)

      assert id == done.id

      assert %{"data" => %{"filter" => "no_target", "total" => 2}} =
               ctx.phone |> api_get("/api/me/goals?filter=no_target") |> json_response(200)
    end

    test "page 2 starts after 100 goals", ctx do
      insert_goals!(ctx.cols["Backlog"], 101)

      assert %{"data" => first} = ctx.phone |> api_get("/api/me/goals") |> json_response(200)
      assert length(first["goals"]) == 100
      assert %{"total" => 101, "next_page" => 2, "page" => 1} = first
      assert hd(first["goals"])["title"] == "Paged goal 1"

      assert %{"data" => second} =
               ctx.phone |> api_get("/api/me/goals?page=2") |> json_response(200)

      assert [%{"title" => "Paged goal 101"}] = second["goals"]
      assert %{"total" => 101, "next_page" => nil, "page" => 2} = second

      for page <- ["0", "abc", "10001"] do
        assert ctx.phone |> api_get("/api/me/goals?page=#{page}") |> json_response(400) == %{
                 "error" => "Bad Request",
                 "message" => "page must be an integer from 1 to 10000."
               }
      end
    end

    test "an unknown filter answers 422", ctx do
      for query <- ["filter=bogus", "filter[]=open", "filter=OPEN"] do
        assert ctx.phone |> api_get("/api/me/goals?#{query}") |> json_response(422) == %{
                 "errors" => %{"filter" => ["is invalid"]}
               }
      end

      # The filter is checked before the page.
      assert ctx.phone |> api_get("/api/me/goals?filter=bogus&page=0") |> json_response(422)
    end

    test "leaves out goals on unseen boards, and takes no board list from the caller", ctx do
      mine = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      stranger_board = ai_optimized_board_fixture(user_fixture())
      task_fixture(columns(stranger_board)["Backlog"], %{type: :goal})

      assert %{"data" => %{"goals" => [%{"id" => id}], "total" => 1}} =
               ctx.phone
               |> api_get("/api/me/goals?board_ids[]=#{stranger_board.id}")
               |> json_response(200)

      assert id == mine.id
    end

    test "a free person gets plan_required while plans are enforced", ctx do
      enforce_plans()

      assert ctx.phone |> api_get("/api/me/goals") |> json_response(403) == @plan_required
    end

    test "boards outside the plan are left out", ctx do
      enforce_plans()
      org_board = ai_optimized_board_fixture(ctx.user)
      into_org_workspace!(ctx.user, org_board)
      org_goal = task_fixture(columns(org_board)["Backlog"], %{type: :goal})
      task_fixture(ctx.cols["Backlog"], %{type: :goal})

      assert %{"data" => %{"goals" => [%{"id" => id}], "filters" => %{"open" => 1}}} =
               ctx.phone |> api_get("/api/me/goals") |> json_response(200)

      assert id == org_goal.id
    end

    test "is sent private, no-store", ctx do
      conn = api_get(ctx.phone, "/api/me/goals")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "refuses an agent API token and no token", ctx do
      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ctx.board, %{"name" => "Agent"})

      for path <- ["/api/me/goals", "/api/me/goals/1"] do
        assert agent_token |> api_get(path) |> json_response(401)
        assert build_conn() |> get(path) |> json_response(401)
      end
    end
  end

  describe "GET /api/me/goals/:id" do
    test "goal detail groups tasks and counts archived_done", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal, created_by_agent: "Planner"})

      backlog = task_fixture(ctx.cols["Backlog"], %{parent_id: goal.id})
      ready = task_fixture(ctx.cols["Ready"], %{parent_id: goal.id})
      doing = task_fixture(ctx.cols["Doing"], %{parent_id: goal.id, created_by_agent: "Claude"})
      review = pending_review!(ctx.cols["Review"], %{parent_id: goal.id})
      done = task_fixture(ctx.cols["Done"], %{parent_id: goal.id}) |> complete!()

      for _ <- 1..2,
          do: task_fixture(ctx.cols["Done"], %{parent_id: goal.id}) |> complete!() |> archive!()

      dropped = task_fixture(ctx.cols["Ready"], %{parent_id: goal.id}) |> archive!()

      assert %{"data" => data} =
               ctx.phone |> api_get("/api/me/goals/#{goal.id}") |> json_response(200)

      assert data["archived_done"] == 2
      assert data["agents"] == ["Planner", "Claude"]

      assert %{
               "id" => goal_id,
               "board" => %{"id" => board_id},
               "counts" => %{"total" => 7, "completed" => 3, "doing" => 1, "review" => 1}
             } = data["goal"]

      assert goal_id == goal.id and board_id == ctx.board.id

      assert Enum.map(data["groups"], & &1["status"]) == @groups

      ids = Map.new(data["groups"], &{&1["status"], Enum.map(&1["tasks"], fn t -> t["id"] end)})

      assert ids == %{
               "backlog" => [backlog.id],
               "ready" => [ready.id],
               "doing" => [doing.id],
               "review" => [review.id],
               "done" => [done.id]
             }

      refute dropped.id in (ids |> Map.values() |> Enum.concat())

      [doing_row] = Enum.find(data["groups"], &(&1["status"] == "doing"))["tasks"]
      assert %{"agent" => "Claude", "reviewable" => false, "type" => "work"} = doing_row
      assert {:ok, _at, 0} = DateTime.from_iso8601(doing_row["in_column_since"])

      [review_row] = Enum.find(data["groups"], &(&1["status"] == "review"))["tasks"]
      assert %{"reviewable" => true, "needs_review" => true} = review_row
    end

    test "a read-only member may read it, and cannot review from it", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      pending_review!(ctx.cols["Review"], %{parent_id: goal.id})
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.user)
      {_d, device} = device_with_tokens_fixture(user_scope_fixture(reader), %{})

      assert %{"data" => %{"goal" => %{"waiting_on_you" => 1}, "groups" => groups}} =
               device.access_token |> api_get("/api/me/goals/#{goal.id}") |> json_response(200)

      assert [%{"reviewable" => false}] = Enum.find(groups, &(&1["status"] == "review"))["tasks"]
    end

    test "a goal on an unseen board answers 404", ctx do
      stranger_goal =
        task_fixture(columns(ai_optimized_board_fixture(user_fixture()))["Backlog"], %{
          type: :goal
        })

      work = task_fixture(ctx.cols["Backlog"])

      for id <- [stranger_goal.id, work.id, "abc", "0", "99999999999999999999"] do
        assert ctx.phone |> api_get("/api/me/goals/#{id}") |> json_response(404) == @not_found
      end
    end

    test "checks the person's plan, then the goal, then the board's plan", ctx do
      enforce_plans()
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})

      assert ctx.phone |> api_get("/api/me/goals/#{goal.id}") |> json_response(403) ==
               @plan_required

      workspace = into_org_workspace!(ctx.user, ai_optimized_board_fixture(ctx.user))

      assert ctx.phone |> api_get("/api/me/goals/#{goal.id}") |> json_response(403) ==
               @plan_required

      foreign_goal =
        task_fixture(columns(ai_optimized_board_fixture(user_fixture()))["Backlog"], %{
          type: :goal
        })

      assert ctx.phone |> api_get("/api/me/goals/#{foreign_goal.id}") |> json_response(404) ==
               @not_found

      ctx.board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()

      assert %{"data" => %{"goal" => %{"id" => id}}} =
               ctx.phone |> api_get("/api/me/goals/#{goal.id}") |> json_response(200)

      assert id == goal.id
    end

    test "is sent private, no-store", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      conn = api_get(ctx.phone, "/api/me/goals/#{goal.id}")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  describe "telemetry" do
    test "emits status viewed with surface and via", ctx do
      attach_telemetry([[:kanban, :status, :viewed]])
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})

      ctx.phone |> api_get("/api/me/goals") |> json_response(200)

      assert_receive {:telemetry_event, [:kanban, :status, :viewed], %{count: 1},
                      %{surface: :goals, via: :ios} = metadata}

      assert Map.keys(metadata) |> Enum.sort() == [:surface, :via]

      ctx.phone |> api_get("/api/me/goals/#{goal.id}") |> json_response(200)

      assert_receive {:telemetry_event, [:kanban, :status, :viewed], %{count: 1},
                      %{surface: :goal, via: :ios}}

      # A refused read emits nothing.
      ctx.phone |> api_get("/api/me/goals?filter=bogus") |> json_response(422)
      ctx.phone |> api_get("/api/me/goals/0") |> json_response(404)

      refute_receive {:telemetry_event, [:kanban, :status, :viewed], _, _}
    end
  end

  describe "contract" do
    test "matches the documented schemas", ctx do
      goal = failed_goal!(ctx.cols["Backlog"])
      target = delivery_target_fixture(ctx.user)
      goal |> Ecto.Changeset.change(target_id: target.id) |> Repo.update!()
      task_fixture(ctx.cols["Doing"], %{parent_id: goal.id, created_by_agent: "Claude"})
      pending_review!(ctx.cols["Review"], %{parent_id: goal.id})
      task_fixture(ctx.cols["Backlog"], %{type: :goal})

      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      list = ctx.phone |> api_get("/api/me/goals") |> json_response(200)
      assert_schema(spec, list, "MeGoalListResponse")
      assert_schema(spec, list["data"], "MeGoalList")
      assert_schema(spec, list["data"]["filters"], "MeGoalFilterCounts")
      assert length(list["data"]["goals"]) == 2

      for row <- list["data"]["goals"], do: assert_goal(spec, row)

      detail = ctx.phone |> api_get("/api/me/goals/#{goal.id}") |> json_response(200)
      assert_schema(spec, detail, "MeGoalDetailResponse")
      assert_schema(spec, detail["data"], "MeGoalDetail")
      assert_goal(spec, detail["data"]["goal"])
      assert detail["data"]["goal"]["target"]

      for group <- detail["data"]["groups"] do
        assert_schema(spec, group, "MeGoalTaskGroup")
        for task <- group["tasks"], do: assert_schema(spec, task, "MeGoalTask")
      end
    end
  end

  defp assert_goal(spec, row) do
    assert_schema(spec, row, "MeGoal")
    assert_schema(spec, row["board"], "MeGoalBoard")
    assert_schema(spec, row["counts"], "MeAgentGoalCounts")
    if row["target"], do: assert_schema(spec, row["target"], "MeGoalTarget")
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
