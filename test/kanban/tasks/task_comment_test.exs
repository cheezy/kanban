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

      # D111: task_id is set on the struct server-side, not cast from attrs.
      changeset =
        TaskComment.changeset(%TaskComment{task_id: task.id}, %{content: "This is a comment"})

      assert changeset.valid?
      assert get_change(changeset, :content) == "This is a comment"
      assert get_field(changeset, :task_id) == task.id
      # A client-supplied task_id in attrs is ignored (not cast).
      refute get_change(TaskComment.changeset(%TaskComment{}, %{task_id: 999}), :task_id)
    end

    test "invalid changeset when content is missing" do
      task = insert_task()

      changeset = TaskComment.changeset(%TaskComment{task_id: task.id}, %{})

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
      # D111: task_id set on the struct; the FK constraint still catches a
      # nonexistent task at insert time.
      changeset =
        TaskComment.changeset(%TaskComment{task_id: -1}, %{content: "This is a comment"})

      assert changeset.valid?

      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).task_id
    end

    test "accepts content at exactly the maximum length" do
      task = insert_task()
      content = String.duplicate("a", TaskComment.content_max_length())

      changeset = TaskComment.changeset(%TaskComment{task_id: task.id}, %{content: content})

      assert TaskComment.content_max_length() == 10_000
      assert changeset.valid?
    end

    test "counts the content cap in codepoints, not graphemes" do
      task = insert_task()
      # One grapheme cluster of 1 + 100 codepoints: 10,000 of them would be
      # 1,010,000 codepoints, far past the cap.
      cluster = "e" <> String.duplicate("\u0301", 100)
      content = String.duplicate(cluster, 100)

      changeset = TaskComment.changeset(%TaskComment{task_id: task.id}, %{content: content})

      refute changeset.valid?
      assert %{content: [_]} = errors_on(changeset)
    end

    test "rejects content with a NUL character" do
      task = insert_task()

      changeset = TaskComment.changeset(%TaskComment{task_id: task.id}, %{content: "a\u0000b"})

      assert "is invalid" in errors_on(changeset).content
    end

    test "treats content of only invisible format characters as blank" do
      task = insert_task()

      for content <- ["\u200b", "\u200e\u202e", " \ufeff "] do
        changeset = TaskComment.changeset(%TaskComment{task_id: task.id}, %{content: content})
        assert errors_on(changeset).content == ["can't be blank"], inspect(content)
      end

      visible = TaskComment.changeset(%TaskComment{task_id: task.id}, %{content: "\u200bok"})
      assert visible.valid?
    end

    test "rejects content longer than the maximum length" do
      task = insert_task()
      content = String.duplicate("a", TaskComment.content_max_length() + 1)

      changeset = TaskComment.changeset(%TaskComment{task_id: task.id}, %{content: content})

      refute changeset.valid?
      assert "should be at most 10000 character(s)" in errors_on(changeset).content
    end

    test "ignores author_user_id, author_agent_name and mentioned_user_ids in attrs" do
      task = insert_task()
      other_user = user_fixture()

      changeset =
        TaskComment.changeset(%TaskComment{task_id: task.id}, %{
          "content" => "Impersonation attempt",
          "author_user_id" => other_user.id,
          "author_agent_name" => "Spoofed Agent",
          "mentioned_user_ids" => [other_user.id]
        })

      assert changeset.valid?
      refute get_change(changeset, :author_user_id)
      refute get_change(changeset, :author_agent_name)
      refute get_change(changeset, :mentioned_user_ids)
      assert get_field(changeset, :author_user_id) == nil
      assert get_field(changeset, :author_agent_name) == nil
      assert get_field(changeset, :mentioned_user_ids) == []
    end
  end

  describe "associations" do
    test "belongs_to task" do
      task = insert_task()

      {:ok, comment} =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Test comment"})
        |> Repo.insert()

      comment = Repo.preload(comment, :task)

      assert comment.task.id == task.id
    end

    test "task has_many comments" do
      task = insert_task()

      {:ok, comment1} =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "First comment"})
        |> Repo.insert()

      {:ok, comment2} =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Second comment"})
        |> Repo.insert()

      task = Repo.preload(task, :comments)

      assert length(task.comments) == 2
      assert Enum.any?(task.comments, fn c -> c.id == comment1.id end)
      assert Enum.any?(task.comments, fn c -> c.id == comment2.id end)
    end

    test "deleting a task deletes its comments" do
      task = insert_task()

      {:ok, comment} =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Test comment"})
        |> Repo.insert()

      Repo.delete(task)

      assert Repo.get(TaskComment, comment.id) == nil
    end
  end

  describe "authorship columns" do
    test "a struct built with author_user_id set persists that author" do
      task = insert_task()
      author = user_fixture()

      comment =
        %TaskComment{task_id: task.id, author_user_id: author.id}
        |> TaskComment.changeset(%{content: "Authored comment"})
        |> Repo.insert!()
        |> Repo.preload(:author)

      assert comment.author_user_id == author.id
      assert comment.author.id == author.id
      assert Repo.get!(TaskComment, comment.id).author_user_id == author.id
    end

    test "persists an author_agent_name of exactly 255 characters" do
      task = insert_task()
      agent_name = String.duplicate("a", 255)

      comment =
        %TaskComment{task_id: task.id, author_agent_name: agent_name}
        |> TaskComment.changeset(%{content: "Posted via the API"})
        |> Repo.insert!()

      assert Repo.get!(TaskComment, comment.id).author_agent_name == agent_name
    end

    test "persists edited_at and mentioned_user_ids set on the struct" do
      task = insert_task()
      mentioned = user_fixture()
      edited_at = DateTime.utc_now(:second)

      comment =
        %TaskComment{task_id: task.id, edited_at: edited_at, mentioned_user_ids: [mentioned.id]}
        |> TaskComment.changeset(%{content: "Hey @someone"})
        |> Repo.insert!()

      reloaded = Repo.get!(TaskComment, comment.id)
      assert reloaded.edited_at == edited_at
      assert reloaded.mentioned_user_ids == [mentioned.id]
    end

    test "a comment without an author keeps nil author fields and empty mentions" do
      task = insert_task()

      {:ok, comment} =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Legacy-style comment"})
        |> Repo.insert()

      reloaded = Repo.get!(TaskComment, comment.id) |> Repo.preload(:author)
      assert reloaded.author_user_id == nil
      assert reloaded.author == nil
      assert reloaded.author_agent_name == nil
      assert reloaded.edited_at == nil
      assert reloaded.mentioned_user_ids == []
    end

    test "a row inserted without mentioned_user_ids gets the empty-array database default" do
      task = insert_task()

      %{rows: [[id]]} =
        Repo.query!(
          "INSERT INTO task_comments (content, task_id, inserted_at, updated_at) " <>
            "VALUES ($1, $2, now(), now()) RETURNING id",
          ["Row written without the new columns", task.id]
        )

      comment = Repo.get!(TaskComment, id)
      assert comment.mentioned_user_ids == []
      assert comment.author_user_id == nil
    end

    test "mentioned_user_ids rejects NULL at the database level" do
      task = insert_task()

      assert_raise Postgrex.Error, ~r/not_null_violation|null value/, fn ->
        Repo.query!(
          "INSERT INTO task_comments (content, task_id, mentioned_user_ids, inserted_at, updated_at) " <>
            "VALUES ($1, $2, NULL, now(), now())",
          ["Null mentions", task.id]
        )
      end
    end

    test "deleting the author nilifies author_user_id instead of deleting the comment" do
      task = insert_task()
      author = user_fixture()

      comment =
        %TaskComment{task_id: task.id, author_user_id: author.id}
        |> TaskComment.changeset(%{content: "Will outlive its author"})
        |> Repo.insert!()

      assert {:ok, _} = Repo.delete(author)

      reloaded = Repo.get(TaskComment, comment.id)
      assert reloaded
      assert reloaded.author_user_id == nil
      assert reloaded.content == "Will outlive its author"
    end

    test "an author_user_id that does not exist is rejected by the foreign key" do
      task = insert_task()

      assert {:error, changeset} =
               %TaskComment{task_id: task.id, author_user_id: -1}
               |> TaskComment.changeset(%{content: "Ghost author"})
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).author_user_id
    end
  end

  describe "timestamps" do
    test "inserted_at and updated_at are set automatically" do
      task = insert_task()

      {:ok, comment} =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Test comment"})
        |> Repo.insert()

      assert comment.inserted_at
      assert comment.updated_at
    end
  end

  describe "put_author_agent_name/2" do
    test "puts the name as a change and accepts 255 characters" do
      task = insert_task()
      name = String.duplicate("a", 255)

      changeset =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Hi"})
        |> TaskComment.put_author_agent_name(name)

      assert changeset.valid?
      assert get_change(changeset, :author_agent_name) == name
    end

    test "rejects a name over 255 characters, counted in codepoints" do
      task = insert_task()

      too_long =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Hi"})
        |> TaskComment.put_author_agent_name(String.duplicate("é", 256))

      refute too_long.valid?
      assert %{author_agent_name: [_]} = errors_on(too_long)

      fits =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Hi"})
        |> TaskComment.put_author_agent_name(String.duplicate("é", 255))

      assert fits.valid?
    end

    test "rejects a name with a NUL character" do
      task = insert_task()

      changeset =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Hi"})
        |> TaskComment.put_author_agent_name("Claude\u0000")

      assert "is invalid" in errors_on(changeset).author_agent_name
    end

    test "nil leaves the comment unattributed" do
      task = insert_task()

      changeset =
        %TaskComment{task_id: task.id}
        |> TaskComment.changeset(%{content: "Hi"})
        |> TaskComment.put_author_agent_name(nil)

      assert changeset.valid?
      assert get_field(changeset, :author_agent_name) == nil
    end
  end

  defp insert_task do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    task_fixture(column)
  end
end
