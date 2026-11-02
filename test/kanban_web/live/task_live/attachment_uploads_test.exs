defmodule KanbanWeb.TaskLive.AttachmentUploadsTest do
  # Not async: the tests change the Kanban.Attachments.Limits app env.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.Limits
  alias Kanban.Tasks.Comments
  alias KanbanWeb.TaskLive.AttachmentUploads

  setup do
    previous = Application.get_env(:kanban, Limits)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, Limits, previous),
        else: Application.delete_env(:kanban, Limits)
    end)

    :ok
  end

  defp bare_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  defp put_limits(limits), do: Application.put_env(:kanban, Limits, limits)

  describe "allow/3" do
    test "builds the accept list and limits from Goal A's configuration" do
      put_limits(max_file_bytes: 1234, max_files_per_task: 3)

      conf = AttachmentUploads.allow(bare_socket(), :files).assigns.uploads.files

      assert conf.max_file_size == 1234
      assert conf.max_entries == 3
      assert conf.auto_upload?
      assert conf.accept == Enum.join(AttachmentUploads.accept(), ",")
      accepted = String.split(conf.accept, ",")

      for type <- ContentType.allowed() do
        assert type in accepted
      end
    end

    test "uses the default limits when none are configured" do
      Application.delete_env(:kanban, Limits)

      conf = AttachmentUploads.allow(bare_socket(), :files).assigns.uploads.files

      assert conf.max_file_size == 26_214_400
      assert conf.max_entries == 20
    end

    test "allow merges caller options such as auto_upload false" do
      conf =
        bare_socket()
        |> AttachmentUploads.allow(:comment_files, auto_upload: false, max_entries: 2)
        |> Map.fetch!(:assigns)
        |> Map.fetch!(:uploads)
        |> Map.fetch!(:comment_files)

      refute conf.auto_upload?
      assert conf.max_entries == 2
    end
  end

  describe "upload_allowed?/2" do
    test "is false before the upload is allowed" do
      refute AttachmentUploads.upload_allowed?(bare_socket(), :files)
    end

    test "is true once allowed and false again after disallow_upload/2" do
      socket = AttachmentUploads.allow(bare_socket(), :files)
      assert AttachmentUploads.upload_allowed?(socket, :files)

      socket = Phoenix.LiveView.disallow_upload(socket, :files)
      # The config keeps its key, marked allowed?: false.
      assert Map.has_key?(socket.assigns.uploads, :files)
      refute AttachmentUploads.upload_allowed?(socket, :files)
    end

    test "is true again after a disallowed upload is allowed anew" do
      socket =
        bare_socket()
        |> AttachmentUploads.allow(:files)
        |> Phoenix.LiveView.disallow_upload(:files)
        |> AttachmentUploads.allow(:files)

      assert AttachmentUploads.upload_allowed?(socket, :files)
    end

    test "reads only the named upload" do
      socket = AttachmentUploads.allow(bare_socket(), :files)
      refute AttachmentUploads.upload_allowed?(socket, :comment_attachments)
    end
  end

  describe "accept/0" do
    test "lists every allowed type and every extension with a known MIME type" do
      accept = AttachmentUploads.accept()

      assert ".png" in accept
      assert ".pdf" in accept
      assert ".csv" in accept
      assert "text/plain" in accept
      assert Enum.all?(ContentType.allowed(), &(&1 in accept))

      # .log has no MIME type LiveView knows, so it is accepted as text/plain.
      refute ".log" in accept
    end
  end

  describe "error_message/1" do
    test "error_message translates every upload and context error" do
      put_limits(max_file_bytes: 2048, max_files_per_task: 7)

      reasons = [
        :too_large,
        :not_accepted,
        :type_not_allowed,
        :type_mismatch,
        :too_many_files,
        :empty,
        :unreadable,
        :quota_exceeded,
        :storage_unavailable,
        :external_client_failure,
        {:plan_required, :attachments},
        :unauthorized,
        :not_found,
        %Ecto.Changeset{},
        :something_unexpected
      ]

      for reason <- reasons do
        message = AttachmentUploads.error_message(reason)
        assert is_binary(message) and message != "", "no message for #{inspect(reason)}"
      end

      assert AttachmentUploads.error_message(:too_large) =~ "2.0 KB"
      assert AttachmentUploads.error_message(:too_many_files) =~ "7"

      assert AttachmentUploads.error_message(:not_accepted) ==
               AttachmentUploads.error_message(:type_not_allowed)
    end

    test "error_message is translated into the current locale" do
      Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
        refute AttachmentUploads.error_message(:not_accepted) == "This file type is not allowed."
      end)
    end
  end

  describe "store_file/4 and store_entries/4" do
    setup do
      owner = user_fixture()
      board = board_fixture(owner)
      task = board |> column_fixture() |> task_fixture()
      %{owner: owner, task: task, scope: Scope.for_user(owner)}
    end

    @tag :tmp_dir
    test "store_entries passes the comment_id through when given", ctx do
      {:ok, comment} = Comments.create_comment(ctx.scope, ctx.task, %{"content" => "logs"})
      path = Path.join(ctx.tmp_dir, "notes.txt")
      File.write!(path, "hello world")
      entry = %{client_name: "notes.txt", client_type: "text/plain"}

      assert {:ok, on_comment} =
               AttachmentUploads.store_file(ctx.scope, path, entry, %{
                 task: ctx.task,
                 comment_id: comment.id
               })

      assert on_comment.comment_id == comment.id
      assert on_comment.filename == "notes.txt"
      assert on_comment.byte_size == 11

      assert {:ok, on_task} =
               AttachmentUploads.store_file(ctx.scope, path, entry, %{task: ctx.task})

      assert on_task.comment_id == nil
    end

    @tag :tmp_dir
    test "store_file returns the context's refusal", ctx do
      path = Path.join(ctx.tmp_dir, "tool.exe")
      File.write!(path, "MZ binary")
      entry = %{client_name: "tool.exe", client_type: "application/x-msdownload"}

      assert {:error, :type_not_allowed} =
               AttachmentUploads.store_file(ctx.scope, path, entry, %{task: ctx.task})

      reader_scope = Scope.for_user(user_fixture())

      assert {:error, :not_found} =
               AttachmentUploads.store_file(reader_scope, path, entry, %{task: ctx.task})
    end

    test "store_entries returns empty lists when nothing has finished uploading", ctx do
      socket = AttachmentUploads.allow(bare_socket(), :files)

      assert AttachmentUploads.store_entries(socket, :files, ctx.scope, %{task: ctx.task}) ==
               %{stored: [], failed: []}
    end
  end
end
