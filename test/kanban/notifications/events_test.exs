defmodule Kanban.Notifications.EventsTest do
  # Some tests add a failing CHECK constraint to the notifications table
  # inside the sandbox transaction; that DDL locks the table, so these tests
  # cannot run concurrently with other notification tests.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Events
  alias Kanban.Notifications.GoalCompletedWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Reviews
  alias Kanban.Tasks
  alias Kanban.Tasks.AgentWorkflow
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

  defp rows_for_target(target_id) do
    Notification
    |> where(event_type: :target_status_changed, url_path: ^"/targets/#{target_id}")
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

  describe "task_reviewed/2" do
    defp reviewed(ctx, attrs) do
      struct(
        ctx.task,
        Map.merge(
          %{review_status: :approved, reviewed_at: ~U[2026-02-03 04:05:06Z]},
          attrs
        )
      )
    end

    test "notifies the completer with outcome, link, reviewer and an email", ctx do
      reviewer = %{ctx.owner | name: "Ada Owner"}
      task = reviewed(ctx, %{completed_by_id: ctx.editor.id, assigned_to_id: ctx.owner.id})

      assert :ok = Events.task_reviewed(task, reviewer)

      assert [%Notification{} = n] = rows(:task_reviewed)
      assert n.user_id == ctx.editor.id
      assert n.metadata == %{"outcome" => "approved"}
      assert n.title == "#{task.identifier}: Ship the inbox"
      assert n.url_path == "/boards/#{ctx.board.id}/tasks/#{task.id}/edit"
      assert n.board_id == ctx.board.id
      assert n.task_id == task.id
      assert n.actor_name == "Ada Owner"
      assert n.dedupe_key == "task_reviewed:#{task.id}:#{DateTime.to_unix(task.reviewed_at)}"
      assert is_nil(n.body)
      assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "falls back to the assignee when there is no completer", ctx do
      task = reviewed(ctx, %{completed_by_id: nil, assigned_to_id: ctx.editor.id})

      assert :ok = Events.task_reviewed(task, ctx.owner)
      assert [%Notification{user_id: user_id}] = rows(:task_reviewed)
      assert user_id == ctx.editor.id
    end

    test "never notifies the reviewer, with no further fallback", ctx do
      own_work = reviewed(ctx, %{completed_by_id: ctx.owner.id, assigned_to_id: ctx.editor.id})
      nobody = reviewed(ctx, %{completed_by_id: nil, assigned_to_id: nil})

      assert :ok = Events.task_reviewed(own_work, ctx.owner)
      assert :ok = Events.task_reviewed(nobody, ctx.owner)
      assert rows(:task_reviewed) == []
    end

    test "does nothing for a task with no review", ctx do
      task = reviewed(ctx, %{completed_by_id: ctx.editor.id, reviewed_at: nil})

      assert :ok = Events.task_reviewed(task, ctx.owner)
      assert rows(:task_reviewed) == []
    end

    test "a change request carries the notes; an approval never carries old notes", ctx do
      changes =
        reviewed(ctx, %{
          completed_by_id: ctx.editor.id,
          review_status: :changes_requested,
          review_notes: "  Add a test  "
        })

      approved =
        reviewed(ctx, %{
          completed_by_id: ctx.reader.id,
          review_notes: "Stale notes from an earlier request"
        })

      :ok = Events.task_reviewed(changes, ctx.owner)
      :ok = Events.task_reviewed(approved, ctx.owner)

      by_user = :task_reviewed |> rows() |> Map.new(&{&1.user_id, &1})

      assert by_user[ctx.editor.id].metadata == %{"outcome" => "changes_requested"}
      assert by_user[ctx.editor.id].body == "Add a test"
      assert by_user[ctx.reader.id].metadata == %{"outcome" => "approved"}
      assert is_nil(by_user[ctx.reader.id].body)
    end

    test "truncates notes to 500 characters", ctx do
      task =
        reviewed(ctx, %{
          completed_by_id: ctx.editor.id,
          review_status: :changes_requested,
          review_notes: String.duplicate("x", 600)
        })

      :ok = Events.task_reviewed(task, ctx.owner)

      assert [%Notification{body: body}] = rows(:task_reviewed)
      assert String.length(body) == 500
    end

    test "a retry of the same review notifies once", ctx do
      task = reviewed(ctx, %{completed_by_id: ctx.editor.id})

      :ok = Events.task_reviewed(task, ctx.owner)
      :ok = Events.task_reviewed(task, ctx.owner)

      assert [_one] = rows(:task_reviewed)
    end

    test "does not notify a completer who is no longer on the board", ctx do
      task = reviewed(ctx, %{completed_by_id: user_fixture().id})

      assert :ok = Events.task_reviewed(task, ctx.owner)
      assert rows(:task_reviewed) == []
    end
  end

  describe "task_unclaimed/3" do
    defp released(ctx, attrs) do
      struct(ctx.task, Map.merge(%{claimed_at: ~U[2026-02-03 04:05:06Z]}, attrs))
    end

    test "notifies the unclaiming user and the creator with the reason", ctx do
      user = %{ctx.owner | name: "Agent Owner"}
      task = released(ctx, %{created_by_id: ctx.editor.id})

      assert :ok = Events.task_unclaimed(task, user, "Blocked on <credentials>")

      assert [first, second] = rows(:task_unclaimed)

      assert Enum.sort([first.user_id, second.user_id]) ==
               Enum.sort([ctx.owner.id, ctx.editor.id])

      for n <- [first, second] do
        assert n.body == "Blocked on <credentials>"
        assert n.actor_name == "Agent Owner"
        assert n.title == "#{task.identifier}: Ship the inbox"
        assert n.url_path == "/boards/#{ctx.board.id}/tasks/#{task.id}/edit"
        assert n.dedupe_key == "task_unclaimed:#{task.id}:#{DateTime.to_unix(task.claimed_at)}"
        assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
      end
    end

    test "de-duplicates when the unclaiming user created the task", ctx do
      task = released(ctx, %{created_by_id: ctx.owner.id})

      assert :ok = Events.task_unclaimed(task, ctx.owner, "why")
      assert [%Notification{user_id: user_id}] = rows(:task_unclaimed)
      assert user_id == ctx.owner.id
    end

    test "a missing, blank or non-text reason stores no body", ctx do
      for {reason, index} <- Enum.with_index([nil, "   ", %{"a" => 1}, 42]) do
        task = released(ctx, %{created_by_id: nil, claimed_at: DateTime.from_unix!(index)})
        assert :ok = Events.task_unclaimed(task, ctx.owner, reason)
      end

      notifications = rows(:task_unclaimed)
      assert length(notifications) == 4
      assert Enum.all?(notifications, &is_nil(&1.body))
    end

    test "truncates the reason to 500 characters", ctx do
      task = released(ctx, %{created_by_id: nil})

      :ok = Events.task_unclaimed(task, ctx.owner, String.duplicate("y", 600))

      assert [%Notification{body: body}] = rows(:task_unclaimed)
      assert String.length(body) == 500
    end

    test "bounds a reason made of combining marks by code points, not graphemes", ctx do
      task = released(ctx, %{created_by_id: nil})
      reason = "a" <> String.duplicate("\u0301", 10_000)

      :ok = Events.task_unclaimed(task, ctx.owner, reason)

      assert [%Notification{body: body}] = rows(:task_unclaimed)
      assert length(String.codepoints(body)) == 500
      assert byte_size(body) <= 2_000
    end

    test "a retry of the same unclaim notifies each recipient once", ctx do
      task = released(ctx, %{created_by_id: ctx.editor.id})

      :ok = Events.task_unclaimed(task, ctx.owner, "why")
      :ok = Events.task_unclaimed(task, ctx.owner, "why")

      assert length(rows(:task_unclaimed)) == 2
    end

    test "falls back to updated_at when the task was never claimed through the API", ctx do
      task = released(ctx, %{created_by_id: nil, claimed_at: nil})

      :ok = Events.task_unclaimed(task, ctx.owner, nil)

      assert [%Notification{dedupe_key: key}] = rows(:task_unclaimed)
      unix = task.updated_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
      assert key == "task_unclaimed:#{task.id}:#{unix}"
    end

    test "does not notify a creator who is no longer on the board", ctx do
      task = released(ctx, %{created_by_id: user_fixture().id})

      :ok = Events.task_unclaimed(task, ctx.owner, "why")

      assert [%Notification{user_id: user_id}] = rows(:task_unclaimed)
      assert user_id == ctx.owner.id
    end
  end

  describe "board_access_changed/4" do
    setup do
      # The shared setup adds two members, which now notifies them.
      Repo.delete_all(Notification)
      :ok
    end

    test "an add names the board and access level and links to the board", ctx do
      stamp = ~N[2026-02-01 09:00:00]

      assert :ok =
               Events.board_access_changed(ctx.board, ctx.editor, :added,
                 actor: ctx.owner,
                 access: :modify,
                 tokens_revoked: 0,
                 membership_id: 42,
                 stamp: stamp
               )

      assert [%Notification{} = row] = rows(:board_access_changed)
      assert row.user_id == ctx.editor.id
      assert row.board_id == ctx.board.id
      assert row.title == ctx.board.name
      assert row.url_path == "/boards/#{ctx.board.id}"
      assert row.task_id == nil
      assert row.metadata == %{"change" => "added", "access" => "modify", "tokens_revoked" => 0}

      assert row.dedupe_key ==
               "board_access_changed:#{ctx.board.id}:#{ctx.editor.id}:42:added:modify:#{stamp |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)}"
    end

    test "an access change names the new level", ctx do
      assert :ok =
               Events.board_access_changed(ctx.board, ctx.editor, :access_changed,
                 actor: ctx.owner,
                 access: :read_only,
                 tokens_revoked: 3
               )

      assert [%Notification{metadata: metadata, board_id: board_id}] =
               rows(:board_access_changed)

      assert board_id == ctx.board.id

      assert metadata == %{
               "change" => "access_changed",
               "access" => "read_only",
               "tokens_revoked" => 3
             }
    end

    test "a removal has no board_id, links to the board list and counts revoked tokens", ctx do
      outsider = user_fixture()

      assert :ok =
               Events.board_access_changed(ctx.board, outsider, :removed,
                 actor: ctx.owner,
                 tokens_revoked: 2
               )

      assert [%Notification{} = row] = rows(:board_access_changed)
      assert row.user_id == outsider.id
      assert row.board_id == nil
      assert row.url_path == "/boards"
      assert row.title == ctx.board.name
      assert row.metadata == %{"change" => "removed", "tokens_revoked" => 2}

      assert [%Notification{id: id}] =
               outsider |> Scope.for_user() |> Kanban.Notifications.list_notifications()

      assert id == row.id
    end

    test "stores the actor's name, never their email", ctx do
      {:ok, named} =
        ctx.owner |> Ecto.Changeset.change(name: "Olivia Owner") |> Repo.update()

      Events.board_access_changed(ctx.board, ctx.editor, :added, actor: named, access: :modify)
      assert [%Notification{actor_name: "Olivia Owner"}] = rows(:board_access_changed)

      Repo.delete_all(Notification)
      {:ok, unnamed} = ctx.owner |> Ecto.Changeset.change(name: nil) |> Repo.update()

      Events.board_access_changed(ctx.board, ctx.editor, :added, actor: unnamed, access: :modify)
      assert [%Notification{actor_name: nil}] = rows(:board_access_changed)
    end

    test "notifies nobody when the actor is the affected user", ctx do
      for change <- [:added, :access_changed, :removed] do
        assert :ok =
                 Events.board_access_changed(ctx.board, ctx.editor, change,
                   actor: ctx.editor,
                   access: :modify
                 )
      end

      assert rows(:board_access_changed) == []
    end

    test "a nil actor still notifies", ctx do
      assert :ok = Events.board_access_changed(ctx.board, ctx.editor, :added, access: :modify)
      assert [%Notification{actor_name: nil}] = rows(:board_access_changed)
    end

    test "a retry of the same change notifies once", ctx do
      opts = [actor: ctx.owner, access: :modify, stamp: ~N[2026-02-01 09:00:00]]

      Events.board_access_changed(ctx.board, ctx.editor, :added, opts)
      Events.board_access_changed(ctx.board, ctx.editor, :added, opts)

      assert [%Notification{}] = rows(:board_access_changed)
    end

    test "an unknown access level or a non-integer count is not stored", ctx do
      Events.board_access_changed(ctx.board, ctx.editor, :added,
        access: :admin,
        tokens_revoked: "lots"
      )

      assert [%Notification{metadata: metadata}] = rows(:board_access_changed)
      assert metadata == %{"change" => "added", "tokens_revoked" => 0}
    end

    test "a board name longer than a title is truncated", ctx do
      board = %{ctx.board | name: String.duplicate("b", 300)}

      Events.board_access_changed(board, ctx.editor, :added, access: :modify)

      assert [%Notification{title: title}] = rows(:board_access_changed)
      assert String.length(title) == 255
    end

    test "an added user who is not a board member is not notified", ctx do
      outsider = user_fixture()

      Events.board_access_changed(ctx.board, outsider, :added, actor: ctx.owner, access: :modify)

      assert rows(:board_access_changed) == []
    end

    test "queues an email for the affected user", ctx do
      Events.board_access_changed(ctx.board, ctx.editor, :added,
        actor: ctx.owner,
        access: :modify
      )

      assert [%Notification{id: id}] = rows(:board_access_changed)
      assert_enqueued(worker: EmailWorker, args: %{notification_id: id})
    end
  end

  describe "target_status_changed/3" do
    @changed_at ~U[2026-06-09 00:17:00Z]

    setup ctx do
      %{
        target:
          delivery_target_fixture(ctx.owner, %{name: "Q3 launch", target_date: ~D[2026-07-21]})
      }
    end

    test "notifies the owner with a board-less link to the target page", ctx do
      assert :ok = Events.target_status_changed(ctx.target, :at_risk, @changed_at)

      assert [%Notification{} = row] = rows(:target_status_changed)
      assert row.user_id == ctx.owner.id
      assert row.board_id == nil
      assert row.task_id == nil
      assert row.title == "Q3 launch"
      assert row.url_path == "/targets/#{ctx.target.id}"
      assert row.metadata == %{"status" => "at_risk", "target_date" => "2026-07-21"}

      assert row.dedupe_key ==
               "target_status:#{ctx.target.id}:at_risk:#{DateTime.to_unix(@changed_at)}"

      assert_enqueued(worker: EmailWorker, args: %{notification_id: row.id})
    end

    test "at_risk and missed are told apart by their metadata", ctx do
      Events.target_status_changed(ctx.target, :at_risk, @changed_at)
      Events.target_status_changed(ctx.target, :missed, DateTime.add(@changed_at, 3600))

      assert ctx.target.id
             |> rows_for_target()
             |> Enum.map(& &1.metadata["status"])
             |> Enum.sort() ==
               ["at_risk", "missed"]
    end

    test "the same recorded change notifies once", ctx do
      Events.target_status_changed(ctx.target, :missed, @changed_at)
      Events.target_status_changed(ctx.target, :missed, @changed_at)

      assert [%Notification{}] = rows(:target_status_changed)
    end

    test "a later change of the same status notifies again", ctx do
      Events.target_status_changed(ctx.target, :at_risk, @changed_at)
      Events.target_status_changed(ctx.target, :at_risk, DateTime.add(@changed_at, 86_400))

      assert length(rows(:target_status_changed)) == 2
    end

    test "does nothing for a healthy status or a target without an owner", ctx do
      assert :ok = Events.target_status_changed(ctx.target, :on_track, @changed_at)
      assert :ok = Events.target_status_changed(ctx.target, :complete, @changed_at)

      assert :ok =
               Events.target_status_changed(%{ctx.target | owner_id: nil}, :missed, @changed_at)

      assert rows(:target_status_changed) == []
    end

    test "never names the target's goals", ctx do
      goal = task_fixture(ctx.cols["Ready"], %{type: :goal, title: "Secret goal title"})
      {:ok, _} = Tasks.update_task(goal, %{target_id: ctx.target.id})

      Events.target_status_changed(ctx.target, :missed, @changed_at)

      assert [%Notification{} = row] = rows(:target_status_changed)
      refute inspect(Map.from_struct(row)) =~ "Secret goal title"
    end
  end

  describe "failure handling" do
    test "a target event failure is logged with the target id only and returns :ok", ctx do
      target = delivery_target_fixture(ctx.owner, %{name: "Private target name"})
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Events.target_status_changed(target, :missed, ~U[2026-06-09 00:17:00Z])
        end)

      assert log =~ "notification target_status_changed not emitted for target #{target.id}"
      refute log =~ "Private target name"
    end

    test "a board event failure is logged with the board id only and returns :ok", ctx do
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert :ok =
                   Events.board_access_changed(ctx.board, ctx.editor, :added,
                     actor: ctx.owner,
                     access: :modify
                   )
        end)

      assert log =~ "notification board_access_changed not emitted for board #{ctx.board.id}"
      refute log =~ ctx.board.name
    end

    test "a failing emitter never changes the membership functions' results", ctx do
      member = user_fixture()
      break_notification_inserts()

      capture_log([level: :warning], fn ->
        assert {:ok, %Boards.BoardUser{access: :modify}} =
                 Boards.add_user_to_board(ctx.board, member, :modify, ctx.owner)

        assert {:ok, %Boards.BoardUser{access: :read_only}} =
                 Boards.update_user_access(ctx.board, member, :read_only, ctx.owner)

        assert {:ok, %Boards.BoardUser{}} =
                 Boards.remove_user_from_board(ctx.board, member, ctx.owner)
      end)
    end

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

    test "review and unclaim failures are logged without free text and return :ok", ctx do
      break_notification_inserts()

      task = %{
        ctx.task
        | completed_by_id: ctx.editor.id,
          review_status: :changes_requested,
          review_notes: "secret review notes",
          reviewed_at: ~U[2026-02-03 04:05:06Z],
          claimed_at: ~U[2026-02-03 04:05:06Z]
      }

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Events.task_reviewed(task, ctx.owner)
          assert :ok = Events.task_unclaimed(task, ctx.owner, "secret unclaim reason")
        end)

      assert log =~ "notification task_reviewed not emitted for task #{task.id}"
      assert log =~ "notification task_unclaimed not emitted for task #{task.id}"
      refute log =~ "Ship the inbox"
      refute log =~ "secret"
    end

    test "a failing emitter never changes approve_review's or request_changes_review's result",
         ctx do
      scope = Scope.for_user(ctx.owner)
      approve = pending_review_task(ctx)
      changes = pending_review_task(ctx)
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %Tasks.Task{review_status: :approved}} =
                   Reviews.approve_review(scope, approve)

          assert {:ok, %Tasks.Task{review_status: :changes_requested}} =
                   Reviews.request_changes_review(scope, changes, review_notes: "Fix it")
        end)

      assert log =~ "notification task_reviewed not emitted for task #{approve.id}"
      assert log =~ "notification task_reviewed not emitted for task #{changes.id}"
    end

    test "a failing emitter never changes unclaim_task's result", ctx do
      task = task_fixture(ctx.cols["Ready"], %{status: :open, created_by_id: ctx.editor.id})

      {:ok, claimed, _hook} =
        Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier, "Agent")

      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %Tasks.Task{status: :open}} =
                   AgentWorkflow.unclaim_task(claimed, ctx.owner, "why")
        end)

      assert log =~ "notification task_unclaimed not emitted for task #{task.id}"
    end
  end

  defp pending_review_task(ctx) do
    task = task_fixture(ctx.cols["Review"])

    {:ok, task} =
      Tasks.update_task(task, %{
        needs_review: true,
        completed_by_agent: "Claude",
        completed_by_id: ctx.editor.id
      })

    task
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
