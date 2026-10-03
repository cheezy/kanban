defmodule Kanban.Notifications.EventsTest do
  # Some tests add a failing CHECK constraint to the notifications table
  # inside the sandbox transaction; that DDL locks the table, so these tests
  # cannot run concurrently with other notification tests.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Events
  alias Kanban.Notifications.GoalCompletedWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Tasks
  alias Kanban.Tasks.Interventions

  setup do
    owner = user_fixture()
    editor = user_fixture()
    reader = user_fixture()
    board = ai_optimized_board_fixture(owner)
    {:ok, _} = Boards.add_user_to_board(board, editor, :modify, owner)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    task = task_fixture(cols["Review"], %{title: "Ship the inbox"})

    %{owner: owner, editor: editor, reader: reader, board: board, cols: cols, task: task}
  end

  defp rows(event_type) do
    Notification
    |> where(event_type: ^event_type)
    |> order_by(:user_id)
    |> Repo.all()
  end

  defp break_notification_inserts do
    Repo.query!(
      "ALTER TABLE notifications ADD CONSTRAINT w2203_always_fails CHECK (false) NOT VALID"
    )
  end

  describe "write_access_members/1" do
    test "returns owner and modify members only", ctx do
      ids =
        ctx.board.id
        |> Events.write_access_members()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([ctx.owner.id, ctx.editor.id])
    end
  end

  describe "review_requested/1" do
    test "notifies owner and modify members, not read-only members", ctx do
      assert :ok = Events.review_requested(ctx.task)

      notified = :review_requested |> rows() |> Enum.map(& &1.user_id)

      assert Enum.sort(notified) == Enum.sort([ctx.owner.id, ctx.editor.id])
      refute ctx.reader.id in notified
    end

    test "builds the title from identifier and title, links to /review, and enqueues email",
         ctx do
      :ok = Events.review_requested(ctx.task)

      for n <- rows(:review_requested) do
        assert n.title == "#{ctx.task.identifier}: Ship the inbox"
        assert n.url_path == "/review"
        assert n.board_id == ctx.board.id
        assert n.task_id == ctx.task.id
        assert is_nil(n.body)
        assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
      end
    end

    test "/review is a real route", _ctx do
      info = Phoenix.Router.route_info(KanbanWeb.Router, "GET", "/review", "localhost")

      assert elem(info.phoenix_live_view, 0) == KanbanWeb.ReviewLive
    end

    test "notifies only the owner when the other member is read-only", ctx do
      board = ai_optimized_board_fixture(ctx.owner)
      {:ok, _} = Boards.add_user_to_board(board, ctx.reader, :read_only, ctx.owner)
      review = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Review"))
      task = task_fixture(review)

      :ok = Events.review_requested(task)

      assert [%Notification{user_id: user_id}] =
               :review_requested |> rows() |> Enum.filter(&(&1.task_id == task.id))

      assert user_id == ctx.owner.id
    end

    test "cuts a long title to 255 characters", ctx do
      task = %{ctx.task | title: String.duplicate("a", 300)}

      :ok = Events.review_requested(task)

      assert :review_requested |> rows() |> Enum.all?(&(String.length(&1.title) == 255))
    end

    test "emitting the same event twice notifies each member once", ctx do
      :ok = Events.review_requested(ctx.task)
      :ok = Events.review_requested(ctx.task)

      assert length(rows(:review_requested)) == 2
    end
  end

  describe "task_assigned/2" do
    test "notifies the assignee with a link to the task's edit route", ctx do
      task = %{ctx.task | assigned_to_id: ctx.editor.id}

      assert :ok = Events.task_assigned(task, ctx.owner)

      assert [%Notification{user_id: user_id, url_path: url_path}] = rows(:task_assigned)
      assert user_id == ctx.editor.id
      assert url_path == "/boards/#{ctx.board.id}/tasks/#{task.id}/edit"
    end

    test "the edit url resolves to the board's edit_task route", ctx do
      path = "/boards/#{ctx.board.id}/tasks/#{ctx.task.id}/edit"
      info = Phoenix.Router.route_info(KanbanWeb.Router, "GET", path, "localhost")

      assert info.phoenix_live_view |> elem(0) == KanbanWeb.BoardLive.Show
      assert info.phoenix_live_view |> elem(1) == :edit_task
    end

    test "notifies nobody when the actor assigned the task to themselves", ctx do
      task = %{ctx.task | assigned_to_id: ctx.editor.id}

      assert :ok = Events.task_assigned(task, ctx.editor)
      assert rows(:task_assigned) == []
    end

    test "notifies nobody when the task has no assignee", ctx do
      assert :ok = Events.task_assigned(%{ctx.task | assigned_to_id: nil}, ctx.owner)
      assert rows(:task_assigned) == []
    end

    test "a nil actor still notifies the assignee", ctx do
      assert :ok = Events.task_assigned(%{ctx.task | assigned_to_id: ctx.editor.id}, nil)
      assert [%Notification{}] = rows(:task_assigned)
    end

    test "an assignee who is not a board member is not notified", ctx do
      outsider = user_fixture()

      assert :ok = Events.task_assigned(%{ctx.task | assigned_to_id: outsider.id}, ctx.owner)
      assert rows(:task_assigned) == []
    end
  end

  describe "claim_expired/1" do
    test "notifies the assignee with a dedupe key from the claim expiry", ctx do
      expires = ~U[2026-01-01 10:00:00Z]
      task = %{ctx.task | assigned_to_id: ctx.editor.id, claim_expires_at: expires}

      assert :ok = Events.claim_expired(task)

      assert [%Notification{user_id: user_id, dedupe_key: key}] = rows(:claim_expired)
      assert user_id == ctx.editor.id
      assert key == "claim_expired:#{task.id}:#{DateTime.to_unix(expires)}"
    end

    test "does nothing without an assignee or a claim expiry", ctx do
      assert :ok = Events.claim_expired(%{ctx.task | assigned_to_id: nil})

      assert :ok =
               Events.claim_expired(%{
                 ctx.task
                 | assigned_to_id: ctx.editor.id,
                   claim_expires_at: nil
               })

      assert rows(:claim_expired) == []
    end

    test "does not notify an assignee who is not on the board", ctx do
      task = %{
        ctx.task
        | assigned_to_id: user_fixture().id,
          claim_expires_at: ~U[2026-01-01 10:00:00Z]
      }

      assert :ok = Events.claim_expired(task)
      assert rows(:claim_expired) == []
    end
  end

  describe "goal_completed/1 and goal_completed_after_commit/1" do
    defp completed_goal(ctx, attrs) do
      goal =
        task_fixture(
          ctx.cols["Done"],
          Map.merge(%{type: :goal, created_by_id: ctx.owner.id}, attrs)
        )

      %{goal | status: :completed, completed_at: ~U[2026-02-02 12:00:00Z]}
    end

    test "notifies creator and assignee once each", ctx do
      goal = completed_goal(ctx, %{assigned_to_id: ctx.editor.id})

      assert :ok = Events.goal_completed(goal)

      users = :goal_completed |> rows() |> Enum.map(& &1.user_id) |> Enum.sort()
      assert users == Enum.sort([ctx.owner.id, ctx.editor.id])
    end

    test "notifies once when the creator is also the assignee", ctx do
      goal = completed_goal(ctx, %{assigned_to_id: ctx.owner.id})

      assert :ok = Events.goal_completed(goal)
      assert [%Notification{}] = rows(:goal_completed)
    end

    test "notifies nobody for a goal with no assignee and a deleted creator", ctx do
      goal = %{completed_goal(ctx, %{}) | created_by_id: nil, assigned_to_id: nil}

      assert :ok = Events.goal_completed(goal)
      assert rows(:goal_completed) == []
    end

    test "does nothing for a goal that is not completed", ctx do
      assert :ok = Events.goal_completed(%{completed_goal(ctx, %{}) | status: :open})
      assert :ok = Events.goal_completed(ctx.task)
      assert rows(:goal_completed) == []
    end

    test "goal_completed_after_commit/1 enqueues the worker only for a completed goal", ctx do
      goal = completed_goal(ctx, %{})

      assert :ok = Events.goal_completed_after_commit(goal)
      assert_enqueued(worker: GoalCompletedWorker, args: %{goal_id: goal.id})

      assert :ok = Events.goal_completed_after_commit(%{goal | status: :open, id: -5})
      refute_enqueued(worker: GoalCompletedWorker, args: %{goal_id: -5})
    end
  end

  describe "after_goal_failed/2" do
    defp failing_goal(ctx, attempts) do
      goal = task_fixture(ctx.cols["Doing"], %{type: :goal, created_by_id: ctx.owner.id})
      %{goal | after_goal_attempts: attempts}
    end

    @fail %{"exit_code" => 1, "output" => "secret /Users/x token=abc", "duration_ms" => 500}
    @ok %{"exit_code" => 0, "output" => "fine", "duration_ms" => 100}

    test "notifies with the exit code and duration but never the output", ctx do
      goal = failing_goal(ctx, [@fail])

      assert :ok = Events.after_goal_failed(goal, @fail)

      assert [%Notification{} = n] = rows(:after_goal_failed)
      assert is_nil(n.body)
      assert n.metadata == %{"exit_code" => 1, "duration_ms" => 500}
      assert n.url_path == "/boards/#{ctx.board.id}/tasks/#{goal.id}/edit"
      refute inspect(n) =~ "secret"
      refute inspect(n) =~ "token=abc"
    end

    test "one failure streak notifies once", ctx do
      goal = failing_goal(ctx, [@fail])
      :ok = Events.after_goal_failed(goal, @fail)
      :ok = Events.after_goal_failed(%{goal | after_goal_attempts: [@fail, @fail]}, @fail)

      assert [%Notification{dedupe_key: key}] = rows(:after_goal_failed)
      assert key == "after_goal_failed:#{goal.id}:0"
    end

    test "a failure after a later success starts a new streak", ctx do
      goal = failing_goal(ctx, [@fail])
      :ok = Events.after_goal_failed(goal, @fail)

      :ok = Events.after_goal_failed(%{goal | after_goal_attempts: [@fail, @ok, @fail]}, @fail)

      keys = :after_goal_failed |> rows() |> Enum.map(& &1.dedupe_key) |> Enum.sort()
      assert keys == ["after_goal_failed:#{goal.id}:0", "after_goal_failed:#{goal.id}:2"]
    end

    test "a grace worker success also ends the streak", ctx do
      grace = %{"exit_code" => 0, "duration_ms" => 0, "source" => "after_goal_grace_worker"}
      goal = failing_goal(ctx, [@fail, grace, @fail])

      :ok = Events.after_goal_failed(goal, @fail)

      assert [%Notification{dedupe_key: key}] = rows(:after_goal_failed)
      assert key == "after_goal_failed:#{goal.id}:2"
    end

    test "omits the duration when it is not an integer", ctx do
      attempt = %{"exit_code" => 2, "output" => "x"}
      goal = failing_goal(ctx, [attempt])
      :ok = Events.after_goal_failed(goal, attempt)

      assert [%Notification{body: nil, metadata: %{"exit_code" => 2}}] =
               rows(:after_goal_failed)
    end

    test "an attempt without an integer exit code notifies with no details", ctx do
      attempt = %{"output" => "x"}
      goal = failing_goal(ctx, [attempt])

      :ok = Events.after_goal_failed(goal, attempt)

      assert [%Notification{body: nil, metadata: metadata}] = rows(:after_goal_failed)
      assert metadata == %{}
    end
  end

  describe "failure handling" do
    test "an error from notify/3 is logged with ids only and returns :ok", ctx do
      bogus = %{ctx.task | id: -1, assigned_to_id: ctx.editor.id}

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Events.task_assigned(bogus, ctx.owner)
        end)

      assert log =~ "notification task_assigned not emitted for task -1"
      refute log =~ "Ship the inbox"
      assert rows(:task_assigned) == []
    end

    test "an exception is rescued, logged with ids only, and returns :ok", ctx do
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Events.review_requested(ctx.task)
        end)

      assert log =~ "notification review_requested not emitted for task #{ctx.task.id}"
      refute log =~ "Ship the inbox"
    end

    test "a task with no column is rescued and returns :ok", ctx do
      log =
        capture_log([level: :warning], fn ->
          assert :ok = Events.review_requested(%{ctx.task | column_id: nil})
        end)

      assert log =~ "notification review_requested not emitted"
    end

    test "a failing emitter never changes complete_task's result", ctx do
      task =
        task_fixture(ctx.cols["Ready"], %{
          needs_review: true,
          status: :open,
          created_by_id: ctx.owner.id
        })

      {:ok, claimed, _hook} =
        Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier, "Agent")

      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %Tasks.Task{}, _hooks} =
                   Tasks.complete_task(claimed, ctx.owner, complete_params(), "Agent")
        end)

      assert log =~ "notification review_requested not emitted"
    end

    test "a failing emitter never changes update_task's result", ctx do
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %Tasks.Task{assigned_to_id: assignee_id}} =
                   Tasks.update_task(ctx.task, %{assigned_to_id: ctx.editor.id}, actor: ctx.owner)

          assert assignee_id == ctx.editor.id
        end)

      assert log =~ "notification task_assigned not emitted"
    end

    test "a failing emitter never changes reassign_goal_unstarted's result", ctx do
      goal = task_fixture(ctx.cols["Ready"], %{type: :goal})
      scope = Scope.for_user(ctx.owner)
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %{moved: [_ | _], skipped: _}} =
                   Interventions.reassign_goal_unstarted(scope, goal, ctx.editor.id)
        end)

      assert log =~ "notification task_assigned not emitted"
    end
  end

  defp complete_params do
    %{
      "completion_summary" => "Did the work",
      "actual_complexity" => "small",
      "actual_files_changed" => "lib/foo.ex",
      "time_spent_minutes" => 5
    }
  end
end
