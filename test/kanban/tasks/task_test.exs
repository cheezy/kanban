defmodule Kanban.Tasks.TaskTest do
  @moduledoc """
  Changeset validation tests for `Kanban.Tasks.Task` archive-metadata
  fields introduced in W570 — `archive_reason`, `archive_note`,
  `archived_by_id`, `duplicate_of_id`.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  # Only includes archive-related casts. Required base fields (title,
  # position, type, priority, status) are already set on the persisted
  # task by the fixture, so validate_required/2 reads them via get_field/2
  # without us re-casting and risking the unique [column_id, position]
  # constraint when we later persist via Repo.update/1.
  defp base_attrs(overrides), do: overrides

  describe "archive_reason field" do
    test "accepts :completed with no archive_note", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: :completed}))
      assert changeset.valid?
      assert get_change(changeset, :archive_reason) == :completed
    end

    test "accepts a nil archive_reason (legacy archived rows)", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: nil}))
      assert changeset.valid?
    end

    test "rejects unknown archive_reason atom via Ecto.Enum", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: :nonsense}))

      refute changeset.valid?
      assert errors_on(changeset).archive_reason != []
    end
  end

  describe "archive_note required for :wontdo / :deferred / :cancelled" do
    for reason <- [:wontdo, :deferred, :cancelled] do
      @reason reason

      test "#{@reason} requires archive_note", %{column: column} do
        task = task_fixture(column)

        changeset = Task.changeset(task, base_attrs(%{archive_reason: @reason}))

        refute changeset.valid?

        assert "must be set when archive_reason is :wontdo, :deferred, or :cancelled" in errors_on(
                 changeset
               ).archive_note
      end

      test "#{@reason} accepts a present archive_note", %{column: column} do
        task = task_fixture(column)

        changeset =
          Task.changeset(
            task,
            base_attrs(%{archive_reason: @reason, archive_note: "Out of scope for v1."})
          )

        assert changeset.valid?
      end

      test "#{@reason} treats whitespace-only archive_note as missing", %{column: column} do
        task = task_fixture(column)

        changeset =
          Task.changeset(task, base_attrs(%{archive_reason: @reason, archive_note: "   \n"}))

        refute changeset.valid?
        assert errors_on(changeset).archive_note != []
      end
    end
  end

  describe "duplicate_of_id required for :duplicate" do
    test "requires duplicate_of_id when archive_reason is :duplicate", %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archive_reason: :duplicate}))

      refute changeset.valid?

      assert "must be set when archive_reason is :duplicate" in errors_on(changeset).duplicate_of_id
    end

    test "accepts a present duplicate_of_id when archive_reason is :duplicate",
         %{column: column} do
      canonical = task_fixture(column)
      task = task_fixture(column)

      changeset =
        Task.changeset(
          task,
          base_attrs(%{archive_reason: :duplicate, duplicate_of_id: canonical.id})
        )

      assert changeset.valid?
    end
  end

  describe "duplicate_of_id forbidden for non-:duplicate reasons" do
    for reason <- [:completed, :wontdo, :deferred, :cancelled] do
      @reason reason

      test "#{@reason} rejects a non-nil duplicate_of_id", %{column: column} do
        canonical = task_fixture(column)
        task = task_fixture(column)

        attrs =
          base_attrs(%{
            archive_reason: @reason,
            archive_note: "Some note",
            duplicate_of_id: canonical.id
          })

        changeset = Task.changeset(task, attrs)

        refute changeset.valid?

        assert "may only be set when archive_reason is :duplicate" in errors_on(changeset).duplicate_of_id
      end
    end
  end

  describe "self-reference check constraint" do
    test "rejects a task that marks itself as its own duplicate", %{column: column} do
      task = task_fixture(column)

      changeset =
        Task.changeset(task, base_attrs(%{archive_reason: :duplicate, duplicate_of_id: task.id}))

      assert {:error, %Ecto.Changeset{} = errored} = Repo.update(changeset)

      assert "must not reference the task itself" in errors_on(errored).duplicate_of_id
    end
  end

  describe "archived_by foreign key" do
    test "accepts a valid archived_by_id pointing at a user",
         %{column: column, user: user} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archived_by_id: user.id}))
      assert changeset.valid?
      assert {:ok, persisted} = Repo.update(changeset)
      assert persisted.archived_by_id == user.id
    end

    test "rejects an archived_by_id that does not point at a real user",
         %{column: column} do
      task = task_fixture(column)

      changeset = Task.changeset(task, base_attrs(%{archived_by_id: 99_999_999}))
      assert {:error, %Ecto.Changeset{} = errored} = Repo.update(changeset)
      assert errors_on(errored).archived_by_id != []
    end
  end

  describe "associations" do
    test "belongs_to :archived_by loads the persisted user", %{column: column, user: user} do
      task = task_fixture(column)

      {:ok, updated} =
        task
        |> Task.changeset(base_attrs(%{archived_by_id: user.id}))
        |> Repo.update()

      loaded = Repo.preload(updated, :archived_by)
      assert loaded.archived_by.id == user.id
    end

    test "belongs_to :duplicate_of loads the canonical task", %{column: column} do
      canonical = task_fixture(column)
      task = task_fixture(column)

      {:ok, updated} =
        task
        |> Task.changeset(
          base_attrs(%{archive_reason: :duplicate, duplicate_of_id: canonical.id})
        )
        |> Repo.update()

      loaded = Repo.preload(updated, :duplicate_of)
      assert loaded.duplicate_of.id == canonical.id
    end
  end
end
