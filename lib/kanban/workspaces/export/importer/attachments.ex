defmodule Kanban.Workspaces.Export.Importer.Attachments do
  @moduledoc """
  The attachments step of `Kanban.Workspaces.Export.Importer`: the last step
  of the import transaction, after tasks and comments.

  A version 1 archive has no attachments and this step does nothing. For a
  version 2 archive, each `attachments.json` row:

    * is skipped and reported when its task was not imported, and refuses
      the import when it names a comment that was not imported, that
      belongs to another task (the database does not check that), or whose
      id two comments in the archive share;
    * has its uploader attributed like any other user reference
      (`Kanban.Workspaces.Export.Importer.Users.attributed/2`).

  Then, before any blob is written, the whole import is refused with
  `:quota_exceeded` when the files would take the Organization past
  `Kanban.Attachments.Limits.organization_quota_bytes/0`, and a task given
  more than `Kanban.Attachments.Limits.max_files_per_task/0` files is
  refused. The quota is checked again once every row is inserted, under the
  quota scope's advisory lock (`Kanban.Attachments.Usage.lock_quota/1`), so
  a concurrent upload cannot take the same room. The lock is taken only
  then, never while blobs are extracted and stored, so uploads into the
  Organization do not wait behind a long import.

  Each blob is then extracted, one at a time, into an owner-only file in an
  unpredictable scratch directory (`Kanban.Workspaces.Export.Writer.create_tmp_dir/1`)
  under the per-file limit and what is left of the archive's blob budget
  (`Kanban.Workspaces.Export.Importer.Archive.extract_blob/4`). Its size and
  sha256 are recomputed; where they differ from the row the recomputed value
  wins and the import is refused. The row goes through
  `Kanban.Attachments.TaskAttachment.create_changeset/3` — filename rules,
  the content-type allow-list, the extension and the file's contents — like
  any upload, under a new storage key (`Kanban.Attachments.Pipeline.storage_key/1`);
  nothing from the archive becomes a key, a path or a scratch file name.
  Finally the blob is stored, unless this is a dry run, which verifies every
  blob and stores none.

  Storage is not transactional, so every key this import stores is tracked
  outside the transaction (`with_stored_keys/1`), and any outcome but a
  commit — an error, a rollback, a dry run, a raise, a failed commit —
  deletes them all. A delete that fails parks a
  `Kanban.Attachments.BlobDeletion` tombstone for the cleanup worker.
  """

  import Ecto.Query, warn: false

  alias Kanban.Attachments.BlobDeletion
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.Pipeline
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Attachments.Usage
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Workspaces.Export.Importer
  alias Kanban.Workspaces.Export.Importer.Archive
  alias Kanban.Workspaces.Export.Importer.Users
  alias Kanban.Workspaces.Export.Writer

  require Logger

  @mismatch "does not match the file in the archive"

  @doc """
  Imports the attachments of `ctx.rows` when the archive has any (version
  2). `ctx` must carry the tasks and comments already imported, the
  `:archive` path and blob index, `:dry_run?` and the `:stored_keys`
  reference from `with_stored_keys/1`.
  """
  @spec import_all(map()) :: map()
  def import_all(%{rows: %{attachments: rows}} = ctx) do
    {items, ctx} =
      rows
      |> Enum.sort_by(& &1["id"])
      |> Enum.reduce({[], ctx}, &resolve/2)

    items = Enum.reverse(items)
    check_per_task(items)
    check_quota(ctx, items)
    count = with_scratch(fn scratch -> store_all(ctx, items, scratch) end)
    recheck_quota(ctx, items)
    Importer.put_count(ctx, :attachments, count)
  end

  def import_all(ctx), do: ctx

  @doc """
  Runs `fun` with a fresh reference for `track/2` and returns its result.
  Every key tracked under it is deleted from storage afterwards unless
  `fun` returned `{:ok, _}` — the result of a committed transaction — so a
  rollback, a dry run, an error, a raise, a throw or an exit (a failed
  commit included) never leaves a stored blob behind without its row.
  """
  @spec with_stored_keys((reference() -> result)) :: result when result: term()
  def with_stored_keys(fun) when is_function(fun, 1) do
    ref = make_ref()
    Process.put({__MODULE__, ref}, [])

    try do
      result = fun.(ref)
      if match?({:ok, _}, result), do: Process.put({__MODULE__, ref}, :committed)
      result
    after
      case Process.delete({__MODULE__, ref}) do
        :committed -> :ok
        keys -> Enum.each(keys, &delete_stored/1)
      end
    end
  end

  @doc "Records `key` as stored under `ref`, before it is written."
  @spec track(reference(), String.t()) :: :ok
  def track(ref, key) when is_reference(ref) and is_binary(key) do
    Process.put({__MODULE__, ref}, [key | Process.get({__MODULE__, ref}, [])])
    :ok
  end

  defp delete_stored(key) do
    case Storage.delete(key) do
      :ok -> :ok
      {:error, reason} -> park(key, reason)
    end
  end

  # The import's transaction has ended, so this tombstone is committed on
  # its own and the cleanup worker retries the delete.
  defp park(key, reason) do
    Logger.warning("workspace import: could not delete a stored blob: #{inspect(reason)}")

    %BlobDeletion{}
    |> BlobDeletion.changeset(%{storage_key: key})
    |> Repo.insert()

    :ok
  rescue
    error ->
      Logger.warning("workspace import: could not park a blob: #{inspect(error.__struct__)}")
  end

  defp resolve(row, {items, ctx}) do
    case Map.fetch(ctx.tasks, row["task_id"]) do
      {:ok, task} -> {[item(ctx, row, task) | items], ctx}
      :error -> {items, Importer.skip(ctx, :attachments, "attachment: task not in the archive")}
    end
  end

  defp item(ctx, row, task) do
    ref = %{"id" => row["id"], "name" => row["filename"]}

    %{
      row: row,
      ref: ref,
      task: task,
      comment_id: comment_id(ctx, row["comment_id"], task, ref),
      uploaded_by_id: Users.attributed(ctx, row["uploaded_by_id"]),
      byte_size: byte_size!(row["byte_size"], ref)
    }
  end

  defp comment_id(_ctx, nil, _task, _ref), do: nil

  defp comment_id(ctx, source_id, task, ref) do
    case Map.get(ctx.comments, source_id) do
      {comment_id, task_id} when task_id == task.id ->
        comment_id

      {_comment_id, _other} ->
        Importer.fail(:attachments, ref, %{comment_id: ["is on another task"]})

      :repeated ->
        Importer.fail(:attachments, ref, %{comment_id: ["is repeated in the archive"]})

      nil ->
        Importer.fail(:attachments, ref, %{comment_id: ["is not in the archive"]})
    end
  end

  # The quota sum needs a real size; the extracted blob must then match it.
  defp byte_size!(size, ref) do
    if is_integer(size) and size > 0 and size <= Limits.max_file_bytes(),
      do: size,
      else: Importer.fail(:attachments, ref, %{byte_size: ["is invalid"]})
  end

  defp check_per_task(items) do
    max = Limits.max_files_per_task()

    items
    |> Enum.group_by(& &1.task.id)
    |> Enum.find(fn {_task_id, list} -> length(list) > max end)
    |> case do
      nil ->
        :ok

      {_task_id, [item | _]} ->
        Importer.fail(:attachments, item.task.identifier, %{
          task_id: ["has more than #{max} files"]
        })
    end
  end

  # Before any blob is extracted, without the lock, so an archive that cannot
  # fit is refused before the slow part. The rows are not inserted yet, so
  # they are not in bytes_used/1.
  defp check_quota(_ctx, []), do: :ok

  defp check_quota(ctx, items) do
    needed = items |> Enum.map(& &1.byte_size) |> Enum.sum()

    if Usage.bytes_used(quota_scope(ctx)) + needed > Limits.organization_quota_bytes(),
      do: Repo.rollback(:quota_exceeded),
      else: :ok
  end

  # After every row is inserted, under the quota scope's advisory lock, which
  # the transaction then holds only until it commits. Taking it before the
  # blobs were extracted and stored held it for the whole import, and every
  # upload into the Organization waited behind it until its query timed out.
  # This transaction sees its own rows, so bytes_used/1 now counts them.
  defp recheck_quota(_ctx, []), do: :ok

  defp recheck_quota(ctx, _items) do
    scope = quota_scope(ctx)
    :ok = Usage.lock_quota(scope)

    if Usage.bytes_used(scope) > Limits.organization_quota_bytes(),
      do: Repo.rollback(:quota_exceeded),
      else: :ok
  end

  defp quota_scope(ctx), do: {:organization, ctx.organization_id}

  defp with_scratch(fun) do
    case Writer.create_tmp_dir(System.tmp_dir!()) do
      {:ok, scratch} ->
        try do
          fun.(scratch)
        after
          File.rm_rf(scratch)
        end

      {:error, _reason} ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp store_all(_ctx, [], _scratch), do: 0

  defp store_all(ctx, items, scratch) do
    boards = boards_by_column(items)

    {count, _budget} =
      items
      |> Enum.with_index()
      |> Enum.reduce(
        {0, Archive.max_attachment_bytes()},
        &store_next(ctx, {boards, scratch}, &1, &2)
      )

    count
  end

  # Each blob is extracted under what is left of the archive's budget.
  defp store_next(ctx, {boards, scratch}, {item, index}, {count, budget}) do
    dest = Path.join(scratch, "blob-#{index}")
    size = store(ctx, item, Map.fetch!(boards, item.task.column_id), dest, budget)
    File.rm(dest)
    {count + 1, budget - size}
  end

  defp boards_by_column(items) do
    column_ids = items |> Enum.map(& &1.task.column_id) |> Enum.uniq()

    from(c in Column, where: c.id in ^column_ids, select: {c.id, c.board_id})
    |> Repo.all()
    |> Map.new()
  end

  defp store(ctx, item, board_id, dest, budget) do
    entry = Map.fetch!(ctx.archive.blobs, item.row["id"])
    blob = extract!(ctx.archive.path, entry, dest, min(Limits.max_file_bytes(), budget))
    check_matches!(item, blob)
    key = Pipeline.storage_key(board_id)
    record = insert_row!(item, key, blob, dest)
    put!(ctx, key, dest, record.content_type)
    blob.byte_size
  end

  defp extract!(path, entry, dest, max_bytes) do
    case Archive.extract_blob(path, entry, dest, max_bytes) do
      {:ok, blob} -> blob
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Archive content is untrusted: where the recomputed value and the row
  # disagree, the recomputed value wins and the import is refused.
  defp check_matches!(item, blob) do
    cond do
      blob.byte_size != item.byte_size ->
        Importer.fail(:attachments, item.ref, %{byte_size: [@mismatch]})

      blob.sha256 != item.row["sha256"] ->
        Importer.fail(:attachments, item.ref, %{sha256: [@mismatch]})

      true ->
        :ok
    end
  end

  defp insert_row!(item, key, blob, dest) do
    %TaskAttachment{
      task_id: item.task.id,
      comment_id: item.comment_id,
      uploaded_by_id: item.uploaded_by_id,
      storage_key: key
    }
    |> TaskAttachment.create_changeset(
      %{
        "filename" => item.row["filename"],
        "content_type" => item.row["content_type"],
        "byte_size" => blob.byte_size,
        "sha256" => blob.sha256
      },
      {:file, dest}
    )
    |> Importer.cast_timestamps(item.row, ["inserted_at"])
    |> Importer.insert!(:attachments, item.ref)
  end

  # Tracked before the put, so even a put that fails part-way is cleaned up.
  defp put!(%{dry_run?: true}, _key, _dest, _content_type), do: :ok

  defp put!(ctx, key, dest, content_type) do
    :ok = track(ctx.stored_keys, key)

    case Storage.put(key, {:file, dest}, content_type: content_type) do
      :ok -> :ok
      {:error, _reason} -> Repo.rollback(:storage_unavailable)
    end
  end
end
