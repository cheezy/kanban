defmodule Kanban.ReviewsTest do
  @moduledoc """
  Tests for `Kanban.Reviews` — the read API for the workspace Review
  Queue at `/review`.
  """
  use Kanban.DataCase
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.ColumnLockHelpers
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Reviews
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board, %{name: "Review", position: 1})
    %{user: user, board: board, column: column}
  end

  defp pending_task!(column, attrs \\ %{}) do
    base = %{
      needs_review: true,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      completed_by_agent: "Claude"
    }

    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(Map.merge(base, attrs))

    task
  end

  defp blocked_dependent!(column, task) do
    column
    |> task_fixture(%{title: "Waits on the reviewed task"})
    |> Ecto.Changeset.change(%{dependencies: [task.identifier], status: :blocked})
    |> Repo.update!()
  end

  # Records each event with whether a transaction was still open when its
  # handler ran, so a test can read the events back in delivery order.
  defp attach_in_order(events) do
    test_pid = self()
    handler_id = "reviews-in-order-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, _measurements, metadata, _config ->
          if self() == test_pid,
            do: send(test_pid, {:in_order, event, metadata, Repo.in_transaction?()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp received_in_order(acc \\ []) do
    receive do
      {:in_order, event, metadata, in_transaction?} ->
        received_in_order([{event, metadata, in_transaction?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp stamp!(task, %DateTime{} = at) do
    from(t in Kanban.Tasks.Task, where: t.id == ^task.id)
    |> Kanban.Repo.update_all(set: [review_requested_at: at])
  end

  describe "waiting_since/1" do
    test "prefers review_requested_at" do
      at = ~U[2026-10-01 09:00:00Z]

      assert Reviews.waiting_since(%{
               review_requested_at: at,
               updated_at: ~N[2026-10-02 09:00:00]
             }) ==
               at
    end

    test "falls back to updated_at as UTC" do
      assert Reviews.waiting_since(%{
               review_requested_at: nil,
               updated_at: ~N[2026-10-02 09:00:00]
             }) ==
               ~U[2026-10-02 09:00:00Z]

      assert Reviews.waiting_since(%{updated_at: ~U[2026-10-02 09:00:00Z]}) ==
               ~U[2026-10-02 09:00:00Z]
    end

    test "returns nil without either timestamp" do
      assert Reviews.waiting_since(%{review_requested_at: nil, updated_at: nil}) == nil
      assert Reviews.waiting_since(%{}) == nil
    end
  end

  describe "list_pending_reviews/1" do
    test "returns an empty list when no tasks are pending review" do
      assert Reviews.list_pending_reviews() == []
    end

    test "returns pending tasks (review_status nil, needs_review true, in Review column)",
         %{column: column} do
      task = pending_task!(column)

      [result] = Reviews.list_pending_reviews()
      assert result.id == task.id
    end

    test "includes tasks with completed_at = nil — a Review-column task is not yet Done",
         %{column: column} do
      task = pending_task!(column, %{completed_at: nil})

      assert task.completed_at == nil

      [result] = Reviews.list_pending_reviews()
      assert result.id == task.id
    end

    test "treats explicit :pending review_status the same as nil", %{column: column} do
      task = pending_task!(column, %{review_status: :pending})

      [result] = Reviews.list_pending_reviews()
      assert result.id == task.id
    end

    test "excludes tasks with review_status :approved / :changes_requested / :rejected",
         %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Enum.each([:approved, :changes_requested, :rejected], fn status ->
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          needs_review: true,
          completed_at: now,
          review_status: status,
          reviewed_at: now,
          reviewed_by_id: user.id
        })
      end)

      assert Reviews.list_pending_reviews() == []
    end

    test "excludes tasks with needs_review: false", %{column: column} do
      column
      |> task_fixture()
      |> Tasks.update_task(%{
        needs_review: false,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert Reviews.list_pending_reviews() == []
    end

    test "excludes tasks not in a column named 'Review'", %{board: board} do
      backlog = column_fixture(board, %{name: "Backlog", position: 2})

      backlog
      |> task_fixture()
      |> Tasks.update_task(%{
        needs_review: true,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert Reviews.list_pending_reviews() == []
    end

    test "is scope-aware — excludes tasks on boards the user cannot access",
         %{column: column} do
      pending_task!(column)

      other_user = user_fixture()
      scope = Scope.for_user(other_user)

      assert Reviews.list_pending_reviews(scope: scope) == []
    end

    test "orders unstamped tasks by updated_at ascending (oldest first)", %{column: column} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      older = pending_task!(column)
      newer = pending_task!(column)

      from(t in Kanban.Tasks.Task, where: t.id == ^older.id)
      # Override updated_at directly so the test is robust to sub-second
      # precision in the timestamps.
      |> Kanban.Repo.update_all(
        set: [updated_at: NaiveDateTime.add(now, -3600, :second), review_requested_at: nil]
      )

      from(t in Kanban.Tasks.Task, where: t.id == ^newer.id)
      |> Kanban.Repo.update_all(set: [updated_at: now, review_requested_at: nil])

      ids = Reviews.list_pending_reviews() |> Enum.map(& &1.id)
      assert ids == [older.id, newer.id]
    end

    test "orders by review_requested_at, so editing a pending task does not move it",
         %{column: column} do
      now = DateTime.utc_now(:second)
      first = pending_task!(column)
      second = pending_task!(column)
      stamp!(first, DateTime.add(now, -7200, :second))
      stamp!(second, DateTime.add(now, -3600, :second))

      {:ok, _} = Tasks.update_task(first, %{title: "Edited while waiting"})

      assert Reviews.list_pending_reviews() |> Enum.map(& &1.id) == [first.id, second.id]
    end

    test "a task created in the Review column is stamped and keeps its place when edited",
         %{column: column} do
      first = pending_task!(column)
      second = pending_task!(column)
      assert %DateTime{} = Kanban.Repo.reload!(first).review_requested_at

      stamp!(first, :second |> DateTime.utc_now() |> DateTime.add(-60, :second))
      {:ok, _} = first |> Kanban.Repo.reload!() |> Tasks.update_task(%{title: "Edited"})

      assert Reviews.list_pending_reviews() |> Enum.map(& &1.id) == [first.id, second.id]
    end

    test "a stamped task sorts against an unstamped one by updated_at", %{column: column} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      legacy = pending_task!(column)
      stamped = pending_task!(column)

      from(t in Kanban.Tasks.Task, where: t.id == ^legacy.id)
      |> Kanban.Repo.update_all(
        set: [updated_at: NaiveDateTime.add(now, -600, :second), review_requested_at: nil]
      )

      stamp!(stamped, now |> NaiveDateTime.add(-3600, :second) |> DateTime.from_naive!("Etc/UTC"))

      assert Reviews.list_pending_reviews() |> Enum.map(& &1.id) == [stamped.id, legacy.id]
    end

    test "preloads :column and :board on returned tasks", %{column: column} do
      pending_task!(column)
      [task] = Reviews.list_pending_reviews()

      assert %Kanban.Columns.Column{} = task.column
      assert %Kanban.Boards.Board{} = task.column.board
    end
  end

  describe "get_pending_review/2" do
    test "returns {:ok, task} for a pending task the user can access",
         %{column: column, user: user} do
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:ok, fetched} = Reviews.get_pending_review(scope, task.id)
      assert fetched.id == task.id
      assert %Kanban.Boards.Board{} = fetched.column.board
    end

    test "returns {:error, :not_found} when the task is on an inaccessible board",
         %{column: column} do
      task = pending_task!(column)
      other_scope = Scope.for_user(user_fixture())

      assert {:error, :not_found} = Reviews.get_pending_review(other_scope, task.id)
    end

    test "returns {:error, :not_found} when the task is not pending review",
         %{column: column, user: user} do
      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{needs_review: false})

      scope = Scope.for_user(user)
      assert {:error, :not_found} = Reviews.get_pending_review(scope, task.id)
    end

    test "returns {:error, :not_found} when the task id does not exist",
         %{user: user} do
      scope = Scope.for_user(user)
      assert {:error, :not_found} = Reviews.get_pending_review(scope, 99_999_999)
    end

    test "returns {:error, :not_found} when the task already has :approved review_status",
         %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          needs_review: true,
          completed_at: now,
          review_status: :approved,
          reviewed_at: now,
          reviewed_by_id: user.id
        })

      scope = Scope.for_user(user)
      assert {:error, :not_found} = Reviews.get_pending_review(scope, task.id)
    end
  end

  describe "queue_stats/1" do
    test "returns zeros and nil oldest_age when the queue is empty" do
      assert Reviews.queue_stats() == %{
               count: 0,
               distinct_agents: 0,
               oldest_age_minutes: nil
             }
    end

    test "counts pending tasks", %{column: column} do
      pending_task!(column)
      pending_task!(column, %{completed_by_agent: "Codex"})

      assert Reviews.queue_stats().count == 2
    end

    test "counts distinct non-nil completed_by_agent values", %{column: column} do
      pending_task!(column, %{completed_by_agent: "Claude"})
      pending_task!(column, %{completed_by_agent: "Claude"})
      pending_task!(column, %{completed_by_agent: "Codex"})
      pending_task!(column, %{completed_by_agent: nil})

      assert Reviews.queue_stats().distinct_agents == 2
    end

    test "oldest_age_minutes uses review_requested_at over a later edit",
         %{column: column} do
      task = pending_task!(column)
      stamp!(task, :second |> DateTime.utc_now() |> DateTime.add(-7200, :second))
      {:ok, _} = Tasks.update_task(task, %{title: "Edited while waiting"})

      stats = Reviews.queue_stats()
      assert stats.oldest_age_minutes in 119..121
    end

    test "falls back to updated_at for oldest_age_minutes on unstamped tasks",
         %{column: column} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      pending_task!(column)
      older = pending_task!(column)

      Kanban.Tasks.Task
      |> Kanban.Repo.update_all(set: [review_requested_at: nil])

      from(t in Kanban.Tasks.Task, where: t.id == ^older.id)
      |> Kanban.Repo.update_all(set: [updated_at: NaiveDateTime.add(now, -7200, :second)])

      stats = Reviews.queue_stats()
      assert stats.oldest_age_minutes >= 119
      assert stats.oldest_age_minutes <= 121
    end

    test "is scope-aware", %{column: column} do
      pending_task!(column)
      other_scope = Scope.for_user(user_fixture())

      assert Reviews.queue_stats(scope: other_scope).count == 0
    end
  end

  describe "approving a goal's child inside the review transaction (D373)" do
    # The approval moves the child to Done inside its own transaction, holding
    # Done's lock, and then re-places the goal. Waiting there for a goal column
    # with a LOWER id would break the ascending lock order and could deadlock
    # against a board drag, so the re-placement must never wait.
    test "never waits for a lower goal column another writer holds",
         %{column: column, user: user, board: board} do
      goal_column = column_fixture(board, %{name: "Goal column", position: 2})
      done = column_fixture(board, %{name: "Done", position: 3})
      assert goal_column.id < done.id

      goal = task_fixture(column, %{title: "Goal", type: :goal})
      child = task_fixture(column, %{title: "Child", parent_id: goal.id})

      {:ok, child} =
        Tasks.update_task(child, %{
          needs_review: true,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          completed_by_agent: "Claude"
        })

      ColumnLockHelpers.relocate!(goal.id, goal_column.id, 0)
      holder = ColumnLockHelpers.hold_columns([goal_column.id], 400)

      {waited, result} =
        ColumnLockHelpers.timed(fn ->
          ExUnit.CaptureLog.capture_log(fn ->
            send(self(), {:approved, Reviews.approve_review(Scope.for_user(user), child)})
          end)
        end)

      assert {:ok, :held} = Elixir.Task.await(holder, 10_000)
      assert result =~ "another writer holds one of the goal's columns"
      assert_received {:approved, {:ok, _approved}}
      assert waited < 250
      assert Repo.get!(Kanban.Tasks.Task, child.id).column_id == done.id
      assert Repo.get!(Kanban.Tasks.Task, goal.id).column_id == goal_column.id
    end
  end

  describe "approve_review/3" do
    test "sets review_status to :approved with reviewed_at and reviewed_by_id",
         %{column: column, user: user, board: board} do
      _done = column_fixture(board, %{name: "Done", position: 2})
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:ok, approved} = Reviews.approve_review(scope, task)
      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, approved.id)

      assert reloaded.review_status == :approved
      assert %DateTime{} = reloaded.reviewed_at
      assert reloaded.reviewed_by_id == user.id
    end

    test "moves the task to the Done column", %{column: column, user: user, board: board} do
      _done = column_fixture(board, %{name: "Done", position: 2})
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:ok, approved} = Reviews.approve_review(scope, task)
      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, approved.id) |> Kanban.Repo.preload(:column)

      assert reloaded.column.name == "Done"
    end

    test "returns {:error, :not_found} when called by a user without board access",
         %{column: column} do
      task = pending_task!(column)
      other_scope = Scope.for_user(user_fixture())

      assert {:error, :not_found} = Reviews.approve_review(other_scope, task)
    end

    test "returns {:error, :not_authorized} when scope is nil", %{column: column} do
      task = pending_task!(column)
      assert {:error, :not_authorized} = Reviews.approve_review(nil, task)
    end

    test "rolls back the review-field write when the workflow step raises",
         %{column: column, user: user} do
      # No Done column on this board. AgentWorkflow.mark_reviewed/2 raises a
      # BadMapError when its position helper can't find one. The outer
      # Repo.transaction/1 catches the raise and rolls back the savepoint, so
      # the review-field write must not persist.
      task = pending_task!(column)
      scope = Scope.for_user(user)

      try do
        Reviews.approve_review(scope, task)
      rescue
        _ -> :ok
      end

      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, task.id)
      assert reloaded.review_status == nil
      assert reloaded.reviewed_at == nil
      assert reloaded.reviewed_by_id == nil
    end
  end

  describe "request_changes_review/3" do
    test "sets review_status to :changes_requested and persists review_notes",
         %{column: column, user: user, board: board} do
      _doing = column_fixture(board, %{name: "Doing", position: 2})
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:ok, changed} =
               Reviews.request_changes_review(scope, task, review_notes: "Please add more tests")

      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, changed.id) |> Kanban.Repo.preload(:column)

      assert reloaded.review_status == :changes_requested
      assert reloaded.review_notes == "Please add more tests"
      assert reloaded.reviewed_by_id == user.id
      assert reloaded.column.name == "Review"
    end

    test "returns {:error, :review_notes_required} when review_notes is missing",
         %{column: column, user: user} do
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:error, :review_notes_required} = Reviews.request_changes_review(scope, task, [])
    end

    test "returns {:error, :review_notes_required} when review_notes is blank",
         %{column: column, user: user} do
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:error, :review_notes_required} =
               Reviews.request_changes_review(scope, task, review_notes: "   ")
    end

    test "returns {:error, :review_notes_required} when review_notes is the empty string",
         %{column: column, user: user} do
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:error, :review_notes_required} =
               Reviews.request_changes_review(scope, task, review_notes: "")
    end

    test "returns {:error, :review_notes_required} when review_notes is non-binary",
         %{column: column, user: user} do
      task = pending_task!(column)
      scope = Scope.for_user(user)

      assert {:error, :review_notes_required} =
               Reviews.request_changes_review(scope, task, review_notes: 42)

      assert {:error, :review_notes_required} =
               Reviews.request_changes_review(scope, task, review_notes: ["a", "b"])
    end

    test "returns {:error, :not_found} when scoped user has no board access",
         %{column: column} do
      task = pending_task!(column)
      other_scope = Scope.for_user(user_fixture())

      assert {:error, :not_found} =
               Reviews.request_changes_review(other_scope, task, review_notes: "nope")
    end

    test "returns {:error, :not_authorized} for a read-only board member and writes nothing",
         %{column: column, board: board, user: owner} do
      task = pending_task!(column)
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)
      reader_scope = Scope.for_user(reader)

      assert {:error, :not_authorized} =
               Reviews.request_changes_review(reader_scope, task, review_notes: "let me in")

      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, task.id)
      assert reloaded.review_status == nil
      assert reloaded.review_notes == nil
      assert reloaded.reviewed_by_id == nil
      assert reloaded.reviewed_at == nil
    end

    test "succeeds for a board member with :modify access",
         %{column: column, board: board, user: owner} do
      task = pending_task!(column)
      modifier = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, modifier, :modify, owner)
      modifier_scope = Scope.for_user(modifier)

      assert {:ok, changed} =
               Reviews.request_changes_review(modifier_scope, task, review_notes: "please fix")

      reloaded = Kanban.Repo.get!(Kanban.Tasks.Task, changed.id)
      assert reloaded.review_status == :changes_requested
      assert reloaded.review_notes == "please fix"
      assert reloaded.reviewed_by_id == modifier.id
    end
  end

  describe "review notifications" do
    setup %{board: board, user: owner} do
      completer = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, completer, :modify, owner)
      %{completer: completer}
    end

    defp reviewed_rows do
      Notification
      |> where(event_type: :task_reviewed)
      |> Repo.all()
    end

    test "approving notifies the completer once with outcome approved and a task link",
         %{column: column, user: user, board: board, completer: completer} do
      _done = column_fixture(board, %{name: "Done", position: 2})
      task = pending_task!(column, %{completed_by_id: completer.id})

      assert {:ok, _approved} = user |> Scope.for_user() |> Reviews.approve_review(task)

      assert [%Notification{} = n] = reviewed_rows()
      assert n.user_id == completer.id
      assert n.metadata == %{"outcome" => "approved"}
      assert n.url_path == "/boards/#{board.id}/tasks/#{task.id}/edit"
      assert is_nil(n.body)
      assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "requesting changes notifies with the notes, truncated to 500 characters",
         %{column: column, user: user, completer: completer} do
      task = pending_task!(column, %{completed_by_id: completer.id})
      notes = String.duplicate("n", 600)

      assert {:ok, _changed} =
               user
               |> Scope.for_user()
               |> Reviews.request_changes_review(task, review_notes: notes)

      assert [%Notification{} = n] = reviewed_rows()
      assert n.user_id == completer.id
      assert n.metadata == %{"outcome" => "changes_requested"}
      assert n.body == String.duplicate("n", 500)
    end

    test "a review that returns an error notifies nobody",
         %{column: column, board: board, user: owner, completer: completer} do
      task = pending_task!(column, %{completed_by_id: completer.id})
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      assert {:error, :review_notes_required} =
               owner |> Scope.for_user() |> Reviews.request_changes_review(task, [])

      assert {:error, :not_authorized} =
               reader
               |> Scope.for_user()
               |> Reviews.request_changes_review(task, review_notes: "x")

      assert {:error, :not_authorized} = Reviews.approve_review(nil, task)
      assert reviewed_rows() == []
    end

    test "reviewing your own agent's work notifies nobody", %{column: column, user: user} do
      task = pending_task!(column, %{completed_by_id: user.id})

      assert {:ok, _changed} =
               user |> Scope.for_user() |> Reviews.request_changes_review(task, review_notes: "x")

      assert reviewed_rows() == []
    end

    test "a completer removed from the board before the review is not notified",
         %{column: column, user: user, board: board, completer: completer} do
      _done = column_fixture(board, %{name: "Done", position: 2})
      task = pending_task!(column, %{completed_by_id: completer.id})
      {:ok, _} = Boards.remove_user_from_board(board, completer, user)

      assert {:ok, _approved} = user |> Scope.for_user() |> Reviews.approve_review(task)
      assert reviewed_rows() == []
    end
  end

  describe "review decision telemetry" do
    setup %{board: board} do
      _done = column_fixture(board, %{name: "Done", position: 2})
      :ok
    end

    test "approve_review emits review_approved with the reviewer id and one completed event",
         %{column: column, user: user, board: board} do
      task = pending_task!(column)

      attach_telemetry([
        [:kanban, :task, :review_approved],
        [:kanban, :task, :review_changes_requested],
        [:kanban, :task, :completed]
      ])

      assert {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)

      assert_receive {:telemetry_event, [:kanban, :task, :review_approved], %{count: 1}, metadata}

      assert metadata == %{task_id: task.id, board_id: board.id, reviewer_user_id: user.id}
      assert_receive {:telemetry_event, [:kanban, :task, :completed], _, _}
      refute_receive {:telemetry_event, [:kanban, :task, :completed], _, _}
      refute_receive {:telemetry_event, [:kanban, :task, :review_changes_requested], _, _}
    end

    test "approving a goal's last child emits its goal events once, after the commit",
         %{column: column, user: user, board: board} do
      goal = task_fixture(column, %{title: "Goal", type: :goal})
      task = pending_task!(column, %{parent_id: goal.id})

      dependent =
        column
        |> task_fixture(%{title: "Waits on the reviewed task"})
        |> Ecto.Changeset.change(%{dependencies: [task.identifier], status: :blocked})
        |> Kanban.Repo.update!()

      events = [
        [:kanban, :goal, :completed],
        [:kanban, :task, :unblocked],
        [:kanban, :goal, :grace_window_scheduled]
      ]

      test_pid = self()
      handler_id = "reviews-goal-events-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          events,
          fn event, _measurements, metadata, _config ->
            send(test_pid, {:goal_event, event, metadata, Kanban.Repo.in_transaction?()})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)

      assert_receive {:goal_event, [:kanban, :goal, :completed], completed, false}
      assert completed == %{goal_id: goal.id, board_id: board.id}

      assert_receive {:goal_event, [:kanban, :task, :unblocked], unblocked, false}
      assert unblocked == %{task_id: dependent.id, board_id: board.id}

      assert_receive {:goal_event, [:kanban, :goal, :grace_window_scheduled], %{goal_id: goal_id},
                      false}

      assert goal_id == goal.id
      refute_receive {:goal_event, _event, _metadata, _in_transaction?}
    end

    test "approving a goal's last child in the review queue emits no after_goal_delivered",
         %{column: column, user: user} do
      goal = task_fixture(column, %{title: "Goal", type: :goal})
      task = pending_task!(column, %{parent_id: goal.id})
      Kanban.TelemetryHelpers.attach_telemetry([:kanban, :api, :after_goal_delivered])

      assert {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)

      # No API response carries the after_goal hook, so nothing was delivered.
      refute_receive {:telemetry_event, [:kanban, :api, :after_goal_delivered], _, _}
    end

    test "a refused approval emits no goal events", %{column: column} do
      goal = task_fixture(column, %{title: "Goal", type: :goal})
      task = pending_task!(column, %{parent_id: goal.id})
      outsider = Scope.for_user(user_fixture())

      attach_telemetry([
        [:kanban, :goal, :completed],
        [:kanban, :task, :unblocked],
        [:kanban, :goal, :grace_window_scheduled]
      ])

      assert {:error, _} = Reviews.approve_review(outsider, task)
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end

    test "approving a task whose goal has another open child emits no goal.completed",
         %{column: column, user: user} do
      goal = task_fixture(column, %{title: "Goal", type: :goal})
      task = pending_task!(column, %{parent_id: goal.id})
      _sibling = task_fixture(column, %{title: "Still open", parent_id: goal.id})
      attach_telemetry([:kanban, :goal, :completed])

      assert {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)
      refute_receive {:telemetry_event, [:kanban, :goal, :completed], _, _}
    end

    test "request_changes_review emits review_changes_requested without the notes",
         %{column: column, user: user, board: board} do
      task = pending_task!(column)
      attach_telemetry([:kanban, :task, :review_changes_requested])

      assert {:ok, _} =
               user
               |> Scope.for_user()
               |> Reviews.request_changes_review(task,
                 review_notes: "Please fix the flaky widget"
               )

      assert_receive {:telemetry_event, [:kanban, :task, :review_changes_requested], %{count: 1},
                      metadata}

      assert metadata == %{task_id: task.id, board_id: board.id, reviewer_user_id: user.id}
      refute inspect(metadata) =~ "flaky widget"
    end

    test "approve_review emits task.completed once, after the commit",
         %{column: column, user: user} do
      task = pending_task!(column)
      attach_in_order([[:kanban, :task, :completed], [:kanban, :task, :review_approved]])

      assert {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)

      assert [
               {[:kanban, :task, :completed], completed, false},
               {[:kanban, :task, :review_approved], %{task_id: task_id}, false}
             ] = received_in_order()

      assert completed == %{task_id: task.id, completed_by: user.id}
      assert task_id == task.id
    end

    test "approving a goal's last child emits task.completed with its goal events, in commit order",
         %{column: column, user: user} do
      goal = task_fixture(column, %{title: "Goal", type: :goal})
      task = pending_task!(column, %{parent_id: goal.id})
      dependent = blocked_dependent!(column, task)

      attach_in_order([
        [:kanban, :goal, :grace_window_scheduled],
        [:kanban, :task, :completed],
        [:kanban, :task, :unblocked],
        [:kanban, :goal, :completed],
        [:kanban, :task, :review_approved]
      ])

      assert {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)

      # task.completed leads even though the approval schedules the goal's
      # grace window before it finishes the task; the goal events follow in
      # the order they were caused, then review_approved.
      assert [
               {[:kanban, :task, :completed], %{task_id: completed_id}, false},
               {[:kanban, :goal, :grace_window_scheduled], %{goal_id: grace_goal_id}, false},
               {[:kanban, :task, :unblocked], %{task_id: unblocked_id}, false},
               {[:kanban, :goal, :completed], %{goal_id: completed_goal_id}, false},
               {[:kanban, :task, :review_approved], %{task_id: approved_id}, false}
             ] = received_in_order()

      assert grace_goal_id == goal.id
      assert completed_id == task.id
      assert unblocked_id == dependent.id
      assert completed_goal_id == goal.id
      assert approved_id == task.id
    end

    test "a rolled-back approval emits no task.completed", %{column: column, user: user} do
      goal = task_fixture(column, %{title: "Goal", type: :goal})
      task = pending_task!(column, %{parent_id: goal.id})
      dependent = blocked_dependent!(column, task)

      # Fails the approval after task.completed has been queued: unblocking the
      # dependent is the last write inside the review transaction. The trigger
      # is created inside the sandboxed test transaction, so it is rolled back
      # with it.
      Repo.query!("""
      CREATE FUNCTION kanban_reviews_test_refuse_unblock() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'unblock refused by test';
      END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER kanban_reviews_test_refuse_unblock BEFORE UPDATE ON tasks
      FOR EACH ROW WHEN (OLD.id = #{dependent.id})
      EXECUTE FUNCTION kanban_reviews_test_refuse_unblock()
      """)

      attach_telemetry([
        [:kanban, :task, :completed],
        [:kanban, :task, :unblocked],
        [:kanban, :task, :review_approved],
        [:kanban, :goal, :completed],
        [:kanban, :goal, :grace_window_scheduled]
      ])

      assert_raise Postgrex.Error, ~r/unblock refused by test/, fn ->
        user |> Scope.for_user() |> Reviews.approve_review(task)
      end

      refute_receive {:telemetry_event, _event, _measurements, _metadata}
      assert Repo.reload!(task).review_status != :approved

      # The process is no longer holding, so a later completion emits at once.
      Kanban.Tasks.TaskTelemetry.completed(task, user.id)
      assert_receive {:telemetry_event, [:kanban, :task, :completed], _, %{task_id: task_id}}
      assert task_id == task.id
    end

    test "a refused approval emits no task.completed",
         %{column: column, board: board, user: owner} do
      goal = task_fixture(column, %{title: "Goal", type: :goal})
      task = pending_task!(column, %{parent_id: goal.id})
      _dependent = blocked_dependent!(column, task)
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      attach_telemetry([
        [:kanban, :task, :completed],
        [:kanban, :task, :review_approved],
        [:kanban, :task, :unblocked],
        [:kanban, :goal, :completed],
        [:kanban, :goal, :grace_window_scheduled]
      ])

      assert {:error, :not_authorized} = Reviews.approve_review(nil, task)

      assert {:error, :not_found} =
               user_fixture() |> Scope.for_user() |> Reviews.approve_review(task)

      # A read-only member gets as far as the transaction and is refused there.
      assert {:error, :not_authorized} =
               reader |> Scope.for_user() |> Reviews.approve_review(task)

      refute_receive {:telemetry_event, _event, _measurements, _metadata}
      assert Repo.reload!(task).review_status == nil
    end

    test "approving a task whose dependent is already unblocked emits no task.unblocked",
         %{column: column, user: user} do
      task = pending_task!(column)

      _dependent =
        column
        |> task_fixture(%{title: "Already ready"})
        |> Ecto.Changeset.change(%{dependencies: [task.identifier], status: :open})
        |> Repo.update!()

      attach_telemetry([[:kanban, :task, :completed], [:kanban, :task, :unblocked]])

      assert {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)

      assert_receive {:telemetry_event, [:kanban, :task, :completed], _, %{task_id: task_id}}
      assert task_id == task.id
      refute_receive {:telemetry_event, _event, _measurements, _metadata}
    end

    test "request_changes_review emits only review_changes_requested, after the commit",
         %{column: column, user: user} do
      task = pending_task!(column)

      attach_in_order([
        [:kanban, :task, :completed],
        [:kanban, :task, :returned_to_doing],
        [:kanban, :task, :review_changes_requested]
      ])

      assert {:ok, _} =
               user
               |> Scope.for_user()
               |> Reviews.request_changes_review(task, review_notes: "Needs another pass")

      assert [{[:kanban, :task, :review_changes_requested], %{task_id: task_id}, false}] =
               received_in_order()

      assert task_id == task.id
    end

    # Documents a known limitation rather than desired behaviour: only the
    # review's own transaction is waited for, so an enclosing transaction that
    # rolls back afterwards does not take the emitted events back.
    test "inside an outer transaction that rolls back, the approval's events are still emitted",
         %{column: column, user: user} do
      task = pending_task!(column)
      attach_in_order([[:kanban, :task, :completed], [:kanban, :task, :review_approved]])

      assert {:error, :outer_rolled_back} =
               Repo.transaction(fn ->
                 {:ok, _} = user |> Scope.for_user() |> Reviews.approve_review(task)
                 Repo.rollback(:outer_rolled_back)
               end)

      assert [
               {[:kanban, :task, :completed], %{task_id: completed_id}, true},
               {[:kanban, :task, :review_approved], %{task_id: approved_id}, true}
             ] = received_in_order()

      assert completed_id == task.id
      assert approved_id == task.id
      assert Repo.reload!(task).review_status == nil
    end

    test "a refused review emits nothing", %{column: column} do
      task = pending_task!(column)

      attach_telemetry([
        [:kanban, :task, :review_approved],
        [:kanban, :task, :review_changes_requested]
      ])

      assert {:error, :not_authorized} = Reviews.approve_review(nil, task)
      outsider_scope = Scope.for_user(user_fixture())
      assert {:error, :not_found} = Reviews.approve_review(outsider_scope, task)

      assert {:error, :review_notes_required} =
               Reviews.request_changes_review(outsider_scope, task, [])

      refute_receive {:telemetry_event, _, _, _}
    end
  end
end
