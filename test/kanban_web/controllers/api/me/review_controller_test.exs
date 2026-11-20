defmodule KanbanWeb.API.Me.ReviewControllerTest do
  # async: false - some tests switch the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks

  @requested_at ~U[2026-11-18 09:30:00Z]

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {_phone, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})
    {_tablet, tablet} = device_with_tokens_fixture(scope, %{device_class: :tablet})
    board = board_fixture(user)
    review = column_fixture(board, %{name: "Review", position: 1})

    %{
      user: user,
      board: board,
      review: review,
      phone: phone.access_token,
      tablet: tablet.access_token
    }
  end

  defp get_review(token, id) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/api/me/reviews/#{id}")
  end

  defp pending_task!(column, attrs \\ %{}) do
    {:ok, task} =
      column
      |> task_fixture(%{title: "Show the member list"})
      |> Tasks.update_task(%{needs_review: true, completed_by_agent: "Claude"})

    task
    |> Ecto.Changeset.change(Map.merge(%{review_requested_at: @requested_at}, attrs))
    |> Repo.update!()
  end

  defp entry(path, diff), do: %{"path" => path, "diff" => diff, "diff_url" => nil}

  defp added(n), do: Enum.map_join(1..n//1, "\n", &"+line #{&1}")

  defp reviewed_attrs do
    %{
      completion_summary: "Added the member list.",
      time_spent_minutes: 45,
      acceptance_criteria: "Members are listed",
      security_considerations: ["Only members see the list"],
      changed_files: [
        entry("lib/kanban/organizations.ex", "+one\n+two"),
        entry("lib/kanban_web/live/org_live/show.ex", "@@ -1,2 +1,2 @@\n-old\n+new\n ctx")
      ],
      reviewer_result: %{
        "status" => "changes_requested",
        "patterns" => %{"status" => "failed", "note" => "The query is in the LiveView."},
        "testing_strategy" => %{"status" => "passed"},
        "issues" => [
          %{
            "severity" => "important",
            "category" => "pattern",
            "file" => "lib/kanban_web/live/org_live/show.ex",
            "line" => 2
          }
        ],
        "acceptance_criteria" => [
          %{"criterion" => "Members are listed", "status" => "met", "evidence" => "a test"}
        ],
        "security_considerations" => %{
          "status" => "passed",
          "considerations" => [
            %{"consideration" => "Only members see the list", "status" => "mitigated"}
          ]
        },
        "project_checks" => [%{"status" => "met"}],
        "behaviour_test_matrix" => %{
          "rows" => [
            %{
              "category" => "Happy path",
              "behaviour" => "Lists members",
              "test_name" => "lists",
              "type" => "integration",
              "status" => "passing"
            }
          ]
        }
      }
    }
  end

  defp with_goal!(task, column) do
    goal = column |> task_fixture(%{title: "Organization console"})
    task |> Ecto.Changeset.change(parent_id: goal.id) |> Repo.update!()
    goal
  end

  defp dependent!(column, task, status) do
    column
    |> task_fixture(%{title: "Waits on #{task.identifier}"})
    |> Ecto.Changeset.change(%{dependencies: [task.identifier], status: status})
    |> Repo.update!()
  end

  defp into_org_workspace!(user, board) do
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    workspace = org_workspace_fixture(organization)

    board
    |> Ecto.Changeset.change(workspace_id: workspace.id)
    |> Repo.update!()
  end

  describe "GET /api/me/reviews and web /review list the same reviews (W2751)" do
    import Phoenix.LiveViewTest

    defp api_ids(token) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/me/reviews")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["task_id"])
    end

    defp web_ids(user) do
      {:ok, _view, html} = build_conn() |> log_in_user(user) |> live(~p"/review")

      ~r/data-review-queue-item-id="(\d+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [id] -> String.to_integer(id) end)
    end

    defp waiting!(column, minutes_ago, attrs \\ %{}) do
      at = DateTime.add(~U[2026-11-18 12:00:00Z], -minutes_ago * 60)
      pending_task!(column, Map.put(attrs, :review_requested_at, at))
    end

    test "the same items in the same order, without archived or other people's tasks", ctx do
      other_review = user_fixture() |> board_fixture() |> column_fixture(%{name: "Review"})
      _other = waiting!(other_review, 90)

      second_review = ctx.user |> board_fixture() |> column_fixture(%{name: "Review"})
      oldest = waiting!(ctx.review, 60)
      middle = waiting!(second_review, 30)
      newest = waiting!(ctx.review, 5)
      _archived = waiting!(ctx.review, 45, %{archived_at: ~U[2026-11-18 11:50:00Z]})

      assert web_ids(ctx.user) == [oldest.id, middle.id, newest.id]
      assert api_ids(ctx.phone) == web_ids(ctx.user)
    end

    test "under enforcement the app leaves out plan-locked boards and keeps the web order", ctx do
      org_board = ctx.user |> board_fixture() |> then(&into_org_workspace!(ctx.user, &1))
      org_review = column_fixture(org_board, %{name: "Review"})

      locked = waiting!(ctx.review, 50)
      first = waiting!(org_review, 40)
      second = waiting!(org_review, 10)

      enforce_plans()

      web = web_ids(ctx.user)
      assert web == [locked.id, first.id, second.id]
      assert api_ids(ctx.phone) == Enum.reject(web, &(&1 == locked.id))
    end
  end

  describe "GET /api/me/reviews/:task_id" do
    test "returns the review for a pending task the person can review", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())
      goal = with_goal!(task, ctx.review)
      held = dependent!(ctx.review, task, :blocked)
      _done = dependent!(ctx.review, task, :completed)

      data = ctx.phone |> get_review(task.id) |> json_response(200) |> Map.fetch!("data")

      assert data["task"] == %{
               "id" => task.id,
               "identifier" => task.identifier,
               "title" => "Show the member list",
               "priority" => "medium",
               "completed_by_agent" => "Claude",
               "time_spent_minutes" => 45,
               "board" => %{"id" => ctx.board.id, "name" => ctx.board.name},
               "goal" => %{
                 "id" => goal.id,
                 "identifier" => goal.identifier,
                 "title" => goal.title
               }
             }

      assert data["summary"] == "Added the member list."

      assert Enum.map(data["verdicts"], &{&1["section"], &1["status"]}) == [
               {"acceptance_criteria", "failed"},
               {"testing_strategy", "passed"},
               {"patterns", "failed"},
               {"pitfalls", "not_assessed"},
               {"security_considerations", "passed"}
             ]

      assert %{"note" => "The query is in the LiveView."} = Enum.at(data["verdicts"], 2)

      assert data["acceptance_criteria"] == [
               %{"criterion" => "Members are listed", "status" => "met", "evidence" => "a test"}
             ]

      assert [%{"consideration" => "Only members see the list", "status" => "mitigated"}] =
               data["security_considerations"]

      assert data["security_findings"] == %{"critical" => 0, "important" => 0, "minor" => 0}
      assert data["project_checks"] == %{"met" => 1, "not_met" => 0, "not_applicable" => 0}
      assert data["exploratory"] == %{"count" => nil, "note" => "see_notes_on_web"}

      assert [%{"behaviour" => "Lists members", "type" => "integration"}] =
               data["behaviour_matrix"]

      assert data["files"] == [
               %{
                 "index" => 1,
                 "path" => "lib/kanban_web/live/org_live/show.ex",
                 "additions" => 1,
                 "deletions" => 1,
                 "truncated" => false,
                 "flagged" => true,
                 "flag_reason" => "issue"
               },
               %{
                 "index" => 0,
                 "path" => "lib/kanban/organizations.ex",
                 "additions" => 2,
                 "deletions" => 0,
                 "truncated" => false,
                 "flagged" => false,
                 "flag_reason" => nil
               }
             ]

      assert data["size"] == %{
               "files" => 2,
               "files_unknown" => false,
               "changed_lines" => 4,
               "truncated" => false,
               "large_change" => false
             }

      assert data["approvable_here"] == true
      assert data["approvable_here_reason"] == nil
      assert data["review_requested_at"] == "2026-11-18T09:30:00Z"
      assert data["waiting_since"] == "2026-11-18T09:30:00Z"

      assert data["holds_up"] == [
               %{"id" => held.id, "identifier" => held.identifier, "title" => held.title}
             ]

      refute Map.has_key?(data, "completion_notes")
      refute inspect(data) =~ "diff_url"
    end

    test "a large change is approvable on a tablet and not on a phone", ctx do
      task = pending_task!(ctx.review, %{changed_files: [entry("lib/a.ex", added(501))]})

      phone = ctx.phone |> get_review(task.id) |> json_response(200) |> Map.fetch!("data")
      tablet = ctx.tablet |> get_review(task.id) |> json_response(200) |> Map.fetch!("data")

      assert phone["approvable_here"] == false
      assert phone["approvable_here_reason"] == "too_large_for_phone"
      assert phone["size"]["large_change"] == true
      assert tablet["approvable_here"] == true
      assert tablet["approvable_here_reason"] == nil
    end

    test "a pending task with no review verdicts answers with empty verdicts", ctx do
      task = pending_task!(ctx.review)

      data = ctx.phone |> get_review(task.id) |> json_response(200) |> Map.fetch!("data")

      assert data["verdicts"] == []
      assert data["files"] == []
      assert data["task"]["goal"] == nil
    end

    test "answers 404 for a task on a board the person can't see", ctx do
      other = user_fixture()
      other_board = board_fixture(other)
      other_review = column_fixture(other_board, %{name: "Review"})
      unseen = pending_task!(other_review)

      assert ctx.phone |> get_review(unseen.id) |> json_response(404) == %{"error" => "Not Found"}
    end

    test "answers 404 for a read-only member, a task not in Review, and ids that are not one",
         ctx do
      owner = user_fixture()
      shared = board_fixture(owner)
      shared_review = column_fixture(shared, %{name: "Review"})
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, owner)
      read_only = pending_task!(shared_review)

      doing = column_fixture(ctx.board, %{name: "Doing"})
      not_in_review = pending_task!(doing)

      not_pending =
        ctx.review
        |> pending_task!()
        |> Ecto.Changeset.change(needs_review: false)
        |> Repo.update!()

      for id <- [
            read_only.id,
            not_in_review.id,
            not_pending.id,
            "abc",
            "0",
            "99999999999999999999"
          ] do
        assert ctx.phone |> get_review(id) |> json_response(404) == %{"error" => "Not Found"},
               "expected 404 for #{inspect(id)}"
      end
    end

    test "answers plan_required on a free board when plans are enforced", ctx do
      task = pending_task!(ctx.review)
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)

      assert ctx.phone |> get_review(task.id) |> json_response(200)

      enforce_plans()

      assert ctx.phone |> get_review(task.id) |> json_response(403) == %{
               "error" => "plan_required",
               "feature" => "mobile_app",
               "message" => "The Stride app is available to boards in an Organization."
             }
    end

    test "under enforcement, a board in the person's Organization is served", ctx do
      task = pending_task!(ctx.review)
      into_org_workspace!(ctx.user, ctx.board)
      enforce_plans()

      assert %{"data" => %{"task" => %{"id" => id}}} =
               ctx.phone |> get_review(task.id) |> json_response(200)

      assert id == task.id
    end

    test "under enforcement, a person outside an Organization is refused before any lookup",
         ctx do
      enforce_plans()

      assert %{"error" => "plan_required"} =
               ctx.phone |> get_review(123_456) |> json_response(403)
    end

    test "an agent API token and a made-up token are refused", ctx do
      task = pending_task!(ctx.review)

      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ai_optimized_board_fixture(ctx.user), %{
          name: "Agent"
        })

      for token <- [agent_token, "not-a-device-token"] do
        assert token |> get_review(task.id) |> json_response(401)
      end
    end

    test "matches the documented response schema", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())
      with_goal!(task, ctx.review)
      dependent!(ctx.review, task, :open)

      data = ctx.phone |> get_review(task.id) |> json_response(200) |> Map.fetch!("data")
      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      for {value, schema} <- [
            {data, "ReviewDetail"},
            {data["task"], "ReviewTask"},
            {data["task"]["board"], "ReviewBoard"},
            {data["task"]["goal"], "ReviewGoal"},
            {hd(data["verdicts"]), "ReviewVerdict"},
            {hd(data["acceptance_criteria"]), "ReviewAcceptanceCriterion"},
            {hd(data["security_considerations"]), "ReviewSecurityConsideration"},
            {data["security_findings"], "ReviewSeverityCounts"},
            {data["project_checks"], "ReviewProjectChecks"},
            {data["exploratory"], "ReviewExploratory"},
            {hd(data["behaviour_matrix"]), "ReviewBehaviourRow"},
            {hd(data["files"]), "ReviewFile"},
            {data["size"], "ReviewSize"},
            {hd(data["holds_up"]), "ReviewHeldTask"}
          ] do
        properties = get_in(spec, ["components", "schemas", schema, "properties"])

        assert value |> Map.keys() |> MapSet.new() == properties |> Map.keys() |> MapSet.new(),
               "#{schema} does not match the rendered keys"

        for {key, rendered} <- value do
          assert type_allowed?(rendered, properties[key]),
                 "#{schema}.#{key} is #{inspect(rendered)}, not #{inspect(properties[key])}"
        end
      end
    end
  end

  # A property with a $ref is checked by its own schema in the loop above.
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
