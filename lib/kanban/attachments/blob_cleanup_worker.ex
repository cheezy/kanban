defmodule Kanban.Attachments.BlobCleanupWorker do
  @moduledoc """
  Removes the stored blobs that `attachment_blob_deletions` tombstones name,
  run by the Oban Cron plugin every 15 minutes on the `:attachments` queue.

  Each run takes up to `:batch_size` (default 200) tombstones whose
  `delete_after` has passed, oldest first, stops taking new ones once
  `:max_run_seconds` (default 600) have passed, and for each one asks
  `Kanban.Attachments.Storage.delete/1` to remove its blob:

    * `:ok` (which includes a blob that is already gone) deletes the
      tombstone, so a run that crashes between the two steps only repeats an
      idempotent delete next time;
    * `{:error, :invalid_key}` deletes the tombstone and logs an error, since
      such a key can never be removed;
    * any other result keeps the tombstone, increments `attempts`, stores the
      reason as `last_error` and moves `delete_after` out by 2^attempts
      minutes from the moment of that try, capped at one day, so a store
      outage is retried without being hammered.

  A tombstone whose key a `task_attachments` row still names is deleted
  without touching the blob, so a stale tombstone (a pending upload whose
  grace period ran out before its row committed, say) can never remove a
  file a live attachment points at; when that row is deleted, the trigger
  queues the key again.

  A tombstone whose `delete_after` is still in the future belongs to an upload
  in flight and is left alone.

  Each key is claimed before its blob is touched. In one short transaction
  the worker locks every tombstone for the key, checks again that no row
  names it, and records the try: `attempts` goes up by one and a due
  tombstone's `delete_after` moves out by the backoff, so a run that crashes
  after the claim only repeats an idempotent delete later. An upload commits
  its row only by removing its own pending tombstone while `attempts` is
  still 0 (`Kanban.Attachments.Pipeline`), so an upload whose key the worker
  has claimed is refused instead of committing a row whose blob is gone, and
  a row that commits first is seen by the claim. Checking once per batch
  before any delete removed the blob of an upload that committed mid-run, and
  a worker run between an upload's put and its commit left a committed row
  with no blob (G488 exploratory campaign, 2026-11-02). No database
  transaction is held across a storage call. Removal is driven only by
  tombstones the database wrote, and every key still passes the storage
  facade's validation.

  Each run then calls `Kanban.Attachments.Storage.sweep/1`, which removes
  what an adapter's unfinished writes left behind once it is an hour old: the
  local adapter's temp files from a process or VM that died mid-write.

  With the local storage adapter a run sees only its own machine's disk, which
  is why that adapter is for a single machine only.

  Logs carry counts, tombstone ids and reason atoms, never a storage key or a
  credential. Settings come from
  `config :kanban, Kanban.Attachments.BlobCleanupWorker`. A `"now"` ISO 8601
  job argument replaces the current time, for tests.
  """

  # Unlike the hourly export cleanup, a crashed run is retried before the
  # next tick. While a run is waiting, running or waiting to retry, the
  # unique states stop the cron plugin from queueing a second one, so two
  # runs never overlap, even across nodes.
  #
  # Those states hold only while a run ends inside Lifeline's one-hour rescue
  # (config/config.exs): a job still executing after that is made available
  # again and runs a second time beside the first. So a run stops taking new
  # tombstones once :max_run_seconds (default 10 minutes) have passed and
  # leaves the rest to the next tick, and timeout/1 ends it outright at 30
  # minutes. Against a store that hangs, one S3 delete can take about 90
  # seconds with its retries, so a 200-tombstone batch would otherwise run
  # for five hours (G488 exploratory campaign, 2026-11-02).
  use Oban.Worker,
    queue: :attachments,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query, warn: false

  alias Kanban.Attachments.BlobDeletion
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Repo

  require Logger

  @default_batch_size 200
  @max_backoff_minutes 24 * 60
  # 2^11 minutes already exceeds one day, so larger exponents are never needed.
  @max_backoff_exponent 11
  @last_error_max_length 64
  # Leftovers of unfinished writes (a Local temp file whose process died
  # mid-write) are swept once they are as old as an upload's grace period.
  @sweep_after_seconds 3_600
  @default_max_run_seconds 600
  @timeout_minutes 30
  @outcomes %{deleted: 0, in_use: 0, invalid: 0, failed: 0, skipped: 0, deferred: 0}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(@timeout_minutes)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    settings = Application.get_env(:kanban, __MODULE__, [])
    clock = %{now: run_time(args), started: System.monotonic_time(:millisecond)}
    budget_ms = budget_ms(settings)

    counts =
      clock.now
      |> due_tombstones(batch_size(settings))
      |> Enum.reduce(@outcomes, fn tombstone, acc ->
        Map.update!(acc, outcome(tombstone, clock, budget_ms), &(&1 + 1))
      end)

    log_counts(counts)
    Storage.sweep(@sweep_after_seconds)
  end

  defp batch_size(settings),
    do: settings |> Keyword.get(:batch_size, @default_batch_size) |> positive_or_default()

  defp budget_ms(settings) do
    settings
    |> Keyword.get(:max_run_seconds, @default_max_run_seconds)
    |> positive_or(@default_max_run_seconds)
    |> Kernel.*(1000)
  end

  # Once the budget is spent the rest of the batch is left as it is.
  defp outcome(tombstone, clock, budget_ms) do
    if elapsed_ms(clock) >= budget_ms, do: :deferred, else: process(tombstone, clock)
  end

  defp log_counts(counts) do
    Logger.info(
      "attachment blob cleanup: #{counts.deleted} deleted, #{counts.in_use} still in use, " <>
        "#{counts.invalid} invalid, #{counts.failed} failed, #{counts.skipped} already handled, " <>
        "#{counts.deferred} left for the next run"
    )
  end

  defp elapsed_ms(%{started: started}), do: System.monotonic_time(:millisecond) - started

  # The moment of this claim: the run's time plus the whole seconds the run
  # has taken so far. A backoff counted from the run's start was already in
  # the past for a key claimed late in a long run, so the next run tried
  # every such key again at once.
  defp claim_time(%{now: now} = clock),
    do: DateTime.add(now, div(elapsed_ms(clock), 1000), :second)

  @doc """
  The backoff, in minutes, after a tombstone's `attempts`-th failed delete:
  2^attempts, capped at one day.
  """
  @spec backoff_minutes(non_neg_integer()) :: pos_integer()
  def backoff_minutes(attempts) when is_integer(attempts) and attempts >= 0 do
    exponent = min(attempts, @max_backoff_exponent)
    min(Integer.pow(2, exponent), @max_backoff_minutes)
  end

  defp due_tombstones(now, batch_size) do
    from(d in BlobDeletion,
      where: d.delete_after <= ^now,
      order_by: [asc: d.delete_after, asc: d.id],
      limit: ^batch_size
    )
    |> Repo.all()
  end

  defp process(tombstone, clock) do
    case claim(tombstone.storage_key, clock.now, claim_time(clock)) do
      {:ok, :handled} -> :skipped
      {:ok, :in_use} -> :in_use
      {:ok, {:claimed, ids, attempts}} -> delete_blob(tombstone, {ids, attempts})
    end
  end

  # Locks every tombstone for the key and, unless a row names the key or no
  # due tombstone is left (an earlier tombstone in this batch, or an upload's
  # commit, handled it), records this try on all of them before the blob is
  # touched. The pending tombstone of an upload still in flight gets its
  # attempts raised too, which is what refuses that upload's commit.
  defp claim(key, now, claimed_at) do
    Repo.transact(fn ->
      tombstones =
        from(d in BlobDeletion,
          where: d.storage_key == ^key,
          lock: "FOR UPDATE",
          select: %{id: d.id, attempts: d.attempts, delete_after: d.delete_after}
        )
        |> Repo.all()

      due_ids = for t <- tombstones, DateTime.compare(t.delete_after, now) != :gt, do: t.id

      cond do
        due_ids == [] -> {:ok, :handled}
        key_in_use?(key) -> drop_stale(due_ids)
        true -> record_try(tombstones, due_ids, claimed_at)
      end
    end)
  end

  # The key's row committed, so its due tombstones are stale (a pending
  # upload whose grace period ran out before the commit, for example); the
  # row's own deletion queues the key again through the trigger.
  defp drop_stale(due_ids) do
    delete_tombstones(due_ids)
    {:ok, :in_use}
  end

  defp record_try(tombstones, due_ids, claimed_at) do
    attempts = (tombstones |> Enum.map(& &1.attempts) |> Enum.max()) + 1
    retry_at = DateTime.add(claimed_at, backoff_minutes(attempts), :minute)

    for t <- tombstones do
      delete_after = if t.id in due_ids, do: retry_at, else: t.delete_after

      from(d in BlobDeletion, where: d.id == ^t.id)
      |> Repo.update_all(set: [attempts: attempts, delete_after: delete_after])
    end

    {:ok, {:claimed, due_ids, attempts}}
  end

  defp key_in_use?(key) do
    from(a in TaskAttachment, where: a.storage_key == ^key)
    |> Repo.exists?()
  end

  # The claim already recorded the try, so a failure only needs its reason.
  defp delete_blob(tombstone, {due_ids, attempts}) do
    case tombstone.storage_key |> Storage.delete() |> outcome() do
      :deleted ->
        delete_tombstones(due_ids)
        :deleted

      :invalid ->
        delete_tombstones(due_ids)

        Logger.error(
          "attachment blob cleanup: dropped tombstone #{tombstone.id}, its storage key is invalid"
        )

        :invalid

      {:failed, reason} ->
        record_failure(tombstone, due_ids, reason, attempts)
    end
  end

  defp outcome(:ok), do: :deleted
  defp outcome({:error, :not_found}), do: :deleted
  defp outcome({:error, :invalid_key}), do: :invalid
  # The storage facade holds the adapter to its contract, so any other
  # result is {:error, :storage_unavailable}.
  defp outcome({:error, reason}), do: {:failed, reason}

  defp delete_tombstones(ids),
    do: from(d in BlobDeletion, where: d.id in ^ids) |> Repo.delete_all()

  defp record_failure(tombstone, due_ids, reason, attempts) do
    from(d in BlobDeletion, where: d.id in ^due_ids)
    |> Repo.update_all(set: [last_error: reason_code(reason)])

    Logger.warning(
      "attachment blob cleanup: tombstone #{tombstone.id} failed with #{reason}, " <>
        "attempt #{attempts}"
    )

    :failed
  end

  defp reason_code(reason),
    do: reason |> Atom.to_string() |> String.slice(0, @last_error_max_length)

  defp positive_or_default(size), do: positive_or(size, @default_batch_size)

  defp positive_or(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_or(_value, default), do: default

  # delete_after is a microsecond column, so the run time keeps microsecond
  # precision.
  defp run_time(%{"now" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> usec(datetime)
      _error -> usec(DateTime.utc_now())
    end
  end

  defp run_time(_args), do: usec(DateTime.utc_now())

  defp usec(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}
end
