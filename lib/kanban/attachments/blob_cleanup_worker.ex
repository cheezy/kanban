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
  in flight and is left alone. No database transaction is held across a
  storage call: the batch is read first and each tombstone is then updated or
  deleted on its own. Removal is driven only by tombstones the database wrote,
  and every key still passes the storage facade's validation.

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

    tombstones = due_tombstones(now, batch_size)
    in_use = keys_in_use(tombstones)

    counts =
      Enum.reduce(tombstones, %{deleted: 0, in_use: 0, invalid: 0, failed: 0}, fn tombstone,
                                                                                  acc ->
        outcome = process(tombstone, in_use, now)
        Map.update!(acc, outcome, &(&1 + 1))
      end)

    Logger.info(
      "attachment blob cleanup: #{counts.deleted} deleted, #{counts.in_use} still in use, " <>
        "#{counts.invalid} invalid, #{counts.failed} failed"
    )

    :ok
  end

  # The storage keys among `tombstones` that a task_attachments row still
  # names. Such a blob is never deleted: the tombstone is stale (a pending
  # upload whose grace period ran out before its row committed, for
  # example), and the row's own deletion queues the key again through the
  # trigger.
  defp keys_in_use([]), do: MapSet.new()

  defp keys_in_use(tombstones) do
    keys = Enum.map(tombstones, & &1.storage_key)

    from(a in TaskAttachment, where: a.storage_key in ^keys, select: a.storage_key)
    |> Repo.all()
    |> MapSet.new()
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

  defp process(tombstone, in_use, now) do
    if MapSet.member?(in_use, tombstone.storage_key) do
      delete_tombstone(tombstone)
      :in_use
    else
      delete_blob(tombstone, now)
    end
  end

  defp delete_blob(tombstone, now) do
    case Storage.delete(tombstone.storage_key) do
      :ok ->
        delete_tombstone(tombstone)
        :deleted

      {:error, :not_found} ->
        delete_tombstone(tombstone)
        :deleted

      {:error, :invalid_key} ->
        delete_tombstone(tombstone)

        Logger.error(
          "attachment blob cleanup: dropped tombstone #{tombstone.id}, its storage key is invalid"
        )

        :invalid

      {:error, reason} when is_atom(reason) ->
        back_off(tombstone, reason, now)
        :failed

      _unexpected ->
        back_off(tombstone, :unexpected_result, now)
        :failed
    end
  end

  defp delete_tombstone(tombstone) do
    from(d in BlobDeletion, where: d.id == ^tombstone.id) |> Repo.delete_all()
  end

  defp back_off(tombstone, reason, now) do
    attempts = tombstone.attempts + 1
    delete_after = DateTime.add(now, backoff_minutes(attempts), :minute)

    from(d in BlobDeletion, where: d.id == ^tombstone.id)
    |> Repo.update_all(
      set: [attempts: attempts, last_error: reason_code(reason), delete_after: delete_after]
    )

    Logger.warning(
      "attachment blob cleanup: tombstone #{tombstone.id} failed with #{reason}, " <>
        "attempt #{attempts}"
    )
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
