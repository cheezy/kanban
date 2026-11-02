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

  describe "display_name/1 and failure_sentence/1" do
    test "display_name/1 shows a client name the way it would be stored" do
      assert AttachmentUploads.display_name("report.pdf") == "report.pdf"
      assert AttachmentUploads.display_name("../../a\u202Etxt.exe") == "atxt.exe"
      assert AttachmentUploads.display_name("  zero\u200Bwidth.txt ") == "zerowidth.txt"
      assert AttachmentUploads.display_name("👨\u200D👩\u200D👧.png") == "👨\u200D👩\u200D👧.png"

      capped = AttachmentUploads.display_name(String.duplicate("b", 5000) <> ".txt")
      assert String.length(capped) == Kanban.Attachments.Filename.max_codepoints()
    end

    test "display_name/1 shows a placeholder for a name with nothing left to show" do
      for raw <- ["", "   ", "\u202E", "..", "dir/", <<0xFF>>, nil] do
        assert AttachmentUploads.display_name(raw) == "unnamed file", inspect(raw)
      end
    end

    test "failure_sentence/1 names the cleaned file and the translated reason" do
      assert AttachmentUploads.failure_sentence({"a\u202Etxt.exe", :too_large}) ==
               "Could not upload atxt.exe: " <> AttachmentUploads.error_message(:too_large)

      assert AttachmentUploads.failure_sentence({"    ", :empty}) ==
               "Could not upload unnamed file: " <> AttachmentUploads.error_message(:empty)
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

    test "the file-count sentence is pluralised" do
      put_limits(max_files_per_task: 1)
      assert AttachmentUploads.error_message(:too_many_files) == "A task can hold at most 1 file."

      put_limits(max_files_per_task: 3)

      assert AttachmentUploads.error_message(:too_many_files) ==
               "A task can hold at most 3 files."
    end

    test "the quota sentence says the file does not fit, not that storage is used up" do
      assert AttachmentUploads.error_message(:quota_exceeded) ==
               "There is not enough attachment storage left for this file."
    end

    test "an unfinished upload has its own sentence" do
      assert AttachmentUploads.error_message(:incomplete) == "This file did not finish uploading."
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

  describe "store_blocker/2 and blocked_message/1" do
    defp staged(attrs),
      do: struct(%Phoenix.LiveView.UploadEntry{ref: "0", valid?: true, done?: true}, attrs)

    defp config(entries, errors \\ []),
      do: %Phoenix.LiveView.UploadConfig{name: :files, ref: "u", entries: entries, errors: errors}

    test "nothing blocks valid files that fit, or nothing staged" do
      assert [] |> config() |> AttachmentUploads.store_blocker(0) == nil
      assert [staged(%{ref: "1"})] |> config() |> AttachmentUploads.store_blocker(1) == nil
    end

    # LiveView's client drops a submit while the input carries error refs.
    test "an upload error blocks, whatever the room" do
      upload =
        config([staged(%{ref: "1"}), staged(%{ref: "2", valid?: false})], [{"2", :too_large}])

      assert AttachmentUploads.store_blocker(upload, 20) == :errors
      full = config([], [{"u", :too_many_files}])
      assert AttachmentUploads.store_blocker(full, 20) == :errors
    end

    test "more valid, uncancelled files than the room blocks" do
      two = config([staged(%{ref: "1"}), staged(%{ref: "2"})])
      assert AttachmentUploads.store_blocker(two, 1) == {:over_room, 1}
      assert AttachmentUploads.store_blocker(two, 0) == {:over_room, 0}

      one_cancelled = config([staged(%{ref: "1"}), staged(%{ref: "2", cancelled?: true})])
      assert AttachmentUploads.store_blocker(one_cancelled, 1) == nil
    end

    test "each blocker says what to do" do
      assert AttachmentUploads.blocked_message(nil) == nil

      assert AttachmentUploads.blocked_message(:errors) ==
               "Cancel the files marked with an error to upload the others."

      assert AttachmentUploads.blocked_message({:over_room, 0}) ==
               "This task has no room for more files. Delete a file or cancel the staged ones."

      assert AttachmentUploads.blocked_message({:over_room, 2}) ==
               "This task has room for 2 more files. Cancel some files to upload the rest."
    end

    test "full_message/0 names the limit and how to make room" do
      put_limits = Application.get_env(:kanban, Limits)
      Application.put_env(:kanban, Limits, max_files_per_task: 1)

      try do
        assert AttachmentUploads.full_message() ==
                 "A task can hold at most 1 file. Delete a file to upload another."
      after
        if put_limits,
          do: Application.put_env(:kanban, Limits, put_limits),
          else: Application.delete_env(:kanban, Limits)
      end
    end
  end
end
