defmodule KanbanWeb.API.Me.TaskControllerTest do
  @moduledoc """
  Tests for `GET /api/me/tasks/:id`, `POST /api/me/tasks/:id/comments`,
  `POST /api/me/tasks/:id/move_to_backlog` and `POST /api/me/tasks`
  (`KanbanWeb.API.Me.TaskController`), W2760.
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
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @plan_required %{
    "error" => "plan_required",
    "feature" => "mobile_app",
    "message" => "The Stride app is available to boards in an Organization."
  }
  @forbidden %{"error" => "Forbidden", "message" => "This needs write access to the board."}
  @not_found %{"error" => "Not Found"}
  @locales ~w(de en es fr ja pt zh)

  setup do
    user = user_fixture(%{name: "Sam Rivera"})
    scope = user_scope_fixture(user)
    {_phone, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})
    board = ai_optimized_board_fixture(user)

    %{user: user, scope: scope, board: board, cols: columns(board), phone: phone.access_token}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp api_get(token, path), do: token |> authed() |> get(path)

  defp post_json(token, path, body) do
    token
    |> authed()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp comment(token, task_id, body),
    do: post_json(token, "/api/me/tasks/#{task_id}/comments", body)

  defp move(token, task_id), do: post_json(token, "/api/me/tasks/#{task_id}/move_to_backlog", %{})
  defp capture(token, body), do: post_json(token, "/api/me/tasks", body)

  defp add_comments!(scope, task, count) do
    for n <- 1..count do
      {:ok, comment} = Tasks.create_comment(scope, task, %{"content" => "comment #{n}"})
      comment
    end
  end

  defp member_token(board, owner, access, attrs \\ %{}) do
    member = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, member, access, owner)
    {_device, tokens} = device_with_tokens_fixture(user_scope_fixture(member), attrs)
    {member, tokens.access_token}
  end

  defp token_with_locale(scope, locale) do
    {_device, tokens} = device_with_tokens_fixture(scope, %{locale: locale})
    tokens.access_token
  end

  defp translated(locale, error) do
    Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
      KanbanWeb.CoreComponents.translate_error(error)
    end)
  end

  defp into_org_workspace!(user, board) do
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, user)
    board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
    workspace
  end

  defp capture_body(board, attrs \\ %{}) do
    Map.merge(%{"board_id" => board.id, "type" => "work", "title" => "Captured"}, attrs)
  end

  describe "GET /api/me/tasks/:id" do
    test "shows a task with its last 20 comments", ctx do
      task =
        task_fixture(ctx.cols["Ready"], %{
          description: "Why it matters",
          acceptance_criteria: "One\nTwo",
          security_considerations: ["Never log the token"],
          key_files: [%{file_path: "lib/a.ex", note: "Edit", position: 0}]
        })

      comments = add_comments!(ctx.scope, task, 21)

      assert %{"data" => data} =
               ctx.phone |> api_get("/api/me/tasks/#{task.id}") |> json_response(200)

      assert data["id"] == task.id
      assert data["identifier"] == task.identifier
      assert data["title"] == task.title
      assert data["type"] == "work"
      assert data["board_id"] == ctx.board.id
      assert data["column"] == %{"id" => ctx.cols["Ready"].id, "name" => "Ready"}
      assert data["description"] == "Why it matters"
      assert data["acceptance_criteria"] == "One\nTwo"
      assert data["security_considerations"] == ["Never log the token"]

      assert data["key_files"] == [
               %{"file_path" => "lib/a.ex", "note" => "Edit", "position" => 0}
             ]

      assert data["created_via"] == nil
      assert data["archived_at"] == nil

      # 21 comments: the last 20, oldest first, the first one left out.
      assert data["has_more_comments"] == true

      assert Enum.map(data["comments"], & &1["id"]) ==
               comments |> Enum.drop(1) |> Enum.map(& &1.id)

      assert %{"content" => "comment 2", "author_name" => "Sam Rivera"} = hd(data["comments"])

      # Exactly 20 comments: all of them, and nothing more.
      other = task_fixture(ctx.cols["Ready"])
      add_comments!(ctx.scope, other, 20)

      assert %{"data" => %{"comments" => twenty, "has_more_comments" => false}} =
               ctx.phone |> api_get("/api/me/tasks/#{other.id}") |> json_response(200)

      assert length(twenty) == 20
    end

    test "a read-only member reads the task, and an archived task shows archived_at", ctx do
      task = task_fixture(ctx.cols["Ready"])
      {:ok, archived} = Tasks.archive_task(task)
      {_reader, token} = member_token(ctx.board, ctx.user, :read_only)

      assert %{"data" => %{"archived_at" => archived_at}} =
               token |> api_get("/api/me/tasks/#{archived.id}") |> json_response(200)

      assert archived_at
    end

    test "answers no-store", ctx do
      task = task_fixture(ctx.cols["Ready"])
      conn = api_get(ctx.phone, "/api/me/tasks/#{task.id}")
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  describe "a task on an unseen board answers 404" do
    test "on every task route, for a foreign, missing or malformed id", ctx do
      owner = user_fixture()
      foreign_board = ai_optimized_board_fixture(owner)
      foreign = task_fixture(columns(foreign_board)["Ready"])

      for id <- [foreign.id, 9_999_999_999, "abc", "0", "99999999999999999999"] do
        assert ctx.phone |> api_get("/api/me/tasks/#{id}") |> json_response(404) == @not_found
        assert ctx.phone |> comment(id, %{content: "hi"}) |> json_response(404) == @not_found
        assert ctx.phone |> move(id) |> json_response(404) == @not_found
      end

      assert Tasks.list_comments(foreign) == []
      assert Repo.reload!(foreign).column_id == columns(foreign_board)["Ready"].id
    end

    test "a public board the person is not a member of is not theirs", ctx do
      owner = user_fixture()
      public = ai_optimized_board_fixture(owner)
      public |> Ecto.Changeset.change(read_only: true) |> Repo.update!()
      task = task_fixture(columns(public)["Ready"])

      assert ctx.phone |> api_get("/api/me/tasks/#{task.id}") |> json_response(404) == @not_found

      assert ctx.phone |> capture(capture_body(public)) |> json_response(404) == @not_found
    end

    test "a missing id and a task on an unseen board run the same queries on every route", ctx do
      foreign = task_fixture(columns(ai_optimized_board_fixture(user_fixture()))["Ready"])
      missing = foreign.id + 1_000_000
      seen = task_fixture(ctx.cols["Ready"])

      requests = [
        &api_get(ctx.phone, "/api/me/tasks/#{&1}"),
        &comment(ctx.phone, &1, %{content: "hi"}),
        &move(ctx.phone, &1)
      ]

      # A first request warms the token's last-used write, which would
      # otherwise run once on whichever request comes first.
      api_get(ctx.phone, "/api/me/tasks/#{seen.id}")

      for request <- requests do
        {missing_conn, missing_sql} = sql_of(fn -> request.(missing) end)
        {foreign_conn, foreign_sql} = sql_of(fn -> request.(foreign.id) end)
        {_seen_conn, seen_sql} = sql_of(fn -> request.(seen.id) end)

        assert json_response(missing_conn, 404) == @not_found
        assert missing_conn.resp_body == foreign_conn.resp_body
        # The same queries, so the same count, in the same order.
        assert foreign_sql == missing_sql

        # Non-vacuous: a task the person can see does go on to more reads.
        assert length(seen_sql) > length(missing_sql)
      end
    end

    test "capture into a board the person cannot see answers 404", ctx do
      foreign_board = ai_optimized_board_fixture(user_fixture())

      for board_id <- [foreign_board.id, 9_999_999_999] do
        assert ctx.phone
               |> capture(%{"board_id" => board_id, "type" => "work", "title" => "x"})
               |> json_response(404) == @not_found
      end

      refute Repo.get_by(Task, title: "x")
    end
  end

  describe "POST /api/me/tasks/:id/comments" do
    test "comments on a task the person can see", ctx do
      task = task_fixture(ctx.cols["Ready"])

      conn =
        comment(ctx.phone, task.id, %{
          "content" => "Keep the old column",
          "task_id" => 1,
          "author_user_id" => 1,
          "author_agent_name" => "Forged"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      assert %{
               "task_id" => task_id,
               "content" => "Keep the old column",
               "author_name" => "Sam Rivera",
               "author_agent_name" => nil
             } = data

      assert task_id == task.id

      # Stored as the web stores it: by the person, with the text as sent.
      assert [stored] = Tasks.list_comments(task)
      assert stored.id == data["id"]
      assert stored.content == "Keep the old column"
      assert stored.author_user_id == ctx.user.id
      assert stored.author_agent_name == nil
    end

    test "a read-only member may comment, as on the web", ctx do
      task = task_fixture(ctx.cols["Ready"])
      {reader, token} = member_token(ctx.board, ctx.user, :read_only)

      assert %{"data" => %{"content" => "Me too"}} =
               token |> comment(task.id, %{content: "Me too"}) |> json_response(201)

      assert [%{author_user_id: author}] = Tasks.list_comments(task)
      assert author == reader.id
    end

    test "a blank comment answers 422", ctx do
      task = task_fixture(ctx.cols["Ready"])
      blank = %{"errors" => %{"content" => ["can't be blank"]}}

      for body <- [%{content: ""}, %{content: "   "}, %{content: "​"}, %{}] do
        assert ctx.phone |> comment(task.id, body) |> json_response(422) == blank
      end

      assert %{"errors" => %{"content" => ["should be at most 10000 character(s)"]}} =
               ctx.phone
               |> comment(task.id, %{content: String.duplicate("a", 10_001)})
               |> json_response(422)

      assert %{"errors" => %{"content" => ["is invalid"]}} =
               ctx.phone |> comment(task.id, %{content: 42}) |> json_response(422)

      assert Tasks.list_comments(task) == []
    end

    test "Pull the Rug: a task deleted before the comment answers 404", ctx do
      task = task_fixture(ctx.cols["Ready"])
      {:ok, _} = Tasks.delete_task(task)

      assert ctx.phone |> comment(task.id, %{content: "Too late"}) |> json_response(404) ==
               @not_found
    end

    test "Pull the Rug: a task deleted, or the person removed, after the lookup answers 404",
         ctx do
      gone = task_fixture(ctx.cols["Ready"])

      conn =
        pull_the_rug(
          fn -> {:ok, _} = Tasks.delete_task(gone) end,
          fn -> comment(ctx.phone, gone.id, %{content: "Too late"}) end
        )

      assert json_response(conn, 404) == @not_found
      refute Repo.get(Task, gone.id)

      # The comment policy refuses a person removed in between; that is a 404
      # too, never a 403 that says the task is there.
      {member, token} = member_token(ctx.board, ctx.user, :modify)
      kept = task_fixture(ctx.cols["Ready"])

      conn =
        pull_the_rug(
          fn ->
            BoardUser
            |> Repo.get_by!(board_id: ctx.board.id, user_id: member.id)
            |> Repo.delete!()
          end,
          fn -> comment(token, kept.id, %{content: "Too late"}) end
        )

      assert json_response(conn, 404) == @not_found
      assert Tasks.list_comments(kept) == []
    end

    test "a mention's push and notification never carry the comment text", ctx do
      task = task_fixture(ctx.cols["Ready"])
      member = user_fixture(%{name: "Riley"})
      {:ok, _} = Boards.add_user_to_board(ctx.board, member, :modify, ctx.user)

      secret = "the vendor contract number"

      assert %{"data" => %{"mentioned_user_ids" => [mentioned]}} =
               ctx.phone
               |> comment(task.id, %{content: "@[Riley](user:#{member.id}) #{secret}"})
               |> json_response(201)

      assert mentioned == member.id

      notifications = Repo.all(Kanban.Notifications.Notification)
      assert Enum.any?(notifications, &(&1.user_id == member.id and &1.event_type == :mentioned))

      for notification <- notifications do
        refute inspect(notification) =~ secret
      end

      jobs = Repo.all(Oban.Job)
      assert jobs != []

      for job <- jobs do
        refute inspect(job.args) =~ secret
      end
    end
  end

  describe "POST /api/me/tasks/:id/move_to_backlog" do
    test "moves a released task to Backlog", ctx do
      in_backlog = task_fixture(ctx.cols["Backlog"])
      task = task_fixture(ctx.cols["Ready"])
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      conn = move(ctx.phone, task.id)

      assert %{"data" => %{"moved" => true, "task" => card}} = json_response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert card["id"] == task.id
      assert card["status"] == "open"

      moved = Repo.reload!(task)
      assert moved.column_id == ctx.cols["Backlog"].id
      assert moved.position > Repo.reload!(in_backlog).position
      assert card["position"] == moved.position

      assert Repo.get_by(TaskHistory,
               task_id: task.id,
               type: :move,
               from_column: "Ready",
               to_column: "Backlog"
             )

      assert_receive {Kanban.Tasks, :task_moved, %Task{id: task_id}}
      assert task_id == task.id

      # A retry moves nothing.
      assert %{"data" => %{"moved" => false, "task" => %{"id" => ^task_id}}} =
               ctx.phone |> move(task.id) |> json_response(200)

      assert Repo.reload!(task).position == moved.position
    end

    test "a task released by an agent's unclaim moves back", ctx do
      task = task_fixture(ctx.cols["Ready"])
      {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.user, ctx.board.id, task.identifier)
      assert claimed.column_id == ctx.cols["Doing"].id
      {:ok, released} = Tasks.unclaim_task(claimed, ctx.user, "Needs a decision")
      assert released.column_id == ctx.cols["Ready"].id

      assert %{"data" => %{"moved" => true}} =
               ctx.phone |> move(task.id) |> json_response(200)

      assert Repo.reload!(task).column_id == ctx.cols["Backlog"].id
    end

    test "an expired claim moves back from Doing and is cleared; a live one stays", ctx do
      task = task_fixture(ctx.cols["Ready"])
      {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.user, ctx.board.id, task.identifier)

      # A live claim is not the phone's to move.
      assert %{"error" => "not_movable"} = ctx.phone |> move(task.id) |> json_response(422)
      assert Repo.reload!(task).column_id == ctx.cols["Doing"].id

      claimed
      |> Ecto.Changeset.change(claim_expires_at: DateTime.utc_now(:second) |> DateTime.add(-60))
      |> Repo.update!()

      assert %{"data" => %{"moved" => true, "task" => %{"status" => "open"}}} =
               ctx.phone |> move(task.id) |> json_response(200)

      assert %Task{
               status: :open,
               claimed_at: nil,
               claim_expires_at: nil,
               assigned_to_id: nil
             } = moved = Repo.reload!(task)

      assert moved.column_id == ctx.cols["Backlog"].id

      assert Repo.get_by(TaskHistory, task_id: task.id, type: :move, from_column: "Doing")
    end

    test "refuses a task outside Ready, a goal and an archived task", ctx do
      doing = task_fixture(ctx.cols["Doing"])
      goal = task_fixture(ctx.cols["Ready"], %{type: :goal})
      archived = task_fixture(ctx.cols["Ready"])
      {:ok, _} = Tasks.archive_task(archived)

      not_movable = %{
        "error" => "not_movable",
        "message" =>
          "Only work and defect tasks in Ready, or in Doing with an expired claim, can be moved to Backlog."
      }

      assert ctx.phone |> move(doing.id) |> json_response(422) == not_movable
      assert ctx.phone |> move(goal.id) |> json_response(422) == not_movable
      assert ctx.phone |> move(archived.id) |> json_response(404) == @not_found

      assert Repo.reload!(doing).column_id == ctx.cols["Doing"].id
      assert Repo.reload!(goal).column_id == ctx.cols["Ready"].id
    end

    test "a read-only member is refused with 403 Forbidden", ctx do
      task = task_fixture(ctx.cols["Ready"])
      {_reader, token} = member_token(ctx.board, ctx.user, :read_only)

      assert token |> move(task.id) |> json_response(403) == @forbidden
      assert Repo.reload!(task).column_id == ctx.cols["Ready"].id
    end

    test "Backlog's WIP limit and a missing Backlog column refuse the move", ctx do
      task = task_fixture(ctx.cols["Ready"])
      task_fixture(ctx.cols["Backlog"])
      ctx.cols["Backlog"] |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()

      assert ctx.phone |> move(task.id) |> json_response(422) == %{
               "error" => "wip_limit_reached",
               "message" => "Backlog has no room for this task under its WIP limit."
             }

      ctx.cols["Backlog"] |> Ecto.Changeset.change(name: "Ideas", wip_limit: 0) |> Repo.update!()

      assert ctx.phone |> move(task.id) |> json_response(422) == %{
               "error" => "no_backlog_column",
               "message" => "This board has no Backlog column."
             }

      assert Repo.reload!(task).column_id == ctx.cols["Ready"].id
    end
  end

  describe "POST /api/me/tasks" do
    test "captures a work task into Backlog with created_via mobile", ctx do
      task_fixture(ctx.cols["Backlog"])
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      conn =
        capture(ctx.phone, capture_body(ctx.board, %{"description" => "One sentence about it."}))

      assert %{"data" => data} = json_response(conn, 201)
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      assert %{
               "title" => "Captured",
               "type" => "work",
               "status" => "open",
               "created_via" => "mobile",
               "description" => "One sentence about it.",
               "comments" => [],
               "has_more_comments" => false
             } = data

      assert data["column"] == %{"id" => ctx.cols["Backlog"].id, "name" => "Backlog"}

      task = Repo.get!(Task, data["id"])
      assert task.created_via == :mobile
      assert task.created_by_id == ctx.user.id
      assert task.column_id == ctx.cols["Backlog"].id
      assert task.identifier == data["identifier"]
      assert task.position == 1

      assert_receive {Kanban.Tasks, :task_created, %Task{id: created_id}}
      assert created_id == task.id
    end

    test "captures a defect, and ignores every field the app form does not have", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      other = user_fixture()

      body =
        capture_body(ctx.board, %{
          "type" => "defect",
          "parent_id" => goal.id,
          "identifier" => "W1",
          "status" => "completed",
          "column_id" => ctx.cols["Ready"].id,
          "assigned_to_id" => other.id,
          "created_via" => "web",
          "needs_review" => true,
          "position" => 0,
          "created_by_id" => other.id
        })

      assert %{"data" => %{"id" => id, "type" => "defect"}} =
               ctx.phone |> capture(body) |> json_response(201)

      task = Repo.get!(Task, id)
      assert task.parent_id == nil
      assert task.identifier != "W1"
      assert task.status == :open
      assert task.column_id == ctx.cols["Backlog"].id
      assert task.assigned_to_id == nil
      assert task.created_via == :mobile
      assert task.needs_review == false
      assert task.created_by_id == ctx.user.id
    end

    test "refuses type goal on capture", ctx do
      assert ctx.phone
             |> capture(capture_body(ctx.board, %{"type" => "goal"}))
             |> json_response(422) == %{"errors" => %{"type" => ["is invalid"]}}

      refute Repo.get_by(Task, title: "Captured")
    end

    test "refuses a body without board_id, type or title", ctx do
      assert %{"errors" => errors} =
               ctx.phone |> capture(%{"description" => "x"}) |> json_response(422)

      assert errors == %{
               "board_id" => ["can't be blank"],
               "type" => ["can't be blank"],
               "title" => ["can't be blank"]
             }

      assert %{"errors" => %{"board_id" => ["is invalid"]}} =
               ctx.phone
               |> capture(capture_body(ctx.board, %{"board_id" => "x"}))
               |> json_response(422)
    end

    test "a title at the 255 limit is captured and one over it is refused", ctx do
      at_limit = String.duplicate("t", 255)

      assert %{"data" => %{"title" => ^at_limit}} =
               ctx.phone
               |> capture(capture_body(ctx.board, %{"title" => at_limit}))
               |> json_response(201)

      assert %{"errors" => %{"title" => ["should be at most 255 character(s)"]}} =
               ctx.phone
               |> capture(capture_body(ctx.board, %{"title" => at_limit <> "t"}))
               |> json_response(422)
    end

    test "a read-only member is refused with 403 Forbidden", ctx do
      {_reader, token} = member_token(ctx.board, ctx.user, :read_only)

      assert token |> capture(capture_body(ctx.board)) |> json_response(403) == @forbidden
      refute Repo.get_by(Task, title: "Captured")
    end

    test "Backlog's WIP limit and a missing Backlog column refuse the capture", ctx do
      task_fixture(ctx.cols["Backlog"])
      ctx.cols["Backlog"] |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()

      assert %{"error" => "wip_limit_reached"} =
               ctx.phone |> capture(capture_body(ctx.board)) |> json_response(422)

      ctx.cols["Backlog"] |> Ecto.Changeset.change(name: "Ideas", wip_limit: 0) |> Repo.update!()

      assert %{"error" => "no_backlog_column"} =
               ctx.phone |> capture(capture_body(ctx.board)) |> json_response(422)

      refute Repo.get_by(Task, title: "Captured")
    end
  end

  describe "Every Locale" do
    test "validation errors come back in the device's locale", ctx do
      task = task_fixture(ctx.cols["Ready"])

      # Non-vacuous: German really is translated.
      assert translated("de", {"can't be blank", [validation: :required]}) ==
               "darf nicht leer sein"

      for locale <- @locales do
        token = token_with_locale(ctx.scope, locale <> "-XX")
        blank = translated(locale, {"can't be blank", [validation: :required]})

        assert token |> comment(task.id, %{content: ""}) |> json_response(422) ==
                 %{"errors" => %{"content" => [blank]}},
               locale

        assert token
               |> capture(capture_body(ctx.board, %{"title" => ""}))
               |> json_response(422) == %{"errors" => %{"title" => [blank]}},
               locale

        invalid = translated(locale, {"is invalid", [validation: :inclusion]})

        assert token
               |> capture(capture_body(ctx.board, %{"type" => "goal"}))
               |> json_response(422) == %{"errors" => %{"type" => [invalid]}},
               locale

        too_long =
          translated(locale, {"should be at most %{count} character(s)", [count: 255]})

        assert token
               |> capture(capture_body(ctx.board, %{"title" => String.duplicate("t", 256)}))
               |> json_response(422) == %{"errors" => %{"title" => [too_long]}},
               locale
      end
    end

    test "an unknown language falls back to English", ctx do
      task = task_fixture(ctx.cols["Ready"])
      token = token_with_locale(ctx.scope, "ko-KR")

      assert token |> comment(task.id, %{content: ""}) |> json_response(422) ==
               %{"errors" => %{"content" => ["can't be blank"]}}
    end
  end

  describe "first action on a decision" do
    setup do
      attach_telemetry([:kanban, :decision, :acted_on])
      :ok
    end

    defp released_task!(ctx) do
      task = task_fixture(ctx.cols["Ready"])
      {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.user, ctx.board.id, task.identifier)
      {:ok, released} = Tasks.unclaim_task(claimed, ctx.user, "Needs a decision")
      released
    end

    test "a reply on a released task emits acted_on via the device's platform", ctx do
      task = released_task!(ctx)

      assert ctx.phone |> comment(task.id, %{content: "On it"}) |> json_response(201)

      assert_receive {:telemetry_event, [:kanban, :decision, :acted_on], %{count: 1},
                      %{kind: :released, action: :reply, via: :ios, task_id: task_id}}

      assert task_id == task.id

      assert ctx.phone |> comment(task.id, %{content: "Again"}) |> json_response(201)
      refute_receive {:telemetry_event, [:kanban, :decision, :acted_on], _, _}
    end

    test "a move to Backlog of a released task emits acted_on with action move", ctx do
      task = released_task!(ctx)

      assert %{"data" => %{"moved" => true}} =
               ctx.phone |> move(task.id) |> json_response(200)

      assert_receive {:telemetry_event, [:kanban, :decision, :acted_on], _,
                      %{kind: :released, action: :move, via: :ios}}
    end

    test "a reply on a task that is no decision emits nothing", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      # A decision on the same board that the reply does not touch.
      released = released_task!(ctx)

      assert ctx.phone |> comment(task.id, %{content: "Hello"}) |> json_response(201)
      refute_receive {:telemetry_event, [:kanban, :decision, :acted_on], _, _}
      assert Repo.aggregate(Kanban.Decisions.DecisionAction, :count) == 0

      # The same route on the decision itself does count, via the phone.
      assert ctx.phone |> comment(released.id, %{content: "On it"}) |> json_response(201)

      assert_receive {:telemetry_event, [:kanban, :decision, :acted_on], _,
                      %{kind: :released, action: :reply, via: :ios, task_id: task_id}}

      assert task_id == released.id
    end
  end

  describe "plans" do
    test "board outside the plan answers plan_required", ctx do
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      task = task_fixture(ctx.cols["Ready"])
      enforce_plans()

      for conn <- [
            api_get(ctx.phone, "/api/me/tasks/#{task.id}"),
            comment(ctx.phone, task.id, %{content: "hi"}),
            move(ctx.phone, task.id),
            capture(ctx.phone, capture_body(ctx.board))
          ] do
        assert json_response(conn, 403) == @plan_required
      end

      assert Tasks.list_comments(task) == []
      assert Repo.reload!(task).column_id == ctx.cols["Ready"].id
    end

    test "a person outside an Organization is refused before any lookup", ctx do
      enforce_plans()

      for conn <- [
            api_get(ctx.phone, "/api/me/tasks/123456"),
            comment(ctx.phone, 123_456, %{}),
            move(ctx.phone, 123_456),
            capture(ctx.phone, %{})
          ] do
        assert json_response(conn, 403) == @plan_required
      end
    end

    test "under enforcement, a task in the person's Organization is served", ctx do
      into_org_workspace!(ctx.user, ctx.board)
      task = task_fixture(ctx.cols["Ready"])
      enforce_plans()

      assert ctx.phone |> api_get("/api/me/tasks/#{task.id}") |> json_response(200)
      assert ctx.phone |> comment(task.id, %{content: "hi"}) |> json_response(201)
      assert ctx.phone |> move(task.id) |> json_response(200)
      assert ctx.phone |> capture(capture_body(ctx.board)) |> json_response(201)
    end
  end

  describe "authentication" do
    test "an agent API token and no token are refused", ctx do
      task = task_fixture(ctx.cols["Ready"])

      {:ok, {_api_token, plain}} =
        ApiTokens.create_api_token(ctx.user, ctx.board, %{name: "Agent"})

      for token <- [plain, "made-up"] do
        assert token |> api_get("/api/me/tasks/#{task.id}") |> json_response(401)
        assert token |> move(task.id) |> json_response(401)
        assert token |> capture(capture_body(ctx.board)) |> json_response(401)
      end

      assert build_conn() |> get("/api/me/tasks/#{task.id}") |> json_response(401)
      assert Repo.reload!(task).column_id == ctx.cols["Ready"].id
    end
  end

  describe "contract" do
    test "matches the documented schemas", ctx do
      task =
        task_fixture(ctx.cols["Ready"], %{
          key_files: [%{file_path: "lib/a.ex", note: "Edit", position: 0}]
        })

      add_comments!(ctx.scope, task, 1)
      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      detail = ctx.phone |> api_get("/api/me/tasks/#{task.id}") |> json_response(200)
      assert_schema(spec, detail, "MeTaskDetailResponse")
      assert_schema(spec, detail["data"], "MeTaskDetail")
      assert_schema(spec, detail["data"]["column"], "MeColumnRef")
      assert_schema(spec, hd(detail["data"]["key_files"]), "MeKeyFile")
      assert_schema(spec, hd(detail["data"]["comments"]), "TaskComment")

      commented = ctx.phone |> comment(task.id, %{content: "hi"}) |> json_response(201)
      assert_schema(spec, commented, "TaskCommentEnvelope")
      assert_schema(spec, commented["data"], "TaskComment")

      moved = ctx.phone |> move(task.id) |> json_response(200)
      assert_schema(spec, moved, "MeMoveToBacklogResponse")
      assert_schema(spec, moved["data"], "MeMoveToBacklogResult")
      assert_schema(spec, moved["data"]["task"], "MeTaskCard")

      captured = ctx.phone |> capture(capture_body(ctx.board)) |> json_response(201)
      assert_schema(spec, captured, "MeTaskDetailResponse")
      assert_schema(spec, captured["data"], "MeTaskDetail")

      doing = task_fixture(ctx.cols["Doing"])
      refusal = ctx.phone |> move(doing.id) |> json_response(422)
      assert_schema(spec, refusal, "MeTaskRefusal")
    end
  end

  # Runs `request`, calling `pull` once inside it, right after the app's task
  # lookup (the request's first query on tasks), so the change lands between
  # the lookup and the action. Returns the request's result.
  defp pull_the_rug(pull, request) do
    test_pid = self()
    pulled = :counters.new(1, [])
    handler_id = "me-task-rug-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and metadata[:source] == "tasks" and
             :counters.get(pulled, 1) == 0 do
          :counters.add(pulled, 1, 1)
          pull.()
        end
      end,
      nil
    )

    try do
      result = request.()
      assert :counters.get(pulled, 1) == 1, "the rug was never pulled"
      result
    after
      :telemetry.detach(handler_id)
    end
  end

  # The SQL text of every query the test process ran inside `fun`, in order.
  defp sql_of(fun) do
    test_pid = self()
    handler_id = "me-task-sql-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, %{query: sql}, _config ->
        if self() == test_pid, do: send(test_pid, {:sql, handler_id, sql})
      end,
      nil
    )

    try do
      {fun.(), collect_sql(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_sql(handler_id, acc) do
    receive do
      {:sql, ^handler_id, sql} -> collect_sql(handler_id, [sql | acc])
    after
      0 -> Enum.reverse(acc)
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
