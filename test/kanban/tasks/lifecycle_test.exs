defmodule Kanban.Tasks.LifecycleTest do
  @moduledoc """
  Tests for `Kanban.Tasks.Lifecycle` archive metadata write path
  introduced in W572 — `archive_task/2` persisting reason / note /
  duplicate_of_id / archived_by_id, and `unarchive_task/1` clearing
  the whole set so restored tasks look fully alive.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.Lifecycle
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  describe "archive_task/2 — no attrs (legacy call sites)" do
    test "stamps archived_at and leaves metadata nil", %{column: column} do
      task = task_fixture(column)

      assert {:ok, archived} = Lifecycle.archive_task(task)

      reloaded = Repo.get!(Task, archived.id)
      assert %DateTime{} = reloaded.archived_at
      assert reloaded.archive_reason == nil
      assert reloaded.archive_note == nil
      assert reloaded.archived_by_id == nil
      assert reloaded.duplicate_of_id == nil
    end

    test "archive_task/1 still works for legacy call sites that pass no attrs",
         %{column: column} do
      task = task_fixture(column)
      assert {:ok, _archived} = Lifecycle.archive_task(task)
    end

    test "broadcasts :task_updated on the task's board topic",
         %{column: column, board: board} do
      task = task_fixture(column)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      {:ok, _archived} = Lifecycle.archive_task(task)

      assert_receive {Kanban.Tasks, :task_updated, %Task{id: tid}}
      assert tid == task.id
    end
  end

  describe "archive_task/2 — with metadata" do
    test "persists archive_reason :completed with no note",
         %{column: column, user: user} do
      task = task_fixture(column)

      {:ok, archived} =
        Lifecycle.archive_task(task, %{
          archive_reason: :completed,
          archived_by_id: user.id
        })

      reloaded = Repo.get!(Task, archived.id)
      assert reloaded.archive_reason == :completed
      assert reloaded.archived_by_id == user.id
      assert reloaded.archive_note == nil
    end

    test "persists archive_reason :wontdo with an archive_note",
         %{column: column, user: user} do
      task = task_fixture(column)

      {:ok, archived} =
        Lifecycle.archive_task(task, %{
          archive_reason: :wontdo,
          archive_note: "Out of scope for this milestone.",
          archived_by_id: user.id
        })

      reloaded = Repo.get!(Task, archived.id)
      assert reloaded.archive_reason == :wontdo
      assert reloaded.archive_note == "Out of scope for this milestone."
    end

    test "persists archive_reason :duplicate with duplicate_of_id",
         %{column: column, user: user} do
      canonical = task_fixture(column)
      task = task_fixture(column)

      {:ok, archived} =
        Lifecycle.archive_task(task, %{
          archive_reason: :duplicate,
          duplicate_of_id: canonical.id,
          archived_by_id: user.id
        })

      reloaded = Repo.get!(Task, archived.id)
      assert reloaded.archive_reason == :duplicate
      assert reloaded.duplicate_of_id == canonical.id
    end
  end

  describe "archive_task/2 — validation" do
    test "rejects :wontdo without an archive_note", %{column: column, user: user} do
      task = task_fixture(column)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Lifecycle.archive_task(task, %{
                 archive_reason: :wontdo,
                 archived_by_id: user.id
               })

      assert errors_on(changeset).archive_note != []

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.archived_at == nil
    end

    test "rejects :duplicate without a duplicate_of_id",
         %{column: column, user: user} do
      task = task_fixture(column)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Lifecycle.archive_task(task, %{
                 archive_reason: :duplicate,
                 archived_by_id: user.id
               })

      assert errors_on(changeset).duplicate_of_id != []
    end

    test "rejects an unknown archive_reason atom", %{column: column} do
      task = task_fixture(column)

      assert {:error, %Ecto.Changeset{}} =
               Lifecycle.archive_task(task, %{archive_reason: :nonsense})
    end
  end

  describe "unarchive_task/1" do
    test "clears archived_at and every archive-metadata field",
         %{column: column, user: user} do
      task = task_fixture(column)

      {:ok, archived} =
        Lifecycle.archive_task(task, %{
          archive_reason: :wontdo,
          archive_note: "test note",
          archived_by_id: user.id
        })

      assert archived.archived_at != nil
      assert archived.archive_reason == :wontdo

      {:ok, restored} = Lifecycle.unarchive_task(archived)
      reloaded = Repo.get!(Task, restored.id)

      assert reloaded.archived_at == nil
      assert reloaded.archive_reason == nil
      assert reloaded.archive_note == nil
      assert reloaded.archived_by_id == nil
      assert reloaded.duplicate_of_id == nil
    end

    test "broadcasts :task_updated on the task's board topic",
         %{column: column, board: board} do
      task = task_fixture(column)
      {:ok, archived} = Lifecycle.archive_task(task)

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")
      {:ok, _restored} = Lifecycle.unarchive_task(archived)

      assert_receive {Kanban.Tasks, :task_updated, %Task{id: tid}}
      assert tid == task.id
    end
  end

  describe "archive_task/2 — cascade to children when archiving a goal" do
    setup %{column: column} do
      goal = task_fixture(column, %{type: :goal, title: "Test Goal"})

      child_a =
        task_fixture(column, %{
          type: :work,
          parent_id: goal.id,
          title: "Child A"
        })

      child_b =
        task_fixture(column, %{
          type: :defect,
          parent_id: goal.id,
          title: "Child B"
        })

      # An already-archived child should NOT be re-archived (its existing
      # archive metadata stays intact).
      pre_archived =
        task_fixture(column, %{
          type: :work,
          parent_id: goal.id,
          title: "Pre-archived child"
        })

      {:ok, pre_archived} =
        Lifecycle.archive_task(pre_archived, %{archive_reason: :completed})

      %{
        goal: goal,
        child_a: child_a,
        child_b: child_b,
        pre_archived: pre_archived
      }
    end

    test "archives all non-archived children when the goal is archived with no attrs",
         %{goal: goal, child_a: child_a, child_b: child_b} do
      assert {:ok, _archived_goal} = Lifecycle.archive_task(goal)

      reloaded_a = Repo.get!(Task, child_a.id)
      reloaded_b = Repo.get!(Task, child_b.id)

      assert %DateTime{} = reloaded_a.archived_at
      assert %DateTime{} = reloaded_b.archived_at
      # No parent reason → children default to :completed (matches the
      # "if no reason provided, mark as :completed" product rule).
      assert reloaded_a.archive_reason == :completed
      assert reloaded_b.archive_reason == :completed
      assert reloaded_a.archive_note == nil
      assert reloaded_b.archive_note == nil
    end

    test "children inherit parent's reason when reason is :completed",
         %{goal: goal, user: user, child_a: child_a} do
      {:ok, _archived_goal} =
        Lifecycle.archive_task(goal, %{
          archive_reason: :completed,
          archived_by_id: user.id
        })

      reloaded_a = Repo.get!(Task, child_a.id)
      assert reloaded_a.archive_reason == :completed
      assert reloaded_a.archived_by_id == user.id
    end

    test "children inherit parent's :wontdo reason AND note",
         %{goal: goal, child_a: child_a, child_b: child_b} do
      {:ok, _archived_goal} =
        Lifecycle.archive_task(goal, %{
          archive_reason: :wontdo,
          archive_note: "Pivoting away from this initiative."
        })

      reloaded_a = Repo.get!(Task, child_a.id)
      reloaded_b = Repo.get!(Task, child_b.id)

      assert reloaded_a.archive_reason == :wontdo
      assert reloaded_a.archive_note == "Pivoting away from this initiative."
      assert reloaded_b.archive_reason == :wontdo
      assert reloaded_b.archive_note == "Pivoting away from this initiative."
    end

    test "children inherit parent's :deferred reason AND note",
         %{goal: goal, child_a: child_a} do
      {:ok, _archived_goal} =
        Lifecycle.archive_task(goal, %{
          archive_reason: :deferred,
          archive_note: "Punted to next quarter."
        })

      reloaded_a = Repo.get!(Task, child_a.id)
      assert reloaded_a.archive_reason == :deferred
      assert reloaded_a.archive_note == "Punted to next quarter."
    end

    test "children default to :completed (not :duplicate) when parent is :duplicate",
         %{column: column, goal: goal, child_a: child_a} do
      canonical = task_fixture(column, %{type: :goal, title: "Canonical goal"})

      {:ok, _archived_goal} =
        Lifecycle.archive_task(goal, %{
          archive_reason: :duplicate,
          duplicate_of_id: canonical.id
        })

      reloaded_a = Repo.get!(Task, child_a.id)
      assert reloaded_a.archive_reason == :completed
      # Children must NEVER inherit duplicate_of_id — they are not
      # duplicates of whatever the parent goal was a duplicate of.
      assert reloaded_a.duplicate_of_id == nil
    end

    test "leaves already-archived children alone",
         %{goal: goal, pre_archived: pre_archived} do
      original_archived_at = pre_archived.archived_at
      original_reason = pre_archived.archive_reason

      {:ok, _archived_goal} =
        Lifecycle.archive_task(goal, %{archive_reason: :wontdo, archive_note: "stale"})

      reloaded = Repo.get!(Task, pre_archived.id)
      assert reloaded.archived_at == original_archived_at
      assert reloaded.archive_reason == original_reason
      # Pre-archived child must NOT inherit the new :wontdo note that
      # was supplied for this archive call.
      assert reloaded.archive_note == nil
    end

    test "does NOT cascade for non-goal tasks", %{column: column} do
      parent_work = task_fixture(column, %{type: :work})

      child =
        task_fixture(column, %{
          type: :work,
          parent_id: parent_work.id
        })

      {:ok, _archived} = Lifecycle.archive_task(parent_work)

      reloaded_child = Repo.get!(Task, child.id)
      assert reloaded_child.archived_at == nil
    end

    test "atomic transaction — failure on parent rolls back the whole archive",
         %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      _child =
        task_fixture(column, %{
          type: :work,
          parent_id: goal.id
        })

      # :wontdo without an archive_note must fail validation on the
      # parent, and the children must remain un-archived (transaction
      # rolled back).
      assert {:error, %Ecto.Changeset{}} =
               Lifecycle.archive_task(goal, %{archive_reason: :wontdo})

      reloaded_goal = Repo.get!(Task, goal.id)
      assert reloaded_goal.archived_at == nil
    end

    test "broadcasts :task_updated for parent goal AND each cascade-archived child",
         %{goal: goal, board: board, child_a: child_a, child_b: child_b} do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      {:ok, _archived_goal} = Lifecycle.archive_task(goal)

      goal_id = goal.id
      child_a_id = child_a.id
      child_b_id = child_b.id

      assert_receive {Kanban.Tasks, :task_updated, %Task{id: ^goal_id}}
      assert_receive {Kanban.Tasks, :task_updated, %Task{id: ^child_a_id}}
      assert_receive {Kanban.Tasks, :task_updated, %Task{id: ^child_b_id}}
    end
  end

  describe "update_changed_files/2 — D36 nil rejection" do
    test "raises FunctionClauseError when given nil", %{column: column} do
      task = task_fixture(column)

      assert_raise FunctionClauseError, fn ->
        Lifecycle.update_changed_files(task, nil)
      end
    end

    test "accepts an empty list (explicit clear)", %{column: column} do
      task = task_fixture(column)
      assert {:ok, %Task{changed_files: []}} = Lifecycle.update_changed_files(task, [])
    end

    test "accepts a populated list", %{column: column} do
      task = task_fixture(column)
      entry = %{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-old\n+new"}
      assert {:ok, %Task{changed_files: [^entry]}} = Lifecycle.update_changed_files(task, [entry])
    end
  end
end
