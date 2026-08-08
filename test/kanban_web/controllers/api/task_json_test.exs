defmodule KanbanWeb.API.TaskJSONTest do
  @moduledoc """
  Round-trip tests asserting `reviewer_result` is persisted and serialized
  verbatim — including the W688/W689 structured fields and arbitrary
  unknown forward-compatible fields.

  The `reviewer_result` field is `:map` on `Kanban.Tasks.Task`, cast as
  a JSON blob, rendered by `KanbanWeb.API.TaskJSON` without allowlisting,
  and `KanbanWeb.API.CompletionResultGate` runs the validator without
  mutating the payload. These tests guard against any regression that
  would narrow that contract.

  Also covers `completion_notes` serialization (D188) — the field was
  historically absent from the serializer, so a submitted value could not
  be read back.

  Finally, guards the two properties the `response_view=slim` work (W2054,
  W2056, W2059) depends on but never asserted: that slimming the *echo*
  changes neither what is **persisted** nor what reaches the **review
  queue** (W2060). Both are structurally true — the write completes before
  the view is resolved, and `KanbanWeb.ReviewLive` loads through
  `Kanban.Reviews.list_pending_reviews/1` rather than through any API view
  — but a structural argument is not a regression test, and these two are.

  Last, the review-field presence guard (W2058), which covers a different
  failure mode from W2060 above: not "does a review field survive the round
  trip" but "is it still *rendered at all*". Nothing caught a later slimming
  change quietly dropping a review field from the **full** view — W2060 reaches
  only four fields, one endpoint, and only through persistence and the review
  queue, never through the rendered shape. The guard states three expectations
  rather than nine assertions: `data/1` renders all nine schema review fields,
  `ack_data/1` renders exactly two of them (`needs_review`, `review_status`),
  and `render_task_summary/1` renders none. Each is asserted as set equality, so
  it fails both when a field goes missing and when one leaks into a view meant
  to be compact.

  Seven of the nine are name-matched against `Task.__schema__(:fields)` by a
  drift canary, so the frozen list cannot silently fall behind the schema; only
  `workflow_steps` and `explorer_result` are named by hand. The canary asserts
  rather than derives on purpose — deriving would make the guard a policy that
  every review-named field MUST be rendered, which is the wrong pressure for a
  module whose compact views exist to expose less.
  """

  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.TaskJSON

  @moduletag capture_log: true

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Test Token",
        "agent_capabilities" => ["code_generation", "testing"]
      })

    column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Backlog"))

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token}")

    %{conn: conn, column: column, user: user, board: board}
  end

  defp structured_reviewer_result do
    %{
      "dispatched" => true,
      "summary" => "Reviewed the diff against all acceptance criteria and pitfalls.",
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 2,
      "issues_found" => 1,
      "schema_version" => "1.0",
      "status" => "changes_requested",
      "issue_counts" => %{"critical" => 0, "important" => 1, "minor" => 0},
      "issues" => [
        %{
          "severity" => "important",
          "category" => "pattern",
          "file" => "lib/foo.ex",
          "line" => 42,
          "description" => "Deviation from documented pattern",
          "suggested_fix" => "Mirror the existing handler shape."
        }
      ],
      "acceptance_criteria" => [
        %{"criterion" => "Criterion A", "status" => "met", "evidence" => "test/foo_test.exs"},
        %{"criterion" => "Criterion B", "status" => "not_met"}
      ],
      "testing_strategy" => %{
        "status" => "passed",
        "notes" => "All required test cases present."
      },
      "patterns" => %{"status" => "passed"},
      "pitfalls" => %{"status" => "failed", "notes" => "One pitfall violated."}
    }
  end

  describe "render_task_summary/1 — canonical summary shape (W2055)" do
    test "renders exactly the eight summary keys and nothing wider", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Summary shape task"})

      summary = TaskJSON.render_task_summary(task)

      assert summary |> Map.keys() |> Enum.sort() == [
               :complexity,
               :created_by_agent,
               :dependencies,
               :id,
               :identifier,
               :priority,
               :status,
               :title
             ]

      # The summary is deliberately narrower than data/1. These three are
      # rendered by the full view and must never leak into the compact row.
      refute Map.has_key?(summary, :description)
      refute Map.has_key?(summary, :key_files)
      refute Map.has_key?(summary, :reviewer_result)
    end

    test "passes every field through verbatim", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Verbatim passthrough task",
          "priority" => "critical",
          "complexity" => "large",
          "dependencies" => ["W900", "W901"],
          "created_by_agent" => "Claude Opus 5"
        })

      summary = TaskJSON.render_task_summary(task)

      assert summary.id == task.id
      assert summary.identifier == task.identifier
      assert summary.title == "Verbatim passthrough task"
      assert summary.status == task.status
      assert summary.priority == :critical
      assert summary.complexity == :large
      assert summary.dependencies == ["W900", "W901"]
      assert summary.created_by_agent == "Claude Opus 5"
    end

    # Built as a bare struct rather than a persisted task on purpose: the
    # schema defaults dependencies to [], so a DB-loaded task never carries
    # nil and the `|| []` branch would otherwise go uncovered.
    test "defaults nil dependencies to an empty list" do
      summary = TaskJSON.render_task_summary(%Task{id: 1, dependencies: nil})

      assert summary.dependencies == []
    end

    test "keeps a nil created_by_agent as a present nil key", %{column: column} do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Unattributed task"})

      summary = TaskJSON.render_task_summary(task)

      assert Map.has_key?(summary, :created_by_agent)
      assert is_nil(summary.created_by_agent)
    end
  end

  describe "index/1 and tree/1 under response_view (W2057)" do
    setup %{column: column} do
      {:ok, goal} = Tasks.create_task(column, %{"title" => "Tree root goal", "type" => "goal"})
      {:ok, child_one} = Tasks.create_task(column, %{"title" => "Child one"})
      {:ok, child_two} = Tasks.create_task(column, %{"title" => "Child two"})

      tree = %{
        task: goal,
        children: [child_one, child_two],
        counts: %{total: 2, completed: 1, blocked: 0}
      }

      %{goal: goal, children: [child_one, child_two], tree: tree}
    end

    test "the full index render is unchanged by an explicit full view", %{children: tasks} do
      assert TaskJSON.index(%{tasks: tasks}) ==
               TaskJSON.index(%{tasks: tasks, response_view: :full})
    end

    test "the slim index reuses the canonical summary renderer", %{children: tasks} do
      assert TaskJSON.index(%{tasks: tasks, response_view: :slim}) ==
               %{data: Enum.map(tasks, &TaskJSON.render_task_summary/1)}
    end

    # render/3 merges conn.assigns, so in production the view function always
    # receives a superset of the keys the controller passed. A bare
    # %{tasks: tasks} clause matches that superset too, so the slim clause only
    # fires because it is written first — and the compiler emits no warning
    # either way. This is the unit-level guard for that ordering; the slim
    # request tests in task_controller_test.exs ("GET /api/tasks" and
    # "GET /api/tasks/:id/tree") guard it end to end through the real merged
    # assigns, and fail too if the clauses are swapped.
    test "the slim clause still wins on a production-shaped assigns map", %{
      children: tasks,
      tree: tree
    } do
      index_assigns = %{
        tasks: tasks,
        response_view: :slim,
        conn: :ignored,
        current_board: :ignored,
        current_user: :ignored
      }

      assert TaskJSON.index(index_assigns) ==
               %{data: Enum.map(tasks, &TaskJSON.render_task_summary/1)}

      tree_assigns = %{
        tree: tree,
        response_view: :slim,
        conn: :ignored,
        current_board: :ignored,
        current_user: :ignored
      }

      assert TaskJSON.tree(tree_assigns).data.children ==
               Enum.map(tree.children, &TaskJSON.render_task_summary/1)
    end

    test "an empty board renders an empty data list in both views" do
      assert TaskJSON.index(%{tasks: []}) == %{data: []}
      assert TaskJSON.index(%{tasks: [], response_view: :slim}) == %{data: []}
    end

    test "the slim tree slims children but keeps a full root and untouched counts", %{tree: tree} do
      full = TaskJSON.tree(%{tree: tree})
      slim = TaskJSON.tree(%{tree: tree, response_view: :slim})

      assert slim.data.task == full.data.task
      assert slim.data.children == Enum.map(tree.children, &TaskJSON.render_task_summary/1)
      assert slim.data.counts == full.data.counts
      assert slim.data.counts == tree.counts
    end

    test "the full tree render is unchanged by an explicit full view", %{tree: tree} do
      assert TaskJSON.tree(%{tree: tree}) == TaskJSON.tree(%{tree: tree, response_view: :full})
    end

    test "a goal with no children renders an empty children list under slim", %{goal: goal} do
      tree = %{task: goal, children: [], counts: %{total: 0, completed: 0, blocked: 0}}

      assert TaskJSON.tree(%{tree: tree, response_view: :slim}).data.children == []
    end

    # Intentional and canonical, not a bug: the summary renderer defaults nil
    # dependencies to [], which is the shape /dependencies, /dependents and
    # goal-creation child_tasks have always returned. data/1 renders the field
    # raw. Reusing the one canonical renderer means inheriting that, and the
    # alternative — a second compact shape that handles nil differently — is
    # exactly what this goal exists to prevent.
    test "the slim row defaults nil dependencies to [] where the full row keeps nil" do
      tasks = [%Task{id: 1, dependencies: nil}]

      [slim_row] = TaskJSON.index(%{tasks: tasks, response_view: :slim}).data
      [full_row] = TaskJSON.index(%{tasks: tasks}).data

      assert slim_row.dependencies == []
      assert is_nil(full_row.dependencies)
    end
  end

  describe "completion_notes serialization (D188)" do
    test "the serializer returns completion_notes for a completed task", %{
      conn: conn,
      column: column
    } do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Task with completion notes"})

      {:ok, task} =
        task
        |> Ecto.Changeset.change(completion_notes: "Explored the importer; parked 2 findings.")
        |> Kanban.Repo.update()

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert Map.has_key?(response, "completion_notes")
      assert response["completion_notes"] == "Explored the importer; parked 2 findings."
    end

    test "the serializer includes the key as null when no notes were recorded", %{
      conn: conn,
      column: column
    } do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Task without completion notes"})

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert Map.has_key?(response, "completion_notes")
      assert is_nil(response["completion_notes"])
    end
  end

  describe "reviewer_result round trip via API JSON" do
    test "structured payload survives create + GET unchanged", %{conn: conn, column: column} do
      payload = structured_reviewer_result()

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with structured reviewer result",
          "reviewer_result" => payload
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["reviewer_result"] == payload
    end

    test "unknown forward-compatible fields survive the round trip",
         %{conn: conn, column: column} do
      payload =
        structured_reviewer_result()
        |> Map.put("future_field", "some value")
        |> Map.put("nested_future", %{
          "another_key" => [1, 2, 3],
          "deeper" => %{"and_deeper" => true}
        })
        |> update_in(["issues", Access.at(0)], &Map.put(&1, "future_per_issue_field", :something))

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with future fields",
          "reviewer_result" => payload
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      # Atom values become strings after JSON round-trip; we compare
      # everything else byte-equivalent. The :something atom in the
      # original payload is normalized to "something" in the response.
      assert response["reviewer_result"]["future_field"] == "some value"

      assert response["reviewer_result"]["nested_future"] == %{
               "another_key" => [1, 2, 3],
               "deeper" => %{"and_deeper" => true}
             }

      first_issue = hd(response["reviewer_result"]["issues"])
      assert first_issue["future_per_issue_field"] == "something"
      assert first_issue["severity"] == "important"
      assert first_issue["category"] == "pattern"
    end

    test "empty arrays in structured fields survive the round trip",
         %{conn: conn, column: column} do
      payload =
        structured_reviewer_result()
        |> Map.put("issues", [])
        |> Map.put("acceptance_criteria", [])

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with empty arrays",
          "reviewer_result" => payload
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["reviewer_result"]["issues"] == []
      assert response["reviewer_result"]["acceptance_criteria"] == []
    end

    test "legacy reviewer_result (no structured fields) still round-trips",
         %{conn: conn, column: column} do
      legacy = %{
        "dispatched" => true,
        "summary" => "Reviewed the diff against acceptance criteria and pitfalls.",
        "duration_ms" => 8_000,
        "acceptance_criteria_checked" => 5,
        "issues_found" => 0
      }

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task with legacy reviewer result",
          "reviewer_result" => legacy
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      response = json_response(conn, 200)["data"]

      assert response["reviewer_result"] == legacy
    end
  end

  describe "reviewer_result persistence at the schema layer" do
    test "Task schema accepts and reloads structured reviewer_result identically",
         %{column: column} do
      payload = structured_reviewer_result()

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Task for schema round trip",
          "reviewer_result" => payload
        })

      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, task.id)

      assert reloaded.reviewer_result == payload
    end
  end

  # W2060: the slim response views must never affect what is persisted or what
  # the review queue displays. Both tests below complete a task through
  # `response_view=slim` — the view that does NOT echo these fields back — and
  # then read them from somewhere else entirely. Reading them from the
  # completion response would defeat the point: that is the path being removed.
  describe "review fields survive a slim completion (W2060)" do
    # The single source of truth for both assertions below. Deriving both from
    # one map is deliberate: two hand-maintained field lists would drift, and a
    # field silently dropped from one list is exactly the regression these
    # tests exist to catch.
    defp slimmed_review_fields do
      %{
        # Extended here rather than in structured_reviewer_result/0, which
        # other tests in this file assert against verbatim. The completion
        # gate requires both of these on a dispatched review.
        "reviewer_result" =>
          Map.merge(structured_reviewer_result(), %{
            "project_checks" => [
              %{
                "check" => "No String.to_atom/1 on user input",
                "source" => "CODE-REVIEW.md",
                "status" => "met",
                "evidence" => "lib/foo.ex:12 uses a literal-string allow-list"
              }
            ],
            "security_considerations" => %{
              "status" => "passed",
              "note" => "No new authorization, injection or disclosure surface in the diff."
            }
          }),
        "explorer_result" => %{
          "dispatched" => true,
          "duration_ms" => 12_450,
          "summary" =>
            "Explored the controller and its sibling view module, then traced " <>
              "the completion write path end to end before implementing."
        },
        "review_report" =>
          "## Review Summary\n\nApproved — 0 issues found.\n\n- criterion 1: met",
        "completion_notes" => "Implemented the change; all tests passing. See the review report."
      }
    end

    defp complete_via_slim!(conn, user, board) do
      columns = Columns.list_columns(board)
      doing = Enum.find(columns, &(&1.name == "Doing"))

      {:ok, task} =
        Tasks.create_task(doing, %{
          "title" => "Slim completion round-trip",
          "status" => "in_progress",
          "claimed_at" => DateTime.utc_now(),
          "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "needs_review" => true
        })

      params =
        Map.merge(slimmed_review_fields(), %{
          "agent_name" => "Claude Opus 5",
          "completion_summary" => "Completed through the slim view for the W2060 guard.",
          "actual_complexity" => "small",
          "actual_files_changed" => "lib/foo.ex, test/foo_test.exs",
          "time_spent_minutes" => 12,
          "after_doing_result" => %{"exit_code" => 0, "output" => "ok", "duration_ms" => 100},
          "before_review_result" => %{"exit_code" => 0, "output" => "ok", "duration_ms" => 100}
        })

      conn = patch(conn, ~p"/api/tasks/#{task.id}/complete?response_view=slim", params)
      body = json_response(conn, 200)

      # Precondition, not the assertion under test: prove we really exercised
      # the slim view, so neither test below can pass by reading an echo.
      refute Map.has_key?(body["data"], "reviewer_result")

      {conn, task}
    end

    test "every review field round-trips verbatim through GET /api/tasks/:id", %{
      conn: conn,
      user: user,
      board: board
    } do
      {conn, task} = complete_via_slim!(conn, user, board)

      response = json_response(get(conn, ~p"/api/tasks/#{task.id}"), 200)["data"]

      for {field, submitted} <- slimmed_review_fields() do
        assert response[field] == submitted,
               "#{field} did not round-trip verbatim through a slim completion"
      end
    end

    test "the review queue still sees every review field", %{
      conn: conn,
      user: user,
      board: board
    } do
      {_conn, task} = complete_via_slim!(conn, user, board)

      # Scoped exactly as ReviewLive.load_queue/1 calls it — an unscoped call
      # would exercise a different query and could mask a scope-filtering leak.
      scope = Kanban.Accounts.Scope.for_user(user)
      queued = Kanban.Reviews.list_pending_reviews(scope: scope)

      assert queued_task = Enum.find(queued, &(&1.id == task.id)),
             "a task completed through the slim view never reached the review queue"

      for {field, submitted} <- slimmed_review_fields() do
        actual = Map.fetch!(queued_task, String.to_existing_atom(field))

        assert actual == submitted,
               "#{field} did not reach the review queue after a slim completion"
      end

      # Negative half of the scope contract. Without this the test would stay
      # green even if apply_board_scope/2 became a no-op — passing a scope
      # would be satisfied syntactically while masking exactly the cross-board
      # leak the scope exists to prevent.
      outsider_scope = user_fixture() |> Kanban.Accounts.Scope.for_user()
      outsider_queue = Kanban.Reviews.list_pending_reviews(scope: outsider_scope)

      refute Enum.any?(outsider_queue, &(&1.id == task.id)),
             "a user with no membership on the board saw the task in the review queue"
    end
  end

  # W2058: the executable form of "no review field may be removed from the full
  # view". W2060 above proves review fields survive *persistence* through a slim
  # completion; it says nothing about the *rendered shape*, covers only four
  # fields, and only the /complete endpoint. These guards cover all nine schema
  # review fields across every view, in both directions — a field missing from
  # the full view fails, and a field leaking into a compact view fails too.
  describe "review-field presence across views (W2058)" do
    # The nine review fields as of W2058. Frozen deliberately rather than fully
    # derived: a pure "every review-named schema field must render" rule would
    # turn a regression guard into a policy, and would push the next maintainer
    # toward rendering a field that may be deliberately internal — the wrong
    # direction for a module whose compact views exist to expose less.
    #
    # The list cannot silently fall behind, because the drift canary below
    # polices it against the schema. Known gap, stated rather than papered over:
    # the canary matches on the substring "review", so a future sibling of
    # explorer_result / workflow_steps (say a planner_result) would not be
    # caught. Nothing in the schema makes that derivable.
    @review_fields ~w(needs_review review_status review_notes review_report
                      workflow_steps explorer_result reviewer_result
                      reviewed_at reviewed_by_id)a

    # The two of the nine that ack_data/1 deliberately carries.
    @ack_review_fields ~w(needs_review review_status)a

    # The seven whose names contain "review". workflow_steps and explorer_result
    # are the only two that must be named by hand.
    @name_matched_review_fields ~w(needs_review review_status review_notes
                                   review_report reviewer_result reviewed_at
                                   reviewed_by_id)a

    # Key-set intersection, normalized to strings so the same helper works on
    # atom-keyed view output and string-keyed JSON alike. Presence only — a
    # field whose value is nil still counts, which is the point: these guards
    # assert the KEY is rendered, never that it is truthy.
    #
    # Every assertion below — the green ones AND the deliberately-doctored red
    # ones — must call this same helper on the same shape. A red-proof that
    # exercised a different code path would only prove an unused function works.
    defp review_fields_in(rendered) do
      wanted = MapSet.new(@review_fields, &to_string/1)

      rendered
      |> Map.keys()
      |> MapSet.new(&to_string/1)
      |> MapSet.intersection(wanted)
    end

    defp expected_set(fields), do: MapSet.new(fields, &to_string/1)

    defp sorted_inspect(enumerable), do: enumerable |> Enum.sort() |> inspect()

    defp field_diff(actual, expected) do
      missing = expected |> MapSet.difference(actual) |> sorted_inspect()
      unexpected = actual |> MapSet.difference(expected) |> sorted_inspect()

      "missing: #{missing}, unexpected: #{unexpected}"
    end

    defp leak_message(rendered, where) do
      "a review field leaked into #{where}: " <> sorted_inspect(review_fields_in(rendered))
    end

    defp bare_task(column) do
      {:ok, task} = Tasks.create_task(column, %{"title" => "Bare review-field task"})
      task
    end

    # data/1 is private, so the full render is reached through its public view.
    defp full_render(task), do: TaskJSON.show(%{task: task}).data

    test "the frozen list still matches the review-named schema fields" do
      derived =
        :fields
        |> Task.__schema__()
        |> Enum.filter(fn field -> field |> to_string() |> String.contains?("review") end)
        |> MapSet.new()

      assert derived == MapSet.new(@name_matched_review_fields), """
      The set of review-named schema fields changed.

      If a new review field was added, decide whether it is API-visible:
        - visible  -> render it in TaskJSON.data/1 and add it to @review_fields
                      and @name_matched_review_fields here
        - internal -> add it to @name_matched_review_fields only, with a comment
                      saying why it is deliberately not rendered

      Do NOT delete this assertion to make it pass — a hand-maintained list that
      nothing polices is exactly the drift this canary exists to catch.

      derived from schema: #{inspect(Enum.sort(derived))}
      frozen here:         #{inspect(Enum.sort(@name_matched_review_fields))}
      """
    end

    test "every frozen review field is still a schema field" do
      schema_fields = :fields |> Task.__schema__() |> MapSet.new()
      frozen = MapSet.new(@review_fields)

      assert MapSet.subset?(frozen, schema_fields),
             "renamed or removed from the schema: " <>
               sorted_inspect(MapSet.difference(frozen, schema_fields))
    end

    # A freshly created task IS the all-nil edge case — needs_review defaults to
    # false, workflow_steps to [], and the other seven are nil. Presence must
    # still hold, which is why every assertion here is key-set based.
    test "the full view renders all nine review fields even when every value is nil", %{
      column: column
    } do
      rendered = full_render(bare_task(column))
      expected = expected_set(@review_fields)

      assert review_fields_in(rendered) == expected,
             field_diff(review_fields_in(rendered), expected)

      # Truthiness would have hidden this: the keys are present AND nil.
      assert is_nil(rendered.reviewer_result)
      assert is_nil(rendered.reviewed_at)
    end

    # AC3, first half: proof the guard actually goes red. Same helper, same
    # shape, one field deleted.
    test "the guard fails when a review field is removed from the full view", %{column: column} do
      rendered = full_render(bare_task(column))
      doctored = Map.delete(rendered, :reviewer_result)
      expected = expected_set(@review_fields)

      refute review_fields_in(doctored) == expected

      assert MapSet.difference(expected, review_fields_in(doctored)) ==
               MapSet.new(["reviewer_result"])
    end

    test "the compact views carry exactly the review fields they are meant to", %{
      column: column
    } do
      task = bare_task(column)

      # ack_data/1 is reached through the public ack/1 view.
      ack = TaskJSON.ack(%{task: task}).data

      assert review_fields_in(ack) == expected_set(@ack_review_fields),
             field_diff(review_fields_in(ack), expected_set(@ack_review_fields))

      # The summary row carries none of them. Set equality rather than a
      # presence check, so a future change that leaks reviewer_result into the
      # compact row fails here rather than passing unnoticed.
      summary = TaskJSON.render_task_summary(task)

      assert review_fields_in(summary) == MapSet.new([]),
             leak_message(summary, "the summary row")
    end

    test "GET /api/tasks/:id renders all nine over the wire", %{conn: conn, column: column} do
      task = bare_task(column)
      body = json_response(get(conn, ~p"/api/tasks/#{task.id}"), 200)["data"]
      expected = expected_set(@review_fields)

      # The wire assertion is not redundant with the data/1 one above: a future
      # nil-stripping encoder step, or a @derive {Jason.Encoder, only: [...]},
      # would drop the key from the wire while data/1 still returned it.
      assert review_fields_in(body) == expected, field_diff(review_fields_in(body), expected)
    end

    test "the full index row and the full tree render all nine over the wire", %{
      conn: conn,
      column: column
    } do
      _task = bare_task(column)
      expected = expected_set(@review_fields)

      [row] = json_response(get(conn, ~p"/api/tasks"), 200)["data"]
      assert review_fields_in(row) == expected, field_diff(review_fields_in(row), expected)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{title: "Presence Goal"}, [
          %{title: "Presence Child"}
        ])

      tree = json_response(get(conn, ~p"/api/tasks/#{goal.id}/tree"), 200)["data"]

      assert review_fields_in(tree["task"]) == expected,
             field_diff(review_fields_in(tree["task"]), expected)

      for child <- tree["children"] do
        assert review_fields_in(child) == expected, field_diff(review_fields_in(child), expected)
      end
    end

    test "the slim index and slim tree children carry no review fields, and the tree root keeps all nine",
         %{conn: conn, column: column} do
      _task = bare_task(column)

      [row] = json_response(get(conn, ~p"/api/tasks?response_view=slim"), 200)["data"]

      assert review_fields_in(row) == MapSet.new([]),
             leak_message(row, "a slim index row")

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{title: "Slim Presence Goal"}, [
          %{title: "Slim Presence Child"}
        ])

      tree =
        json_response(get(conn, ~p"/api/tasks/#{goal.id}/tree?response_view=slim"), 200)["data"]

      # The root is deliberately NOT slimmed, so it must still carry all nine.
      assert review_fields_in(tree["task"]) == expected_set(@review_fields),
             field_diff(review_fields_in(tree["task"]), expected_set(@review_fields))

      for child <- tree["children"] do
        assert review_fields_in(child) == MapSet.new([]),
               leak_message(child, "a slim tree child")
      end
    end

    test "the slim changed_files ack carries exactly the two ack review fields", %{
      conn: conn,
      column: column
    } do
      task = bare_task(column)
      payload = %{"changed_files" => [%{"path" => "lib/a.ex", "diff" => "@@ -1 +1 @@\n-a\n+b"}]}

      full =
        json_response(put(conn, ~p"/api/tasks/#{task.id}/changed_files", payload), 200)["data"]

      slim =
        json_response(
          put(conn, ~p"/api/tasks/#{task.id}/changed_files?response_view=slim", payload),
          200
        )["data"]

      assert review_fields_in(full) == expected_set(@review_fields),
             field_diff(review_fields_in(full), expected_set(@review_fields))

      assert review_fields_in(slim) == expected_set(@ack_review_fields),
             field_diff(review_fields_in(slim), expected_set(@ack_review_fields))
    end
  end
end
