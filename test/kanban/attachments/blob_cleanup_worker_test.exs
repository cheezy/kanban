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
    def put(key, source, opts) do
      result = Local.put(key, source, opts)
      run_hook(:after_put, key)
      result
    end

    @impl true
    def stream(key), do: Local.stream(key)

    @impl true
    def delete(key) do
      send(self(), {:storage_deleted, key})
      run_hook(:before_delete, key)

      case Process.get(:delete_result) do
        nil -> Local.delete(key)
        result -> result
      end
    end

    @impl true
    def exists(key), do: Local.exists(key)

    @impl true
    def sweep(older_than), do: Local.sweep(older_than)

    # A test can run code at a step boundary, in the process making the
    # storage call, to stand in for another process interleaving there.
    defp run_hook(name, key) do
      case Process.get(name) do
        nil -> :ok
        hook -> hook.(key)
      end
    end
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

    test "an unexpected adapter result keeps the row as a storage failure" do
      # The storage facade turns a result outside the adapter contract into
      # :storage_unavailable and logs which contract was broken.
      first = tombstone(key(), minutes(-2))
      Process.put(:delete_result, {:error, "a message, not a reason atom"})
      log = capture_log(fn -> assert :ok = run() end)

      assert log =~ "attachment storage delete failed: :unexpected_reason"

      assert %BlobDeletion{attempts: 1, last_error: "storage_unavailable"} =
               updated = reload(first)

      assert DateTime.compare(updated.delete_after, minutes(2)) == :eq

      second = tombstone(key(), minutes(-2))
      Process.put(:delete_result, :what)
      log = capture_log(fn -> assert :ok = run() end)

      assert log =~ "attachment storage delete failed: :unexpected_result"
      assert %BlobDeletion{attempts: 1, last_error: "storage_unavailable"} = reload(second)
    end

    test "an adapter delete that raises or exits fails that key and the run goes on" do
      first = tombstone(stored_blob(), minutes(-3))
      second = tombstone(stored_blob(), minutes(-2))
      first_key = first.storage_key

      Process.put(:before_delete, fn
        ^first_key -> raise "store overloaded"
        _other -> :ok
      end)

      log = capture_log(fn -> assert :ok = run() end)

      assert log =~ "attachment storage delete failed: :exception"
      refute log =~ "store overloaded"
      assert %BlobDeletion{attempts: 1, last_error: "storage_unavailable"} = reload(first)
      assert reload(second) == nil
      refute blob_exists?(second.storage_key)

      Process.put(:before_delete, fn _key -> exit(:timeout) end)
      log = capture_log(fn -> assert :ok = run(minutes(10)) end)

      assert log =~ "attachment storage delete failed: :exit"
      assert %BlobDeletion{attempts: 2} = reload(first)
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
      # The pending tombstone stays, with the claim recorded on it, so the
      # upload it belongs to is refused at commit rather than naming a blob
      # that was just deleted.
      assert %BlobDeletion{attempts: 1, delete_after: delete_after} = reload(pending)
      assert delete_after == minutes(60)
    end

    test "two due tombstones for the same key are both removed" do
      key = stored_blob()
      rows = [tombstone(key, minutes(-2)), tombstone(key, minutes(-1))]

      assert :ok = run()

      refute blob_exists?(key)
      assert Enum.all?(rows, &(reload(&1) == nil))
    end

    test "each run sweeps the local adapter's temp files once they are an hour old",
         %{tmp_dir: tmp_dir} do
      _ = stored_blob()
      staging = Path.join([tmp_dir, "root", ".staging"])
      old = Path.join(staging, ".tmp-left-by-a-killed-put")
      young = Path.join(staging, ".tmp-still-being-written")

      for {path, age} <- [{old, 3_700}, {young, 30}] do
        File.write!(path, "partial")
        File.touch!(path, System.os_time(:second) - age)
      end

      assert :ok = run()

      refute File.exists?(old)
      assert File.exists?(young)
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

  describe "racing an upload" do
    setup %{tmp_dir: tmp_dir} do
      user = user_fixture()
      task = user |> board_fixture() |> column_fixture() |> task_fixture()
      path = Path.join(tmp_dir, "notes.txt")
      File.write!(path, "racing an upload\n")

      %{
        scope: Kanban.Accounts.Scope.for_user(user),
        task: task,
        upload: %{path: path, filename: "notes.txt", content_type: "text/plain"}
      }
    end

    test "a run between an upload's put and its commit refuses the upload instead of leaving a row with no blob",
         %{scope: scope, task: task, upload: upload} do
      # The pending tombstone comes due early, as with a future "now".
      Process.put(:after_put, fn _key ->
        assert :ok = run(DateTime.add(DateTime.utc_now(), 2, :hour))
      end)

      assert {:error, :storage_unavailable} =
               Kanban.Attachments.create_attachment(scope, task, upload)

      assert Repo.aggregate(Kanban.Attachments.TaskAttachment, :count) == 0
      assert_received {:storage_deleted, key}
      refute blob_exists?(key)
      assert Repo.aggregate(BlobDeletion, :count) == 0
    end

    test "an upload that commits after the batch is read keeps its blob", %{task: task} do
      first = tombstone(stored_blob(), minutes(-10))
      first_key = first.storage_key
      # An upload's blob is stored and its pending tombstone has come due.
      key = stored_blob()
      tombstone(key, minutes(-5))

      # The run reads a batch holding both tombstones; while it deletes the
      # first blob, the upload commits its row and removes its tombstone.
      Process.put(:before_delete, fn
        ^first_key ->
          attachment_fixture(task, %{storage_key: key})
          BlobDeletion |> where([d], d.storage_key == ^key) |> Repo.delete_all()

        _other ->
          :ok
      end)

      assert :ok = run()

      refute blob_exists?(first_key)
      assert blob_exists?(key)
      refute_received {:storage_deleted, ^key}
    end

    test "a row that commits after the batch is read, with its tombstone still due, keeps its blob",
         %{task: task} do
      first = tombstone(stored_blob(), minutes(-10))
      first_key = first.storage_key
      key = stored_blob()
      stale = tombstone(key, minutes(-5))

      Process.put(:before_delete, fn
        ^first_key -> attachment_fixture(task, %{storage_key: key})
        _other -> :ok
      end)

      assert :ok = run()

      assert blob_exists?(key)
      assert reload(stale) == nil
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

  describe "a long run" do
    # The run's summary line is info, below the test level. The module is
    # not async, so lowering the global level here is safe.
    setup do
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)
    end

    # A slow first delete stands in for a store that hangs: the hook sleeps
    # past the budget (or past a whole second) before that delete returns.
    defp slow_first_delete(first_key, sleep_ms) do
      Process.put(:before_delete, fn
        ^first_key -> Process.sleep(sleep_ms)
        _key -> :ok
      end)
    end

    test "stops taking tombstones once max_run_seconds have passed and leaves the rest untouched" do
      Application.put_env(:kanban, BlobCleanupWorker, max_run_seconds: 1)

      first = tombstone(stored_blob(), minutes(-30))
      second = tombstone(stored_blob(), minutes(-20))
      third = tombstone(stored_blob(), minutes(-10))
      slow_first_delete(first.storage_key, 1_100)

      log = capture_log([level: :info], fn -> assert :ok = run() end)

      assert reload(first) == nil
      assert_received {:storage_deleted, first_key} when first_key == first.storage_key
      refute_received {:storage_deleted, _key}

      for row <- [second, third] do
        assert %BlobDeletion{attempts: 0} = kept = reload(row)
        assert kept.delete_after == row.delete_after
        assert blob_exists?(row.storage_key)
      end

      assert log =~ "1 deleted"
      assert log =~ "2 left for the next run"

      # The next run takes them.
      assert :ok = run()
      assert reload(second) == nil
      assert reload(third) == nil
    end

    test "a run inside its budget takes the whole batch" do
      rows = for minutes <- [-3, -2, -1], do: tombstone(stored_blob(), minutes(minutes))

      log = capture_log([level: :info], fn -> assert :ok = run() end)

      assert Enum.all?(rows, &(reload(&1) == nil))
      assert log =~ "0 left for the next run"
    end

    test "falls back to the default budget when max_run_seconds is not a positive integer" do
      for setting <- [0, -5, "600", nil] do
        Application.put_env(:kanban, BlobCleanupWorker, max_run_seconds: setting)
        row = tombstone(stored_blob(), minutes(-1))

        assert :ok = run()
        assert reload(row) == nil
      end
    end

    test "counts each failure's backoff from the moment of its try, not from the run's start" do
      Process.put(:delete_result, {:error, :storage_unavailable})
      first = tombstone(key(), minutes(-30))
      second = tombstone(key(), minutes(-20))
      slow_first_delete(first.storage_key, 1_100)

      capture_log(fn -> assert :ok = run() end)

      # attempts 1 backs off 2 minutes. The first key was tried at the run's
      # start; the second at least a second later.
      assert %BlobDeletion{attempts: 1, delete_after: first_retry} = reload(first)
      assert %BlobDeletion{attempts: 1, delete_after: second_retry} = reload(second)
      assert first_retry == minutes(2)
      assert DateTime.compare(second_retry, DateTime.add(minutes(2), 1, :second)) != :lt
    end

    test "is timed out by Oban well before Lifeline would rescue it" do
      assert BlobCleanupWorker.timeout(%Oban.Job{}) == :timer.minutes(30)

      {amount, :minutes} = Application.fetch_env!(:kanban, Oban)[:lifeline][:rescue_after]
      assert BlobCleanupWorker.timeout(%Oban.Job{}) < :timer.minutes(amount)
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
