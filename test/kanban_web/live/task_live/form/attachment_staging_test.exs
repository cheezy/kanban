defmodule KanbanWeb.TaskLive.Form.AttachmentStagingTest do
  # Not async: some tests switch the global :plans_enforced env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Phoenix.LiveViewTest

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TaskLive.Form.AttachmentStaging

  defp socket_for(scope),
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_scope: scope}}

  defp owner_and_board do
    owner = user_fixture()
    {owner, board_fixture(owner)}
  end

  defp upload_conf(socket), do: socket.assigns[:uploads][AttachmentStaging.upload_name()]

  defp stage_notes(conn, board, column) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

    view
    |> file_input("#task-form", AttachmentStaging.upload_name(), [
      %{name: "notes.txt", content: "hello", type: "text/plain"}
    ])
    |> render_upload("notes.txt")

    view
  end

  defp submit(view, title, column) do
    view
    |> element("#task-form")
    |> render_submit(%{"task" => %{"title" => title, "column_id" => column.id}})
  end

  describe "allow/3" do
    test "allow sets up uploads only for a new task on an unlocked board" do
      {owner, board} = owner_and_board()
      socket = owner |> Scope.for_user() |> socket_for()

      open = AttachmentStaging.allow(socket, board, :new_task)
      assert open.assigns.attachment_staging == :open
      assert %{auto_upload?: false} = upload_conf(open)

      edit = AttachmentStaging.allow(socket, board, :edit_task)
      assert edit.assigns.attachment_staging == :hidden
      refute upload_conf(edit)

      enforce_plans()
      locked = AttachmentStaging.allow(socket, board, :new_task)
      assert locked.assigns.attachment_staging == :locked
      refute upload_conf(locked)
    end

    test "hides the field for a read-only member, a stranger and no scope" do
      {owner, board} = owner_and_board()
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      for scope <- [Scope.for_user(reader), Scope.for_user(user_fixture()), nil] do
        socket = scope |> socket_for() |> AttachmentStaging.allow(board, :new_task)
        assert socket.assigns.attachment_staging == :hidden
        refute upload_conf(socket)
      end
    end

    test "allows the upload once, so a second call keeps the same config" do
      {owner, board} = owner_and_board()
      socket = owner |> Scope.for_user() |> socket_for()

      first = AttachmentStaging.allow(socket, board, :new_task)
      again = AttachmentStaging.allow(first, board, :new_task)

      assert upload_conf(again).ref == upload_conf(first).ref
      assert AttachmentStaging.upload_allowed?(again)
    end
  end

  describe "cancel/2" do
    test "leaves the socket unchanged for an unknown ref, with or without the upload" do
      {owner, board} = owner_and_board()
      bare = socket_for(Scope.for_user(owner))
      allowed = AttachmentStaging.allow(bare, board, :new_task)

      assert AttachmentStaging.cancel(bare, "nope") == bare
      assert AttachmentStaging.cancel(allowed, "nope") == allowed
      assert AttachmentStaging.cancel(allowed, nil) == allowed
    end
  end

  describe "store_staged/3" do
    test "does nothing when the upload was never allowed" do
      socket = socket_for(nil)
      assert {^socket, []} = AttachmentStaging.store_staged(socket, nil, %Task{id: 1})
    end

    test "store_staged passes the new task and no comment_id to Goal A's create function",
         %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      board = board_fixture(user)
      column = column_fixture(board)
      attach_telemetry([:kanban, :attachment, :uploaded])
      view = stage_notes(conn, board, column)
      submit(view, "With a file", column)

      task = Repo.get_by!(Task, title: "With a file")
      assert [attachment] = Repo.all(TaskAttachment)
      assert attachment.task_id == task.id
      assert is_nil(attachment.comment_id)
      assert attachment.uploaded_by_id == user.id
      assert attachment.filename == "notes.txt"

      task_id = task.id
      board_id = board.id

      assert_received {:telemetry_event, [:kanban, :attachment, :uploaded], _measurements,
                       %{task_id: ^task_id, comment_id: nil, board_id: ^board_id}}
    end

    test "store_staged refuses every staged file when the board's plan no longer includes attachments",
         %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      board = board_fixture(user)
      column = column_fixture(board)
      view = stage_notes(conn, board, column)

      enforce_plans()
      attach_telemetry([:kanban, :plan, :feature_refused])
      submit(view, "Locked after staging", column)

      assert Repo.get_by(Task, title: "Locked after staging")
      assert Repo.all(TaskAttachment) == []
      assert render(view) =~ AttachmentUploads.error_message({:plan_required, :attachments})

      assert_received {:telemetry_event, [:kanban, :plan, :feature_refused], _measurements,
                       %{feature: :attachments, surface: :live_view}}
    end
  end

  describe "failure_message/1 and put_failure_flash/2" do
    test "names every failed file with its translated reason" do
      message =
        AttachmentStaging.failure_message([
          {"a.txt", :too_large},
          {"b.exe", :type_not_allowed}
        ])

      assert message =~ "a.txt"
      assert message =~ AttachmentUploads.error_message(:too_large)
      assert message =~ "b.exe"
      assert message =~ AttachmentUploads.error_message(:type_not_allowed)
    end

    test "names each file the way it would be stored, never with a bidi override" do
      message = AttachmentStaging.failure_message([{"evil\u202Efdp.exe", :not_accepted}])

      refute message =~ "\u202E"
      assert message =~ "Could not upload evilfdp.exe:"
    end

    test "puts no flash when nothing failed and an error flash otherwise" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert AttachmentStaging.put_failure_flash(socket, []) == socket

      flashed = AttachmentStaging.put_failure_flash(socket, [{"a.txt", :quota_exceeded}])
      assert flashed.assigns.flash["error"] =~ "a.txt"
    end
  end

  describe "field/1" do
    test "renders nothing when hidden and the inline lock when locked" do
      assert render_component(&AttachmentStaging.field/1, state: :hidden) == ""

      html = render_component(&AttachmentStaging.field/1, state: :locked)
      assert html =~ ~s(data-locked-feature="attachments")
      assert html =~ ~s(data-variant="inline")
      refute html =~ ~s(type="file")
    end
  end
end
