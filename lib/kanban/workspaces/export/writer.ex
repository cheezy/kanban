defmodule Kanban.Workspaces.Export.Writer do
  @moduledoc """
  Writes a workspace export archive to disk (W2222).

  The rows are read inside one database transaction, board by board, with
  `Repo.stream/2`, and each row is written to its entity file as soon as it is
  read, so a workspace with thousands of tasks is never held in memory at
  once. The transaction runs at REPEATABLE READ, READ ONLY, so every file and
  the manifest's counts describe one consistent snapshot.

  The entity files are written to a scratch directory inside the export
  directory, zipped there, and the zip is renamed into
  `<export_dir>/<workspace_id>/<export_id>.zip` — a rename on one filesystem,
  so a half-written archive is never visible at the final path. The scratch
  directory has an unpredictable name (`create_tmp_dir/1`, 128 random bits)
  and is created exclusively and owner-only, so nothing can be planted at its
  path beforehand: an existing directory or symlink there fails the export
  instead of being written through. It is always removed.

  Errors come back as one of two codes and never as a message or a path:
  `:storage_unavailable` when the disk refused a write, `:export_failed` for
  anything else.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  require Logger

  @max_rows 500
  @board_entities [
    :boards,
    :columns,
    :labels,
    :tasks,
    :task_labels,
    :comments,
    :task_history,
    :board_users
  ]
  @task_user_fields [
    :assigned_to_id,
    :created_by_id,
    :completed_by_id,
    :reviewed_by_id,
    :archived_by_id
  ]

  @type result :: %{path: String.t(), byte_size: non_neg_integer(), counts: map()}

  @doc """
  Writes the archive of `workspace` for the export with `export_id` under
  `export_dir`. Returns the final path, its size and the per-entity counts.
  """
  @spec write_archive(Workspace.t(), integer(), String.t()) ::
          {:ok, result()} | {:error, :storage_unavailable | :export_failed}
  def write_archive(%Workspace{} = workspace, export_id, export_dir)
      when is_integer(export_id) and is_binary(export_dir) do
    final = archive_path(export_dir, workspace.id, export_id)

    with :ok <- mkdir(export_dir),
         {:ok, tmp_dir} <- create_tmp_dir(export_dir) do
      build_in(workspace, export_id, tmp_dir, final)
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  @doc """
  Creates a new owner-only scratch directory in `export_dir` with a random
  name, `.tmp-` and 22 URL-safe characters (128 bits from
  `:crypto.strong_rand_bytes/1`), so its path cannot be guessed. It is created
  exclusively: `{:error, :eexist}` when anything, a symlink included, already
  has that name. The name carries no export or workspace id.
  """
  @spec create_tmp_dir(String.t()) :: {:ok, String.t()} | {:error, File.posix()}
  def create_tmp_dir(export_dir) when is_binary(export_dir) do
    name = ".tmp-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    path = Path.join(export_dir, name)

    with :ok <- mkdir_exclusive(path), do: {:ok, path}
  end

  @doc false
  # File.mkdir/1, unlike mkdir_p, fails on an existing path instead of
  # reusing it, and never follows a symlink planted there.
  @spec mkdir_exclusive(String.t()) :: :ok | {:error, File.posix()}
  def mkdir_exclusive(path) do
    with :ok <- File.mkdir(path), do: restrict(path, 0o700)
  end

  defp build_in(workspace, export_id, tmp_dir, final) do
    build_archive(workspace, tmp_dir, final)
  rescue
    error ->
      Logger.warning("workspace export #{export_id} failed: #{inspect(error.__struct__)}")

      {:error, error_code(error)}
  catch
    {:storage, reason} -> {:error, error_code(reason)}
  after
    File.rm_rf(tmp_dir)
  end

  defp archive_path(export_dir, workspace_id, export_id),
    do: Path.join([export_dir, Integer.to_string(workspace_id), "#{export_id}.zip"])

  defp build_archive(workspace, tmp_dir, final) do
    with :ok <- final |> Path.dirname() |> mkdir(),
         {:ok, counts} <- write_files(workspace, tmp_dir),
         {:ok, size} <- finish_archive(tmp_dir, final) do
      {:ok, %{path: final, byte_size: size, counts: counts}}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  # Zips the scratch directory into the final path, restricts the archive to
  # its owner and returns its size.
  defp finish_archive(tmp_dir, final) do
    with :ok <- zip(tmp_dir, final),
         :ok <- restrict(final, 0o600),
         {:ok, %File.Stat{size: size}} <- File.stat(final) do
      {:ok, size}
    end
  end

  defp mkdir(path) do
    with :ok <- File.mkdir_p(path), do: restrict(path, 0o700)
  end

  # Owner-only, so other OS users on a shared host cannot read the archives.
  # Best effort: an operator-provided EXPORT_DIR the app may write to but not
  # chmod still works.
  defp restrict(path, mode) do
    _ = File.chmod(path, mode)
    :ok
  end

  defp write_files(workspace, tmp_dir) do
    Repo.transaction(fn -> write_snapshot(workspace, tmp_dir) end, timeout: :infinity)
  end

  # Runs inside the transaction: every entity file, then the manifest.
  defp write_snapshot(workspace, tmp_dir) do
    snapshot()
    board_ids = board_ids(workspace.id)
    {counts, user_ids} = write_board_entities(tmp_dir, board_ids)
    {member_count, user_ids} = write_members(tmp_dir, workspace.id, user_ids)
    user_count = write_users(tmp_dir, user_ids)

    counts =
      counts |> Map.put(:workspace_members, member_count) |> Map.put(:users, user_count)

    write_manifest(tmp_dir, workspace.name, counts)
    counts
  end

  defp write_board_entities(tmp_dir, board_ids) do
    Enum.reduce(@board_entities, {%{}, MapSet.new()}, fn entity, {counts, user_ids} ->
      {count, user_ids} = write_entity(tmp_dir, entity, board_ids, user_ids)
      {Map.put(counts, entity, count), user_ids}
    end)
  end

  defp write_manifest(tmp_dir, workspace_name, counts) do
    manifest = Serializer.encode_manifest(workspace_name, counts, DateTime.utc_now())
    path = Path.join(tmp_dir, Serializer.file_name(:manifest))
    write_file!(path, manifest)
  end

  # The export reads one snapshot. The test sandbox runs every transaction
  # nested inside its own, where the level can no longer be set, so
  # config/test.exs turns this off.
  defp snapshot do
    settings = Application.get_env(:kanban, __MODULE__, [])

    if Keyword.get(settings, :snapshot_isolation, true) do
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
    end

    :ok
  end

  defp board_ids(workspace_id) do
    from(b in Board, where: b.workspace_id == ^workspace_id, order_by: b.id, select: b.id)
    |> Repo.all()
  end

  defp write_entity(tmp_dir, entity, board_ids, user_ids) do
    path = Path.join(tmp_dir, Serializer.file_name(entity))

    open_array!(path, fn io ->
      Enum.reduce(board_ids, {0, user_ids}, fn board_id, acc ->
        entity
        |> board_query(board_id)
        |> Repo.stream(max_rows: @max_rows)
        |> Enum.reduce(acc, fn row, {count, ids} ->
          write_row!(io, entity, row, count)
          {count + 1, collect_user_ids(entity, row, ids)}
        end)
      end)
    end)
  end

  defp write_members(tmp_dir, workspace_id, user_ids) do
    path = Path.join(tmp_dir, Serializer.file_name(:workspace_members))

    query =
      from m in WorkspaceMember,
        where: m.workspace_id == ^workspace_id and m.role in [:member, :guest],
        order_by: m.id

    open_array!(path, fn io ->
      query
      |> Repo.stream(max_rows: @max_rows)
      |> Enum.reduce({0, user_ids}, fn row, {count, ids} ->
        write_row!(io, :workspace_members, row, count)
        {count + 1, MapSet.put(ids, row.user_id)}
      end)
    end)
  end

  defp write_users(tmp_dir, user_ids) do
    path = Path.join(tmp_dir, Serializer.file_name(:users))
    ids = user_ids |> MapSet.delete(nil) |> MapSet.to_list()

    rows =
      from(u in User,
        where: u.id in ^ids,
        order_by: u.id,
        select: %{id: u.id, email: u.email, name: u.name}
      )
      |> Repo.all()

    {count, _ids} =
      open_array!(path, fn io ->
        rows
        |> Enum.with_index()
        |> Enum.each(fn {row, index} -> write_row!(io, :users, row, index) end)

        {length(rows), nil}
      end)

    count
  end

  defp board_query(:boards, board_id), do: from(b in Board, where: b.id == ^board_id)

  defp board_query(:columns, board_id),
    do: from(c in Column, where: c.board_id == ^board_id, order_by: c.id)

  defp board_query(:labels, board_id),
    do: from(l in Label, where: l.board_id == ^board_id, order_by: l.id)

  defp board_query(:board_users, board_id),
    do: from(bu in BoardUser, where: bu.board_id == ^board_id, order_by: bu.id)

  defp board_query(:tasks, board_id) do
    from t in Task,
      join: c in Column,
      on: c.id == t.column_id,
      where: c.board_id == ^board_id,
      order_by: t.id
  end

  defp board_query(:task_labels, board_id) do
    from tl in TaskLabel,
      join: t in Task,
      on: t.id == tl.task_id,
      join: c in Column,
      on: c.id == t.column_id,
      where: c.board_id == ^board_id,
      order_by: tl.id,
      select: %{task_id: tl.task_id, label_id: tl.label_id}
  end

  defp board_query(:comments, board_id), do: task_child_query(TaskComment, board_id)
  defp board_query(:task_history, board_id), do: task_child_query(TaskHistory, board_id)

  defp task_child_query(schema, board_id) do
    from r in schema,
      join: t in Task,
      on: t.id == r.task_id,
      join: c in Column,
      on: c.id == t.column_id,
      where: c.board_id == ^board_id,
      order_by: r.id
  end

  defp collect_user_ids(:tasks, task, ids),
    do: Enum.reduce(@task_user_fields, ids, &MapSet.put(&2, Map.fetch!(task, &1)))

  defp collect_user_ids(:comments, comment, ids) do
    [comment.author_user_id | comment.mentioned_user_ids || []]
    |> Enum.reduce(ids, &MapSet.put(&2, &1))
  end

  defp collect_user_ids(:task_history, history, ids),
    do: ids |> MapSet.put(history.from_user_id) |> MapSet.put(history.to_user_id)

  defp collect_user_ids(:board_users, board_user, ids), do: MapSet.put(ids, board_user.user_id)
  defp collect_user_ids(_entity, _row, ids), do: ids

  defp open_array!(path, fun) do
    # No :delayed_write: a disk-full error then surfaces on the write itself,
    # as a storage error, rather than on close as a MatchError.
    case File.open(path, [:write, :binary], fn io ->
           write!(io, "[")
           result = fun.(io)
           write!(io, "]")
           result
         end) do
      {:ok, result} -> result
      {:error, reason} -> throw({:storage, reason})
    end
  end

  defp write_row!(io, entity, row, index) do
    separator = if index == 0, do: "", else: ","
    json = entity |> Serializer.encode_row(row) |> Jason.encode_to_iodata!()
    write!(io, [separator, json])
  end

  defp write!(io, data) do
    case :file.write(io, data) do
      :ok -> :ok
      {:error, reason} -> throw({:storage, reason})
    end
  end

  defp write_file!(path, data) do
    case File.write(path, data) do
      :ok -> :ok
      {:error, reason} -> throw({:storage, reason})
    end
  end

  defp zip(tmp_dir, final) do
    tmp_zip = Path.join(tmp_dir, "archive.zip")
    files = Enum.map(Serializer.file_names(), &String.to_charlist/1)

    zip_name = String.to_charlist(tmp_zip)
    cwd = String.to_charlist(tmp_dir)

    with {:ok, _name} <- :zip.create(zip_name, files, cwd: cwd) do
      File.rename(tmp_zip, final)
    end
  end

  @storage_errors [:eacces, :enospc, :erofs, :enoent, :enotdir, :eisdir, :edquot, :eperm, :eexist]

  defp error_code(reason) when reason in @storage_errors, do: :storage_unavailable
  defp error_code(%File.Error{}), do: :storage_unavailable
  defp error_code(_reason), do: :export_failed
end
