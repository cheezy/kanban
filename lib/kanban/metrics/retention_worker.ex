defmodule Kanban.Metrics.RetentionWorker do
  @moduledoc """
  Daily cron job that removes stored telemetry metrics older than the
  configured retention period (`Oban.Plugins.Cron`, every day at 03:23 UTC).

  `KanbanWeb.Telemetry.MetricsStorage` writes every persisted metric to the
  `metrics_events` table, with user ids, board ids and request paths, and
  nothing else ever removes those rows. This job deletes each row whose
  `recorded_at` is older than the retention period. A row recorded exactly at
  the cutoff is kept.

  The period is read at run time from

      config :kanban, Kanban.Metrics.RetentionWorker, retention_days: 90

  `config/config.exs` sets the 90-day default. A missing setting, or one that
  is not a positive whole number of days, removes nothing and logs a warning,
  so a mistake in the setting can never empty the table.

  Rows are removed in batches of `batch_size` (default 1,000), one `DELETE`
  per batch, so a large backlog never holds one long lock on the table. The
  job stops when a batch removes fewer rows than the batch size.

  It touches only `metrics_events`. The `audit_events` table has its own
  retention rules and database roles (`Kanban.AuditLog.purge_before/1`) and is
  never queried here. There is no Ecto schema for `metrics_events`; it is
  queried by table name, as in `Kanban.Metrics.UserActivity`.

  When it finishes, the job emits `[:kanban, :metrics, :retention_completed]`
  with the number of rows removed and the number of batches run.
  """

  # A run that fails is simply re-run by the next day's cron tick.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query, warn: false

  alias Kanban.Repo

  require Logger

  @table "metrics_events"
  @default_batch_size 1_000
  @seconds_per_day 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    settings = settings()

    settings
    |> retention_days()
    |> run_retention(run_time(args), settings)

    :ok
  end

  defp run_retention({:ok, days}, now, settings) do
    cutoff = DateTime.add(now, -days * @seconds_per_day, :second)
    {removed, batches} = delete_older_than(cutoff, batch_size(settings))
    report(removed, batches, days)
  end

  defp run_retention(:error, _now, settings) do
    Logger.warning(
      "metrics retention skipped: retention_days must be a positive integer, got " <>
        inspect(Keyword.get(settings, :retention_days))
    )
  end

  @doc """
  Deletes `metrics_events` rows recorded before `cutoff`, `batch_size` rows at
  a time, and returns `{rows_removed, batches_run}`.

  A row recorded exactly at `cutoff` is kept. An empty table returns `{0, 1}`.
  """
  @spec delete_older_than(DateTime.t(), pos_integer()) ::
          {non_neg_integer(), pos_integer()}
  def delete_older_than(%DateTime{} = cutoff, batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    delete_batches(cutoff, batch_size, 0, 0)
  end

  defp delete_batches(cutoff, batch_size, removed, batches) do
    expired_ids =
      from m in @table,
        where: m.recorded_at < type(^cutoff, :utc_datetime_usec),
        order_by: m.id,
        limit: ^batch_size,
        select: m.id

    {count, _rows} =
      from(m in @table, where: m.id in subquery(expired_ids))
      |> Repo.delete_all()

    removed = removed + count
    batches = batches + 1

    if count < batch_size do
      {removed, batches}
    else
      delete_batches(cutoff, batch_size, removed, batches)
    end
  end

  defp report(removed, batches, days) do
    Kanban.Telemetry.emit(
      [:kanban, :metrics, :retention_completed],
      %{count: removed, batches: batches},
      %{retention_days: days}
    )

    if removed > 0 do
      Logger.info("metrics retention: removed #{removed} row(s) older than #{days} day(s)")
    end
  end

  defp settings, do: Application.get_env(:kanban, __MODULE__, [])

  defp retention_days(settings) do
    case Keyword.get(settings, :retention_days) do
      days when is_integer(days) and days > 0 -> {:ok, days}
      _invalid -> :error
    end
  end

  # An invalid batch size falls back to the default rather than skipping the
  # run: it changes only how the work is split, never what is removed.
  defp batch_size(settings) do
    case Keyword.get(settings, :batch_size) do
      size when is_integer(size) and size > 0 -> size
      _other -> @default_batch_size
    end
  end

  # "now" (ISO 8601) is a test seam; cron jobs carry empty args.
  defp run_time(%{"now" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      _error -> DateTime.utc_now()
    end
  end

  defp run_time(_args), do: DateTime.utc_now()
end
