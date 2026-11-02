defmodule Kanban.Attachments.Pipeline do
  @moduledoc false
  # The scope-free core of creating an attachment, shared by
  # `Kanban.Attachments.create_attachment/4` and, later, the Jira import's
  # `import_attachment/4`. It never authorizes and never broadcasts: the
  # caller has already resolved the board through the task's column, checked
  # access and the plan, and built the base struct with the server-set ids.
  #
  # The steps, in order (docs/plans/ATTACHMENTS-DESIGN.md §4.2):
  #
  #   1. Pre-check the per-task count, which needs no file IO.
  #   2. Refuse an empty or too large temp file from File.stat (never a
  #      client value) before reading it, then read it exactly once into a
  #      private snapshot capped one byte past the limit. byte_size is the
  #      snapshot's size, and every later step reads the snapshot, which is
  #      removed when the call ends.
  #   3. Hash the snapshot for its sha256.
  #   4. Build the changeset, which sniffs the contents against the type, and
  #      pre-check the quota, all before anything is stored.
  #   5. Park a pending tombstone for the new key, due one hour later, then
  #      put the snapshot.
  #   6. In one transaction: key-share lock the uploader, board and comment
  #      rows, lock the task row, then the quota scope's advisory lock,
  #      re-check count and quota, insert, and remove the pending tombstone,
  #      refusing with :storage_unavailable if the cleanup worker has
  #      already claimed the key (its attempts are no longer 0).
  #   7. If the put or the transaction fails, delete the blob and, only when
  #      that succeeds, its tombstone; otherwise the tombstone stays for the
  #      cleanup worker.
  #
  # Telemetry: `uploaded` after the insert commits, `upload_refused` for each
  # of the seven refusal reasons. Metadata carries ids, sizes and the reason
  # only, never the filename, the contents or the hash.

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Kanban.Attachments.BlobDeletion
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Attachments.Usage
  alias Kanban.Repo

  # Longer than any realistic upload, so the cleanup worker never removes a
  # blob that is still being stored.
  @pending_grace_seconds 3_600
  @chunk_bytes 65_536
  @not_allowed "is not an allowed type"
  @fk_fields [:task_id, :comment_id, :board_id, :uploaded_by_id]

  @refusal_reasons [
    :too_large,
    :type_not_allowed,
    :type_mismatch,
    :empty,
    :too_many_files,
    :quota_exceeded,
    :storage_unavailable
  ]

  @type upload :: %{path: Path.t(), filename: String.t(), content_type: String.t() | nil}
  @type source :: :upload | :import

  @doc false
  @spec refusal_reasons() :: [atom()]
  def refusal_reasons, do: @refusal_reasons

  @doc false
  @spec create(TaskAttachment.t(), term(), [{:source, source()}]) ::
          {:ok, TaskAttachment.t()} | {:error, atom() | Changeset.t()}
  def create(%TaskAttachment{} = base, upload, opts) do
    source = Keyword.fetch!(opts, :source)

    base
    |> run(upload)
    |> report(base, source)
  end

  defp run(base, upload) do
    with {:ok, file, attrs} <- read_upload(upload, base.task_id) do
      try do
        prepare_and_store(base, attrs, file)
      after
        remove_snapshot(file.path)
      end
    end
  end

  defp prepare_and_store(base, attrs, file) do
    with {:ok, changeset, key} <- prepare(base, attrs, file) do
      store(changeset, key, file)
    end
  end

  # The caller's file is read exactly once, into a private snapshot capped one
  # byte past the size limit. Its size, sha256, sniff and the stored bytes all
  # come from the snapshot, so a file that grows or is rewritten after the
  # size check can never store bytes that differ from what was checked and
  # counted against the quota.
  defp inspect_file(path) do
    with {:ok, _size} <- file_size(path),
         {:ok, snapshot, size} <- snapshot(path) do
      hash_snapshot(snapshot, size)
    end
  end

  defp hash_snapshot(snapshot, size) do
    case sha256(snapshot) do
      {:ok, sha256} -> {:ok, %{path: snapshot, size: size, sha256: sha256}}
      {:error, reason} -> discard_snapshot(snapshot, reason)
    end
  end

  # The snapshot is a Plug.Upload temp file, so Plug's upload server removes
  # it when this process ends, whatever ends it. The `after` in run/2 removes
  # it sooner on every normal return, but an exit signal (a LiveView killed
  # mid-upload, a shutdown) skips `after` clauses and left a full copy of the
  # user's file in the temp directory for good (G488 exploratory campaign,
  # 2026-11-02).
  defp snapshot(source) do
    with {:ok, target} <- Plug.Upload.random_file("stride-upload"),
         {:ok, device} <- File.open(target, [:write, :binary]) do
      copied = copy_capped(source, device, target)
      _ = File.close(device)
      settle_snapshot(copied, target)
    else
      _error -> {:error, :unreadable}
    end
  end

  defp copy_capped(source, device, target) do
    with :ok <- File.chmod(target, 0o600) do
      :file.copy(source, device, Limits.max_file_bytes() + 1)
    end
  end

  # A refused or failed snapshot is removed here, so the caller only ever
  # holds a snapshot path that it must clean up itself.
  defp settle_snapshot({:ok, 0}, target), do: discard_snapshot(target, :empty)

  defp settle_snapshot({:ok, size}, target) do
    if size > Limits.max_file_bytes(),
      do: discard_snapshot(target, :too_large),
      else: {:ok, target, size}
  end

  defp settle_snapshot(_error, target), do: discard_snapshot(target, :unreadable)

  defp discard_snapshot(snapshot, reason) do
    remove_snapshot(snapshot)
    {:error, reason}
  end

  # Plug.Upload.delete/1 also drops Plug's record of the file, which a
  # long-lived caller such as a LiveView would otherwise accumulate.
  defp remove_snapshot(snapshot) do
    _ = Plug.Upload.delete(snapshot)
    :ok
  end

  # Everything that can refuse the file before it is stored: the changeset,
  # then the quota.
  defp prepare(%TaskAttachment{board_id: board_id} = base, attrs, file) do
    key = storage_key(board_id)

    with {:ok, changeset} <- build_changeset(base, key, attrs, file),
         :ok <- Usage.check_limits(base.task_id, Usage.quota_scope(board_id), file.size) do
      {:ok, changeset, key}
    end
  end

  # The upload's shape, then the per-task count, which needs no file IO, and
  # only then the file itself.
  defp read_upload(%{path: path, filename: filename} = upload, task_id)
       when is_binary(path) and is_binary(filename) do
    with :ok <- precheck_count(task_id),
         {:ok, file} <- inspect_file(path) do
      {:ok, file, %{filename: filename, content_type: Map.get(upload, :content_type)}}
    end
  end

  defp read_upload(_upload, _task_id), do: {:error, :unreadable}

  defp precheck_count(task_id) do
    if Usage.count_for_task(task_id) >= Limits.max_files_per_task(),
      do: {:error, :too_many_files},
      else: :ok
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} -> {:error, :empty}
      {:ok, %File.Stat{type: :regular, size: size}} -> check_size(size)
      _other -> {:error, :unreadable}
    end
  end

  defp check_size(size) do
    if size > Limits.max_file_bytes(), do: {:error, :too_large}, else: {:ok, size}
  end

  defp sha256(path) do
    digest =
      path
      |> File.stream!(@chunk_bytes)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, Base.encode16(digest, case: :lower)}
  rescue
    File.Error -> {:error, :unreadable}
  end

  defp storage_key(board_id), do: "boards/#{board_id}/#{Ecto.UUID.generate()}"

  # The changeset sniffs `{:file, path}` itself: its own head for a binary
  # type, and the whole body for a text type, which a fixed-size head could
  # not prove is text.
  defp build_changeset(base, key, attrs, file) do
    changeset =
      TaskAttachment.create_changeset(
        %{base | storage_key: key},
        Map.merge(attrs, %{byte_size: file.size, sha256: file.sha256}),
        {:file, file.path}
      )

    if changeset.valid?, do: {:ok, changeset}, else: refuse_changeset(changeset)
  end

  defp refuse_changeset(changeset) do
    case refusal_reason(changeset.errors) do
      nil -> {:error, changeset}
      reason -> {:error, reason}
    end
  end

  # An unusable file name also leaves the type undeterminable, so it is
  # checked first: the caller gets the changeset, not a misleading
  # :type_mismatch.
  defp refusal_reason(errors) do
    cond do
      Keyword.has_key?(errors, :filename) -> nil
      size_error?(errors, :greater_than) -> :empty
      size_error?(errors, :less_than_or_equal_to) -> :too_large
      content_type_error(errors) == @not_allowed -> :type_not_allowed
      content_type_error(errors) != nil -> :type_mismatch
      true -> nil
    end
  end

  defp size_error?(errors, kind) do
    Enum.any?(errors, fn
      {:byte_size, {_message, opts}} -> opts[:kind] == kind
      _other -> false
    end)
  end

  defp content_type_error(errors) do
    case Keyword.get(errors, :content_type) do
      {message, _opts} -> message
      nil -> nil
    end
  end

  defp store(changeset, key, file) do
    park_tombstone!(key)
    content_type = Changeset.get_field(changeset, :content_type)

    case Storage.put(key, {:file, file.path}, content_type: content_type) do
      :ok ->
        changeset |> insert(key, file.size) |> discard_on_error(key)

      {:error, _reason} ->
        discard(key)
        {:error, :storage_unavailable}
    end
  end

  defp park_tombstone!(key) do
    delete_after = DateTime.add(DateTime.utc_now(), @pending_grace_seconds, :second)

    %BlobDeletion{}
    |> BlobDeletion.changeset(%{storage_key: key, delete_after: delete_after})
    |> Repo.insert!()
  end

  defp insert(changeset, key, size) do
    task_id = Changeset.get_field(changeset, :task_id)

    Repo.transact(fn ->
      with {:ok, scope} <- Usage.lock_for_upload(task_id, upload_refs(changeset)),
           :ok <- Usage.check_limits(task_id, scope, size),
           {:ok, attachment} <- changeset |> Repo.insert() |> map_insert_error(),
           :ok <- release_pending_tombstone(key) do
        {:ok, attachment}
      end
    end)
  end

  # The row commits only if the upload's own pending tombstone is still
  # untouched. The cleanup worker raises a tombstone's attempts when it
  # claims the key, before it deletes the blob, so a claimed key means the
  # blob may already be gone: the insert is rolled back and the blob
  # discarded instead of committing a row with nothing behind it. A worker
  # claim in progress holds the tombstone's row lock, so this delete waits
  # for it.
  defp release_pending_tombstone(key) do
    query = from(d in BlobDeletion, where: d.storage_key == ^key and d.attempts == 0)

    case Repo.delete_all(query) do
      {0, _rows} -> {:error, :storage_unavailable}
      {_count, _rows} -> :ok
    end
  end

  # The rows the insert references besides the task, in the order
  # Usage.lock_for_upload/2 key-share locks them.
  defp upload_refs(changeset) do
    for field <- [:uploaded_by_id, :board_id, :comment_id],
        do: {field, Changeset.get_field(changeset, field)}
  end

  # A task, comment or uploader deleted between the checks and the insert
  # fails a foreign key; to the caller the thing it named is gone.
  defp map_insert_error({:error, %Changeset{errors: errors} = changeset}) do
    if errors != [] and Enum.all?(errors, fn {field, _} -> field in @fk_fields end),
      do: {:error, :not_found},
      else: {:error, changeset}
  end

  defp map_insert_error(result), do: result

  defp discard_on_error({:ok, _attachment} = result, _key), do: result

  defp discard_on_error({:error, _reason} = error, key) do
    discard(key)
    error
  end

  # No row references `key` here, so deleting the blob directly is safe. The
  # tombstone goes only once the blob is gone; if the delete fails it stays,
  # and the cleanup worker removes the blob after the grace period.
  defp discard(key) do
    case Storage.delete(key) do
      :ok -> delete_tombstone(key)
      {:error, _reason} -> :kept
    end

    :ok
  end

  defp delete_tombstone(key) do
    query = from(d in BlobDeletion, where: d.storage_key == ^key)
    Repo.delete_all(query)
  end

  defp report({:ok, attachment} = result, _base, source) do
    Kanban.Telemetry.emit(
      [:kanban, :attachment, :uploaded],
      %{count: 1, byte_size: attachment.byte_size},
      %{
        attachment_id: attachment.id,
        task_id: attachment.task_id,
        board_id: attachment.board_id,
        comment_id: attachment.comment_id,
        user_id: attachment.uploaded_by_id,
        source: source
      }
    )

    result
  end

  defp report({:error, reason} = result, base, source) when reason in @refusal_reasons do
    Kanban.Telemetry.emit(
      [:kanban, :attachment, :upload_refused],
      %{count: 1},
      %{
        reason: reason,
        source: source,
        task_id: base.task_id,
        board_id: base.board_id,
        user_id: base.uploaded_by_id
      }
    )

    result
  end

  defp report(result, _base, _source), do: result
end
