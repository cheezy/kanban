defmodule KanbanWeb.API.Me.DecisionControllerTest do
  @moduledoc """
  Tests for `GET /api/me/decisions` (`KanbanWeb.API.Me.DecisionController`)
  and `GET /api/me/reviews` (`KanbanWeb.API.Me.ReviewController.index/2`),
  W2758.
  """
  # async: false - some tests switch the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks

  @empty_summary %{"waiting" => 0, "held_up" => 0, "agents_working" => 0}
  @plan_required %{
    "error" => "plan_required",
    "feature" => "mobile_app",
    "message" => "The Stride app is available to boards in an Organization."
  }

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {_phone, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})
    board = ai_optimized_board_fixture(user)

    %{user: user, scope: scope, board: board, cols: columns(board), phone: phone.access_token}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp api_get(token, path) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(path)
  end

  defp decisions(token), do: token |> api_get("/api/me/decisions") |> json_response(200)
  defp reviews(token), do: token |> api_get("/api/me/reviews") |> json_response(200)

  defp pending_task!(column, seconds_ago \\ 600) do
    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{
        needs_review: true,
        completed_at: now(),
        completed_by_agent: "Claude"
      })

    task
    |> Ecto.Changeset.change(review_requested_at: DateTime.add(now(), -seconds_ago))
    |> Repo.update!()
  end

  defp dependent!(column, identifiers) do
    column
    |> task_fixture()
    |> Ecto.Changeset.change(dependencies: identifiers)
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

    board
    |> Ecto.Changeset.change(workspace_id: workspace.id)
    |> Repo.update!()
  end

  defp org_board_organization(board) do
    Repo.preload(board, workspace: :organization).workspace.organization
  end

  defp ids(items), do: Enum.map(items, & &1["id"])

  describe "GET /api/me/decisions" do
    test "returns decisions and the summary", ctx do
      review = pending_task!(ctx.cols["Review"])
      held = dependent!(ctx.cols["Backlog"], [review.identifier])
      goal = failed_goal!(ctx.cols["Doing"])

      attach_telemetry([:kanban, :decisions, :built])

      assert %{"data" => %{"items" => items, "summary" => summary}} = decisions(ctx.phone)

      assert_receive {:telemetry_event, [:kanban, :decisions, :built], %{count: 2},
                      %{source: :api}}

      # Both hold up one task, so the goal, which has waited longer, comes first.
      assert ids(items) == ["hook_failed:goal:#{goal.id}", "review:task:#{review.id}"]

      item = Enum.find(items, &(&1["kind"] == "review"))

      assert item["task_id"] == review.id
      assert item["board_id"] == ctx.board.id
      assert item["holds_up"] == 1
      assert item["held_identifiers"] == [held.identifier]
      assert item["actions"] == ["open_review", "approve", "request_changes", "open_on_web"]

      assert item["summary"] == %{
               "identifier" => review.identifier,
               "title" => review.title,
               "priority" => Atom.to_string(review.priority),
               "agent" => "Claude",
               "board" => %{"id" => ctx.board.id, "name" => ctx.board.name}
             }

      assert %{"verdicts" => [], "first_failed_note" => nil} = item["details"]

      hook = Enum.find(items, &(&1["kind"] == "hook_failed"))
      assert hook["details"] == %{"exit_code" => 1, "duration_ms" => 4000}

      # Two tasks held up: the review's dependent and the failed goal itself.
      assert summary == %{"waiting" => 2, "held_up" => 2, "agents_working" => 0}
    end

    test "the badge count equals the summary's waiting", ctx do
      for seconds <- [100, 200, 300], do: pending_task!(ctx.cols["Review"], seconds)
      failed_goal!(ctx.cols["Doing"])

      %{"data" => %{"items" => items, "summary" => summary}} = decisions(ctx.phone)

      assert summary["waiting"] == length(items)
      assert summary["waiting"] == 4
    end

    test "an empty inbox returns an empty list and zero summary", ctx do
      assert decisions(ctx.phone) == %{"data" => %{"items" => [], "summary" => @empty_summary}}
      assert reviews(ctx.phone) == %{"data" => []}
    end

    test "a person in two workspaces sees both boards' items", ctx do
      other = user_fixture()
      org_board = other |> ai_optimized_board_fixture() |> then(&into_org_workspace!(other, &1))
      organization_member_fixture(org_board_organization(org_board), ctx.user)
      {:ok, _} = Boards.add_user_to_board(org_board, ctx.user, :modify, other)

      mine = pending_task!(ctx.cols["Review"], 600)
      theirs = pending_task!(columns(org_board)["Review"], 1200)

      refute org_board.workspace_id == ctx.board.workspace_id

      assert %{"data" => %{"items" => items}} = decisions(ctx.phone)
      assert ids(items) == ["review:task:#{theirs.id}", "review:task:#{mine.id}"]
      assert Enum.map(items, & &1["board_id"]) == [org_board.id, ctx.board.id]
    end

    test "a person removed from a board stops seeing its items on the next call", ctx do
      other = user_fixture()
      shared = ai_optimized_board_fixture(other)
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :modify, other)
      task = pending_task!(columns(shared)["Review"])

      assert %{"data" => %{"items" => [%{"task_id" => task_id}]}} = decisions(ctx.phone)
      assert task_id == task.id

      {:ok, _} = Boards.remove_user_from_board(shared, ctx.user, other)

      assert decisions(ctx.phone)["data"]["items"] == []
      assert reviews(ctx.phone)["data"] == []
    end

    test "a read-only member is offered only open_on_web", ctx do
      other = user_fixture()
      shared = ai_optimized_board_fixture(other)
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, other)
      pending_task!(columns(shared)["Review"])

      assert %{"data" => %{"items" => [item]}} = decisions(ctx.phone)
      assert item["actions"] == ["open_on_web"]
    end

    test "a phone's review item agrees with approvable_here", ctx do
      files = Enum.map_join(1..11, ", ", &"lib/file_#{&1}.ex")

      large =
        ctx.cols["Review"]
        |> pending_task!()
        |> Ecto.Changeset.change(actual_files_changed: files)
        |> Repo.update!()

      small = pending_task!(ctx.cols["Review"])
      {_tablet, tablet} = device_with_tokens_fixture(ctx.scope, %{device_class: :tablet})

      for {token, task} <- [{ctx.phone, large}, {ctx.phone, small}, {tablet.access_token, large}] do
        detail = token |> api_get("/api/me/reviews/#{task.id}") |> json_response(200)
        approvable = detail["data"]["approvable_here"]
        assert is_boolean(approvable)

        for list <- [decisions(token)["data"]["items"], reviews(token)["data"]] do
          item = Enum.find(list, &(&1["task_id"] == task.id))
          assert "approve" in item["actions"] == approvable
        end
      end

      refute ctx.phone
             |> api_get("/api/me/reviews/#{large.id}")
             |> json_response(200)
             |> get_in(["data", "approvable_here"])
    end

    test "a read-only member's link opens the board", ctx do
      other = user_fixture()
      shared = ai_optimized_board_fixture(other)
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, other)
      pending_task!(columns(shared)["Review"])

      assert %{"data" => %{"items" => [item]}} = decisions(ctx.phone)
      assert item["web_url"] == KanbanWeb.Endpoint.url() <> "/boards/#{shared.id}"
    end

    test "matches the documented schemas", ctx do
      review = pending_task!(ctx.cols["Review"])
      dependent!(ctx.cols["Backlog"], [review.identifier])
      failed_goal!(ctx.cols["Doing"])

      data = decisions(ctx.phone)["data"]
      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      details_schema = %{
        "review" => "DecisionReviewDetails",
        "hook_failed" => "DecisionHookFailedDetails"
      }

      item_pairs =
        Enum.flat_map(data["items"], fn item ->
          [
            {item, "DecisionItem"},
            {item["summary"], "DecisionTaskSummary"},
            {item["summary"]["board"], "DecisionBoard"},
            {item["details"], Map.fetch!(details_schema, item["kind"])}
          ]
        end)

      assert length(item_pairs) == 8

      for {value, schema} <-
            [{data, "DecisionList"}, {data["summary"], "DecisionSummary"}] ++ item_pairs do
        assert_schema(spec, value, schema)
      end

      for item <- data["items"], action <- item["actions"] do
        assert action in spec["components"]["schemas"]["DecisionItem"]["properties"]["actions"][
                 "items"
               ]["enum"]
      end

      for item <- reviews(ctx.phone)["data"], do: assert_schema(spec, item, "DecisionItem")
    end
  end

  describe "GET /api/me/reviews" do
    test "reviews returns only review items in decision order", ctx do
      newer = pending_task!(ctx.cols["Review"], 300)
      older = pending_task!(ctx.cols["Review"], 3600)
      blocking = pending_task!(ctx.cols["Review"], 60)
      dependent!(ctx.cols["Backlog"], [blocking.identifier])
      failed_goal!(ctx.cols["Doing"])

      attach_telemetry([:kanban, :decisions, :built])

      assert %{"data" => queue} = reviews(ctx.phone)
      assert_receive {:telemetry_event, _, %{count: 4}, %{source: :api}}

      decision_reviews =
        decisions(ctx.phone)["data"]["items"] |> Enum.filter(&(&1["kind"] == "review"))

      assert queue == decision_reviews

      assert ids(queue) == [
               "review:task:#{blocking.id}",
               "review:task:#{older.id}",
               "review:task:#{newer.id}"
             ]
    end
  end

  describe "plan gating" do
    test "plan_required when the person has no paid access", ctx do
      pending_task!(ctx.cols["Review"])
      enforce_plans()

      for path <- ["/api/me/decisions", "/api/me/reviews"] do
        assert ctx.phone |> api_get(path) |> json_response(403) == @plan_required
      end
    end

    test "boards outside the plan never appear", ctx do
      free = pending_task!(ctx.cols["Review"])

      org_board =
        ctx.user |> ai_optimized_board_fixture() |> then(&into_org_workspace!(ctx.user, &1))

      paid = pending_task!(columns(org_board)["Review"])

      enforce_plans()

      assert %{"data" => %{"items" => items, "summary" => summary}} = decisions(ctx.phone)
      assert ids(items) == ["review:task:#{paid.id}"]
      assert summary["waiting"] == 1
      assert ids(reviews(ctx.phone)["data"]) == ["review:task:#{paid.id}"]
      refute "review:task:#{free.id}" in ids(items)
    end
  end

  describe "authentication" do
    test "an agent API token gets 401", ctx do
      pending_task!(ctx.cols["Review"])

      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ai_optimized_board_fixture(ctx.user), %{
          name: "Agent"
        })

      for path <- ["/api/me/decisions", "/api/me/reviews"],
          token <- [agent_token, "not-a-device-token"] do
        assert token |> api_get(path) |> json_response(401)
      end
    end

    test "a request with no token gets 401" do
      for path <- ["/api/me/decisions", "/api/me/reviews"] do
        assert build_conn() |> get(path) |> json_response(401)
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

  # A property with a $ref is checked by its own schema.
  defp type_allowed?(_value, %{"$ref" => _}), do: true

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
