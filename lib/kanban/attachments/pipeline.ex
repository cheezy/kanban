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
  #   2. Take byte_size from File.stat of the temp file (never a client
  #      value), refusing an empty or too large file before reading it.
  #   3. Stream the file once for its sha256.
  #   4. Build the changeset, which sniffs the contents against the type, and
  #      pre-check the quota, all before anything is stored.
  #   5. Park a pending tombstone for the new key, due one hour later, then
  #      put the blob.
  #   6. In one transaction: lock the task row, then the quota scope's
  #      advisory lock, re-check count and quota, insert, and remove the
  #      pending tombstone.
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

  defp run(%TaskAttachment{task_id: task_id} = base, upload) do
    with {:ok, file, attrs} <- read_upload(upload, task_id),
         {:ok, changeset, key} <- prepare(base, attrs, file) do
      store(changeset, key, file)
    end
  end

  # Size from File.stat and the sha256 from one read of the file.
  defp inspect_file(path) do
    with {:ok, size} <- file_size(path),
         {:ok, sha256} <- sha256(path) do
      {:ok, %{path: path, size: size, sha256: sha256}}
    end
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
      with {:ok, scope} <- Usage.lock_for_upload(task_id),
           :ok <- Usage.check_limits(task_id, scope, size),
           {:ok, attachment} <- changeset |> Repo.insert() |> map_insert_error() do
        delete_tombstone(key)
        {:ok, attachment}
      end
    end)
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
