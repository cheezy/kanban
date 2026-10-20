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
    * deletes failed and expired export rows older than `:keep_days`
      (default 30).

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
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Workspace

  require Logger

  @default_stale_after_hours 6
  @default_keep_days 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = run_time(args)
    settings = Application.get_env(:kanban, __MODULE__, [])

    expired = expire_due(now)
    orphaned = delete_orphaned_dirs()
    stale = fail_stale(now, Keyword.get(settings, :stale_after_hours, @default_stale_after_hours))
    removed = delete_old(now, Keyword.get(settings, :keep_days, @default_keep_days))

    Logger.info(
      "workspace export cleanup: #{expired} expired, #{orphaned} orphaned, " <>
        "#{stale} timed out, #{removed} removed"
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
