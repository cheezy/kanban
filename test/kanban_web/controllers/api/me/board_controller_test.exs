defmodule KanbanWeb.API.Me.BoardControllerTest do
  @moduledoc """
  Tests for `GET /api/me/boards`, `GET /api/me/boards/:id/columns/:name` and
  `POST /api/me/boards/:id/promote` (`KanbanWeb.API.Me.BoardController`),
  W2759.
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
  @forbidden %{"error" => "Forbidden", "message" => "This needs write access to the board."}

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

  defp promote(token, board_id, body) do
    token
    |> authed()
    |> put_req_header("content-type", "application/json")
    |> post("/api/me/boards/#{board_id}/promote", Jason.encode!(body))
  end

  defp label!(task, label),
    do: Repo.insert!(%Kanban.Labels.TaskLabel{task_id: task.id, label_id: label.id})

  defp column_ids(column) do
    column |> Tasks.list_tasks() |> Enum.map(&{&1.id, &1.position})
  end

  defp into_org_workspace!(user, board) do
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, user)
    board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
    workspace
  end

  describe "GET /api/me/boards" do
    test "lists boards with column counts and workspace", ctx do
      for _ <- 1..2, do: task_fixture(ctx.cols["Backlog"])
      task_fixture(ctx.cols["Review"])
      workspace = into_org_workspace!(ctx.user, ctx.board)

      owner = user_fixture()
      shared = ai_optimized_board_fixture(owner)
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, owner)

      assert %{"data" => boards} = ctx.phone |> api_get("/api/me/boards") |> json_response(200)
      by_id = Map.new(boards, &{&1["id"], &1})

      assert by_id[ctx.board.id] == %{
               "id" => ctx.board.id,
               "name" => ctx.board.name,
               "access" => "owner",
               "group" => "workspace",
               "workspace" => %{
                 "id" => workspace.id,
                 "name" => workspace.name,
                 "slug" => workspace.slug
               },
               "counts" => %{
                 "backlog" => 2,
                 "ready" => 0,
                 "doing" => 0,
                 "review" => 1,
                 "done" => 0
               },
               "idle_agents" => 0
             }

      assert %{"group" => "shared", "workspace" => nil, "access" => "read_only"} =
               by_id[shared.id]
    end

    test "answers no-store", ctx do
      conn = api_get(ctx.phone, "/api/me/boards")
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  describe "GET /api/me/boards/:id/columns/:name" do
    test "column read pages at 100 by position", ctx do
      tasks = for _ <- 1..101, do: task_fixture(ctx.cols["Backlog"])
      task_fixture(ctx.cols["Backlog"], %{type: :goal})

      path = "/api/me/boards/#{ctx.board.id}/columns/backlog"
      page1 = ctx.phone |> api_get(path) |> json_response(200) |> Map.fetch!("data")

      assert page1["column"] == %{"id" => ctx.cols["Backlog"].id, "name" => "Backlog"}
      assert page1["board_id"] == ctx.board.id
      assert %{"page" => 1, "per_page" => 100, "total" => 101, "next_page" => 2} = page1
      assert Enum.map(page1["tasks"], & &1["id"]) == tasks |> Enum.take(100) |> Enum.map(& &1.id)

      page2 = ctx.phone |> api_get(path <> "?page=2") |> json_response(200) |> Map.fetch!("data")
      assert Enum.map(page2["tasks"], & &1["id"]) == [List.last(tasks).id]
      assert page2["next_page"] == nil

      for bad <- ["0", "x", "10001", "1.5"] do
        assert %{"error" => "Bad Request"} =
                 ctx.phone |> api_get(path <> "?page=" <> bad) |> json_response(400)
      end
    end

    test "a card carries the §6.9 fields as counts", ctx do
      label = Kanban.LabelsFixtures.label_fixture(ctx.board, %{name: "zeta", color: :blue})
      first = Kanban.LabelsFixtures.label_fixture(ctx.board, %{name: "Alpha", color: :red})

      task =
        ctx.cols["Backlog"]
        |> task_fixture(%{
          acceptance_criteria: "One\n\n  \nTwo\nThree",
          security_considerations: ["a", "b"],
          priority: :high
        })

      label!(task, label)
      label!(task, first)

      assert %{"data" => %{"tasks" => [card]}} =
               ctx.phone
               |> api_get("/api/me/boards/#{ctx.board.id}/columns/Backlog")
               |> json_response(200)

      assert card["identifier"] == task.identifier
      assert card["priority"] == "high"
      assert card["label"] == %{"id" => first.id, "name" => "Alpha", "color" => "red"}
      assert card["criteria_count"] == 3
      assert card["security_considerations_count"] == 2
      refute Map.has_key?(card, "acceptance_criteria")
    end

    test "an unknown column, a foreign board or a bad id answers 404", ctx do
      other = ai_optimized_board_fixture(user_fixture())

      for path <- [
            "/api/me/boards/#{ctx.board.id}/columns/Nope",
            "/api/me/boards/#{ctx.board.id}/columns/Backlog%27%20OR%201%3D1",
            "/api/me/boards/#{other.id}/columns/Backlog",
            "/api/me/boards/abc/columns/Backlog",
            "/api/me/boards/99999999999999999999/columns/Backlog"
          ] do
        assert ctx.phone |> api_get(path) |> json_response(404) == %{"error" => "Not Found"},
               "expected 404 for #{path}"
      end
    end
  end

  describe "POST /api/me/boards/:id/promote" do
    test "promote sets needs_review when asked", ctx do
      [a, b] = for _ <- 1..2, do: task_fixture(ctx.cols["Backlog"])
      c = task_fixture(ctx.cols["Backlog"])
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      body =
        ctx.phone
        |> promote(ctx.board.id, %{task_ids: [b.id, a.id], needs_review: true})
        |> json_response(200)

      assert %{"data" => %{"promoted" => promoted, "already_ready" => []}} = body
      assert Enum.map(promoted, &{&1["id"], &1["needs_review"]}) == [{a.id, true}, {b.id, true}]
      assert column_ids(ctx.cols["Ready"]) == [{a.id, 0}, {b.id, 1}]

      # The web board hears each move, as it does for a drag.
      for task <- [a, b] do
        task_id = task.id
        assert_receive {Kanban.Tasks, :task_moved, %{id: ^task_id}}
      end

      # Without needs_review the flag is left alone.
      assert %{"data" => %{"promoted" => [%{"needs_review" => false}]}} =
               ctx.phone |> promote(ctx.board.id, %{task_ids: [c.id]}) |> json_response(200)
    end

    test "only task_ids and needs_review are read from the body", ctx do
      task = task_fixture(ctx.cols["Backlog"])

      assert ctx.phone
             |> promote(ctx.board.id, %{
               task_ids: [task.id],
               title: "Changed",
               priority: "critical"
             })
             |> json_response(200)

      reloaded = Repo.reload!(task)
      assert reloaded.title == task.title
      assert reloaded.priority == task.priority
    end

    test "a read-only member gets 403 on promote", ctx do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.user)
      {_device, tokens} = device_with_tokens_fixture(user_scope_fixture(reader))
      task = task_fixture(ctx.cols["Backlog"])

      assert tokens.access_token
             |> promote(ctx.board.id, %{task_ids: [task.id]})
             |> json_response(403) ==
               @forbidden

      # Refused before the body is read.
      assert tokens.access_token |> promote(ctx.board.id, %{task_ids: []}) |> json_response(403) ==
               @forbidden

      assert Repo.reload!(task).column_id == ctx.cols["Backlog"].id
    end

    test "an empty task list answers 422", ctx do
      for body <- [%{task_ids: []}, %{}, %{needs_review: true}] do
        assert ctx.phone |> promote(ctx.board.id, body) |> json_response(422) == %{
                 "errors" => %{"task_ids" => ["can't be blank"]}
               }
      end

      assert %{"errors" => %{"task_ids" => ["should have at most 100 item(s)"]}} =
               ctx.phone
               |> promote(ctx.board.id, %{task_ids: Enum.to_list(1..101)})
               |> json_response(422)

      for bad <- [["x"], [0], [-3]] do
        assert %{"errors" => %{"task_ids" => ["is invalid"]}} =
                 ctx.phone |> promote(ctx.board.id, %{task_ids: bad}) |> json_response(422)
      end

      assert %{"errors" => %{"needs_review" => ["is invalid"]}} =
               ctx.phone
               |> promote(ctx.board.id, %{task_ids: [1], needs_review: "maybe"})
               |> json_response(422)
    end

    test "a task from another board, or archived, answers 404 and moves nothing", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      other = ai_optimized_board_fixture(ctx.user)
      foreign = other |> columns() |> Map.fetch!("Backlog") |> task_fixture()
      {:ok, archived} = ctx.cols["Backlog"] |> task_fixture() |> Tasks.archive_task()

      for bad <- [foreign.id, archived.id] do
        assert ctx.phone
               |> promote(ctx.board.id, %{task_ids: [task.id, bad]})
               |> json_response(404) == %{"error" => "Not Found"}
      end

      assert column_ids(ctx.cols["Ready"]) == []
    end

    test "a goal or a task outside Backlog answers 422 not_promotable", ctx do
      doing = task_fixture(ctx.cols["Doing"])

      assert ctx.phone |> promote(ctx.board.id, %{task_ids: [doing.id]}) |> json_response(422) ==
               %{
                 "error" => "not_promotable",
                 "message" => "Only work and defect tasks in Backlog can be promoted to Ready.",
                 "task_ids" => [doing.id]
               }

      # A goal refuses wherever it sits, Ready included, and nothing moves.
      backlog = task_fixture(ctx.cols["Backlog"])

      for column <- ["Backlog", "Ready"] do
        goal = task_fixture(ctx.cols[column], %{type: :goal})

        assert %{"error" => "not_promotable", "task_ids" => [goal_id]} =
                 ctx.phone
                 |> promote(ctx.board.id, %{task_ids: [backlog.id, goal.id]})
                 |> json_response(422)

        assert goal_id == goal.id
        assert Kanban.Repo.reload!(backlog).column_id == ctx.cols["Backlog"].id
      end
    end

    test "two promotes of the same task leave one Ready task in order", ctx do
      existing = task_fixture(ctx.cols["Ready"])
      task = task_fixture(ctx.cols["Backlog"])

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            ctx.phone |> promote(ctx.board.id, %{task_ids: [task.id]}) |> json_response(200)
          end)
        end)
        |> Task.await_many(30_000)
        |> Enum.map(& &1["data"])

      assert results |> Enum.map(&length(&1["promoted"])) |> Enum.sort() == [0, 1]
      assert results |> Enum.flat_map(& &1["already_ready"]) == [task.id]
      assert column_ids(ctx.cols["Ready"]) == [{existing.id, 0}, {task.id, 1}]
    end

    test "a foreign board or a bad id answers 404", ctx do
      other = ai_optimized_board_fixture(user_fixture())

      for id <- [other.id, "abc", 0] do
        assert ctx.phone |> promote(id, %{task_ids: [1]}) |> json_response(404) == %{
                 "error" => "Not Found"
               }
      end
    end
  end

  describe "plans" do
    test "board outside the plan answers plan_required", ctx do
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      task = task_fixture(ctx.cols["Backlog"])
      enforce_plans()

      assert ctx.phone
             |> api_get("/api/me/boards/#{ctx.board.id}/columns/Backlog")
             |> json_response(403) == @plan_required

      assert ctx.phone |> promote(ctx.board.id, %{task_ids: [task.id]}) |> json_response(403) ==
               @plan_required

      # The list leaves the locked board out.
      assert %{"data" => []} = ctx.phone |> api_get("/api/me/boards") |> json_response(200)
      assert Repo.reload!(task).column_id == ctx.cols["Backlog"].id
    end

    test "a person outside an Organization is refused before any lookup", ctx do
      enforce_plans()

      for conn <- [
            api_get(ctx.phone, "/api/me/boards"),
            api_get(ctx.phone, "/api/me/boards/123456/columns/Backlog"),
            promote(ctx.phone, 123_456, %{task_ids: []})
          ] do
        assert json_response(conn, 403) == @plan_required
      end
    end

    test "under enforcement, a board in the person's Organization is served", ctx do
      into_org_workspace!(ctx.user, ctx.board)
      task = task_fixture(ctx.cols["Backlog"])
      enforce_plans()

      assert %{"data" => [%{"id" => id}]} =
               ctx.phone |> api_get("/api/me/boards") |> json_response(200)

      assert id == ctx.board.id

      assert ctx.phone |> promote(ctx.board.id, %{task_ids: [task.id]}) |> json_response(200)
    end
  end

  describe "authentication" do
    test "an agent API token and no token are refused", ctx do
      {:ok, {_api_token, plain}} =
        ApiTokens.create_api_token(ctx.user, ctx.board, %{name: "Agent"})

      for token <- [plain, "made-up"] do
        assert token |> api_get("/api/me/boards") |> json_response(401)
      end

      assert build_conn() |> get("/api/me/boards") |> json_response(401)
    end
  end

  describe "contract" do
    test "matches the documented schemas", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      label = Kanban.LabelsFixtures.label_fixture(ctx.board, %{name: "mobile"})
      label!(task, label)
      task_fixture(ctx.cols["Backlog"])

      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      boards = ctx.phone |> api_get("/api/me/boards") |> json_response(200)
      assert_schema(spec, boards, "MeBoardListResponse")

      for board <- boards["data"] do
        assert_schema(spec, board, "MeBoard")
        assert_schema(spec, board["counts"], "MeBoardCounts")
        if board["workspace"], do: assert_schema(spec, board["workspace"], "MeWorkspace")
      end

      page =
        ctx.phone
        |> api_get("/api/me/boards/#{ctx.board.id}/columns/Backlog")
        |> json_response(200)

      assert_schema(spec, page, "MeColumnPageResponse")
      assert_schema(spec, page["data"], "MeColumnPage")
      assert_schema(spec, page["data"]["column"], "MeColumnRef")

      cards = page["data"]["tasks"]
      assert length(cards) == 2
      for card <- cards, do: assert_schema(spec, card, "MeTaskCard")
      assert_schema(spec, hd(cards)["label"], "MeCardLabel")

      promoted =
        ctx.phone |> promote(ctx.board.id, %{task_ids: [task.id]}) |> json_response(200)

      assert_schema(spec, promoted, "MePromoteResponse")
      assert_schema(spec, promoted["data"], "MePromoteResult")
      for card <- promoted["data"]["promoted"], do: assert_schema(spec, card, "MeTaskCard")

      refusal =
        ctx.phone
        |> promote(ctx.board.id, %{task_ids: [List.last(cards)["id"], task.id]})
        |> json_response(200)

      assert refusal["data"]["already_ready"] == [task.id]
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
