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
end
