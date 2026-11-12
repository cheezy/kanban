defmodule Kanban.Workspaces.Export.CleanupWorker do
  @moduledoc """
  Hourly housekeeping for workspace exports (W2222), run by the Oban Cron
  plugin on the `:maintenance` queue.

  Each run:

    * deletes the archive of every succeeded export whose `expires_at` has
      passed, and marks the export expired;
    * deletes the archive directory of every workspace that no longer exists
      (its export rows went with it, so nothing else would ever remove it);
    * fails, with `timed_out`, every pending or running export not touched for
      `:stale_after_hours` (default 6), so a job lost with its node never
      blocks the next export of its workspace;
    * deletes every `<export_dir>/<workspace_id>/<export_id>.zip` whose export
      is not pending, running or succeeded: the archive of a job killed after
      it renamed the archive into place but before it marked the export
      succeeded, once that export has been timed out, or of an export row
      that no longer exists;
    * deletes failed and expired export rows older than `:keep_days`
      (default 30);
    * removes the `.tmp-` scratch directories in the export directory last
      changed more than an hour beyond `:stale_after_hours` ago
      (`Kanban.TmpDirGuard.sweep/4`): what a VM killed mid-export left behind.
      An export still running on another machine that shares `EXPORT_DIR` is
      younger than that, or has been timed out already; the extra hour covers
      clocks that disagree by less than that between the machines and the
      storage. Symlinks and entries not
      named like a scratch directory are kept, and so is any directory
      another operating-system user made; an export directory that is not
      this user's own owner-only directory is not swept at all.

  Its one log line counts what each step did, and never names a path.

  It only ever deletes a file whose path lies inside
  `Kanban.Workspaces.Export.export_dir/0`. Archives live on the disk of the
  machine that wrote them, so a run never treats a file it cannot see as
  gone: with more than one machine the archive may sit on another one. A
  succeeded export whose file is missing (a redeploy that replaced the disk)
  simply answers not found when downloaded, and expires on its `expires_at`
  like any other. A deployment with more than one machine points `EXPORT_DIR`
  at storage they all share, and that storage belongs to this deployment
  alone: the orphan sweep deletes every `<export_dir>/<id>/` directory whose
  workspace this database does not know, so an `EXPORT_DIR` shared with
  another deployment would lose that deployment's archives. Settings come from
  `config :kanban, Kanban.Workspaces.Export.CleanupWorker`. A `"now"` ISO 8601
  job argument replaces the current time, for tests.
  """

  # A run that fails is simply re-run by the next hourly tick.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.TmpDirGuard
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Workspace

  require Logger

  @default_stale_after_hours 6
  @default_keep_days 30
  # Hours the scratch-directory sweep waits beyond :stale_after_hours, so a
  # machine whose clock runs ahead of the export storage's cannot sweep the
  # directory of an export that has not been timed out yet.
  @sweep_margin_hours 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = run_time(args)
    settings = Application.get_env(:kanban, __MODULE__, [])

    stale_after_hours = Keyword.get(settings, :stale_after_hours, @default_stale_after_hours)

    expired = expire_due(now)
    orphaned = delete_orphaned_dirs()
    stale = fail_stale(now, stale_after_hours)
    unreferenced = delete_unreferenced_archives()
    removed = delete_old(now, Keyword.get(settings, :keep_days, @default_keep_days))
    swept = sweep_tmp_dirs(stale_after_hours)

    Logger.info(
      "workspace export cleanup: #{expired} expired, #{orphaned} orphaned, " <>
        "#{unreferenced} unreferenced archives, #{stale} timed out, #{removed} removed, " <>
        "#{swept} stale temporary directories"
    )

    :ok
  end

  defp expire_due(now) do
    from(e in WorkspaceExport, where: e.status == "succeeded" and e.expires_at <= ^now)
    |> Repo.all()
    |> Enum.count(fn export ->
      delete_file(export.file_path)
      Export.mark_expired(export) != :skip
    end)
  end

  # <export_dir>/<workspace_id>/ directories whose workspace is gone.
  defp delete_orphaned_dirs do
    dir = Export.export_dir()
    ids = workspace_dir_ids(dir)
    existing = existing_workspace_ids(ids)

    ids
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.count(&delete_workspace_dir(dir, &1))
  end

  # The positive integer names among the export directory's entries.
  defp workspace_dir_ids(dir) do
    case File.ls(dir) do
      {:ok, names} -> for name <- names, {id, ""} <- [Integer.parse(name)], id > 0, do: id
      {:error, _reason} -> []
    end
  end

  defp existing_workspace_ids(ids) do
    from(w in Workspace, where: w.id in ^ids, select: w.id)
    |> Repo.all()
    |> MapSet.new()
  end

  # True when the directory was inside the export dir and was removed.
  defp delete_workspace_dir(dir, id) do
    path = Path.join(dir, Integer.to_string(id))
    Export.safe_path?(path) and File.dir?(path) and match?({:ok, _}, File.rm_rf(path))
  end

  # Archives named <export_id>.zip in the workspace directories whose export
  # row is gone, failed or expired. Runs after fail_stale, so the archive of a
  # job that was killed before it marked its export succeeded goes in the run
  # that times that export out. A running export's archive is kept, so one
  # that has just been renamed into place is never removed.
  defp delete_unreferenced_archives do
    archives = archives(Export.export_dir())
    live = archives |> Enum.map(&elem(&1, 0)) |> live_export_ids()

    Enum.count(archives, fn {export_id, path} ->
      not MapSet.member?(live, export_id) and delete_archive(path)
    end)
  end

  defp archives(dir), do: dir |> workspace_dir_ids() |> Enum.flat_map(&archive_files(dir, &1))

  # {export_id, path} for each <export_id>.zip in a workspace directory that is
  # a real directory, never one reached through a symlink.
  defp archive_files(dir, workspace_id) do
    workspace_dir = Path.join(dir, Integer.to_string(workspace_id))

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(workspace_dir),
         {:ok, names} <- File.ls(workspace_dir) do
      Enum.flat_map(names, &archive_entry(workspace_dir, &1))
    else
      _not_a_directory -> []
    end
  end

  # [{export_id, path}] for an entry named <export_id>.zip, else [].
  defp archive_entry(workspace_dir, name) do
    case Regex.run(~r/\A([1-9][0-9]*)\.zip\z/, name) do
      [_name, id] -> [{String.to_integer(id), Path.join(workspace_dir, name)}]
      nil -> []
    end
  end

  defp live_export_ids([]), do: MapSet.new()

  defp live_export_ids(ids) do
    from(e in WorkspaceExport,
      where: e.id in ^ids and e.status in ["pending", "running", "succeeded"],
      select: e.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # True when a regular file inside the export directory was removed; a
  # symlink named like an archive is kept, and nothing it points at is touched.
  defp delete_archive(path) do
    Export.safe_path?(path) and match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) and
      File.rm(path) == :ok
  end

  defp fail_stale(now, hours) when is_integer(hours) and hours > 0 do
    cutoff = DateTime.add(now, -hours, :hour)

    from(e in WorkspaceExport,
      where: e.status in ["pending", "running"] and e.updated_at < ^cutoff
    )
    |> Repo.all()
    |> Enum.count(&(Export.mark_failed(&1, "timed_out") != :skip))
  end

  defp fail_stale(_now, _hours), do: 0

  defp delete_old(now, days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(now, -days, :day)

    {count, _} =
      from(e in WorkspaceExport,
        where: e.status in ["failed", "expired"] and e.updated_at < ^cutoff
      )
      |> Repo.delete_all()

    count
  end

  defp delete_old(_now, _days), do: 0

  # Scratch directories a killed VM left in the export directory. The sweep
  # runs on the wall clock, never the "now" argument, because it compares
  # against directory mtimes. The default export directory sits in the shared
  # system temporary directory, so the sweep needs it to be this user's own,
  # owner-only directory, and removes only directories this user made.
  defp sweep_tmp_dirs(hours) do
    case TmpDirGuard.own_uid() do
      {:ok, uid} ->
        TmpDirGuard.sweep(Export.export_dir(), sweep_after_seconds(hours), "workspace export",
          owner: uid
        )

      {:error, _reason} ->
        0
    end
  end

  # An hour longer than the age at which a running export is timed out; an
  # unusable setting falls back to the default rather than to no threshold.
  defp sweep_after_seconds(hours) when is_integer(hours) and hours > 0,
    do: (hours + @sweep_margin_hours) * 3600

  defp sweep_after_seconds(_hours), do: sweep_after_seconds(@default_stale_after_hours)

  defp delete_file(path) do
    if Export.safe_path?(path), do: File.rm(path)
    :ok
  end

  defp run_time(%{"now" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> DateTime.truncate(DateTime.utc_now(), :second)
    end
  end

  defp run_time(_args), do: DateTime.truncate(DateTime.utc_now(), :second)
end
