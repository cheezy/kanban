defmodule Kanban.AttachmentsTest do
  # Not async: tests swap the application-wide storage adapter, attachment
  # limits and plan enforcement.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments
  alias Kanban.Attachments.BlobDeletion
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Attachments.Usage
  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Tasks.Comments
  alias Kanban.Tasks.Task

  @moduletag :tmp_dir

  @uploaded [:kanban, :attachment, :uploaded]
  @refused [:kanban, :attachment, :upload_refused]
  @downloaded [:kanban, :attachment, :downloaded]
  @deleted [:kanban, :attachment, :deleted]
  @feature_refused [:kanban, :plan, :feature_refused]
  @owner_delete [:kanban, :audit, :attachment_deleted_by_owner]

  defmodule HookAdapter do
    @moduledoc false
    # Delegates to the local adapter, reporting each call to the calling
    # process and letting a test replace a put or a delete result. The facade
    # calls the adapter in the caller's process, so the process dictionary is
    # the test's own.
    @behaviour Kanban.Attachments.Storage

    alias Kanban.Attachments.Storage.Local

    @impl true
    def put(key, source, opts) do
      send(self(), {:storage_put, key})

      case Process.get(:on_put) do
        nil -> Local.put(key, source, opts)
        fun -> fun.(key, source, opts)
      end
    end

    @impl true
    def stream(key), do: Local.stream(key)

    @impl true
    def delete(key) do
      send(self(), {:storage_deleted, key})

      case Process.get(:delete_result) do
        nil -> Local.delete(key)
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end

    @impl true
    def exists(key), do: Local.exists(key)
  end

  setup do
    restore_env_on_exit(Storage)
    restore_env_on_exit(Limits)
    Application.put_env(:kanban, Storage, adapter: HookAdapter)

    owner = user_fixture()
    personal_board = board_fixture(owner)
    personal_workspace_id = personal_board.workspace_id
    organization = organization_fixture()
    board = owner |> board_fixture() |> move_board_to_organization(organization)
    join_board_organization(board, owner)

    modifier = user_fixture()
    reader = user_fixture()
    join_board_organization(board, modifier)
    join_board_organization(board, reader)
    {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

    task = board |> column_fixture() |> task_fixture()

    %{
      owner: owner,
      modifier: modifier,
      reader: reader,
      stranger: user_fixture(),
      organization: organization,
      board: board,
      task: task,
      personal_board: personal_board,
      personal_workspace_id: personal_workspace_id
    }
  end

  defp restore_env_on_exit(key) do
    previous = Application.get_env(:kanban, key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, key, previous),
        else: Application.delete_env(:kanban, key)
    end)
  end

  defp put_limits(limits) do
    Application.put_env(
      :kanban,
      Limits,
      Keyword.merge(Application.get_env(:kanban, Limits, []), limits)
    )
  end

  defp scope(user), do: Scope.for_user(user)

  defp upload(dir, name, bytes, content_type \\ "text/plain") do
    path = Path.join(dir, "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, bytes)
    %{path: path, filename: name, content_type: content_type}
  end

  defp text_upload(ctx, bytes \\ "hello attachment\n"),
    do: upload(ctx.tmp_dir, "notes.txt", bytes)

  defp comment_by(user, task) do
    {:ok, comment} = user |> scope() |> Comments.create_comment(task, %{"content" => "see file"})
    comment
  end

  defp row_count(task),
    do: TaskAttachment |> where([a], a.task_id == ^task.id) |> Repo.aggregate(:count)

  defp tombstone(key), do: Repo.get_by(BlobDeletion, storage_key: key)

  defp leave_organization(board, workspace_id) do
    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace_id])
  end

  describe "create_attachment/4" do
    test "create_attachment stores the blob and inserts the row for a modify member", ctx do
      bytes = "hello attachment\n"
      file = ctx |> text_upload(bytes) |> Map.put(:byte_size, 999_999)

      assert {:ok, attachment} =
               ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, file)

      assert attachment.task_id == ctx.task.id
      assert attachment.board_id == ctx.board.id
      assert attachment.uploaded_by_id == ctx.modifier.id
      assert attachment.comment_id == nil
      assert attachment.filename == "notes.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.byte_size == byte_size(bytes)
      assert attachment.sha256 == :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      assert String.starts_with?(attachment.storage_key, "boards/#{ctx.board.id}/")
      assert Storage.exists(attachment.storage_key) == {:ok, true}
      assert tombstone(attachment.storage_key) == nil
    end

    test "the owner can upload too", ctx do
      assert {:ok, attachment} =
               ctx.owner |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert attachment.uploaded_by_id == ctx.owner.id
    end

    test "create_attachment attaches to a comment the uploader wrote on the same task", ctx do
      comment = comment_by(ctx.modifier, ctx.task)

      assert {:ok, attachment} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx), comment: comment)

      assert attachment.comment_id == comment.id
      assert attachment.task_id == ctx.task.id
    end

    test "create_attachment refuses a comment from another task", ctx do
      other_task = ctx.board |> column_fixture() |> task_fixture()
      foreign = comment_by(ctx.modifier, other_task)

      assert {:error, :not_found} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx), comment: foreign)

      someone_elses = comment_by(ctx.owner, ctx.task)

      assert {:error, :unauthorized} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx),
                 comment: someone_elses
               )

      gone = comment_by(ctx.modifier, ctx.task)
      Repo.delete!(gone)

      assert {:error, :not_found} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx), comment: gone)

      assert row_count(ctx.task) == 0
      refute_received {:storage_put, _}
    end

    test "create_attachment refuses a read_only member with unauthorized", ctx do
      assert {:error, :unauthorized} =
               ctx.reader |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert row_count(ctx.task) == 0
      refute_received {:storage_put, _}
    end

    test "create_attachment returns not_found for a non-member", ctx do
      free_task = ctx.personal_board |> column_fixture() |> task_fixture()
      enforce_plans()
      attach_telemetry([@feature_refused, @refused])

      assert {:error, :not_found} =
               ctx.stranger
               |> scope()
               |> Attachments.create_attachment(free_task, text_upload(ctx))

      assert {:error, :not_found} =
               ctx.stranger
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert {:error, :not_found} = Attachments.create_attachment(nil, ctx.task, text_upload(ctx))

      assert {:error, :not_found} =
               ctx.owner |> scope() |> Attachments.create_attachment(%Task{}, %{})

      refute_received {:telemetry_event, _, _, _}
      refute_received {:storage_put, _}
    end

    test "create_attachment refuses a free board with plan_required when plans are enforced",
         ctx do
      task = ctx.personal_board |> column_fixture() |> task_fixture()
      enforce_plans()
      attach_telemetry([@feature_refused, @refused])

      assert {:error, {:plan_required, :attachments}} =
               ctx.owner |> scope() |> Attachments.create_attachment(task, text_upload(ctx))

      assert row_count(task) == 0
      refute_received {:storage_put, _}
      assert_received {:telemetry_event, @feature_refused, _, %{feature: :attachments}}
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "create_attachment accepts the 20th file and refuses the 21st on a task", ctx do
      put_limits(max_files_per_task: 20)
      for _ <- 1..19, do: attachment_fixture(ctx.task)

      assert {:ok, _twentieth} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert_received {:storage_put, _twentieth_key}

      assert {:error, :too_many_files} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      refute_received {:storage_put, _}
      assert row_count(ctx.task) == 20

      # The count is checked before the file is read at all.
      unread = %{path: Path.join(ctx.tmp_dir, "absent.txt"), filename: "a.txt", content_type: nil}

      assert {:error, :too_many_files} =
               ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, unread)
    end

    test "create_attachment refuses an upload that would exceed the Organization quota", ctx do
      put_limits(organization_quota_bytes: 100)
      sibling = ctx.owner |> board_fixture() |> move_board_to_organization(ctx.organization)
      attachment_fixture(sibling |> column_fixture() |> task_fixture(), %{byte_size: 90})

      assert {:error, :quota_exceeded} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(
                 ctx.task,
                 text_upload(ctx, "eleven char")
               )

      assert {:ok, _} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(
                 ctx.task,
                 text_upload(ctx, "ten chars!")
               )

      assert Usage.bytes_used({:organization, ctx.organization.id}) == 100

      assert {:error, :quota_exceeded} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx, "x"))

      assert row_count(ctx.task) == 1
    end

    test "create_attachment stores exactly the bytes it checked when the temp file grows later",
         ctx do
      upload = text_upload(ctx, "hello")
      parent = self()

      Process.put(:on_put, fn key, {:file, source} = from, opts ->
        File.write!(upload.path, String.duplicate("x", 100), [:append])
        send(parent, {:put_source, source})
        Storage.Local.put(key, from, opts)
      end)

      assert {:ok, attachment} =
               ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, upload)

      assert_received {:put_source, source}
      refute source == upload.path
      refute File.exists?(source)

      {:ok, stream} = Storage.stream(attachment.storage_key)
      assert Enum.join(stream) == "hello"
      assert attachment.byte_size == 5
    end

    test "create_attachment deletes the stored blob when the insert fails", ctx do
      comment = comment_by(ctx.modifier, ctx.task)

      Process.put(:on_put, fn key, source, opts ->
        :ok = Storage.Local.put(key, source, opts)
        Repo.delete!(comment)
        :ok
      end)

      assert {:error, :not_found} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx), comment: comment)

      assert_received {:storage_put, key}
      assert_received {:storage_deleted, ^key}
      assert Storage.exists(key) == {:ok, false}
      assert tombstone(key) == nil
      assert row_count(ctx.task) == 0
    end

    test "a failed blob delete after a failed insert leaves the tombstone for the worker", ctx do
      comment = comment_by(ctx.modifier, ctx.task)
      Process.put(:delete_result, {:error, :storage_unavailable})

      Process.put(:on_put, fn key, source, opts ->
        :ok = Storage.Local.put(key, source, opts)
        Repo.delete!(comment)
        :ok
      end)

      assert {:error, :not_found} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx), comment: comment)

      assert_received {:storage_put, key}
      assert %BlobDeletion{delete_after: due} = tombstone(key)
      assert DateTime.diff(due, DateTime.utc_now(), :second) in 3_500..3_600
      assert row_count(ctx.task) == 0
    end

    test "create_attachment refuses contradicting bytes without storing a blob", ctx do
      put_limits(max_file_bytes: 64)
      fake_png = upload(ctx.tmp_dir, "picture.png", "plain text, not an image", "image/png")
      exe = upload(ctx.tmp_dir, "tool.exe", "MZ binary", "application/x-msdownload")
      empty = upload(ctx.tmp_dir, "empty.txt", "")
      big = upload(ctx.tmp_dir, "big.txt", String.duplicate("a", 65))

      missing = %{
        path: Path.join(ctx.tmp_dir, "missing.txt"),
        filename: "missing.txt",
        content_type: "text/plain"
      }

      for {file, reason} <- [
            {fake_png, :type_mismatch},
            {exe, :type_not_allowed},
            {empty, :empty},
            {big, :too_large},
            {missing, :unreadable},
            {%{filename: "no-path.txt"}, :unreadable}
          ] do
        assert ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, file) ==
                 {:error, reason}
      end

      refute_received {:storage_put, _}
      assert row_count(ctx.task) == 0
      assert Repo.aggregate(BlobDeletion, :count) == 0
    end

    test "an invalid file name is a changeset error", ctx do
      file = upload(ctx.tmp_dir, "ok.txt", "text") |> Map.put(:filename, "..")

      assert {:error, %Ecto.Changeset{} = changeset} =
               ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, file)

      assert %{filename: [_ | _]} = errors_on(changeset)
      refute_received {:storage_put, _}
    end

    test "create_attachment returns storage_unavailable and inserts nothing when the put fails",
         ctx do
      Process.put(:on_put, fn _key, _source, _opts -> {:error, :storage_unavailable} end)

      assert {:error, :storage_unavailable} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert_received {:storage_put, key}
      assert_received {:storage_deleted, ^key}
      assert tombstone(key) == nil
      assert row_count(ctx.task) == 0
    end

    test "a put that raises, exits, throws or breaks the contract is storage_unavailable, not a crash",
         ctx do
      attach_telemetry([@refused])

      misbehaving = [
        fn _key, _source, _opts -> raise "Finch was unable to provide a connection" end,
        fn _key, _source, _opts -> exit(:timeout) end,
        fn _key, _source, _opts -> throw(:oops) end,
        fn key, source, opts ->
          :ok = Storage.Local.put(key, source, opts)
          {:ok, "etag"}
        end,
        fn _key, _source, _opts -> nil end
      ]

      for on_put <- misbehaving do
        Process.put(:on_put, on_put)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error, :storage_unavailable} =
                     ctx.modifier
                     |> scope()
                     |> Attachments.create_attachment(ctx.task, text_upload(ctx))
          end)

        assert log =~ "attachment storage put failed"
        refute log =~ "Finch"
        assert_received {:storage_put, key}
        assert_received {:storage_deleted, ^key}
        assert Storage.exists(key) == {:ok, false}
        assert tombstone(key) == nil

        assert_received {:telemetry_event, @refused, _, %{reason: :storage_unavailable}}
      end

      assert row_count(ctx.task) == 0
    end

    test "a discard delete that raises keeps the refusal and leaves the tombstone for the worker",
         ctx do
      attach_telemetry([@refused])
      Process.put(:on_put, fn _key, _source, _opts -> {:error, :storage_unavailable} end)
      Process.put(:delete_result, fn -> raise "connection reset" end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :storage_unavailable} =
                 ctx.modifier
                 |> scope()
                 |> Attachments.create_attachment(ctx.task, text_upload(ctx))
      end)

      assert_received {:storage_put, key}
      assert %BlobDeletion{attempts: 0} = tombstone(key)
      assert_received {:telemetry_event, @refused, _, %{reason: :storage_unavailable}}
    end

    test "an upload killed mid-put leaves no copy of the file in the temp directory", ctx do
      test_pid = self()

      Process.put(:on_put, fn _key, {:file, snapshot}, _opts ->
        send(test_pid, {:snapshot, snapshot, File.read!(snapshot)})
        Process.sleep(:infinity)
      end)

      # The spawned uploader needs the hook and the adapter the test set.
      on_put = Process.get(:on_put)
      upload = text_upload(ctx, "secret quarterly figures\n")
      scope = scope(ctx.modifier)

      uploader =
        spawn(fn ->
          Process.put(:on_put, on_put)

          receive do
            :go -> Attachments.create_attachment(scope, ctx.task, upload)
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, uploader)
      send(uploader, :go)

      assert_receive {:snapshot, snapshot, "secret quarterly figures\n"}, 5_000
      ref = Process.monitor(uploader)
      Process.exit(uploader, :kill)
      assert_receive {:DOWN, ^ref, :process, ^uploader, :killed}

      assert eventually(fn -> not File.exists?(snapshot) end)
      assert row_count(ctx.task) == 0
    end
  end

  # Plug's upload server removes a dead owner's files asynchronously.
  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  describe "list_task_attachments/2 and list_comment_attachments/2" do
    test "list_task_attachments returns task-level and comment-level attachments oldest first with comment_id",
         ctx do
      comment = comment_by(ctx.modifier, ctx.task)
      newest = attachment_fixture(ctx.task, %{inserted_at: ~N[2026-01-03 00:00:00]})

      on_comment =
        attachment_fixture(ctx.task, %{comment: comment, inserted_at: ~N[2026-01-02 00:00:00]})

      oldest = attachment_fixture(ctx.task, %{inserted_at: ~N[2026-01-01 00:00:00]})
      attachment_fixture(ctx.board |> column_fixture() |> task_fixture())

      assert {:ok, listed} = ctx.reader |> scope() |> Attachments.list_task_attachments(ctx.task)
      assert Enum.map(listed, & &1.id) == [oldest.id, on_comment.id, newest.id]
      assert Enum.map(listed, & &1.comment_id) == [nil, comment.id, nil]

      assert {:error, :not_found} =
               ctx.stranger |> scope() |> Attachments.list_task_attachments(ctx.task)

      assert {:error, :not_found} =
               ctx.owner |> scope() |> Attachments.list_task_attachments(%Task{})
    end

    test "both lists preload the uploader, nil once the uploader's account is deleted", ctx do
      comment = comment_by(ctx.modifier, ctx.task)
      by_modifier = attachment_fixture(ctx.task, %{uploaded_by: ctx.modifier, comment: comment})
      orphan = attachment_fixture(ctx.task)

      assert {:ok, listed} = ctx.reader |> scope() |> Attachments.list_task_attachments(ctx.task)
      by_id = Map.new(listed, &{&1.id, &1})
      assert by_id[by_modifier.id].uploaded_by.id == ctx.modifier.id
      assert by_id[orphan.id].uploaded_by == nil

      assert {:ok, [on_comment]} =
               ctx.reader |> scope() |> Attachments.list_comment_attachments(comment)

      assert on_comment.uploaded_by.id == ctx.modifier.id
    end

    test "list_task_attachments returns an empty list for a task with no attachments", ctx do
      attachment_fixture(ctx.board |> column_fixture() |> task_fixture())
      assert ctx.reader |> scope() |> Attachments.list_task_attachments(ctx.task) == {:ok, []}
    end

    test "list_comment_attachments returns only that comment's attachments", ctx do
      comment = comment_by(ctx.modifier, ctx.task)
      other_comment = comment_by(ctx.owner, ctx.task)
      mine = attachment_fixture(ctx.task, %{comment: comment})
      attachment_fixture(ctx.task, %{comment: other_comment})
      attachment_fixture(ctx.task)

      assert {:ok, [listed]} =
               ctx.reader |> scope() |> Attachments.list_comment_attachments(comment)

      assert listed.id == mine.id

      assert {:error, :not_found} =
               ctx.stranger |> scope() |> Attachments.list_comment_attachments(comment)

      Repo.delete!(comment)

      assert {:error, :not_found} =
               ctx.reader |> scope() |> Attachments.list_comment_attachments(comment)
    end
  end

  describe "list_attachments_by_task/3" do
    test "groups the files of the named tasks on the board, comment files included, oldest first",
         ctx do
      other_task = ctx.board |> column_fixture() |> task_fixture()
      first = attachment_fixture(ctx.task, %{uploaded_by: ctx.owner})
      comment = comment_by(ctx.owner, ctx.task)
      on_comment = attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, comment: comment})
      elsewhere = attachment_fixture(other_task, %{uploaded_by: ctx.owner})

      assert {:ok, by_task} =
               ctx.reader
               |> scope()
               |> Attachments.list_attachments_by_task(ctx.board.id, [ctx.task.id, other_task.id])

      assert Enum.map(by_task[ctx.task.id], & &1.id) == [first.id, on_comment.id]
      assert Enum.map(by_task[other_task.id], & &1.id) == [elsewhere.id]
      assert %Kanban.Accounts.User{} = hd(by_task[ctx.task.id]).uploaded_by
    end

    test "leaves out tasks that were not named and tasks on another board", ctx do
      unnamed = ctx.board |> column_fixture() |> task_fixture()
      attachment_fixture(unnamed, %{uploaded_by: ctx.owner})
      foreign = ctx.personal_board |> column_fixture() |> task_fixture()
      attachment_fixture(foreign, %{uploaded_by: ctx.owner})

      assert {:ok, by_task} =
               ctx.owner
               |> scope()
               |> Attachments.list_attachments_by_task(ctx.board.id, [ctx.task.id, foreign.id])

      assert by_task == %{}
    end

    test "refuses a non-member and a free board the way every list does", ctx do
      attachment_fixture(ctx.task, %{uploaded_by: ctx.owner})

      assert {:error, :not_found} =
               ctx.stranger
               |> scope()
               |> Attachments.list_attachments_by_task(ctx.board.id, [ctx.task.id])

      assert {:ok, %{}} =
               ctx.owner |> scope() |> Attachments.list_attachments_by_task(ctx.board.id, [])

      free_task = ctx.personal_board |> column_fixture() |> task_fixture()
      enforce_plans()

      assert ctx.owner
             |> scope()
             |> Attachments.list_attachments_by_task(ctx.personal_board.id, [free_task.id]) ==
               {:error, {:plan_required, :attachments}}

      assert {:error, :not_found} =
               ctx.owner |> scope() |> Attachments.list_attachments_by_task("1", [ctx.task.id])
    end
  end

  describe "fetch_for_download/2" do
    test "fetch_for_download allows a read_only member and returns not_found for a non-member",
         ctx do
      attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.modifier, byte_size: 12})
      attach_telemetry(@downloaded)

      assert {:ok, fetched} =
               ctx.reader |> scope() |> Attachments.fetch_for_download(attachment.id)

      assert fetched.id == attachment.id

      assert_received {:telemetry_event, @downloaded, %{count: 1, byte_size: 12}, metadata}

      assert metadata == %{
               attachment_id: attachment.id,
               task_id: ctx.task.id,
               board_id: ctx.board.id,
               user_id: ctx.reader.id,
               via: :download
             }

      assert {:error, :not_found} =
               ctx.stranger |> scope() |> Attachments.fetch_for_download(attachment.id)

      assert {:error, :not_found} = ctx.reader |> scope() |> Attachments.fetch_for_download(-1)

      assert {:error, :not_found} =
               ctx.reader |> scope() |> Attachments.fetch_for_download("#{attachment.id}")

      assert {:error, :not_found} = ctx.reader |> scope() |> Attachments.fetch_for_download(nil)
      refute_received {:telemetry_event, @downloaded, _, _}
    end

    test "fetch_for_download/3 records a preview as via :preview", ctx do
      attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.modifier})
      attach_telemetry(@downloaded)

      assert {:ok, _} =
               ctx.reader |> scope() |> Attachments.fetch_for_download(attachment.id, :preview)

      assert_received {:telemetry_event, @downloaded, %{count: 1}, %{via: :preview}}
    end

    test "fetch_for_download/3 refuses a via outside :download, :preview and :head", ctx do
      attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.modifier})

      # Built at runtime: a literal would be flagged by the type checker.
      unknown_via = String.to_existing_atom("inline")

      assert_raise FunctionClauseError, fn ->
        ctx.reader |> scope() |> Attachments.fetch_for_download(attachment.id, unknown_via)
      end
    end
  end

  describe "delete_attachment/2" do
    test "delete_attachment lets the uploader delete and queues the blob for deletion", ctx do
      attach_telemetry([@deleted, @owner_delete])

      {:ok, attachment} =
        ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert {:ok, deleted} = ctx.modifier |> scope() |> Attachments.delete_attachment(attachment)

      assert deleted.id == attachment.id
      refute Repo.get(TaskAttachment, attachment.id)
      assert %BlobDeletion{} = tombstone(attachment.storage_key)
      refute_received {:storage_deleted, _}

      assert_received {:telemetry_event, @deleted, %{count: 1},
                       %{attachment_id: id, user_id: uid}}

      assert {id, uid} == {attachment.id, ctx.modifier.id}
      refute_received {:telemetry_event, @owner_delete, _, _}
    end

    test "an uploader removed from the board can no longer delete their file", ctx do
      attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.modifier})
      {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.modifier, ctx.owner)

      assert {:error, :not_found} =
               ctx.modifier |> scope() |> Attachments.delete_attachment(attachment)

      assert Repo.get(TaskAttachment, attachment.id)
    end

    test "delete_attachment lets the owner delete another member's attachment and audits it",
         ctx do
      attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.modifier})
      own = attachment_fixture(ctx.task, %{uploaded_by: ctx.owner})
      attach_telemetry(@owner_delete)

      assert {:ok, _} = ctx.owner |> scope() |> Attachments.delete_attachment(attachment)

      assert_received {:telemetry_event, @owner_delete, _, metadata}

      assert metadata == %{
               user_id: ctx.owner.id,
               organization_id: ctx.organization.id,
               board_id: ctx.board.id,
               task_id: ctx.task.id,
               attachment_id: attachment.id,
               uploaded_by_id: ctx.modifier.id
             }

      refute inspect(metadata) =~ attachment.filename

      assert {:ok, _} = ctx.owner |> scope() |> Attachments.delete_attachment(own)
      refute_received {:telemetry_event, @owner_delete, _, _}
    end

    test "an owner delete on an Organization board is listed in that Organization's audit log",
         ctx do
      attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.modifier})

      assert {:ok, _} = ctx.owner |> scope() |> Attachments.delete_attachment(attachment)

      assert [event] =
               AuditLog.list_events(
                 organization_id: ctx.organization.id,
                 action: :attachment_deleted_by_owner
               )

      assert event.actor_user_id == ctx.owner.id
      assert event.organization_id == ctx.organization.id
      assert event.actor_in_organization == true
    end

    test "an owner delete on a board outside any Organization records no organization_id",
         ctx do
      modifier = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.personal_board, modifier, :modify, ctx.owner)
      task = ctx.personal_board |> column_fixture() |> task_fixture()
      attachment = attachment_fixture(task, %{uploaded_by: modifier})
      attach_telemetry(@owner_delete)

      assert {:ok, _} = ctx.owner |> scope() |> Attachments.delete_attachment(attachment)

      assert_received {:telemetry_event, @owner_delete, _, metadata}
      refute Map.has_key?(metadata, :organization_id)
      assert metadata.board_id == ctx.personal_board.id

      assert [event] = AuditLog.list_events(action: :attachment_deleted_by_owner)
      assert event.organization_id == nil
    end

    test "delete_attachment refuses a modify member who did not upload", ctx do
      attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.owner})

      assert {:error, :unauthorized} =
               ctx.modifier |> scope() |> Attachments.delete_attachment(attachment)

      assert {:error, :unauthorized} =
               ctx.reader |> scope() |> Attachments.delete_attachment(attachment)

      assert {:error, :not_found} =
               ctx.stranger |> scope() |> Attachments.delete_attachment(attachment)

      assert Repo.get(TaskAttachment, attachment.id)

      assert {:error, :not_found} =
               ctx.owner |> scope() |> Attachments.delete_attachment(%TaskAttachment{})
    end
  end

  describe "plan gate and Organization moves" do
    test "list, fetch_for_download and delete refuse a free board with plan_required when plans are enforced",
         ctx do
      task = ctx.personal_board |> column_fixture() |> task_fixture()
      attachment = attachment_fixture(task, %{uploaded_by: ctx.owner})
      comment = comment_by(ctx.owner, task)
      enforce_plans()

      plan_required = {:error, {:plan_required, :attachments}}
      assert ctx.owner |> scope() |> Attachments.list_task_attachments(task) == plan_required

      assert ctx.owner |> scope() |> Attachments.list_comment_attachments(comment) ==
               plan_required

      assert ctx.owner |> scope() |> Attachments.fetch_for_download(attachment.id) ==
               plan_required

      assert ctx.owner |> scope() |> Attachments.delete_attachment(attachment) == plan_required
      assert Repo.get(TaskAttachment, attachment.id)
    end

    test "files on a board that left its Organization stay stored and list again after it moves back into one",
         ctx do
      {:ok, attachment} =
        ctx.owner |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      leave_organization(ctx.board, ctx.personal_workspace_id)
      enforce_plans()

      plan_required = {:error, {:plan_required, :attachments}}
      assert ctx.owner |> scope() |> Attachments.list_task_attachments(ctx.task) == plan_required

      assert ctx.owner |> scope() |> Attachments.fetch_for_download(attachment.id) ==
               plan_required

      assert ctx.owner |> scope() |> Attachments.delete_attachment(attachment) == plan_required
      assert Repo.get(TaskAttachment, attachment.id)
      assert Storage.exists(attachment.storage_key) == {:ok, true}
      assert Usage.bytes_used({:organization, ctx.organization.id}) == 0

      move_board_to_organization(ctx.board, ctx.organization)

      assert {:ok, [listed]} = ctx.owner |> scope() |> Attachments.list_task_attachments(ctx.task)
      assert listed.id == attachment.id

      assert Usage.bytes_used({:organization, ctx.organization.id}) == attachment.byte_size

      leave_organization(ctx.board, ctx.personal_workspace_id)
      Task |> Repo.get!(ctx.task.id) |> Repo.delete!()

      assert %BlobDeletion{} = tombstone(attachment.storage_key)
    end

    test "a board outside an Organization reads and writes normally when plans are not enforced",
         ctx do
      task = ctx.personal_board |> column_fixture() |> task_fixture()

      assert {:ok, attachment} =
               ctx.owner |> scope() |> Attachments.create_attachment(task, text_upload(ctx))

      assert {:ok, [_]} = ctx.owner |> scope() |> Attachments.list_task_attachments(task)
      assert {:ok, _} = ctx.owner |> scope() |> Attachments.fetch_for_download(attachment.id)
      assert Usage.quota_scope(ctx.personal_board.id) == {:board, ctx.personal_board.id}
      assert {:ok, _} = ctx.owner |> scope() |> Attachments.delete_attachment(attachment)
    end
  end

  describe "telemetry and broadcasts" do
    test "create_attachment emits uploaded with ids only and never the filename", ctx do
      attach_telemetry(@uploaded)
      comment = comment_by(ctx.modifier, ctx.task)
      file = upload(ctx.tmp_dir, "quarterly-secret-plan.txt", "contents\n")

      {:ok, attachment} =
        ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, file, comment: comment)

      assert_received {:telemetry_event, @uploaded, %{count: 1, byte_size: 9}, metadata}

      assert metadata == %{
               attachment_id: attachment.id,
               task_id: ctx.task.id,
               board_id: ctx.board.id,
               comment_id: comment.id,
               user_id: ctx.modifier.id,
               source: :upload
             }

      refute inspect(metadata) =~ "quarterly"
      refute inspect(metadata) =~ attachment.sha256
    end

    test "a refused upload emits upload_refused with its reason", ctx do
      attach_telemetry(@refused)
      put_limits(max_files_per_task: 1)
      exe = upload(ctx.tmp_dir, "tool.exe", "MZ binary", "application/x-msdownload")

      assert {:error, :type_not_allowed} =
               ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, exe)

      assert_received {:telemetry_event, @refused, %{count: 1}, %{reason: :type_not_allowed}}

      attachment_fixture(ctx.task)

      assert {:error, :too_many_files} =
               ctx.modifier
               |> scope()
               |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert_received {:telemetry_event, @refused, %{count: 1}, metadata}

      assert metadata == %{
               reason: :too_many_files,
               source: :upload,
               task_id: ctx.task.id,
               board_id: ctx.board.id,
               user_id: ctx.modifier.id
             }

      assert {:error, :unauthorized} =
               ctx.reader |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      refute_received {:telemetry_event, @refused, _, _}
    end

    test "a file the changeset refuses emits upload_refused invalid_file and returns the changeset",
         ctx do
      attach_telemetry(@refused)

      for name <- ["", "   ", "/", ".", ".."] do
        bad = upload(ctx.tmp_dir, "x.txt", "hello\n") |> Map.put(:filename, name)

        assert {:error, %Ecto.Changeset{} = changeset} =
                 ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, bad)

        assert Keyword.has_key?(changeset.errors, :filename)

        assert_received {:telemetry_event, @refused, %{count: 1}, metadata}

        assert metadata == %{
                 reason: :invalid_file,
                 source: :upload,
                 task_id: ctx.task.id,
                 board_id: ctx.board.id,
                 user_id: ctx.modifier.id
               }
      end

      assert row_count(ctx.task) == 0
    end

    test "uploaded and upload_refused carry source upload", ctx do
      attach_telemetry([@uploaded, @refused])

      {:ok, _} =
        ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      {:error, :empty} =
        ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx, ""))

      assert_received {:telemetry_event, @uploaded, _, %{source: :upload}}
      assert_received {:telemetry_event, @refused, _, %{source: :upload, reason: :empty}}
    end

    test "create and delete broadcast attachment_changed on the board topic", ctx do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")
      payload = %{task_id: ctx.task.id, board_id: ctx.board.id}

      {:ok, attachment} =
        ctx.modifier |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      assert_received {Attachments, :attachment_changed, ^payload}

      {:error, :unauthorized} =
        ctx.reader |> scope() |> Attachments.create_attachment(ctx.task, text_upload(ctx))

      refute_received {Attachments, :attachment_changed, _}

      {:ok, _} = ctx.modifier |> scope() |> Attachments.delete_attachment(attachment)
      assert_received {Attachments, :attachment_changed, ^payload}
    end
  end
end
