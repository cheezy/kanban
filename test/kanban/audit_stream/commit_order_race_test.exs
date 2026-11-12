defmodule Kanban.AuditStream.CommitOrderRaceTest do
  @moduledoc """
  Proves the commit-order claim of `Kanban.AuditStream.Reader` with real,
  committing connections and the real, cluster-wide snapshot horizon
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §7.2, §7.3, §14 "Commit order").

  The sandboxed `Kanban.AuditStream.ReaderTest` cannot prove it: a sandboxed
  test runs inside one open transaction, so its rows never fall below its own
  horizon and it has to pass a `:horizon` by hand. Here every process checks
  out its connection with `sandbox: false`, every row commits for real, and
  every read uses the Reader's default horizon.

  ## Running

  These tests carry `@moduletag :audit_stream_race`, which `test/test_helper.exs`
  excludes, so the normal suite never runs them. Their rows commit, and the
  append-only trigger on `audit_events` refuses to delete them, so they run
  only in a throwaway database, dropped before and after the run:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race test/kanban/audit_stream/commit_order_race_test.exs
      dropdb kanban_test_race

  The `test` alias creates and migrates `kanban_test_race`. Drop it between
  runs: fixtures commit, and the unique integers in their names restart with
  every VM. `setup_all` refuses any database whose name does not end in
  `_race`.

  The horizon is cluster-wide, so an open writing transaction in another
  database on the same server (another `kanban_test` partition, the dev app)
  holds it back too. Every wait for the horizon therefore polls with a deadline
  rather than sleeping, and every assertion compares events with each other,
  never with an absolute transaction id, so a foreign transaction slows these
  tests rather than failing them, up to the deadline. The deadline is 150
  seconds, above the sandbox's 120-second ownership timeout, so a sandboxed
  test in another partition cannot outlast it; a foreign transaction held open
  longer than that still fails the wait, which then reports what is waiting.
  """
  use ExUnit.Case, async: false

  import Kanban.OrganizationsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream.Reader
  alias Kanban.Repo

  @moduletag :audit_stream_race
  @moduletag timeout: 900_000

  # How long one wait for the horizon may take before the test fails. It is
  # above the sandbox's 120 s ownership timeout, which bounds how long a
  # sandboxed test in another partition can hold a transaction open.
  @deadline_ms 150_000
  @await_ms 180_000

  setup_all do
    database = Repo.config()[:database]

    unless String.ends_with?(database, "_race") do
      raise """
      #{inspect(__MODULE__)} commits audit events that can never be deleted, so it \
      runs only in the throwaway kanban_test_race database, not #{database}:

          dropdb --if-exists kanban_test_race
          MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race #{Path.relative_to_cwd(__ENV__.file)}
          dropdb kanban_test_race
      """
    end

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{organization: race_organization("audit-race")}
  end

  test "reader returns A (lower txid, higher id) before B", %{organization: organization} do
    t2_commits_first(organization)
    t1_commits_first(race_organization("audit-race-order"))
  end

  test "long-open writing transaction holds the horizon", %{organization: organization} do
    holder =
      held_transaction(fn ->
        insert_event!(organization, "race_held")
      end)

    held = await_message(holder, :holding)
    later = insert_event!(organization, "race_later")

    # The later event is committed, but its transaction id is above the
    # holder's, so the reader must not pass it while the holder is open.
    assert read_all(organization) == []
    assert %{events_waiting: 1, events_above_horizon: 1} = waiting(organization)
    assert Process.alive?(holder.pid)

    release(holder)

    assert ids(await_events(organization, 2)) == [held.id, later.id]
  end

  test "read-only open transaction does not hold the horizon", %{organization: organization} do
    holder =
      held_transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")

        Repo.query!("SELECT count(*) FROM audit_events WHERE organization_id = $1", [
          organization.id
        ])

        %{rows: [[xid]]} = Repo.query!("SELECT pg_current_xact_id_if_assigned()")
        xid
      end)

    # The reading transaction took a snapshot but no transaction id.
    assert await_message(holder, :holding) == nil

    event = insert_event!(organization, "race_after_reader")

    assert ids(await_events(organization, 1)) == [event.id]
    assert Process.alive?(holder.pid)

    release(holder)
  end

  test "rolled-back event never appears", %{organization: organization} do
    rolled_back = held_transaction(fn -> insert_event!(organization, "race_rolled_back") end)
    discarded = await_message(rolled_back, :holding)

    committed = insert_event!(organization, "race_committed")
    assert read_all(organization) == []

    release(rolled_back, :rollback)

    assert ids(await_events(organization, 1)) == [committed.id]
    assert Repo.get(AuditEvent, discarded.id) == nil

    # read_range applies no horizon, so it would show the row if it existed.
    last = {9_223_372_036_854_775_807, 9_223_372_036_854_775_807}
    assert ids(Reader.read_range(organization.id, {0, 0}, last)) == [committed.id]
  end

  test "Organization with no events reads nothing", %{organization: busy} do
    empty = race_organization("audit-race-empty")

    committed =
      1..4
      |> Enum.map(fn n -> writer(busy, n, 5, 0) end)
      |> Enum.flat_map(&Task.await(&1, @await_ms))

    # The busy Organization's events are all below the horizon now, so the
    # horizon has passed every transaction this test made.
    assert length(await_events(busy, length(committed))) == length(committed)

    assert Reader.next_batch(empty.id, {0, 0}) == []

    assert Reader.waiting_counts(empty.id, {0, 0}) == %{
             events_waiting: 0,
             events_above_horizon: 0,
             oldest_waiting_at: nil
           }
  end

  test "concurrent writers with looping reader deliver the committed set exactly once",
       %{organization: organization} do
    reader = looping_reader(organization)
    writers = Enum.map(1..writer_count(), fn n -> writer(organization, n, 20, 5) end)
    committed = writers |> Enum.flat_map(&Task.await(&1, @await_ms)) |> MapSet.new()

    send(reader.pid, {:expect, MapSet.size(committed)})
    delivered = Task.await(reader, @await_ms)
    delivered_ids = Enum.map(delivered, fn {_txid, id} -> id end)

    assert delivered_ids == Enum.uniq(delivered_ids)
    assert MapSet.new(delivered_ids) == committed
    assert delivered == Enum.sort(delivered)
  end

  # T2 commits B while T1, which took its transaction id first, is still
  # open; T1 then inserts A and commits. A has the lower txid and the higher id.
  defp t2_commits_first(organization) do
    t1 = order_t1(organization)
    :ok = await_message(t1, :has_xid)

    b = insert_event!(organization, "race_b")

    send(t1.pid, :insert)
    a = await_message(t1, :inserted)

    # B is committed but sits above T1's transaction id, and A is not
    # committed: nothing may be read yet.
    assert read_all(organization) == []
    assert %{events_waiting: 1, events_above_horizon: 1} = waiting(organization)

    send(t1.pid, :commit)
    Task.await(t1, @await_ms)

    assert_a_before_b(await_events(organization, 2), a, b)
  end

  # T1 takes its transaction id, T2 inserts B and stays open, T1 inserts A and
  # commits first. The reader delivers A, then B once T2 commits.
  defp t1_commits_first(organization) do
    t1 = order_t1(organization)
    :ok = await_message(t1, :has_xid)

    t2 = held_transaction(fn -> insert_event!(organization, "race_b") end)
    b = await_message(t2, :holding)

    a = commit_a(t1)
    [first] = await_events(organization, 1)
    assert first.id == a.id

    release(t2)
    assert_b_after(organization, first, a, b)
  end

  # Once T2 has committed, the cursor after A delivers B, and a full read
  # gives A then B, each once.
  defp assert_b_after(organization, first, a, b) do
    [second] = await_events(organization, 1, {first.txid, first.id})
    assert second.id == b.id

    assert_a_before_b([first, second], a, b)
    assert ids(read_all(organization)) == [a.id, b.id]
  end

  # Lets T1 insert A and commit; returns A.
  defp commit_a(t1) do
    send(t1.pid, :insert)
    a = await_message(t1, :inserted)
    send(t1.pid, :commit)
    Task.await(t1, @await_ms)
    a
  end

  defp assert_a_before_b(events, a, b) do
    assert [%{id: a_id} = read_a, %{id: b_id} = read_b] = events
    assert {a_id, b_id} == {a.id, b.id}
    assert read_a.txid < read_b.txid
    assert read_a.id > read_b.id
  end

  # T1 of the order test: takes a transaction id, then inserts A on :insert
  # and commits on :commit.
  defp order_t1(organization) do
    parent = self()

    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.transaction(
        fn ->
          Repo.query!("SELECT pg_current_xact_id()")
          send(parent, {:has_xid, self(), :ok})
          receive do: (:insert -> :ok)
          send(parent, {:inserted, self(), insert_event!(organization, "race_a")})
          receive do: (:commit -> :ok)
        end,
        timeout: :infinity
      )
    end)
  end

  # A transaction that runs `fun`, reports its result and stays open until
  # release/2 commits or rolls it back.
  defp held_transaction(fun) do
    parent = self()

    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.transaction(
        fn ->
          send(parent, {:holding, self(), fun.()})

          receive do
            :commit -> :ok
            :rollback -> Repo.rollback(:released)
          end
        end,
        timeout: :infinity
      )
    end)
  end

  # The value a racer reported under `tag`, sent as {tag, racer_pid, value}.
  defp await_message(task, tag) do
    pid = task.pid

    receive do
      {^tag, ^pid, value} -> value
    after
      5_000 -> flunk("no #{inspect(tag)} from #{inspect(pid)} within 5s")
    end
  end

  defp release(task, how \\ :commit) do
    send(task.pid, how)
    Task.await(task, @await_ms)
  end

  # Six writers, fewer on a small pool: every racer owns a connection until it
  # exits, and the test process and the looping reader hold two more.
  defp writer_count, do: Repo.config()[:pool_size] |> Kernel.-(2) |> min(6) |> max(2)

  # `transactions` transactions of one to three events each, every fifth one
  # rolled back. Returns the ids that committed.
  defp writer(organization, n, transactions, max_hold_ms) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Enum.flat_map(1..transactions, &write_round(organization, n, &1, max_hold_ms))
    end)
  end

  # One writer transaction; returns the ids it committed.
  defp write_round(organization, n, round, max_hold_ms) do
    result =
      Repo.transaction(fn ->
        events =
          Enum.map(1..:rand.uniform(3), fn _ ->
            insert_event!(organization, "race_writer_#{n}")
          end)

        hold(max_hold_ms)
        if rem(round, 5) == 0, do: Repo.rollback(:discarded), else: events
      end)

    case result do
      {:ok, events} -> ids(events)
      {:error, :discarded} -> []
    end
  end

  defp hold(0), do: :ok
  defp hold(max_ms), do: Process.sleep(:rand.uniform(max_ms + 1) - 1)

  # Reads in small batches, advancing its cursor, until it has delivered the
  # number of events it is told to expect, then makes one more read that must
  # come back empty. Returns every delivered {txid, id} in delivery order.
  defp looping_reader(organization) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      deadline = System.monotonic_time(:millisecond) + @deadline_ms
      delivered = read_loop(organization, {0, 0}, [], nil, deadline)
      {txid, id} = List.last(delivered)
      [] = Reader.next_batch(organization.id, {txid, id}, batch_size: 7)
      delivered
    end)
  end

  defp read_loop(organization, cursor, delivered, expected, deadline) do
    expected = expected || receive_expected()

    cond do
      expected && length(delivered) >= expected ->
        Enum.reverse(delivered)

      System.monotonic_time(:millisecond) > deadline ->
        flunk("looping reader delivered #{length(delivered)} of #{inspect(expected)} events")

      true ->
        {cursor, delivered} = read_step(organization, cursor, delivered)
        read_loop(organization, cursor, delivered, expected, deadline)
    end
  end

  # One batch after `cursor`: the advanced cursor and the delivered pairs,
  # newest first, or a short pause when nothing is below the horizon yet.
  defp read_step(organization, cursor, delivered) do
    case Reader.next_batch(organization.id, cursor, batch_size: 7) do
      [] ->
        Process.sleep(5)
        {cursor, delivered}

      batch ->
        pairs = Enum.map(batch, &{&1.txid, &1.id})
        {List.last(pairs), Enum.reverse(pairs, delivered)}
    end
  end

  defp receive_expected do
    receive do
      {:expect, count} -> count
    after
      0 -> nil
    end
  end

  # Every event below the horizon after `cursor`, read batch by batch.
  defp read_all(organization, cursor \\ {0, 0}, acc \\ []) do
    case Reader.next_batch(organization.id, cursor, batch_size: 3) do
      [] -> Enum.reverse(acc)
      batch -> read_all(organization, cursor_after(batch), Enum.reverse(batch, acc))
    end
  end

  # Polls until `count` events after `cursor` are below the horizon. Fails at
  # the deadline, naming what is still waiting.
  defp await_events(organization, count, cursor \\ {0, 0}) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    poll_events(organization, count, cursor, deadline)
  end

  defp poll_events(organization, count, cursor, deadline) do
    events = read_all(organization, cursor)

    cond do
      length(events) >= count ->
        events

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "expected #{count} events below the horizon, read #{length(events)}; " <>
            "waiting: #{inspect(Reader.waiting_counts(organization.id, cursor))}"
        )

      true ->
        Process.sleep(10)
        poll_events(organization, count, cursor, deadline)
    end
  end

  defp waiting(organization), do: Reader.waiting_counts(organization.id, {0, 0})

  defp cursor_after(batch) do
    last = List.last(batch)
    {last.txid, last.id}
  end

  defp ids(events), do: Enum.map(events, & &1.id)

  defp insert_event!(organization, action) do
    %{action: action, organization_id: organization.id}
    |> AuditEvent.insert_changeset()
    |> Repo.insert!()
  end

  defp race_organization(prefix) do
    organization_fixture(%{name: "#{prefix} #{System.unique_integer([:positive])}"})
  end
end
