defmodule Kanban.AuditStream.DispatchWorkerRaceTest do
  @moduledoc """
  The audit stream worker with real, committing connections and Oban in
  `testing: :disabled` mode, the only mode in which a unique insert takes
  Oban's advisory lock, so uniqueness holds under concurrent inserts
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1, §14 "Worker"): one job
  per destination plus at most one follow-up, the lease
  stopping a second run, a run whose lease expired being unable to move the
  cursor, no transaction open during the POST, and the send deadline.

  ## Running

  Tagged `:audit_stream_race`, which `test/test_helper.exs` excludes. The
  events these tests commit can never be deleted (the append-only trigger),
  so they run only in the throwaway race database, where `config/test.exs`
  also switches Oban to `testing: :disabled`:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race test/kanban/audit_stream/dispatch_worker_race_test.exs
      dropdb kanban_test_race

  Events are inserted with a chosen small `txid`, below any horizon, so the
  tests never wait for the horizon.
  """
  use ExUnit.Case, async: false

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Lease
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport

  @moduletag :audit_stream_race

  # A Req adapter that reports the request's options to the process
  # registered under its own name, and answers 200.
  defmodule RecordingAdapter do
    @moduledoc false
    def run(request) do
      send(__MODULE__, {:request_timeout, request.options[:request_timeout]})
      {request, Req.Response.new(status: 200, body: "ok")}
    end
  end

  @moduletag timeout: 300_000

  @await_ms 30_000

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

    organization =
      organization_fixture(%{name: "audit-worker-race #{System.unique_integer([:positive])}"})

    %{organization: organization, destination: destination_fixture(organization, :https)}
  end

  defp event!(organization, txid) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ('organization_updated', $1, '{}', now() AT TIME ZONE 'UTC', $2) RETURNING id
        """,
        [organization.id, txid]
      )

    id
  end

  defp run(destination),
    do: DispatchWorker.perform(%Oban.Job{args: %{"destination_id" => destination.id}})

  defp cursor(destination), do: Repo.get!(Cursor, destination.id)

  defp attempts(destination),
    do: from(a in Attempt, where: a.destination_id == ^destination.id) |> Repo.all()

  defp queued(destination) do
    id = Integer.to_string(destination.id)

    query =
      from(j in Oban.Job,
        where:
          j.worker == "Kanban.AuditStream.DispatchWorker" and
            fragment("?->>'destination_id' = ?", j.args, ^id) and
            j.state in ["available", "scheduled", "retryable"]
      )

    Repo.all(query)
  end

  # A stub that tells the test it is posting, then waits for `{:reply,
  # status}`. `check` runs inside the POST, in the worker's process.
  defp blocking_stub(check \\ fn -> :ok end) do
    test = self()

    Req.Test.stub(Transport, fn conn ->
      send(test, {:posting, self(), check.()})

      receive do
        {:reply, status} -> Plug.Conn.send_resp(conn, status, "ok")
      after
        @await_ms -> Plug.Conn.send_resp(conn, 599, "timeout")
      end
    end)
  end

  defp start_run(destination) do
    task = Task.async(fn -> run(destination) end)
    assert_receive {:posting, poster, check}, @await_ms
    {task, poster, check}
  end

  test "one job per destination plus at most one follow-up", %{destination: destination} do
    assert {:ok, first} = AuditStream.enqueue_dispatch(destination.id)
    refute first.conflict?
    assert {:ok, %{conflict?: true}} = AuditStream.enqueue_dispatch(destination.id)

    at = DateTime.add(DateTime.utc_now(), 300, :second)

    assert {:ok, %{conflict?: true}} =
             AuditStream.enqueue_dispatch(destination.id, scheduled_at: at)

    assert length(queued(destination)) == 1

    # A running job can queue its own follow-up: executing is not a unique state.
    from(j in Oban.Job, where: j.id == ^first.id)
    |> Repo.update_all(set: [state: "executing"])

    assert {:ok, follow_up} = AuditStream.enqueue_dispatch(destination.id, scheduled_at: at)
    refute follow_up.conflict?
    assert {:ok, %{conflict?: true}} = AuditStream.enqueue_dispatch(destination.id)
    assert length(queued(destination)) == 1

    from(j in Oban.Job, where: j.id in ^[first.id, follow_up.id]) |> Repo.delete_all()
  end

  test "a run that ends with a retry leaves exactly one queued job", ctx do
    event!(ctx.organization, 1)
    Req.Test.stub(Transport, &Plug.Conn.send_resp(&1, 503, "busy"))
    {:ok, running} = AuditStream.enqueue_dispatch(ctx.destination.id)

    from(j in Oban.Job, where: j.id == ^running.id)
    |> Repo.update_all(set: [state: "executing"])

    assert :ok = run(ctx.destination)

    assert [follow_up] = queued(ctx.destination)
    assert follow_up.state == "scheduled"
    assert DateTime.diff(follow_up.scheduled_at, cursor(ctx.destination).next_attempt_at) in -1..1

    from(j in Oban.Job, where: j.id in ^[running.id, follow_up.id]) |> Repo.delete_all()
  end

  test "a draining run past its budget queues its own follow-up while it executes", ctx do
    for txid <- 1..2, do: event!(ctx.organization, txid)
    original = Application.get_env(:kanban, DispatchWorker)
    on_exit(fn -> restore(DispatchWorker, original) end)
    Application.put_env(:kanban, DispatchWorker, batch_size: 1, drain_ms: 0)
    Req.Test.stub(Transport, &Plug.Conn.send_resp(&1, 200, "ok"))
    {:ok, running} = AuditStream.enqueue_dispatch(ctx.destination.id)

    from(j in Oban.Job, where: j.id == ^running.id)
    |> Repo.update_all(set: [state: "executing"])

    assert :ok = run(ctx.destination)

    assert [%{outcome: :delivered}] = attempts(ctx.destination)
    assert [follow_up] = queued(ctx.destination)
    assert follow_up.state in ["available", "scheduled"]
    assert abs(DateTime.diff(follow_up.scheduled_at, DateTime.utc_now())) <= 2

    # Within its budget, a run drains every batch itself and queues nothing.
    Repo.delete!(follow_up)
    Application.put_env(:kanban, DispatchWorker, batch_size: 1)
    assert :ok = run(ctx.destination)

    assert length(attempts(ctx.destination)) == 2
    assert queued(ctx.destination) == []

    Repo.delete!(running)
  end

  test "the lease stops a second run", ctx do
    a = event!(ctx.organization, 1)
    blocking_stub()
    {task, poster, _check} = start_run(ctx.destination)

    # The second run, while the first is in its POST, sends nothing and
    # comes back once the lease expires.
    assert {:snooze, seconds} = run(ctx.destination)
    assert seconds in 1..(Lease.ttl() + 1)
    refute_received {:posting, _, _}

    send(poster, {:reply, 200})
    assert :ok = Task.await(task, @await_ms)
    assert cursor(ctx.destination).last_event_id == a
    assert [%{outcome: :delivered}] = attempts(ctx.destination)

    takes =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Lease.take(ctx.destination.id) end) end)
      |> Enum.map(&Task.await(&1, @await_ms))

    assert Enum.count(takes, &match?({:ok, _}, &1)) == 1
  end

  test "a run whose lease expired cannot move the cursor or record an outcome", ctx do
    event!(ctx.organization, 1)
    blocking_stub()
    {task, poster, _check} = start_run(ctx.destination)
    before = cursor(ctx.destination)

    from(c in Cursor, where: c.destination_id == ^ctx.destination.id)
    |> Repo.update_all(set: [leased_until: DateTime.add(DateTime.utc_now(), -1, :second)])

    assert {:ok, other} = Lease.take(ctx.destination.id)

    send(poster, {:reply, 200})
    assert :ok = Task.await(task, @await_ms)

    cursor = cursor(ctx.destination)
    assert {cursor.last_txid, cursor.last_event_id} == {0, 0}
    assert cursor.pending_batch_id == before.pending_batch_id
    assert cursor.lease_token == other
    assert attempts(ctx.destination) == []

    # Nothing moved, so a run is queued for the batch.
    assert [job] = queued(ctx.destination)
    Repo.delete!(job)
  end

  # Here rather than in the sandbox tests: it swaps the Transport's global
  # Req options for an adapter that records the request, and only this
  # module, which runs alone, can do that without reaching another test.
  test "the POST carries an overall request_timeout within the lease", ctx do
    event!(ctx.organization, 1)
    Process.register(self(), RecordingAdapter)
    original = Application.get_env(:kanban, Transport)
    on_exit(fn -> Application.put_env(:kanban, Transport, original) end)
    Application.put_env(:kanban, Transport, req_options: [adapter: RecordingAdapter])

    assert :ok = run(ctx.destination)
    assert_received {:request_timeout, timeout}
    assert timeout == DispatchWorker.send_timeout_ms()
    assert timeout < Lease.ttl() * 1_000
    assert [%{outcome: :delivered}] = attempts(ctx.destination)
  end

  test "no transaction is open during the POST", ctx do
    event!(ctx.organization, 1)
    destination_id = ctx.destination.id

    # The POST runs in its own process on the run's connection. Were the run
    # holding a transaction there, this query would wait for it and time out;
    # it answers, and no transaction id has been assigned to the one it runs
    # in, so no write of the run is pending.
    blocking_stub(fn ->
      Repo.query!("SELECT pg_current_xact_id_if_assigned() IS NULL").rows
    end)

    {task, poster, check} = start_run(ctx.destination)
    assert check == [[true]]

    # Neither row the run writes is locked while it posts.
    {:ok, locked} =
      Repo.transact(fn ->
        cursor =
          Repo.query!(
            "SELECT 1 FROM audit_stream_cursors WHERE destination_id = $1 FOR UPDATE NOWAIT",
            [destination_id]
          )

        destination =
          Repo.query!("SELECT 1 FROM audit_stream_destinations WHERE id = $1 FOR UPDATE NOWAIT", [
            destination_id
          ])

        {:ok, {cursor.num_rows, destination.num_rows}}
      end)

    assert locked == {1, 1}

    send(poster, {:reply, 200})
    assert :ok = Task.await(task, @await_ms)
    assert [%{outcome: :delivered}] = attempts(ctx.destination)
  end

  test "the Organization snapshot commits with the pending batch, before the POST", ctx do
    event!(ctx.organization, 1)
    blocking_stub()

    {task, poster, _check} = start_run(ctx.destination)

    # The prepare transaction has committed: another connection sees the
    # pending batch and its snapshot together.
    pending = cursor(ctx.destination)
    assert pending.pending_batch_id
    assert pending.pending_organization_id == ctx.organization.id
    assert pending.pending_organization_name == ctx.organization.name

    # A rename committed while the POST is in flight changes nothing pending.
    from(o in Kanban.Organizations.Organization, where: o.id == ^ctx.organization.id)
    |> Repo.update_all(set: [name: "renamed mid-flight #{System.unique_integer([:positive])}"])

    send(poster, {:reply, 503})
    assert :ok = Task.await(task, @await_ms)

    retried = cursor(ctx.destination)
    assert retried.pending_batch_id == pending.pending_batch_id
    assert retried.pending_organization_name == ctx.organization.name
  end

  test "a send past the deadline is stopped, recorded as a retry, cursor kept", ctx do
    event!(ctx.organization, 1)
    original = Application.get_env(:kanban, DispatchWorker)
    on_exit(fn -> restore(DispatchWorker, original) end)
    Application.put_env(:kanban, DispatchWorker, send_deadline_ms: 200)

    Req.Test.stub(Transport, fn conn ->
      Process.sleep(@await_ms)
      Plug.Conn.send_resp(conn, 200, "late")
    end)

    {elapsed_us, result} = :timer.tc(fn -> run(ctx.destination) end)

    assert result == :ok
    assert elapsed_us < 10_000_000

    assert [%{outcome: :retry, error: "Could not connect to the destination"}] =
             attempts(ctx.destination)

    assert cursor(ctx.destination).last_event_id == 0
    assert [job] = queued(ctx.destination)
    Repo.delete!(job)
  end

  defp restore(key, nil), do: Application.delete_env(:kanban, key)
  defp restore(key, value), do: Application.put_env(:kanban, key, value)
end
