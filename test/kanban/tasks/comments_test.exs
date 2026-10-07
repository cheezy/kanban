defmodule Kanban.Tasks.CommentsTest do
  @moduledoc """
  Unit tests for the comment context extracted out of the task form
  LiveComponent so the web layer holds no Ecto queries (CODE-REVIEW.md,
  "LiveView / context boundary"): authorization via CommentPolicy, edited_at
  stamping, owner-delete auditing and the board PubSub broadcast.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Tasks
  alias Kanban.Tasks.Comments
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column, task: task_fixture(column)}
  end

  describe "create_comment/4" do
    test "creates a comment attached to the task, authored by the scope user",
         %{user: user, task: task} do
      assert {:ok, comment} =
               user |> scope() |> Comments.create_comment(task, %{"content" => "Looks good"})

      assert comment.task_id == task.id
      assert comment.content == "Looks good"
      assert comment.author_user_id == user.id
      assert comment.author_agent_name == nil
      assert comment.edited_at == nil
    end

    test "sets author_agent_name from opts", %{user: user, task: task} do
      assert {:ok, comment} =
               user
               |> scope()
               |> Comments.create_comment(task, %{"content" => "Agent note"},
                 author_agent_name: "Claude Opus 5.5"
               )

      assert comment.author_agent_name == "Claude Opus 5.5"
      assert comment.author_user_id == user.id
    end

    test "lets owner, modify and read-only members comment", ctx do
      %{modifier: modifier, reader: reader} = add_members(ctx)

      for member <- [ctx.user, modifier, reader] do
        assert {:ok, comment} =
                 member |> scope() |> Comments.create_comment(ctx.task, %{"content" => "Hi"})

        assert comment.author_user_id == member.id
      end
    end

    test "refuses a user with no board membership and writes nothing", %{task: task} do
      stranger = user_fixture()

      assert {:error, :unauthorized} =
               stranger |> scope() |> Comments.create_comment(task, %{"content" => "Sneaky"})

      assert comment_count(task) == 0
    end

    test "refuses a nil scope", %{task: task} do
      assert {:error, :unauthorized} = Comments.create_comment(nil, task, %{"content" => "x"})
      assert comment_count(task) == 0
    end

    test "accepts a plain map scope shaped like Scope", %{user: user, task: task} do
      assert {:ok, comment} = Comments.create_comment(%{user: user}, task, %{"content" => "Map"})
      assert comment.author_user_id == user.id
    end

    test "returns :not_found for an unsaved task", %{user: user} do
      assert {:error, :not_found} =
               user |> scope() |> Comments.create_comment(%Task{}, %{"content" => "x"})
    end

    test "returns an error changeset when content is blank", %{user: user, task: task} do
      assert {:error, changeset} =
               user |> scope() |> Comments.create_comment(task, %{"content" => ""})

      refute changeset.valid?
      assert %{content: [_ | _]} = errors_on(changeset)
    end

    test "ignores client-supplied task_id and author fields (D111)",
         %{user: user, task: task, column: column} do
      other_task = task_fixture(column)
      other_user = user_fixture()

      {:ok, comment} =
        user
        |> scope()
        |> Comments.create_comment(task, %{
          "content" => "Redirect attempt",
          "task_id" => other_task.id,
          "author_user_id" => other_user.id,
          "author_agent_name" => "Impostor",
          "edited_at" => "2020-01-01T00:00:00Z"
        })

      assert comment.task_id == task.id
      assert comment.author_user_id == user.id
      assert comment.author_agent_name == nil
      assert comment.edited_at == nil
    end

    test "authorizes against the task's own board, not the caller's", %{task: task} do
      other_owner = user_fixture()
      _other_board = board_fixture(other_owner)

      assert {:error, :unauthorized} =
               other_owner |> scope() |> Comments.create_comment(task, %{"content" => "x"})
    end

    test "broadcasts :comment_changed on the board topic", %{user: user, board: board, task: task} do
      subscribe(board)

      {:ok, _} = user |> scope() |> Comments.create_comment(task, %{"content" => "Ping"})

      assert_receive {Comments, :comment_changed, %{task_id: task_id, board_id: board_id}}
      assert task_id == task.id
      assert board_id == board.id
    end

    test "does not broadcast when refused or invalid", %{user: user, board: board, task: task} do
      subscribe(board)

      {:error, :unauthorized} =
        user_fixture() |> scope() |> Comments.create_comment(task, %{"content" => "x"})

      {:error, %Ecto.Changeset{}} =
        user |> scope() |> Comments.create_comment(task, %{"content" => ""})

      refute_receive {Comments, :comment_changed, _}
    end

    test "is reachable through the Tasks facade", %{user: user, task: task} do
      assert {:ok, comment} =
               user |> scope() |> Tasks.create_comment(task, %{"content" => "Via facade"})

      assert comment.task_id == task.id

      assert {:ok, agent_comment} =
               user
               |> scope()
               |> Tasks.create_comment(task, %{"content" => "Agent"}, author_agent_name: "Bot")

      assert agent_comment.author_agent_name == "Bot"
    end
  end

  describe "update_comment/3" do
    setup ctx do
      members = add_members(ctx)

      {:ok, comment} =
        members.reader |> scope() |> Comments.create_comment(ctx.task, %{"content" => "v1"})

      Map.put(members, :comment, comment)
    end

    test "lets the author edit, stamping edited_at and keeping inserted_at",
         %{reader: reader, comment: comment} do
      assert {:ok, updated} =
               reader |> scope() |> Comments.update_comment(comment, %{"content" => "v2"})

      assert updated.content == "v2"
      assert %DateTime{} = updated.edited_at
      assert updated.inserted_at == comment.inserted_at
      assert Repo.get!(TaskComment, comment.id).content == "v2"
    end

    test "refuses non-authors, including the owner", %{user: owner, modifier: modifier} = ctx do
      for user <- [owner, modifier, user_fixture()] do
        assert {:error, :unauthorized} =
                 user |> scope() |> Comments.update_comment(ctx.comment, %{"content" => "hijack"})
      end

      assert Repo.get!(TaskComment, ctx.comment.id).content == "v1"
    end

    test "refuses edits to a legacy authorless comment", %{user: owner, task: task} do
      legacy = Repo.insert!(%TaskComment{task_id: task.id, content: "old"})

      assert {:error, :unauthorized} =
               owner |> scope() |> Comments.update_comment(legacy, %{"content" => "new"})
    end

    test "refuses an author who has been removed from the board", ctx do
      {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.reader, ctx.user)

      assert {:error, :unauthorized} =
               ctx.reader
               |> scope()
               |> Comments.update_comment(ctx.comment, %{"content" => "late"})
    end

    test "ignores a forged task_id or author on the caller's struct", ctx do
      forged = %{ctx.comment | author_user_id: ctx.user.id, task_id: -1}

      assert {:error, :unauthorized} =
               ctx.user |> scope() |> Comments.update_comment(forged, %{"content" => "forged"})
    end

    test "returns a changeset for blank content and leaves edited_at nil",
         %{reader: reader, comment: comment} do
      assert {:error, %Ecto.Changeset{}} =
               reader |> scope() |> Comments.update_comment(comment, %{"content" => ""})

      assert Repo.get!(TaskComment, comment.id).edited_at == nil
    end

    test "returns :not_found when the comment was deleted first",
         %{reader: reader, comment: comment} do
      {:ok, _} = reader |> scope() |> Comments.delete_comment(comment)

      assert {:error, :not_found} =
               reader |> scope() |> Comments.update_comment(comment, %{"content" => "too late"})
    end

    test "returns :not_found when the comment is deleted between read and write",
         %{reader: reader, comment: comment} do
      delete_after_comment_read(comment.id)

      assert {:error, :not_found} =
               reader |> scope() |> Comments.update_comment(comment, %{"content" => "raced"})

      refute Repo.get(TaskComment, comment.id)
    end

    test "returns :not_found for a comment with no id", %{reader: reader} do
      assert {:error, :not_found} =
               reader |> scope() |> Comments.update_comment(%TaskComment{}, %{"content" => "x"})
    end

    test "broadcasts :comment_changed on success only", %{board: board, reader: reader} = ctx do
      subscribe(board)

      {:error, :unauthorized} =
        ctx.user |> scope() |> Comments.update_comment(ctx.comment, %{"content" => "x"})

      refute_receive {Comments, :comment_changed, _}

      {:ok, _} = reader |> scope() |> Comments.update_comment(ctx.comment, %{"content" => "v2"})
      assert_receive {Comments, :comment_changed, %{task_id: task_id, board_id: board_id}}
      assert {task_id, board_id} == {ctx.task.id, board.id}
    end

    test "is reachable through the Tasks facade", %{reader: reader, comment: comment} do
      assert {:ok, _} =
               reader |> scope() |> Tasks.update_comment(comment, %{"content" => "facade"})
    end
  end

  describe "delete_comment/2" do
    setup ctx do
      members = add_members(ctx)

      {:ok, comment} =
        members.reader |> scope() |> Comments.create_comment(ctx.task, %{"content" => "bye"})

      attach_audit()
      Map.put(members, :comment, comment)
    end

    test "lets the author delete without an audit event", %{reader: reader, comment: comment} do
      assert {:ok, _} = reader |> scope() |> Comments.delete_comment(comment)

      refute Repo.get(TaskComment, comment.id)
      refute_receive {:audit, _, _}
    end

    test "lets the owner delete another user's comment and audit-logs it without the body",
         %{user: owner, reader: reader, board: board, task: task, comment: comment} do
      assert {:ok, _} = owner |> scope() |> Comments.delete_comment(comment)

      refute Repo.get(TaskComment, comment.id)
      assert_receive {:audit, %{count: 1}, metadata}
      assert metadata.user_id == owner.id
      assert metadata.board_id == board.id
      assert metadata.task_id == task.id
      assert metadata.comment_id == comment.id
      assert metadata.author_user_id == reader.id
      refute Map.has_key?(metadata, :content)
      refute metadata |> Map.values() |> Enum.any?(&(&1 == "bye"))
    end

    test "audit-logs the owner deleting a legacy authorless comment", %{user: owner, task: task} do
      legacy = Repo.insert!(%TaskComment{task_id: task.id, content: "old"})

      assert {:ok, _} = owner |> scope() |> Comments.delete_comment(legacy)

      assert_receive {:audit, _, metadata}
      assert metadata.comment_id == legacy.id
      refute Map.has_key?(metadata, :author_user_id)
    end

    test "does not audit-log the owner deleting their own comment", %{user: owner, task: task} do
      {:ok, own} = owner |> scope() |> Comments.create_comment(task, %{"content" => "mine"})

      assert {:ok, _} = owner |> scope() |> Comments.delete_comment(own)
      refute_receive {:audit, _, _}
    end

    test "refuses modify and read-only non-authors and non-members", ctx do
      {:ok, owner_comment} =
        ctx.user |> scope() |> Comments.create_comment(ctx.task, %{"content" => "o"})

      assert {:error, :unauthorized} =
               ctx.modifier |> scope() |> Comments.delete_comment(ctx.comment)

      assert {:error, :unauthorized} =
               ctx.reader |> scope() |> Comments.delete_comment(owner_comment)

      assert {:error, :unauthorized} =
               user_fixture() |> scope() |> Comments.delete_comment(ctx.comment)

      assert {:error, :unauthorized} = Comments.delete_comment(nil, ctx.comment)

      assert Repo.get(TaskComment, ctx.comment.id)
      assert Repo.get(TaskComment, owner_comment.id)
    end

    test "refuses an author removed from the board", ctx do
      {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.reader, ctx.user)

      assert {:error, :unauthorized} =
               ctx.reader |> scope() |> Comments.delete_comment(ctx.comment)
    end

    test "refuses the owner of a different board", %{comment: comment} do
      other_owner = user_fixture()
      _other_board = board_fixture(other_owner)

      assert {:error, :unauthorized} = other_owner |> scope() |> Comments.delete_comment(comment)
    end

    test "returns :not_found when already deleted", %{reader: reader, comment: comment} do
      {:ok, _} = reader |> scope() |> Comments.delete_comment(comment)

      assert {:error, :not_found} = reader |> scope() |> Comments.delete_comment(comment)
    end

    test "returns :not_found when the comment is deleted between read and write",
         %{reader: reader, comment: comment} do
      delete_after_comment_read(comment.id)

      assert {:error, :not_found} = reader |> scope() |> Comments.delete_comment(comment)
      refute_receive {:audit, _, _}
    end

    test "broadcasts :comment_changed on success only", %{board: board} = ctx do
      subscribe(board)

      {:error, :unauthorized} = ctx.modifier |> scope() |> Comments.delete_comment(ctx.comment)
      refute_receive {Comments, :comment_changed, _}

      {:ok, _} = ctx.reader |> scope() |> Comments.delete_comment(ctx.comment)
      assert_receive {Comments, :comment_changed, %{task_id: task_id, board_id: board_id}}
      assert {task_id, board_id} == {ctx.task.id, board.id}
    end

    test "is reachable through the Tasks facade", %{reader: reader, comment: comment} do
      assert {:ok, _} = reader |> scope() |> Tasks.delete_comment(comment)
    end
  end

  describe "get_comment!/1" do
    test "returns the comment", %{user: user, task: task} do
      {:ok, comment} = user |> scope() |> Comments.create_comment(task, %{"content" => "find me"})

      assert Tasks.get_comment!(comment.id).content == "find me"
    end

    test "raises for a missing id" do
      assert_raise Ecto.NoResultsError, fn -> Comments.get_comment!(-1) end
    end
  end

  describe "list_comments/1" do
    test "lists the task's comments oldest first with authors preloaded",
         %{user: user, task: task, column: column} do
      {:ok, first} = user |> scope() |> Comments.create_comment(task, %{"content" => "First"})
      {:ok, second} = user |> scope() |> Comments.create_comment(task, %{"content" => "Second"})
      other_task = task_fixture(column)

      {:ok, _} =
        user |> scope() |> Comments.create_comment(other_task, %{"content" => "Elsewhere"})

      comments = Tasks.list_comments(task)

      assert Enum.map(comments, & &1.id) == [first.id, second.id]
      assert Enum.all?(comments, &(&1.author.id == user.id))
    end

    test "returns an empty list when there are none", %{task: task} do
      assert Comments.list_comments(task) == []
    end
  end

  describe "get_task_with_comments!/1" do
    test "preloads comments newest-first", %{user: user, task: task} do
      {:ok, first} = user |> scope() |> Comments.create_comment(task, %{"content" => "First"})
      {:ok, second} = user |> scope() |> Comments.create_comment(task, %{"content" => "Second"})

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

  defp scope(user), do: Scope.for_user(user)

  defp add_members(%{board: board, user: owner}) do
    modifier = user_fixture()
    reader = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
    %{modifier: modifier, reader: reader}
  end

  defp comment_count(task) do
    TaskComment
    |> where([c], c.task_id == ^task.id)
    |> Repo.aggregate(:count)
  end

  defp subscribe(board), do: Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

  # Simulates a concurrent delete: the first task_comments SELECT this test
  # process runs (fetch_with_board/1) is followed at once by a delete of the
  # row, so the context's later update/delete hits a stale entry.
  defp delete_after_comment_read(comment_id) do
    test_pid = self()
    handler_id = "comments-race-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and metadata[:source] == "task_comments" and
             String.starts_with?(metadata[:query] || "", "SELECT") do
          :telemetry.detach(handler_id)
          Repo.delete_all(from(c in TaskComment, where: c.id == ^comment_id))
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_audit do
    test_pid = self()
    event = [:kanban, :audit, :comment_deleted_by_owner]
    handler_id = "comments-test-audit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:audit, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
