defmodule KanbanWeb.API.TelemetryFieldsLockTest do
  @moduledoc """
  The paid task fields (`telemetry_event` and `metrics_to_track`) over REST
  while paid plans are enforced: a free board accepts them but does not store
  them, and the success body warns; a paid board stores them as before.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @moduletag capture_log: true

  @refused [:kanban, :plan, :feature_refused]
  @warning "telemetry_event, metrics_to_track need a board in an Organization and were not stored."
  @fields %{"telemetry_event" => "[:kanban, :task, :done]", "metrics_to_track" => "count"}

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Telemetry lock token",
        "agent_capabilities" => ["code_generation"]
      })

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token}")

    columns = Columns.list_columns(board)

    %{
      conn: conn,
      user: user,
      board: board,
      backlog: Enum.find(columns, &(&1.name == "Backlog")),
      doing: Enum.find(columns, &(&1.name == "Doing"))
    }
  end

  defp make_paid(%Board{id: id}) do
    workspace = org_workspace_fixture(organization_fixture())

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    :ok
  end

  defp work(attrs), do: Map.merge(%{"title" => "Telemetry task", "type" => "work"}, attrs)

  defp stored(id), do: Task |> Repo.get!(id) |> Map.take([:telemetry_event, :metrics_to_track])

  defp none, do: %{telemetry_event: nil, metrics_to_track: nil}

  defp kept, do: %{telemetry_event: "[:kanban, :task, :done]", metrics_to_track: "count"}

  defp existing_task(ctx, attrs) do
    {:ok, task} =
      Tasks.create_task(
        ctx.backlog,
        Map.merge(%{"title" => "Existing", "created_by_id" => ctx.user.id}, attrs)
      )

    task
  end

  defp goal_with_children do
    %{
      "title" => "Telemetry goal",
      "type" => "goal",
      "tasks" => [
        work(%{"title" => "Child A", "telemetry_event" => "[:a]"}),
        work(%{"title" => "Child B", "metrics_to_track" => "b"})
      ]
    }
  end

  defp child_ids(goal_id),
    do: Task |> where(parent_id: ^goal_id) |> select([t], t.id) |> Repo.all()

  describe "a free board under enforcement" do
    setup :enforce_plans

    test "POST /api/tasks succeeds, stores neither field and warns", %{conn: conn} do
      attach_telemetry(@refused)
      body = conn |> post(~p"/api/tasks", task: work(@fields)) |> json_response(201)

      assert body["warnings"] == [@warning]
      assert stored(body["data"]["id"]) == none()

      assert_received {:telemetry_event, @refused, %{count: 1},
                       %{feature: :telemetry, surface: :rest}}
    end

    test "POST /api/tasks names only the field that was sent, even when empty", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/tasks", task: work(%{"metrics_to_track" => ""}))
        |> json_response(201)

      assert body["warnings"] == [
               "metrics_to_track needs a board in an Organization and was not stored."
             ]
    end

    test "POST /api/tasks with a goal strips the children and warns once", %{conn: conn} do
      attach_telemetry(@refused)
      body = conn |> post(~p"/api/tasks", task: goal_with_children()) |> json_response(201)

      assert body["warnings"] == [@warning]
      ids = child_ids(body["goal"]["id"])
      assert length(ids) == 2
      assert Enum.all?(ids, &(stored(&1) == none()))
      assert_received {:telemetry_event, @refused, _, %{surface: :rest}}
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "POST /api/tasks/batch strips every goal and child and warns once", %{conn: conn} do
      attach_telemetry(@refused)

      goals = [
        Map.put(goal_with_children(), "telemetry_event", "[:goal]"),
        %{"title" => "Plain goal", "type" => "goal", "tasks" => [work(%{})]}
      ]

      body = conn |> post(~p"/api/tasks/batch", goals: goals) |> json_response(201)

      assert body["success"]
      assert body["total"] == 2
      assert body["warnings"] == [@warning]

      for goal <- body["goals"] do
        goal_id = goal["goal"]["id"]
        assert stored(goal_id) == none()
        assert goal_id |> child_ids() |> Enum.all?(&(stored(&1) == none()))
      end

      assert_received {:telemetry_event, @refused, _, %{surface: :rest}}
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "PATCH /api/tasks/:id applies the other fields, keeps stored values and warns",
         %{conn: conn} = ctx do
      task = existing_task(ctx, @fields)
      attach_telemetry(@refused)

      body =
        conn
        |> patch(~p"/api/tasks/#{task.id}",
          task: %{"title" => "Renamed", "telemetry_event" => "[:new]", "metrics_to_track" => nil}
        )
        |> json_response(200)

      assert body["warnings"] == [@warning]
      assert body["data"]["title"] == "Renamed"
      assert stored(task.id) == kept()
      assert_received {:telemetry_event, @refused, _, %{feature: :telemetry, surface: :rest}}
    end

    test "PATCH /api/tasks/:id with only the paid fields is a successful no-op",
         %{conn: conn} = ctx do
      task = existing_task(ctx, %{})

      body =
        conn
        |> patch(~p"/api/tasks/#{task.id}", task: %{"telemetry_event" => "[:x]"})
        |> json_response(200)

      assert body["warnings"] == [
               "telemetry_event needs a board in an Organization and was not stored."
             ]

      assert stored(task.id) == none()
    end

    test "a PATCH refused for a forbidden field returns 422 without a warning",
         %{conn: conn} = ctx do
      task = existing_task(ctx, %{})
      attach_telemetry(@refused)

      body =
        conn
        |> patch(~p"/api/tasks/#{task.id}",
          task: %{"telemetry_event" => "[:x]", "completed_by_agent" => "x"}
        )
        |> json_response(422)

      refute Map.has_key?(body, "warnings")
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "requests without the paid fields get no warnings key", %{conn: conn} = ctx do
      attach_telemetry(@refused)
      created = conn |> post(~p"/api/tasks", task: work(%{})) |> json_response(201)
      refute Map.has_key?(created, "warnings")

      batch =
        conn
        |> post(~p"/api/tasks/batch", goals: [%{"title" => "G", "type" => "goal"}])
        |> json_response(201)

      refute Map.has_key?(batch, "warnings")

      task = existing_task(ctx, %{})

      updated =
        conn |> patch(~p"/api/tasks/#{task.id}", task: %{"title" => "X"}) |> json_response(200)

      refute Map.has_key?(updated, "warnings")
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "PATCH /api/tasks/:id/complete succeeds when a client includes the fields",
         %{conn: conn} = ctx do
      {:ok, task} =
        Tasks.create_task(ctx.doing, %{
          "title" => "Claimed",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => ctx.user.id,
          "created_by_id" => ctx.user.id,
          "needs_review" => true
        })

      hook = %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}

      params =
        Map.merge(@fields, %{
          "completion_summary" => "Done",
          "actual_complexity" => "small",
          "actual_files_changed" => "1",
          "time_spent_minutes" => 5,
          "after_doing_result" => hook,
          "before_review_result" => hook
        })

      body = conn |> patch(~p"/api/tasks/#{task.id}/complete", params) |> json_response(200)

      assert body["data"]["id"] == task.id
      refute Map.has_key?(body, "warnings")
      assert stored(task.id) == none()
    end
  end

  describe "a paid board under enforcement" do
    setup %{board: board} do
      enforce_plans()
      make_paid(board)
    end

    test "POST /api/tasks stores the fields with no warnings", %{conn: conn} do
      body = conn |> post(~p"/api/tasks", task: work(@fields)) |> json_response(201)

      refute Map.has_key?(body, "warnings")
      assert stored(body["data"]["id"]) == kept()
    end

    test "POST /api/tasks/batch stores the children's fields", %{conn: conn} do
      body =
        conn |> post(~p"/api/tasks/batch", goals: [goal_with_children()]) |> json_response(201)

      refute Map.has_key?(body, "warnings")
      [goal] = body["goals"]
      values = goal["goal"]["id"] |> child_ids() |> Enum.map(&stored/1)
      assert %{telemetry_event: "[:a]", metrics_to_track: nil} in values
      assert %{telemetry_event: nil, metrics_to_track: "b"} in values
    end

    test "PATCH /api/tasks/:id stores the fields", %{conn: conn} = ctx do
      task = existing_task(ctx, %{})
      body = conn |> patch(~p"/api/tasks/#{task.id}", task: @fields) |> json_response(200)

      refute Map.has_key?(body, "warnings")
      assert stored(task.id) == kept()
    end
  end

  describe "a free board without enforcement" do
    test "POST /api/tasks with a goal stores the fields with no warnings", %{conn: conn} do
      attach_telemetry(@refused)
      body = conn |> post(~p"/api/tasks", task: goal_with_children()) |> json_response(201)

      refute Map.has_key?(body, "warnings")
      values = body["goal"]["id"] |> child_ids() |> Enum.map(&stored/1)
      assert %{telemetry_event: "[:a]", metrics_to_track: nil} in values
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "PATCH /api/tasks/:id stores the fields", %{conn: conn} = ctx do
      task = existing_task(ctx, %{})
      conn |> patch(~p"/api/tasks/#{task.id}", task: @fields) |> json_response(200)

      assert stored(task.id) == kept()
    end
  end
end
