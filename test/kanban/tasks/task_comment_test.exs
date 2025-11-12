defmodule Kanban.Tasks.TaskCommentTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks.TaskComment

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      task = insert_task()

      attrs = %{
        content: "This is a comment",
        task_id: task.id
      }

      changeset = TaskComment.changeset(%TaskComment{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :content) == "This is a comment"
      assert get_change(changeset, :task_id) == task.id
    end

    test "invalid changeset when content is missing" do
      task = insert_task()

      attrs = %{task_id: task.id}

      changeset = TaskComment.changeset(%TaskComment{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).content
    end

    test "invalid changeset when task_id is missing" do
      attrs = %{content: "This is a comment"}

      changeset = TaskComment.changeset(%TaskComment{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
    end

    test "invalid changeset when task_id does not exist" do
      attrs = %{
        content: "This is a comment",
        task_id: -1
      }

      changeset = TaskComment.changeset(%TaskComment{}, attrs)

      assert changeset.valid?

      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).task_id
    end
  end

  describe "associations" do
    test "belongs_to task" do
      task = insert_task()

      {:ok, comment} =
        %TaskComment{}
        |> TaskComment.changeset(%{content: "Test comment", task_id: task.id})
        |> Repo.insert()

      comment = Repo.preload(comment, :task)

      assert comment.task.id == task.id
    end

    test "task has_many comments" do
      task = insert_task()

      {:ok, comment1} =
        %TaskComment{}
        |> TaskComment.changeset(%{content: "First comment", task_id: task.id})
        |> Repo.insert()

      {:ok, comment2} =
        %TaskComment{}
        |> TaskComment.changeset(%{content: "Second comment", task_id: task.id})
        |> Repo.insert()

      task = Repo.preload(task, :comments)

      assert length(task.comments) == 2
      assert Enum.any?(task.comments, fn c -> c.id == comment1.id end)
      assert Enum.any?(task.comments, fn c -> c.id == comment2.id end)
    end

    test "deleting a task deletes its comments" do
      task = insert_task()

      {:ok, comment} =
        %TaskComment{}
        |> TaskComment.changeset(%{content: "Test comment", task_id: task.id})
        |> Repo.insert()

      Repo.delete(task)

      assert Repo.get(TaskComment, comment.id) == nil
    end
  end

  describe "timestamps" do
    test "inserted_at and updated_at are set automatically" do
      task = insert_task()

      {:ok, comment} =
        %TaskComment{}
        |> TaskComment.changeset(%{content: "Test comment", task_id: task.id})
        |> Repo.insert()

      assert comment.inserted_at
      assert comment.updated_at
    end
  end

  defp insert_task do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    task_fixture(column)
  end
end
