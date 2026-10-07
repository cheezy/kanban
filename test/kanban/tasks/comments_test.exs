defmodule Kanban.Tasks.CommentsTest do
  @moduledoc """
  Unit tests for the comment persistence extracted out of the task form
  LiveComponent so the web layer holds no Ecto queries (CODE-REVIEW.md,
  "LiveView / context boundary").
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.Comments
  alias Kanban.Tasks.TaskComment

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column, task: task_fixture(column)}
  end

  describe "create_comment/2" do
    test "creates a comment attached to the given task", %{task: task} do
      assert {:ok, comment} = Comments.create_comment(task.id, %{"content" => "Looks good"})

      assert comment.task_id == task.id
      assert comment.content == "Looks good"
    end

    test "returns an error changeset when content is blank", %{task: task} do
      assert {:error, changeset} = Comments.create_comment(task.id, %{"content" => ""})

      refute changeset.valid?
      assert %{content: [_ | _]} = errors_on(changeset)
    end

    test "ignores a client-supplied task_id so a comment cannot be redirected (D111)",
         %{task: task, column: column} do
      other_task = task_fixture(column)

      {:ok, comment} =
        Comments.create_comment(task.id, %{
          "content" => "Redirect attempt",
          "task_id" => other_task.id
        })

      assert comment.task_id == task.id
    end

    test "is reachable through the Tasks facade", %{task: task} do
      assert {:ok, comment} = Tasks.create_comment(task.id, %{"content" => "Via facade"})
      assert comment.task_id == task.id
    end
  end

  describe "get_task_with_comments!/1" do
    test "preloads comments newest-first", %{task: task} do
      {:ok, first} = Comments.create_comment(task.id, %{"content" => "First"})
      {:ok, second} = Comments.create_comment(task.id, %{"content" => "Second"})

      loaded = Tasks.get_task_with_comments!(task.id)

      assert Enum.map(loaded.comments, & &1.id) == [second.id, first.id]
    end

    test "returns a task with an empty comment list when there are none", %{task: task} do
      assert Tasks.get_task_with_comments!(task.id).comments == []
    end

    test "preloads each comment's author", %{task: task} do
      author = user_fixture()
      Repo.insert!(%TaskComment{task_id: task.id, author_user_id: author.id, content: "Mine"})
      Repo.insert!(%TaskComment{task_id: task.id, content: "Authorless"})

      [authorless, authored] = Tasks.get_task_with_comments!(task.id).comments

      assert authored.author.id == author.id
      assert authorless.author == nil
    end

    test "leaves the comment with a nil author after the author is deleted", %{task: task} do
      author = user_fixture()
      Repo.insert!(%TaskComment{task_id: task.id, author_user_id: author.id, content: "Orphaned"})

      assert {:ok, _} = Repo.delete(author)

      [comment] = Tasks.get_task_with_comments!(task.id).comments
      assert comment.content == "Orphaned"
      assert comment.author_user_id == nil
      assert comment.author == nil
    end
  end

  describe "comment author preloading on the read views" do
    setup %{task: task} do
      author = user_fixture()
      Repo.insert!(%TaskComment{task_id: task.id, author_user_id: author.id, content: "First"})
      Repo.insert!(%TaskComment{task_id: task.id, content: "Second"})
      %{author: author}
    end

    test "get_task_for_view!/1 preloads :author", %{task: task, author: author} do
      assert_authors(Tasks.get_task_for_view!(task.id).comments, author)
    end

    test "get_task_for_view/1 preloads :author", %{task: task, author: author} do
      assert_authors(Tasks.get_task_for_view(task.id).comments, author)
    end

    test "get_task_by_identifier_for_view/2 preloads :author",
         %{task: task, column: column, author: author} do
      loaded = Tasks.get_task_by_identifier_for_view(task.identifier, [column.id])
      assert_authors(loaded.comments, author)
    end

    # Both comments share an inserted_at second, so the asc ordering can tie;
    # look them up by content rather than relying on list position.
    defp assert_authors(comments, author) do
      by_content = Map.new(comments, &{&1.content, &1})
      assert map_size(by_content) == 2
      assert by_content["First"].author.id == author.id
      assert by_content["Second"].author == nil
    end
  end

  describe "list_goal_choices_for_board/2" do
    # task_fixture/2 assigns identifiers itself, so expectations are derived
    # from the persisted records rather than hardcoded.
    setup %{board: board, column: column} do
      first = task_fixture(column, %{type: :goal, title: "First goal"})
      second = task_fixture(column, %{type: :goal, title: "Second goal"})
      work = task_fixture(column, %{type: :work, title: "Some work"})

      %{board: board, first: first, second: second, work: work}
    end

    test "returns only goals, as {identifier, title, id} ordered by identifier",
         %{board: board, first: first, second: second} do
      expected =
        [
          {first.identifier, "First goal", first.id},
          {second.identifier, "Second goal", second.id}
        ]
        |> Enum.sort_by(&elem(&1, 0))

      assert Tasks.list_goal_choices_for_board(board.id, nil) == expected
    end

    test "excludes the given task so a goal is never its own parent",
         %{board: board, first: first, second: second} do
      choices = Tasks.list_goal_choices_for_board(board.id, first.id)

      assert choices == [{second.identifier, "Second goal", second.id}]
    end

    test "excludes archived goals", %{board: board, first: first, second: second} do
      {:ok, _archived} =
        second
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()

      assert Tasks.list_goal_choices_for_board(board.id, nil) == [
               {first.identifier, "First goal", first.id}
             ]
    end

    test "does not leak goals from another board", %{board: board, user: user} do
      other_column = column_fixture(board_fixture(user))
      other_goal = task_fixture(other_column, %{type: :goal, title: "Other board goal"})

      ids =
        board.id
        |> Tasks.list_goal_choices_for_board(nil)
        |> Enum.map(&elem(&1, 2))

      refute other_goal.id in ids
    end
  end
end
