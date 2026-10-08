defmodule Kanban.Tasks.CommentNotifierTest do
  @moduledoc """
  Mention notifications emitted after a comment save (W2213): who is
  notified on create and edit, the payload, the actor, and that a failing
  notifications call never changes the save's result.

  Not async: the failure tests add a CHECK constraint to `notifications`,
  which takes a table lock other sandboxed tests would wait on.
  """
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Tasks.CommentNotifier
  alias Kanban.Tasks.Comments
  alias Kanban.Tasks.TaskComment

  doctest Kanban.Tasks.CommentNotifier

  setup do
    owner = user_fixture(%{name: "Owner Person"})
    board = board_fixture(owner)
    column = column_fixture(board)
    task = task_fixture(column)
    ada = user_fixture(%{name: "Ada"})
    bo = user_fixture(%{name: "Bo"})
    cy = user_fixture(%{name: "Cy"})

    for member <- [ada, bo, cy] do
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
    end

    %{owner: owner, board: board, task: task, ada: ada, bo: bo, cy: cy}
  end

  describe "new_mentions/2" do
    test "returns ids in the new set but not the old set, minus the author" do
      comment = %TaskComment{author_user_id: 1, mentioned_user_ids: [4, 1, 2, 3]}

      assert CommentNotifier.new_mentions([2], comment) == [4, 3]
    end

    test "is empty when nothing was added" do
      comment = %TaskComment{author_user_id: 1, mentioned_user_ids: [2, 3]}

      assert CommentNotifier.new_mentions([3, 2], comment) == []
    end

    test "treats nil previous ids as none" do
      comment = %TaskComment{author_user_id: 1, mentioned_user_ids: [2]}

      assert CommentNotifier.new_mentions(nil, comment) == [2]
    end

    test "excludes the author even when previously unmentioned" do
      comment = %TaskComment{author_user_id: 7, mentioned_user_ids: [7]}

      assert CommentNotifier.new_mentions([], comment) == []
    end
  end

  describe "notification_attrs/4" do
    test "references the task and comment without copying the content",
         %{owner: owner, board: board, task: task} do
      comment = %TaskComment{id: 42, task_id: task.id, content: "secret plan", edited_at: nil}

      attrs = CommentNotifier.notification_attrs(comment, task, board.id, owner)

      assert attrs == %{
               title: "#{task.identifier}: #{task.title}",
               url_path: "/boards/#{board.id}/tasks/#{task.id}/edit#comment-42",
               actor_name: "Owner Person",
               metadata: %{"comment_id" => 42},
               board_id: board.id,
               task_id: task.id,
               dedupe_key: "mentioned:42:created"
             }

      refute Map.has_key?(attrs, :body)
    end

    test "an agent-authored comment names the agent and the token's user",
         %{owner: owner, board: board, task: task} do
      comment = %TaskComment{id: 1, author_agent_name: "Claude Opus 5.5"}

      assert %{actor_name: "Claude Opus 5.5 (Owner Person)"} =
               CommentNotifier.notification_attrs(comment, task, board.id, owner)
    end

    test "an agent-authored comment by a nameless user names only the agent",
         %{board: board, task: task} do
      comment = %TaskComment{id: 1, author_agent_name: "Claude"}
      nameless = %{name: nil, email: "someone@example.com"}

      assert %{actor_name: "Claude"} =
               CommentNotifier.notification_attrs(comment, task, board.id, nameless)
    end

    test "a long agent name is trimmed so the user's name survives within 255",
         %{owner: owner, board: board, task: task} do
      comment = %TaskComment{id: 1, author_agent_name: String.duplicate("a", 255)}

      %{actor_name: actor} = CommentNotifier.notification_attrs(comment, task, board.id, owner)

      assert String.length(actor) == 255
      assert String.ends_with?(actor, " (Owner Person)")
    end

    test "never falls back to the author's email", %{board: board, task: task} do
      nameless = %{name: nil, email: "someone@example.com"}

      assert %{actor_name: nil} =
               CommentNotifier.notification_attrs(%TaskComment{id: 1}, task, board.id, nameless)
    end

    test "an edit's dedupe key carries its edited_at second", %{board: board, task: task} do
      edited_at = ~U[2026-10-07 12:00:00Z]
      comment = %TaskComment{id: 9, edited_at: edited_at}

      assert %{dedupe_key: key} =
               CommentNotifier.notification_attrs(comment, task, board.id, nil)

      assert key == "mentioned:9:#{DateTime.to_unix(edited_at)}"
    end
  end

  describe "comment create" do
    test "mentioning two members emits exactly two :mentioned notifications",
         %{owner: owner, board: board, task: task, ada: ada, bo: bo} do
      {:ok, comment} = create(owner, task, "cc #{mention(ada)} and #{mention(bo)}")

      rows = mention_rows()
      assert Enum.map(rows, & &1.user_id) == Enum.sort([ada.id, bo.id])

      for row <- rows do
        assert row.task_id == task.id
        assert row.metadata == %{"comment_id" => comment.id}
        assert row.actor_name == "Owner Person"
        assert row.url_path == "/boards/#{board.id}/tasks/#{task.id}/edit#comment-#{comment.id}"
        assert row.body == nil
        refute row.title =~ "cc"
      end

      for member <- [ada, bo] do
        member_scope = Scope.for_user(member)

        # Being added to the board in setup also left an unread notification.
        visible = Notifications.list_notifications(member_scope)

        assert [%Notification{metadata: metadata}] =
                 Enum.filter(visible, &(&1.event_type == :mentioned))

        assert metadata == %{"comment_id" => comment.id}
        assert Notifications.unread_count(member_scope) == length(visible)
      end
    end

    test "the author is never notified about mentioning themselves",
         %{owner: owner, task: task, ada: ada} do
      {:ok, comment} = create(owner, task, "#{mention(owner)} #{mention(ada)}")

      assert comment.mentioned_user_ids == [owner.id, ada.id]
      assert Enum.map(mention_rows(), & &1.user_id) == [ada.id]
    end

    test "an agent-posted comment mentioning its token's own user notifies nobody",
         %{owner: owner, task: task} do
      {:ok, _comment} = create(owner, task, mention(owner), author_agent_name: "Bot")

      assert mention_rows() == []
    end

    test "agent comments carry the agent name as the actor",
         %{owner: owner, task: task, ada: ada} do
      {:ok, _comment} = create(owner, task, mention(ada), author_agent_name: "Claude Opus 5.5")

      assert [%Notification{actor_name: "Claude Opus 5.5 (Owner Person)"}] = mention_rows()
    end

    test "a comment with no mentions notifies nobody", %{owner: owner, task: task} do
      {:ok, _comment} = create(owner, task, "no mentions here")

      assert mention_rows() == []
    end
  end

  describe "comment edit" do
    test "notifies only users newly added by the edit",
         %{owner: owner, task: task, ada: ada, bo: bo, cy: cy} do
      {:ok, comment} = create(owner, task, mention(ada))

      {:ok, _} = edit(owner, comment, "#{mention(ada)} #{mention(bo)} #{mention(cy)}")

      assert owner_counts() == %{ada.id => 1, bo.id => 1, cy.id => 1}
    end

    test "an edit that keeps the same mentions notifies nobody new",
         %{owner: owner, task: task, ada: ada} do
      {:ok, comment} = create(owner, task, "hi #{mention(ada)}")

      {:ok, _} = edit(owner, comment, "hello again #{mention(ada)}")

      assert owner_counts() == %{ada.id => 1}
    end

    test "a mention removed and restored by a later edit notifies again",
         %{owner: owner, board: board, task: task, ada: ada} do
      {:ok, comment} = create(owner, task, mention(ada))
      {:ok, removed} = edit(owner, comment, "no one")
      assert removed.mentioned_user_ids == []

      # edited_at has second precision; a restoring edit in a later second
      # carries a new dedupe key, so it notifies the restored user again.
      restored = %{
        removed
        | mentioned_user_ids: [ada.id],
          edited_at: DateTime.add(removed.edited_at, 1)
      }

      assert CommentNotifier.notify_mentions(restored, [], board.id, owner) == :ok

      assert owner_counts() == %{ada.id => 2}
    end

    test "re-sending the same write notifies once", %{owner: owner, task: task, ada: ada} do
      {:ok, comment} = create(owner, task, "draft")
      {:ok, edited} = edit(owner, comment, mention(ada))
      board_id = task_board_id(task)

      assert CommentNotifier.notify_mentions(edited, [], board_id, owner) == :ok

      assert owner_counts() == %{ada.id => 1}
    end
  end

  describe "edge cases" do
    test "a mentioned user removed from the board before notify is skipped",
         %{owner: owner, board: board, task: task, ada: ada, bo: bo} do
      {:ok, comment} = create(owner, task, "draft")
      {:ok, _} = Boards.remove_user_from_board(board, bo, owner)

      comment = %{comment | mentioned_user_ids: [ada.id, bo.id]}
      assert CommentNotifier.notify_mentions(comment, [], board.id, owner) == :ok

      assert Enum.map(mention_rows(), & &1.user_id) == [ada.id]
    end

    test "a comment deleted right after creation keeps its save result",
         %{owner: owner, task: task, ada: ada} do
      {:ok, comment} = create(owner, task, mention(ada))
      assert {:ok, _} = owner |> Scope.for_user() |> Comments.delete_comment(comment)

      assert [%Notification{user_id: user_id}] = mention_rows()
      assert user_id == ada.id
    end

    test "a task that no longer exists is logged and returns :ok",
         %{owner: owner, board: board, ada: ada} do
      comment = %TaskComment{
        id: 123,
        task_id: -1,
        author_user_id: owner.id,
        mentioned_user_ids: [ada.id]
      }

      log =
        capture_log([level: :warning], fn ->
          assert CommentNotifier.notify_mentions(comment, [], board.id, owner) == :ok
        end)

      assert log =~ "notification mentioned not emitted for comment 123: :task_not_found"
      assert mention_rows() == []
    end
  end

  describe "notification failures" do
    test "an invalid payload is logged by field name and returns :ok",
         %{owner: owner, task: task, ada: ada} do
      {:ok, comment} = create(owner, task, "draft")
      other_board = board_fixture(owner)
      comment = %{comment | mentioned_user_ids: [ada.id]}

      log =
        capture_log([level: :warning], fn ->
          assert CommentNotifier.notify_mentions(comment, [], other_board.id, owner) == :ok
        end)

      assert log =~ "notification mentioned not emitted for comment #{comment.id}: [:task_id]"
      assert mention_rows() == []
    end

    test "a failing notify on create is logged and the comment is still saved",
         %{owner: owner, task: task, ada: ada} do
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %TaskComment{} = comment} = create(owner, task, "secret #{mention(ada)}")
          send(self(), {:saved, comment})
        end)

      assert_received {:saved, comment}
      assert Repo.get(TaskComment, comment.id)
      assert log =~ "notification mentioned not emitted for comment #{comment.id}"
      refute log =~ "secret"
      refute log =~ task.title
    end

    test "a failing notify on update is logged and the update still returns :ok",
         %{owner: owner, task: task, ada: ada} do
      {:ok, comment} = create(owner, task, "plain")
      break_notification_inserts()

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, updated} = edit(owner, comment, "now #{mention(ada)}")
          assert updated.mentioned_user_ids == [ada.id]
        end)

      assert log =~ "notification mentioned not emitted for comment #{comment.id}"
      assert Repo.reload!(comment).mentioned_user_ids == [ada.id]
    end
  end

  defp create(user, task, content, opts \\ []) do
    user |> Scope.for_user() |> Comments.create_comment(task, %{"content" => content}, opts)
  end

  defp edit(user, comment, content) do
    user |> Scope.for_user() |> Comments.update_comment(comment, %{"content" => content})
  end

  defp task_board_id(task) do
    Kanban.Columns.Column
    |> where(id: ^task.column_id)
    |> select([c], c.board_id)
    |> Repo.one!()
  end

  defp mention(user), do: "@[#{user.name}](user:#{user.id})"

  defp mention_rows do
    Notification
    |> where(event_type: :mentioned)
    |> order_by(:user_id)
    |> Repo.all()
  end

  defp owner_counts do
    mention_rows() |> Enum.frequencies_by(& &1.user_id)
  end

  defp break_notification_inserts do
    Repo.query!(
      "ALTER TABLE notifications ADD CONSTRAINT w2213_always_fails CHECK (false) NOT VALID"
    )
  end
end
