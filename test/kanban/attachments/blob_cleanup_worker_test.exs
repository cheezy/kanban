defmodule Kanban.Attachments.BlobCleanupWorkerTest do
  # Not async: tests swap the application-wide storage adapter, its local
  # root and the worker's settings.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Attachments.BlobCleanupWorker
  alias Kanban.Attachments.BlobDeletion
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.Storage.Local
  alias Kanban.Tasks.Task

  @moduletag :tmp_dir

  @now ~U[2026-11-01 12:00:00.000000Z]

  defmodule ResultAdapter do
    @moduledoc false
    # Delegates to the local adapter, reporting each delete to the calling
    # process and letting a test replace a delete result. The facade calls the
    # adapter in the caller's process, so the process dictionary is the
    # test's own.
    @behaviour Kanban.Attachments.Storage

    alias Kanban.Attachments.Storage.Local

    @impl true
    def put(key, source, opts), do: Local.put(key, source, opts)

    @impl true
    def stream(key), do: Local.stream(key)

    @impl true
    def delete(key) do
      send(self(), {:storage_deleted, key})

      case Process.get(:delete_result) do
        nil -> Local.delete(key)
        result -> result
      end
    end

    @impl true
    def exists(key), do: Local.exists(key)
  end

  setup %{tmp_dir: tmp_dir} do
    restore_env_on_exit(Storage)
    restore_env_on_exit(Local)
    restore_env_on_exit(BlobCleanupWorker)

    Application.put_env(:kanban, Storage, adapter: ResultAdapter)
    Application.put_env(:kanban, Local, root: Path.join(tmp_dir, "root"))

    :ok
  end

  defp restore_env_on_exit(key) do
    previous = Application.fetch_env(:kanban, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kanban, key, value)
        :error -> Application.delete_env(:kanban, key)
      end
    end)
  end

  defp run(now \\ @now), do: perform_job(BlobCleanupWorker, %{"now" => DateTime.to_iso8601(now)})

  defp key, do: unique_storage_key(System.unique_integer([:positive]))

  defp stored_blob do
    key = key()
    :ok = Storage.put(key, {:binary, "contents"})
    key
  end

  defp tombstone(storage_key, delete_after, attrs \\ %{}) do
    %BlobDeletion{storage_key: storage_key, delete_after: delete_after}
    |> struct(attrs)
    |> Repo.insert!()
  end

  defp minutes(minutes, from \\ @now), do: DateTime.add(from, minutes, :minute)

  defp reload(tombstone), do: Repo.get(BlobDeletion, tombstone.id)

  defp blob_exists?(key) do
    {:ok, exists} = Storage.exists(key)
    exists
  end

  describe "perform/1" do
    test "deletes the blob and the tombstone for a due row" do
      key = stored_blob()
      row = tombstone(key, minutes(-1))

      assert :ok = run()

      assert_received {:storage_deleted, ^key}
      refute blob_exists?(key)
      assert reload(row) == nil
    end

    test "never deletes a blob a live attachment still names, and drops the stale tombstone" do
      task = user_fixture() |> board_fixture() |> column_fixture() |> task_fixture()
      key = stored_blob()
      attachment_fixture(task, storage_key: key)
      row = tombstone(key, minutes(-1))

      assert :ok = run()

      refute_received {:storage_deleted, ^key}
      assert blob_exists?(key)
      assert reload(row) == nil
    end

    test "leaves a row whose delete_after is in the future" do
      key = stored_blob()
      row = tombstone(key, minutes(1))

      assert :ok = run()

      refute_received {:storage_deleted, _key}
      assert blob_exists?(key)
      assert %BlobDeletion{attempts: 0, last_error: nil} = reload(row)
    end

    test "treats a blob that is already gone as deleted" do
      missing = tombstone(key(), minutes(-5))
      Process.put(:delete_result, nil)

      assert :ok = run()
      assert reload(missing) == nil

      not_found = tombstone(key(), minutes(-5))
      Process.put(:delete_result, {:error, :not_found})

      assert :ok = run()
      assert reload(not_found) == nil
    end

    test "keeps the row, bumps attempts and backs off when storage is unavailable" do
      key = key()
      row = tombstone(key, minutes(-1), %{attempts: 2})
      Process.put(:delete_result, {:error, :storage_unavailable})

      log = capture_log([level: :warning], fn -> assert :ok = run() end)

      assert %BlobDeletion{attempts: 3, last_error: "storage_unavailable"} = updated = reload(row)
      # 2^3 minutes after the run.
      assert DateTime.compare(updated.delete_after, minutes(8)) == :eq
      assert log =~ "tombstone #{row.id} failed with storage_unavailable"
      refute log =~ key
    end

    test "caps the backoff at one day however many attempts have failed" do
      row = tombstone(key(), minutes(-1), %{attempts: 40})
      Process.put(:delete_result, {:error, :storage_unavailable})

      capture_log(fn -> assert :ok = run() end)

      updated = reload(row)
      assert updated.attempts == 41
      assert DateTime.compare(updated.delete_after, minutes(24 * 60)) == :eq
    end

    test "records an unexpected adapter result as unexpected_result and keeps the row" do
      first = tombstone(key(), minutes(-2))
      Process.put(:delete_result, {:error, "a message, not a reason atom"})
      capture_log(fn -> assert :ok = run() end)

      assert %BlobDeletion{attempts: 1, last_error: "unexpected_result"} = updated = reload(first)
      assert DateTime.compare(updated.delete_after, minutes(2)) == :eq

      second = tombstone(key(), minutes(-2))
      Process.put(:delete_result, :what)
      capture_log(fn -> assert :ok = run() end)

      assert %BlobDeletion{attempts: 1, last_error: "unexpected_result"} = reload(second)
    end

    test "processes at most batch_size rows per run, oldest first" do
      Application.put_env(:kanban, BlobCleanupWorker, batch_size: 2)

      newest = tombstone(stored_blob(), minutes(-1))
      oldest = tombstone(stored_blob(), minutes(-30))
      middle = tombstone(stored_blob(), minutes(-10))

      assert :ok = run()

      assert reload(oldest) == nil
      assert reload(middle) == nil
      assert %BlobDeletion{} = reload(newest)
      assert blob_exists?(newest.storage_key)

      assert :ok = run()
      assert reload(newest) == nil
    end

    test "a batch of exactly batch_size rows is drained in one run" do
      Application.put_env(:kanban, BlobCleanupWorker, batch_size: 2)

      rows = for minutes <- [-3, -2], do: tombstone(stored_blob(), minutes(minutes))

      assert :ok = run()
      assert Enum.all?(rows, &(reload(&1) == nil))
    end

    test "falls back to the default batch size when the setting is not a positive integer" do
      Application.put_env(:kanban, BlobCleanupWorker, batch_size: 0)
      row = tombstone(stored_blob(), minutes(-1))

      assert :ok = run()
      assert reload(row) == nil
    end

    test "drops a row whose key fails validation and logs it" do
      invalid_key = "../outside/the/root"
      row = tombstone(invalid_key, minutes(-1))

      log = capture_log([level: :error], fn -> assert :ok = run() end)

      assert reload(row) == nil
      # The facade refuses the key before the adapter is ever called.
      refute_received {:storage_deleted, _key}
      assert log =~ "dropped tombstone #{row.id}"
      refute log =~ invalid_key
    end

    test "a run with no tombstones returns ok and touches nothing" do
      assert Repo.aggregate(BlobDeletion, :count) == 0

      assert :ok = run()

      refute_received {:storage_deleted, _key}
      assert Repo.aggregate(BlobDeletion, :count) == 0
    end

    test "a due tombstone removes the blob while a pending tombstone for the same key waits" do
      key = stored_blob()
      due = tombstone(key, minutes(-1))
      pending = tombstone(key, minutes(60))

      assert :ok = run()

      refute blob_exists?(key)
      assert reload(due) == nil
      assert %BlobDeletion{attempts: 0} = reload(pending)
    end

    test "two due tombstones for the same key are both removed" do
      key = stored_blob()
      rows = [tombstone(key, minutes(-2)), tombstone(key, minutes(-1))]

      assert :ok = run()

      refute blob_exists?(key)
      assert Enum.all?(rows, &(reload(&1) == nil))
    end

    test "uses the current time when no now argument is given" do
      past = tombstone(stored_blob(), DateTime.add(DateTime.utc_now(), -60, :second))
      future = tombstone(stored_blob(), DateTime.add(DateTime.utc_now(), 3600, :second))

      assert :ok = perform_job(BlobCleanupWorker, %{})
      assert reload(past) == nil
      assert %BlobDeletion{} = reload(future)

      assert :ok = perform_job(BlobCleanupWorker, %{"now" => "not a timestamp"})
      assert %BlobDeletion{} = reload(future)
    end
  end

  describe "end to end" do
    test "deleting a task with attachments then running the worker removes their blobs" do
      user = user_fixture()
      column = user |> board_fixture() |> column_fixture()
      task = task_fixture(column)
      survivor = attachment_fixture(task_fixture(column))

      attachments = for _ <- 1..2, do: attachment_fixture(task)
      keys = Enum.map(attachments, & &1.storage_key)

      for key <- [survivor.storage_key | keys], do: :ok = Storage.put(key, {:binary, "data"})

      Task |> Repo.get!(task.id) |> Repo.delete!()

      # The trigger stamps delete_after with the database clock, so run a
      # minute ahead of it.
      assert :ok = run(DateTime.add(DateTime.utc_now(), 60, :second))

      refute Enum.any?(keys, &blob_exists?/1)
      assert blob_exists?(survivor.storage_key)
      assert BlobDeletion |> where([d], d.storage_key in ^keys) |> Repo.all() == []
    end
  end

  describe "backoff_minutes/1" do
    test "doubles with each attempt and is capped at one day" do
      assert BlobCleanupWorker.backoff_minutes(0) == 1
      assert BlobCleanupWorker.backoff_minutes(1) == 2
      assert BlobCleanupWorker.backoff_minutes(3) == 8
      assert BlobCleanupWorker.backoff_minutes(10) == 1024
      assert BlobCleanupWorker.backoff_minutes(11) == 1440
      assert BlobCleanupWorker.backoff_minutes(1_000_000) == 1440
    end
  end

  describe "uniqueness" do
    test "inserting the job twice while one is available is deduplicated" do
      assert {:ok, first} = %{} |> BlobCleanupWorker.new() |> Oban.insert()
      assert {:ok, second} = %{} |> BlobCleanupWorker.new() |> Oban.insert()

      assert second.conflict?
      assert second.id == first.id
      assert length(all_enqueued(worker: BlobCleanupWorker)) == 1
    end

    test "a run waiting to retry keeps the next tick from queueing another" do
      assert {:ok, first} = %{} |> BlobCleanupWorker.new() |> Oban.insert()

      first
      |> Ecto.Changeset.change(state: "retryable", attempt: 1)
      |> Repo.update!()

      assert {:ok, second} = %{} |> BlobCleanupWorker.new() |> Oban.insert()

      assert second.conflict?
      assert second.id == first.id
    end

    test "its unique option covers the available, scheduled and executing states" do
      unique = BlobCleanupWorker.__opts__()[:unique]
      states = MapSet.new(unique[:states])
      required = MapSet.new([:available, :scheduled, :executing])

      assert MapSet.subset?(required, states)
      # A run waiting to retry also blocks the next tick, so runs never overlap.
      assert MapSet.member?(states, :retryable)
      assert unique[:period] == :infinity
    end
  end

  describe "configuration" do
    test "the crontab schedules the worker on the attachments queue" do
      oban = Application.fetch_env!(:kanban, Oban)

      {Oban.Plugins.Cron, opts} =
        oban |> Keyword.fetch!(:plugins) |> List.keyfind(Oban.Plugins.Cron, 0)

      assert {"*/15 * * * *", BlobCleanupWorker} in Keyword.fetch!(opts, :crontab)
      assert BlobCleanupWorker.__opts__()[:queue] == :attachments
      assert BlobCleanupWorker.__opts__()[:max_attempts] == 3
      assert Keyword.fetch!(oban, :queues)[:attachments] == 1
    end

    test "config.exs sets the batch size" do
      # The setup restores the env, so this reads what config.exs set.
      assert Application.fetch_env!(:kanban, BlobCleanupWorker)[:batch_size] == 200
    end
  end
end
