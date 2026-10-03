defmodule Kanban.ReviewsTest do
  @moduledoc """
  Tests for `Kanban.Reviews` — the read API for the workspace Review
  Queue at `/review`.
  """
  use Kanban.DataCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
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
end
