defmodule KanbanWeb.TaskLive.CommentAttachmentsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TaskLive.CommentAttachments

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    task = board |> column_fixture() |> task_fixture()
    %{owner: owner, board: board, task: task}
  end

  defp comment(task, user, content \\ "With files") do
    {:ok, comment} =
      user |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => content})

    comment
  end

  defp member(board, owner, access) do
    user = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, user, access, owner)
    user
  end

  describe "group_by_comment/1" do
    test "groups the task's comment attachments by comment_id with one list call",
         %{owner: owner, task: task} do
      first = comment(task, owner, "First")
      second = comment(task, owner, "Second")
      a1 = attachment_fixture(task, %{comment: first, uploaded_by: owner})
      b1 = attachment_fixture(task, %{comment: second, uploaded_by: owner})
      a2 = attachment_fixture(task, %{comment: first, uploaded_by: owner})

      grouped =
        owner
        |> Scope.for_user()
        |> Attachments.list_task_attachments(%Task{id: task.id})
        |> CommentAttachments.group_by_comment()

      assert Map.keys(grouped) |> Enum.sort() == Enum.sort([first.id, second.id])
      assert Enum.map(grouped[first.id], & &1.id) == [a1.id, a2.id]
      assert Enum.map(grouped[second.id], & &1.id) == [b1.id]
    end

    test "drops task-level rows when grouping", %{owner: owner, task: task} do
      on_comment = comment(task, owner)
      _task_level = attachment_fixture(task, %{uploaded_by: owner})
      kept = attachment_fixture(task, %{comment: on_comment, uploaded_by: owner})

      assert %{} = grouped = CommentAttachments.group_by_comment({:ok, Repo.all(TaskAttachment)})
      assert grouped == %{on_comment.id => [Repo.get!(TaskAttachment, kept.id)]}
    end

    test "yields an empty map for an error or an empty list" do
      assert CommentAttachments.group_by_comment({:error, :not_found}) == %{}
      assert CommentAttachments.group_by_comment({:error, {:plan_required, :attachments}}) == %{}
      assert CommentAttachments.group_by_comment([]) == %{}
    end
  end

  describe "can_attach?/2" do
    test "lets the owner and modify members attach, never read-only members or strangers",
         %{owner: owner, board: board} do
      modifier = member(board, owner, :modify)
      reader = member(board, owner, :read_only)

      assert owner |> Scope.for_user() |> CommentAttachments.can_attach?(board.id)
      assert modifier |> Scope.for_user() |> CommentAttachments.can_attach?(board.id)
      refute reader |> Scope.for_user() |> CommentAttachments.can_attach?(board.id)
      refute user_fixture() |> Scope.for_user() |> CommentAttachments.can_attach?(board.id)
      refute CommentAttachments.can_attach?(nil, board.id)
    end

    test "is false without a board", %{owner: owner} do
      refute owner |> Scope.for_user() |> CommentAttachments.can_attach?(nil)
    end
  end

  describe "load/3" do
    test "costs the same number of queries however many comments carry files",
         %{owner: owner, board: board, task: task} do
      scope = Scope.for_user(owner)
      attachment_fixture(task, %{comment: comment(task, owner), uploaded_by: owner})

      few = count_queries(fn -> CommentAttachments.load(scope, task, board.id) end)

      for _n <- 1..5 do
        on_comment = comment(task, owner)

        for _file <- 1..3,
            do: attachment_fixture(task, %{comment: on_comment, uploaded_by: owner})
      end

      many = count_queries(fn -> CommentAttachments.load(scope, task, board.id) end)

      assert few == many
      assert map_size(CommentAttachments.load(scope, task, board.id).comment_attachments) == 6
    end

    test "says what a viewer may do on an unlocked board", %{
      owner: owner,
      board: board,
      task: task
    } do
      reader = member(board, owner, :read_only)

      assert %{can_attach?: true, attach_locked?: false} =
               owner |> Scope.for_user() |> CommentAttachments.load(task, board.id)

      assert %{can_attach?: false, attach_locked?: false} =
               reader |> Scope.for_user() |> CommentAttachments.load(task, board.id)
    end

    test "has nothing for a thread without a board", %{owner: owner, task: task} do
      assert owner |> Scope.for_user() |> CommentAttachments.load(task, nil) == %{
               comment_attachments: %{},
               can_attach?: false,
               attach_locked?: false,
               attach_room: 0
             }
    end

    # Async: reads the configured limit rather than changing it.
    test "counts the room left on the task, its own files and its comments' alike",
         %{owner: owner, task: task, board: board} do
      scope = Scope.for_user(owner)
      limit = Kanban.Attachments.Limits.max_files_per_task()
      assert %{attach_room: ^limit} = CommentAttachments.load(scope, task, board.id)

      attachment_fixture(task, %{uploaded_by: owner})
      {:ok, comment} = Kanban.Tasks.Comments.create_comment(scope, task, %{"content" => "c"})
      attachment_fixture(task, %{comment: comment})

      room = limit - 2
      assert %{attach_room: ^room} = CommentAttachments.load(scope, task, board.id)
    end
  end

  describe "check_plan/1" do
    test "is ok on an unlocked board and not found without one", %{board: board} do
      assert CommentAttachments.check_plan(board.id) == :ok
      assert CommentAttachments.check_plan(nil) == {:error, :not_found}
    end
  end

  describe "find_removable/2" do
    setup %{owner: owner, task: task} do
      comment = comment(task, owner)
      other = comment(task, owner, "Other")
      attachment = attachment_fixture(task, %{comment: comment, uploaded_by: owner})
      elsewhere = attachment_fixture(task, %{comment: other, uploaded_by: owner})

      assigns = %{
        editing_id: comment.id,
        entries: [
          %{comment: comment, can_edit: true},
          %{comment: other, can_edit: true}
        ],
        comment_attachments: %{comment.id => [attachment], other.id => [elsewhere]}
      }

      %{assigns: assigns, comment: comment, attachment: attachment, elsewhere: elsewhere}
    end

    test "returns an attachment on the comment being edited by its author",
         %{assigns: assigns, attachment: attachment} do
      assert CommentAttachments.find_removable(assigns, to_string(attachment.id)) ==
               {:ok, attachment}
    end

    test "refuses an attachment on another comment, or when not editing",
         %{assigns: assigns, attachment: attachment, elsewhere: elsewhere} do
      assert CommentAttachments.find_removable(assigns, to_string(elsewhere.id)) ==
               {:error, :unauthorized}

      assert CommentAttachments.find_removable(
               %{assigns | editing_id: nil},
               to_string(attachment.id)
             ) == {:error, :unauthorized}
    end

    test "refuses an editing comment the viewer may not edit",
         %{assigns: assigns, comment: comment, attachment: attachment} do
      entries = [%{comment: comment, can_edit: false}]

      assert CommentAttachments.find_removable(
               %{assigns | entries: entries},
               to_string(attachment.id)
             ) == {:error, :unauthorized}
    end

    test "is not found for an unknown, malformed or non-string id", %{assigns: assigns} do
      assert CommentAttachments.find_removable(assigns, "0") == {:error, :not_found}
      assert CommentAttachments.find_removable(assigns, "12abc") == {:error, :not_found}
      assert CommentAttachments.find_removable(assigns, 12) == {:error, :not_found}
    end
  end

  describe "failure_message/1" do
    test "is nil when nothing failed" do
      assert CommentAttachments.failure_message([]) == nil
    end

    test "names every failed file with its translated reason" do
      message =
        CommentAttachments.failure_message([
          {"big.log", :too_large},
          {"third.txt", :too_many_files}
        ])

      assert message =~ "Could not upload big.log: #{AttachmentUploads.error_message(:too_large)}"

      assert message =~
               "Could not upload third.txt: #{AttachmentUploads.error_message(:too_many_files)}"
    end

    test "names each file the way it would be stored, never with a bidi override" do
      message = CommentAttachments.failure_message([{"evil\u202Efdp.exe", :not_accepted}])

      refute message =~ "\u202E"
      assert message =~ "Could not upload evilfdp.exe:"
    end
  end

  describe "cancel_entry/2" do
    test "leaves the socket unchanged for an unknown ref, with or without the upload" do
      bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assert CommentAttachments.cancel_entry(bare, "phx-unknown") == bare
      refute CommentAttachments.upload_allowed?(bare)

      allowed = AttachmentUploads.allow(bare, CommentAttachments.upload_name())
      assert CommentAttachments.upload_allowed?(allowed)
      assert CommentAttachments.cancel_entry(allowed, "phx-unknown") == allowed
    end
  end

  test "upload_name/0 is the composer's upload" do
    assert CommentAttachments.upload_name() == :comment_attachments
  end

  defp count_queries(fun) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:repo_query, handler_id})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_queries(handler_id, 0)
  end

  defp drain_queries(handler_id, count) do
    receive do
      {:repo_query, ^handler_id} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end
end
