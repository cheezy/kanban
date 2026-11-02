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

  describe "store_staged/3 order and unfinished files" do
    setup do
      previous = Application.get_env(:kanban, Kanban.Attachments.Limits)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kanban, Kanban.Attachments.Limits, previous),
          else: Application.delete_env(:kanban, Kanban.Attachments.Limits)
      end)

      :ok
    end

    defp open_new_task(conn) do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")
      {view, column}
    end

    defp stage(view, files) do
      input = file_input(view, "#task-form", AttachmentStaging.upload_name(), files)
      for %{name: name} <- files, do: render_upload(input, name)
      view
    end

    defp text_file(name, content \\ "x"), do: %{name: name, content: content, type: "text/plain"}

    test "stores the staged files in the order they were chosen", %{conn: conn} do
      {view, column} = open_new_task(conn)

      view
      |> stage(Enum.map(~w(first.txt second.txt third.txt), &text_file/1))
      |> submit("Ordered", column)

      names = TaskAttachment |> Repo.all() |> Enum.sort_by(& &1.id) |> Enum.map(& &1.filename)
      assert names == ~w(first.txt second.txt third.txt)
    end

    test "keeps the first chosen files when the task's file limit is reached", %{conn: conn} do
      {view, column} = open_new_task(conn)
      view = stage(view, Enum.map(~w(one.txt two.txt three.txt), &text_file/1))
      Application.put_env(:kanban, Kanban.Attachments.Limits, max_files_per_task: 1)
      submit(view, "Capped", column)

      assert [%{filename: "one.txt"}] = Repo.all(TaskAttachment)
      html = render(view)
      assert html =~ "Could not upload two.txt: A task can hold at most 1 file."
      assert html =~ "Could not upload three.txt:"
    end

    # LiveView's client drops a submit while the file input carries error
    # refs, so an enabled Save Task would do nothing at all when clicked.
    test "Save Task waits while a staged file has an error, and says why", %{conn: conn} do
      Application.put_env(:kanban, Kanban.Attachments.Limits, max_file_bytes: 16)
      {view, _column} = open_new_task(conn)
      save = "#task-form button[phx-disable-with]"

      refute has_element?(view, save <> "[disabled]")

      stage(view, [
        text_file("fine.txt", "hello"),
        text_file("large.txt", String.duplicate("x", 64))
      ])

      assert has_element?(view, save <> "[disabled]")

      assert view |> element("#task-attachments-blocked") |> render() =~
               "Cancel the files marked with an error to upload the others."

      large =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(li[id^="upload-entry-"]))
        |> Enum.find(&(LazyHTML.text(&1) =~ "large.txt"))
        |> LazyHTML.attribute("id")
        |> hd()
        |> String.replace_prefix("upload-entry-", "")

      view
      |> element(~s(#task-form button[phx-click="cancel-attachment"][phx-value-ref="#{large}"]))
      |> render_click()

      refute has_element?(view, save <> "[disabled]")
      refute has_element?(view, "#task-attachments-blocked")
    end

    # A browser never sends this submit (see the test above); the server
    # still names every file it did not store if one arrives.
    test "names a staged file that never finished uploading instead of dropping it",
         %{conn: conn} do
      Application.put_env(:kanban, Kanban.Attachments.Limits, max_file_bytes: 16)
      {view, column} = open_new_task(conn)

      view
      |> stage([
        text_file("fine.txt", "hello"),
        text_file("large.txt", String.duplicate("x", 64))
      ])
      |> submit("With a refused file", column)

      assert Repo.get_by(Task, title: "With a refused file")
      assert Repo.all(TaskAttachment) == []
      html = render(view)
      assert html =~ "Could not upload large.txt: " <> AttachmentUploads.error_message(:too_large)
      assert html =~ "Could not upload fine.txt: " <> AttachmentUploads.error_message(:incomplete)
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

  describe "blocker/2" do
    defp conf(entries, errors \\ []),
      do: %Phoenix.LiveView.UploadConfig{
        name: :task_attachments,
        ref: "u",
        entries: entries,
        errors: errors
      }

    test "is nil unless the field is open with an upload" do
      assert AttachmentStaging.blocker(:hidden, nil) == nil
      assert AttachmentStaging.blocker(:locked, conf([], [{"u", :too_many_files}])) == nil
      assert AttachmentStaging.blocker(:open, false) == nil
      assert AttachmentStaging.blocker(:open, conf([])) == nil
    end

    test "is :errors while a staged file or the upload has an error" do
      entry = %Phoenix.LiveView.UploadEntry{ref: "1", valid?: false}
      assert AttachmentStaging.blocker(:open, conf([entry], [{"1", :too_large}])) == :errors
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
