defmodule Kanban.Attachments.BlobDeletionTriggerTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Archives.Retention
  alias Kanban.Attachments.BlobDeletion
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    task = task_fixture(column)

    %{user: user, board: board, column: column, task: task}
  end

  defp comment_fixture(task) do
    Repo.insert!(%TaskComment{task_id: task.id, content: "comment #{System.unique_integer()}"})
  end

  defp tombstones(keys) do
    BlobDeletion
    |> where([d], d.storage_key in ^keys)
    |> select([d], d.storage_key)
    |> Repo.all()
    |> Enum.sort()
  end

  defp attachment_exists?(attachment), do: Repo.get(TaskAttachment, attachment.id) != nil

  test "deleting an attachment row records its storage key", %{task: task} do
    attachment = attachment_fixture(task)
    other = attachment_fixture(task)

    Repo.delete!(attachment)

    assert [tombstone] =
             BlobDeletion |> where([d], d.storage_key == ^attachment.storage_key) |> Repo.all()

    assert tombstone.storage_key == attachment.storage_key
    assert tombstone.attempts == 0
    assert tombstone.last_error == nil
    assert %DateTime{} = tombstone.delete_after
    assert DateTime.diff(DateTime.utc_now(), tombstone.delete_after, :second) in 0..60
    assert %DateTime{} = tombstone.inserted_at

    assert tombstones([other.storage_key]) == []
    assert attachment_exists?(other)
  end

  test "deleting the task cascades and records every key", %{task: task, column: column} do
    attachments = for _ <- 1..3, do: attachment_fixture(task)
    survivor = attachment_fixture(task_fixture(column))
    keys = Enum.map(attachments, & &1.storage_key)

    Task |> Repo.get!(task.id) |> Repo.delete!()

    assert tombstones(keys) == Enum.sort(keys)
    refute Enum.any?(attachments, &attachment_exists?/1)
    assert attachment_exists?(survivor)
    assert tombstones([survivor.storage_key]) == []
  end

  test "deleting a comment cascades only that comment's attachments", %{task: task} do
    comment = comment_fixture(task)
    on_comment = attachment_fixture(task, %{comment: comment})
    on_task = attachment_fixture(task)

    Repo.delete!(comment)

    assert tombstones([on_comment.storage_key, on_task.storage_key]) == [on_comment.storage_key]
    refute attachment_exists?(on_comment)
    assert attachment_exists?(on_task)
    assert Repo.get(Task, task.id)
  end

  test "deleting the board records keys for all its attachments", %{
    user: user,
    board: board,
    column: column,
    task: task
  } do
    second_task = task_fixture(column_fixture(board))
    comment = comment_fixture(task)

    attachments = [
      attachment_fixture(task),
      attachment_fixture(task, %{comment: comment}),
      attachment_fixture(second_task)
    ]

    other_board_task = user |> board_fixture() |> column_fixture() |> task_fixture()
    survivor = attachment_fixture(other_board_task)
    keys = Enum.map(attachments, & &1.storage_key)

    Repo.delete!(board)

    # A row reached through both board_id and its task's cascade is still
    # deleted once, so each key is queued exactly once.
    assert tombstones(keys) == Enum.sort(keys)
    assert BlobDeletion |> where([d], d.storage_key in ^keys) |> Repo.aggregate(:count) == 3
    refute Enum.any?(attachments, &attachment_exists?/1)
    assert attachment_exists?(survivor)
    assert column.board_id == board.id
  end

  test "a bulk delete_all queues every deleted row", %{task: task} do
    attachments = for _ <- 1..2, do: attachment_fixture(task)
    keys = Enum.map(attachments, & &1.storage_key)

    assert {2, _} = TaskAttachment |> where([a], a.task_id == ^task.id) |> Repo.delete_all()

    assert tombstones(keys) == Enum.sort(keys)
  end

  test "the archived-task retention purge queues every attachment of a purged task", %{
    task: task,
    column: column
  } do
    attachments = for _ <- 1..2, do: attachment_fixture(task)
    kept = attachment_fixture(task_fixture(column))
    keys = Enum.map(attachments, & &1.storage_key)
    archived_at = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)

    Task |> where([t], t.id == ^task.id) |> Repo.update_all(set: [archived_at: archived_at])

    assert {1, _batches} = Retention.purge_archived_before(DateTime.utc_now(), 100)

    assert tombstones(keys) == Enum.sort(keys)
    assert tombstones([kept.storage_key]) == []
    assert attachment_exists?(kept)
  end

  test "deleting the uploader nilifies uploaded_by_id and keeps the row", %{task: task} do
    uploader = user_fixture()
    attachment = attachment_fixture(task, %{uploaded_by: uploader})
    assert attachment.uploaded_by_id == uploader.id

    Repo.delete!(uploader)

    reloaded = Repo.get!(TaskAttachment, attachment.id)
    assert reloaded.uploaded_by_id == nil
    assert reloaded.storage_key == attachment.storage_key
    assert tombstones([attachment.storage_key]) == []
  end

  test "a duplicate storage_key is refused by the unique index", %{task: task} do
    attachment = attachment_fixture(task)

    assert_raise Ecto.ConstraintError, ~r/task_attachments_storage_key_index/, fn ->
      attachment_fixture(task, %{storage_key: attachment.storage_key})
    end

    changeset =
      %TaskAttachment{
        task_id: task.id,
        board_id: attachment.board_id,
        storage_key: attachment.storage_key
      }
      |> TaskAttachment.create_changeset(
        %{
          "filename" => "dup.txt",
          "content_type" => "text/plain",
          "byte_size" => 3,
          "sha256" => attachment.sha256
        },
        "dup"
      )

    assert {:error, changeset} = Repo.insert(changeset)
    assert %{storage_key: ["has already been taken"]} = errors_on(changeset)
  end

  test "the database refuses a non-positive byte_size", %{task: task} do
    assert_raise Ecto.ConstraintError, ~r/byte_size_positive/, fn ->
      attachment_fixture(task, %{byte_size: 0})
    end
  end

  test "create_changeset/3 inserts a row the trigger later queues", %{task: task, user: user} do
    attachment = attachment_fixture(task)

    {:ok, inserted} =
      %TaskAttachment{
        task_id: task.id,
        board_id: attachment.board_id,
        uploaded_by_id: user.id,
        storage_key: unique_storage_key(attachment.board_id)
      }
      |> TaskAttachment.create_changeset(
        %{
          "filename" => "notes.md",
          "content_type" => "",
          "byte_size" => 7,
          "sha256" => attachment.sha256
        },
        "# notes"
      )
      |> Repo.insert()

    assert inserted.content_type == "text/markdown"
    Repo.delete!(inserted)
    assert tombstones([inserted.storage_key]) == [inserted.storage_key]
  end

  test "BlobDeletion.changeset/2 parks a tombstone with a later delete_after" do
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, parked} =
      %BlobDeletion{}
      |> BlobDeletion.changeset(%{storage_key: "boards/1/pending", delete_after: later})
      |> Repo.insert()

    assert parked.delete_after == later
    assert parked.attempts == 0

    refute BlobDeletion.changeset(%BlobDeletion{}, %{}).valid?

    assert %{storage_key: [_]} =
             errors_on(
               BlobDeletion.changeset(%BlobDeletion{}, %{storage_key: String.duplicate("a", 513)})
             )
  end

  test "preloads attachments through Task and TaskComment associations", %{task: task} do
    comment = comment_fixture(task)
    on_task = attachment_fixture(task)
    on_comment = attachment_fixture(task, %{comment: comment})

    loaded_task = Task |> Repo.get!(task.id) |> Repo.preload(:attachments)

    assert loaded_task.attachments |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([on_task.id, on_comment.id])

    loaded_comment = TaskComment |> Repo.get!(comment.id) |> Repo.preload(:attachments)
    assert Enum.map(loaded_comment.attachments, & &1.id) == [on_comment.id]

    attachment =
      TaskAttachment |> Repo.get!(on_comment.id) |> Repo.preload([:task, :comment, :board])

    assert attachment.task.id == task.id
    assert attachment.comment.id == comment.id
    assert attachment.board.id == attachment.board_id
  end
end
