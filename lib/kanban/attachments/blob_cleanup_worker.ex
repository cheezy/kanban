defmodule Kanban.Attachments.BlobCleanupWorker do
  @moduledoc """
  Removes the stored blobs that `attachment_blob_deletions` tombstones name,
  run by the Oban Cron plugin every 15 minutes on the `:attachments` queue.

  Each run takes up to `:batch_size` (default 200) tombstones whose
  `delete_after` has passed, oldest first, and for each one asks
  `Kanban.Attachments.Storage.delete/1` to remove its blob:

    * `:ok` (which includes a blob that is already gone) deletes the
      tombstone, so a run that crashes between the two steps only repeats an
      idempotent delete next time;
    * `{:error, :invalid_key}` deletes the tombstone and logs an error, since
      such a key can never be removed;
    * any other result keeps the tombstone, increments `attempts`, stores the
      reason as `last_error` and moves `delete_after` out by 2^attempts
      minutes, capped at one day, so a store outage is retried without being
      hammered.

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

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = run_time(args)
    settings = Application.get_env(:kanban, __MODULE__, [])

    batch_size =
      settings |> Keyword.get(:batch_size, @default_batch_size) |> positive_or_default()

    counts =
      now
      |> due_tombstones(batch_size)
      |> Enum.reduce(%{deleted: 0, in_use: 0, invalid: 0, failed: 0, skipped: 0}, fn tombstone,
                                                                                     acc ->
        Map.update!(acc, process(tombstone, now), &(&1 + 1))
      end)

    Logger.info(
      "attachment blob cleanup: #{counts.deleted} deleted, #{counts.in_use} still in use, " <>
        "#{counts.invalid} invalid, #{counts.failed} failed, #{counts.skipped} already handled"
    )

    :ok
  end

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

  defp process(tombstone, now) do
    case claim(tombstone.storage_key, now) do
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
  defp claim(key, now) do
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
        true -> record_try(tombstones, due_ids, now)
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

  defp record_try(tombstones, due_ids, now) do
    attempts = (tombstones |> Enum.map(& &1.attempts) |> Enum.max()) + 1
    retry_at = DateTime.add(now, backoff_minutes(attempts), :minute)

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
  defp outcome({:error, reason}) when is_atom(reason), do: {:failed, reason}
  defp outcome(_unexpected), do: {:failed, :unexpected_result}

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

  defp positive_or_default(size) when is_integer(size) and size > 0, do: size
  defp positive_or_default(_size), do: @default_batch_size

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
