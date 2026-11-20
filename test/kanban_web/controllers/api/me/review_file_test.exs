defmodule KanbanWeb.API.Me.ReviewFileTest do
  # async: false - one test switches the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks

  @requested_at ~U[2026-11-18 09:30:00Z]

  @show_diff """
  @@ -1,2 +1,2 @@
  -def old, do: :old
  +def new, do: "new"
   end
  """

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {_phone, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})
    board = board_fixture(user)
    review = column_fixture(board, %{name: "Review", position: 1})

    %{user: user, board: board, review: review, phone: phone.access_token}
  end

  defp get_file(token, id, index) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/api/me/reviews/#{id}/files/#{index}")
  end

  defp pending_task!(column, attrs) do
    {:ok, task} =
      column
      |> task_fixture(%{title: "Show the member list"})
      |> Tasks.update_task(%{needs_review: true, completed_by_agent: "Claude"})

    task
    |> Ecto.Changeset.change(Map.merge(%{review_requested_at: @requested_at}, attrs))
    |> Repo.update!()
  end

  defp entry(path, diff), do: %{"path" => path, "diff" => diff, "diff_url" => nil}

  defp reviewed_attrs do
    %{
      changed_files: [
        entry("lib/kanban/organizations.ex", "@@ -1,0 +1,2 @@\n+one\n+two"),
        entry("lib/kanban_web/live/org_live/show.ex", @show_diff),
        entry("README.md", "")
      ],
      reviewer_result: %{
        "issues" => [
          %{
            "severity" => "important",
            "category" => "pattern",
            "file" => "lib/kanban_web/live/org_live/show.ex",
            "line" => 2,
            "description" => "The query belongs in the context."
          },
          %{
            "severity" => "minor",
            "category" => "testing",
            "file" => "./lib/kanban_web/live/org_live/show.ex",
            "description" => "No test for the empty list."
          },
          %{"severity" => "minor", "category" => "pattern", "file" => "lib/other.ex", "line" => 1}
        ]
      }
    }
  end

  describe "GET /api/me/reviews/:task_id/files/:index" do
    test "returns highlighted lines for a file index", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())

      data = ctx.phone |> get_file(task.id, 1) |> json_response(200) |> Map.fetch!("data")

      assert %{
               "index" => 1,
               "path" => "lib/kanban_web/live/org_live/show.ex",
               "language" => "elixir",
               "file_count" => 3,
               "additions" => 1,
               "deletions" => 1,
               "truncated" => false,
               "flagged" => true,
               "flag_reason" => "issue",
               "review_requested_at" => "2026-11-18T09:30:00Z"
             } = data

      assert Enum.map(data["lines"], &{&1["kind"], &1["old"], &1["new"]}) == [
               {"hunk", nil, nil},
               {"del", 1, nil},
               {"add", nil, 1},
               {"ctx", 2, 2}
             ]

      add = Enum.at(data["lines"], 2)
      assert %{"class" => "keyword", "text" => "def"} in add["spans"]
      assert Enum.map_join(add["spans"], & &1["text"]) == ~s(def new, do: "new")

      assert data["notes"] == [
               %{
                 "line" => 2,
                 "anchored" => true,
                 "severity" => "important",
                 "category" => "pattern",
                 "description" => "The query belongs in the context."
               },
               %{
                 "line" => nil,
                 "anchored" => false,
                 "severity" => "minor",
                 "category" => "testing",
                 "description" => "No test for the empty list."
               }
             ]

      other = ctx.phone |> get_file(task.id, 0) |> json_response(200) |> Map.fetch!("data")
      assert %{"path" => "lib/kanban/organizations.ex", "flagged" => false, "notes" => []} = other
      assert %{"additions" => 2, "deletions" => 0, "flag_reason" => nil} = other
    end

    test "answers 404 for an index out of range", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())

      for index <- ["3", "99", "-1", "abc", "1.5", "10001"] do
        assert ctx.phone |> get_file(task.id, index) |> json_response(404) == %{
                 "error" => "Not Found"
               },
               "expected 404 for index #{inspect(index)}"
      end

      listed_only = pending_task!(ctx.review, %{actual_files_changed: "lib/a.ex, lib/b.ex"})

      assert ctx.phone |> get_file(listed_only.id, 0) |> json_response(404) == %{
               "error" => "Not Found"
             }

      no_path = pending_task!(ctx.review, %{changed_files: [%{"diff" => "+x"}]})
      assert ctx.phone |> get_file(no_path.id, 0) |> json_response(404)
    end

    test "answers 404 for a board the person can't see", ctx do
      other = user_fixture()
      other_review = other |> board_fixture() |> column_fixture(%{name: "Review"})
      unseen = pending_task!(other_review, reviewed_attrs())

      assert ctx.phone |> get_file(unseen.id, 0) |> json_response(404) == %{
               "error" => "Not Found"
             }

      owner = user_fixture()
      shared = board_fixture(owner)
      shared_review = column_fixture(shared, %{name: "Review"})
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, owner)
      read_only = pending_task!(shared_review, reviewed_attrs())

      not_pending =
        ctx.review
        |> pending_task!(reviewed_attrs())
        |> Ecto.Changeset.change(needs_review: false)
        |> Repo.update!()

      for id <- [read_only.id, not_pending.id, "abc"] do
        assert ctx.phone |> get_file(id, 0) |> json_response(404) == %{"error" => "Not Found"},
               "expected 404 for task #{inspect(id)}"
      end
    end

    test "a file with an empty diff returns no lines", ctx do
      task =
        pending_task!(ctx.review, %{
          changed_files: [entry("README.md", ""), %{"path" => "lib/none.ex"}]
        })

      assert %{"lines" => [], "additions" => 0, "deletions" => 0, "language" => "plain"} =
               ctx.phone |> get_file(task.id, 0) |> json_response(200) |> Map.fetch!("data")

      assert %{"lines" => [], "additions" => nil, "deletions" => nil, "truncated" => false} =
               ctx.phone |> get_file(task.id, 1) |> json_response(200) |> Map.fetch!("data")
    end

    test "answers plan_required on a free board when plans are enforced", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)

      assert ctx.phone |> get_file(task.id, 0) |> json_response(200)

      enforce_plans()

      assert %{"error" => "plan_required", "feature" => "mobile_app"} =
               ctx.phone |> get_file(task.id, 0) |> json_response(403)
    end

    test "matches the documented response schema", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())

      body = ctx.phone |> get_file(task.id, 1) |> json_response(200)
      data = body["data"]
      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      for {value, schema} <- [
            {body, "ReviewFileDiffResponse"},
            {data, "ReviewFileDiff"},
            {Enum.at(data["lines"], 2), "ReviewDiffLine"},
            {hd(Enum.at(data["lines"], 2)["spans"]), "ReviewDiffSpan"},
            {hd(data["notes"]), "ReviewFileNote"}
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

  describe "files_version" do
    defp get_versioned(token, id, index, version) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/me/reviews/#{id}/files/#{index}", %{"files_version" => version})
    end

    defp detail_version(token, id) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/me/reviews/#{id}")
      |> json_response(200)
      |> get_in(["data", "files_version"])
    end

    defp replace_files!(task, files),
      do: task |> Ecto.Changeset.change(changed_files: files) |> Repo.update!()

    test "the detail and each file carry the same version", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())

      version = detail_version(ctx.phone, task.id)
      assert is_binary(version) and version != ""

      data = ctx.phone |> get_file(task.id, 1) |> json_response(200) |> Map.fetch!("data")
      assert data["files_version"] == version

      assert ctx.phone |> get_versioned(task.id, 1, version) |> json_response(200)
    end

    test "a stale version answers 409 files_changed with the current version", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())
      stale = detail_version(ctx.phone, task.id)

      # The agent resubmitted in place: same count, files reordered.
      [a, b, c] = task.changed_files
      replace_files!(task, [b, a, c])
      current = detail_version(ctx.phone, task.id)
      refute current == stale

      assert %{
               "error" => "files_changed",
               "files_version" => ^current,
               "message" => message
             } = ctx.phone |> get_versioned(task.id, 0, stale) |> json_response(409)

      assert message =~ "Reload"

      assert %{"data" => %{"path" => "lib/kanban_web/live/org_live/show.ex"}} =
               ctx.phone |> get_versioned(task.id, 0, current) |> json_response(200)
    end

    test "a diff edited in place changes the version", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())
      before = detail_version(ctx.phone, task.id)

      [a, b, c] = task.changed_files
      replace_files!(task, [Map.put(a, "diff", "@@ -1,0 +1,1 @@\n+other"), b, c])

      refute detail_version(ctx.phone, task.id) == before

      assert %{"error" => "files_changed"} =
               ctx.phone |> get_versioned(task.id, 0, before) |> json_response(409)
    end

    test "a missing or empty version skips the check", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())

      assert ctx.phone |> get_file(task.id, 0) |> json_response(200)
      assert ctx.phone |> get_versioned(task.id, 0, "") |> json_response(200)
    end

    test "the 409 matches the documented FilesChanged schema", ctx do
      task = pending_task!(ctx.review, reviewed_attrs())
      body = ctx.phone |> get_versioned(task.id, 0, "stale") |> json_response(409)
      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()
      properties = get_in(spec, ["components", "schemas", "FilesChanged", "properties"])

      assert body |> Map.keys() |> MapSet.new() == properties |> Map.keys() |> MapSet.new()
    end
  end

  describe "archived tasks" do
    test "answer 404 for the detail and the files", ctx do
      task =
        ctx.review
        |> pending_task!(reviewed_attrs())
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
        |> Repo.update!()

      assert ctx.phone |> get_file(task.id, 0) |> json_response(404) == %{"error" => "Not Found"}

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> ctx.phone)
             |> get("/api/me/reviews/#{task.id}")
             |> json_response(404)
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
