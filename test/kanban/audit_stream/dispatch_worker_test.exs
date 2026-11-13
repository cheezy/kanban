defmodule Kanban.AuditStream.DispatchWorkerTest do
  @moduledoc """
  The audit stream worker in the Ecto sandbox, with every request going to a
  `Req.Test` stub on `Kanban.Webhooks.Transport`. Events are inserted with a
  chosen small `txid`, which is below any real horizon, so the worker reads
  them with no horizon option (one test sets the worker's `:horizon` seam to
  hold an event back); the events the worker records itself carry the
  sandbox transaction's own id and are never read. Events are inserted at
  2026-11-01 unless a test says otherwise, so a destination with more than
  one batch waiting is catching up and paced rather than drained; the
  draining tests insert recent events and set the worker's `:batch_size`
  and `:drain_ms` seams. The uniqueness, lease and
  open-transaction tests that need committing connections are in
  `Kanban.AuditStream.DispatchWorkerRaceTest`.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.Pacing
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.AuditStream.Reseed
  alias Kanban.Organizations.Organization
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport

  @delivered [:kanban, :audit_stream, :batch_delivered]
  @failed [:kanban, :audit_stream, :batch_failed]

  setup do
    organization = organization_fixture()
    %{organization: organization, destination: destination_fixture(organization, :https)}
  end

  # --- helpers ------------------------------------------------------------------

  defp event!(
         organization,
         txid,
         action \\ "organization_updated",
         inserted_at \\ ~N[2026-11-01 00:00:00.000000]
       ) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ($1, $2, $3, $4, $5) RETURNING id
        """,
        [
          action,
          organization.id,
          %{"email" => "someone@example.com"},
          inserted_at,
          txid
        ]
      )

    id
  end

  defp own_txid do
    %{rows: [[txid]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    txid
  end

  defp run(destination), do: perform_job(DispatchWorker, %{destination_id: destination.id})

  # Replies `status` (with `headers` and `body`), reporting each request's
  # batch id and event ids to the test process. `before` runs first.
  defp stub(status, opts \\ []) do
    test = self()
    before = Keyword.get(opts, :before, fn -> :ok end)

    headers = Keyword.get(opts, :headers, [])
    reply = Keyword.get(opts, :body, "ok")

    Req.Test.stub(Transport, fn conn ->
      before.()
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, batch_header(conn), event_ids(body), body})

      conn
      |> put_headers(headers)
      |> Plug.Conn.send_resp(status, reply)
    end)
  end

  defp put_headers(conn, headers),
    do: Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)

  defp batch_header(conn), do: conn |> Plug.Conn.get_req_header("x-stride-batch") |> List.first()

  # Req.Test's plug adapter inflates a gzip request body before the stub
  # reads it.
  defp event_ids(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Map.fetch!("id") |> String.to_integer()))
  end

  defp cursor(destination), do: Repo.get!(Cursor, destination.id)
  defp fresh(destination), do: Repo.get!(Destination, destination.id)

  defp attempts(destination),
    do:
      from(a in Attempt, where: a.destination_id == ^destination.id, order_by: a.id) |> Repo.all()

  defp make_due(destination) do
    from(c in Cursor, where: c.destination_id == ^destination.id)
    |> Repo.update_all(set: [next_attempt_at: nil])
  end

  defp set_destination(destination, fields) do
    from(d in Destination, where: d.id == ^destination.id) |> Repo.update_all(set: fields)
  end

  defp set_cursor(destination, fields) do
    from(c in Cursor, where: c.destination_id == ^destination.id) |> Repo.update_all(set: fields)
  end

  defp audit_actions(organization, action) do
    query =
      from(e in AuditEvent,
        where: e.organization_id == ^organization.id and e.action == ^action,
        order_by: e.id
      )

    Repo.all(query)
  end

  defp follow_ups(destination),
    do: all_enqueued(worker: DispatchWorker, args: %{destination_id: destination.id})

  defp seconds_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now())

  # --- delivery -------------------------------------------------------------------

  describe "a 2xx" do
    test "2xx advances the cursor and records a delivered attempt", ctx do
      attach_telemetry([@delivered, @failed])
      a = event!(ctx.organization, 1)
      b = event!(ctx.organization, 2)
      stub(204)

      assert :ok = run(ctx.destination)

      assert_received {:request, batch_id, [^a, ^b], _body}
      assert is_binary(batch_id)

      cursor = cursor(ctx.destination)
      assert {cursor.last_txid, cursor.last_event_id} == {2, b}
      assert cursor.last_inserted_at == ~U[2026-11-01 00:00:00.000000Z]
      assert cursor.pending_batch_id == nil
      assert cursor.pending_attempts == 0
      assert cursor.next_attempt_at == nil
      assert cursor.lease_token == nil and cursor.leased_until == nil

      assert [attempt] = attempts(ctx.destination)
      assert attempt.outcome == :delivered
      assert attempt.batch_id == batch_id
      assert attempt.event_count == 2
      assert attempt.bytes > 0
      assert {attempt.first_event_id, attempt.last_event_id} == {a, b}
      assert attempt.http_status == 204
      assert attempt.error == nil

      destination = fresh(ctx.destination)
      assert destination.state == :healthy
      assert destination.consecutive_failures == 0
      assert %DateTime{} = destination.last_success_at

      assert_received {:telemetry_event, @delivered, %{count: 1, events: 2, bytes: bytes},
                       metadata}

      assert bytes == attempt.bytes
      assert metadata == %{kind: :https}
      refute_received {:telemetry_event, @failed, _, _}

      # Nothing more is waiting, so the sweep queues the next run.
      assert follow_ups(ctx.destination) == []
    end

    test "no events waiting ends without a POST", ctx do
      stub(200)

      assert :ok = run(ctx.destination)

      refute_received {:request, _, _, _}
      assert attempts(ctx.destination) == []
      assert follow_ups(ctx.destination) == []

      cursor = cursor(ctx.destination)
      assert {cursor.last_txid, cursor.last_event_id} == {0, 0}
      assert cursor.lease_token == nil
    end

    test "a cut batch records the destination's filter_version", ctx do
      set_destination(ctx.destination, filter_version: 4)
      event!(ctx.organization, 1)
      stub(503)

      run(ctx.destination)

      assert cursor(ctx.destination).pending_filter_version == 4
    end
  end

  describe "retries" do
    test "retry resends exactly the pending batch with the same batch_id", ctx do
      a = event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, batch_id, [^a], first_body}

      pending = cursor(ctx.destination)
      assert pending.pending_batch_id == batch_id
      assert {pending.last_txid, pending.last_event_id} == {0, 0}

      newer = event!(ctx.organization, 2)
      make_due(ctx.destination)
      stub(200)
      run(ctx.destination)

      assert_received {:request, ^batch_id, [^a], second_body}
      assert Jason.decode!(first_body) == Jason.decode!(second_body)

      cursor = cursor(ctx.destination)
      assert {cursor.last_txid, cursor.last_event_id} == {1, a}
      assert newer > a

      assert [
               %{outcome: :retry, batch_id: ^batch_id},
               %{outcome: :delivered, batch_id: ^batch_id}
             ] =
               attempts(ctx.destination)
    end

    test "a run before next_attempt_at sends nothing and queues a run for then", ctx do
      event!(ctx.organization, 1)
      due = DateTime.add(DateTime.utc_now(), 600, :second)
      set_cursor(ctx.destination, next_attempt_at: due)
      stub(200)

      run(ctx.destination)

      refute_received {:request, _, _, _}
      assert [job] = follow_ups(ctx.destination)
      assert DateTime.diff(job.scheduled_at, due) in -1..1
      assert cursor(ctx.destination).lease_token == nil
    end

    test "backoff, cap and Retry-After set next_attempt_at", ctx do
      for _ <- 1..20 do
        assert Outcome.delay(0) in 15..18
        assert Outcome.delay(2) in 60..72
      end

      assert Outcome.delay(10) == 900
      assert Outcome.delay(0, 120) == 120
      assert Outcome.delay(0, 7_200) == 3_600
      assert Outcome.delay(10, 60) == 900

      event!(ctx.organization, 1)
      stub(503, headers: [{"retry-after", "120"}])
      run(ctx.destination)

      assert seconds_from_now(cursor(ctx.destination).next_attempt_at) in 118..120
      assert [job] = follow_ups(ctx.destination)
      assert seconds_from_now(job.scheduled_at) in 118..120

      make_due(ctx.destination)
      stub(429, headers: [{"retry-after", "7200"}])
      run(ctx.destination)
      assert seconds_from_now(cursor(ctx.destination).next_attempt_at) in 3_598..3_600

      make_due(ctx.destination)
      stub(503, headers: [{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}])
      run(ctx.destination)
      # Third failure: 15 s x 2^2, plus up to 20%; an HTTP date is ignored.
      assert seconds_from_now(cursor(ctx.destination).next_attempt_at) in 58..72
      assert fresh(ctx.destination).consecutive_failures == 3
    end

    test "parse_retry_after/1 takes whole seconds only" do
      assert Outcome.parse_retry_after("30") == 30
      assert Outcome.parse_retry_after(" 30 ") == 30
      assert Outcome.parse_retry_after("-1") == nil
      assert Outcome.parse_retry_after("1.5") == nil
      assert Outcome.parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT") == nil
      assert Outcome.parse_retry_after(nil) == nil
    end

    test "a transport error retries with a bounded error", ctx do
      attach_telemetry(@failed)
      event!(ctx.organization, 1)
      Req.Test.stub(Transport, &Req.Test.transport_error(&1, :econnrefused))

      run(ctx.destination)

      assert [%{outcome: :retry, http_status: nil, error: "Could not connect to the destination"}] =
               attempts(ctx.destination)

      assert fresh(ctx.destination).state == :retrying
      assert_received {:telemetry_event, @failed, %{count: 1}, %{kind: :https, outcome: :retry}}
    end

    test "a send that crashes is recorded as a failed connection and retried", ctx do
      event!(ctx.organization, 1)
      Req.Test.stub(Transport, fn _conn -> raise "boom in the send" end)

      log = capture_log(fn -> assert :ok = run(ctx.destination) end)

      assert [%{outcome: :retry, error: "Could not connect to the destination"}] =
               attempts(ctx.destination)

      assert log =~ "boom in the send"
      assert fresh(ctx.destination).state == :retrying
      assert cursor(ctx.destination).last_event_id == 0
      assert [_job] = follow_ups(ctx.destination)
    end
  end

  describe "refusals" do
    test "unauthorized and config_error mark failing at once", ctx do
      event!(ctx.organization, 1)
      stub(401)

      run(ctx.destination)

      destination = fresh(ctx.destination)
      assert destination.state == :failing
      assert destination.halted_reason == nil
      assert destination.state_reason == "The destination refused the credentials (HTTP 401)"
      assert [%{outcome: :unauthorized, http_status: 401}] = attempts(ctx.destination)
      assert seconds_from_now(cursor(ctx.destination).next_attempt_at) in 898..900
      assert [_follow_up] = follow_ups(ctx.destination)

      assert [%{metadata: %{"reason" => "unauthorized"}} = event] =
               audit_actions(ctx.organization, "audit_stream_failing")

      assert event.actor_user_id == nil

      now = DateTime.utc_now()

      plan =
        Outcome.plan(
          {:config_error, :bad_index},
          "x",
          %Destination{state: :retrying, consecutive_failures: 2},
          %{},
          now
        )

      assert plan.destination.state == :failing
      assert plan.destination.consecutive_failures == 3
      assert plan.audit == {:failing, :config_error}
      assert DateTime.diff(plan.cursor.next_attempt_at, now) == 900

      assert Outcome.attempt_outcome({:config_error, :bad_index}) == :config_error
    end

    test "third permanent rejection halts with rejected_batch", ctx do
      event!(ctx.organization, 1)
      stub(400)

      run(ctx.destination)
      assert cursor(ctx.destination).pending_attempts == 1
      assert seconds_from_now(cursor(ctx.destination).next_attempt_at) in 298..300
      assert fresh(ctx.destination).state == :retrying

      make_due(ctx.destination)
      run(ctx.destination)
      assert cursor(ctx.destination).pending_attempts == 2
      assert fresh(ctx.destination).halted_reason == nil

      make_due(ctx.destination)
      run(ctx.destination)

      destination = fresh(ctx.destination)
      assert destination.state == :failing
      assert destination.halted_reason == :rejected_batch
      assert destination.state_reason == "Rejected by the destination (HTTP 400)"
      cursor = cursor(ctx.destination)
      assert cursor.pending_batch_id != nil
      assert cursor.next_attempt_at == nil
      assert {cursor.last_txid, cursor.last_event_id} == {0, 0}

      assert [%{metadata: %{"reason" => "rejected_batch"}}] =
               audit_actions(ctx.organization, "audit_stream_failing")

      rejected = attempts(ctx.destination)
      assert length(rejected) == 3
      assert Enum.all?(rejected, &(&1.outcome == :rejected))

      for _ <- 1..3, do: assert_received({:request, _, _, _})
      run(ctx.destination)
      refute_received {:request, _, _, _}
    end

    test "413 halves the batch with a new batch_id and single-event 413 is permanent", ctx do
      [a, b, _c] = for txid <- 1..3, do: event!(ctx.organization, txid)
      stub(413)

      run(ctx.destination)
      assert_received {:request, first_id, [^a, ^b, _], _}

      cursor = cursor(ctx.destination)
      assert cursor.pending_batch_id != first_id

      assert {cursor.pending_first_txid, cursor.pending_last_txid, cursor.pending_last_id} ==
               {1, 2, b}

      assert cursor.next_attempt_at == nil
      assert [%{outcome: :rejected, http_status: 413} = attempt] = attempts(ctx.destination)
      assert attempt.error =~ "in halves"
      assert fresh(ctx.destination).state == :healthy
      assert [_follow_up] = follow_ups(ctx.destination)

      run(ctx.destination)
      second_id = cursor.pending_batch_id
      assert_received {:request, ^second_id, [^a, ^b], _}

      # One event that still gets 413 is a permanent rejection.
      run(ctx.destination)
      assert_received {:request, _third, [^a], _}
      single = cursor(ctx.destination)
      assert single.pending_attempts == 1
      assert seconds_from_now(single.next_attempt_at) in 298..300

      assert ctx.destination |> attempts() |> List.last() |> Map.fetch!(:error) ==
               "Too large for the destination (HTTP 413)"
    end

    test "blocked address halts and unresolvable retries", ctx do
      event!(ctx.organization, 1)
      stub(200)

      blocked =
        destination_fixture(ctx.organization, :https,
          url: "https://internal.example.com/in/abcdefgh"
        )

      run(blocked)
      refute_received {:request, _, _, _}

      destination = fresh(blocked)
      assert destination.state == :failing
      assert destination.halted_reason == :blocked_address
      assert destination.state_reason == "The URL points to a private or reserved network address"
      assert [%{outcome: :blocked, http_status: nil}] = attempts(blocked)
      assert follow_ups(blocked) == []

      lost =
        destination_fixture(ctx.organization, :https,
          url: "https://nowhere.example.net/in/abcdefgh"
        )

      run(lost)
      refute_received {:request, _, _, _}

      destination = fresh(lost)
      assert destination.state == :retrying
      assert destination.halted_reason == nil

      assert [%{outcome: :retry, error: "The URL has a host name that could not be found"}] =
               attempts(lost)

      assert [_follow_up] = follow_ups(lost)
    end

    test "txid lower than the cursor's halts with txid_reset", ctx do
      event!(ctx.organization, 1)
      set_cursor(ctx.destination, last_txid: own_txid() + 1_000_000)
      stub(200)

      run(ctx.destination)

      refute_received {:request, _, _, _}
      destination = fresh(ctx.destination)
      assert destination.state == :failing
      assert destination.halted_reason == :txid_reset
      assert destination.state_reason =~ "The database was moved"
      assert attempts(ctx.destination) == []

      assert [%{metadata: %{"reason" => "txid_reset"}}] =
               audit_actions(ctx.organization, "audit_stream_failing")
    end

    # A destination that had received everything before the move has no
    # event after its cursor, so only the sweep's cursor check queues it.
    test "caught-up destination halts with txid_reset after txids go backwards", ctx do
      caught_up = destination_fixture(ctx.organization, :datadog)
      id = event!(ctx.organization, 1)
      set_cursor(caught_up, last_txid: own_txid() + 1_000_000, last_event_id: 0)
      # A pending batch from the old server counts too.
      set_cursor(ctx.destination,
        last_txid: 1,
        last_event_id: id,
        pending_last_txid: own_txid() + 1_000_000
      )

      stub(200)

      assert Reader.next_waiting_at(ctx.organization.id, {own_txid() + 1_000_000, 0}) == nil

      due = AuditStream.due_for_dispatch(DateTime.utc_now())
      assert caught_up.id in due
      assert ctx.destination.id in due

      run(caught_up)

      refute_received {:request, _, _, _}
      assert %{state: :failing, halted_reason: :txid_reset} = fresh(caught_up)
      assert attempts(caught_up) == []

      # Halted, so the sweep never queues it again.
      refute caught_up.id in AuditStream.due_for_dispatch(DateTime.utc_now())
    end

    test "after a move and a re-seed the worker sends the new server's events only", ctx do
      # Restored rows keep the old server's txids, above every new one.
      old = own_txid() + 1_000_000
      delivered = event!(ctx.organization, old, "organization_updated", ~N[2026-11-05 10:00:00])
      held = event!(ctx.organization, old + 5, "organization_updated", ~N[2026-11-05 11:00:00])

      set_cursor(ctx.destination,
        last_txid: old,
        last_event_id: delivered,
        last_inserted_at: ~U[2026-11-05 10:00:00.000000Z]
      )

      # Written on the new server after the move.
      written_after = event!(ctx.organization, 2, "organization_updated", ~N[2026-11-06 09:00:00])
      stub(200)

      run(ctx.destination)
      refute_received {:request, _, _, _}
      assert fresh(ctx.destination).halted_reason == :txid_reset

      assert {:ok, %{destinations: 1}} = AuditStream.reseed_cursors()
      assert [%Gap{reason: :database_move, events: 1}] = Repo.all(Gap)
      assert ctx.destination.id in AuditStream.due_for_dispatch(DateTime.utc_now())

      run(ctx.destination)

      assert_received {:request, _batch, [^written_after], _body}
      assert %{state: :healthy, halted_reason: nil} = fresh(ctx.destination)

      assert {cursor(ctx.destination).last_txid, cursor(ctx.destination).last_event_id} ==
               {2, written_after}

      # The restored event never follows, however many runs come.
      make_due(ctx.destination)
      run(ctx.destination)
      refute_received {:request, _, _, _}
      assert cursor(ctx.destination).restored_max_event_id == held
    end

    test "the sweep leaves a caught-up cursor on this server alone", ctx do
      id = event!(ctx.organization, 1)
      set_cursor(ctx.destination, last_txid: 1, last_event_id: id)

      refute ctx.destination.id in AuditStream.due_for_dispatch(DateTime.utc_now())
    end

    # Once this server's txids pass the old cursor the move is invisible, so
    # it is caught while paused or backing off, not only while sending. A halt
    # for another reason waits for a person and is never replaced.
    test "a paused or backed-off destination halts with txid_reset after a move; a halted one keeps its halt",
         ctx do
      moved = own_txid() + 1_000_000
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      paused = destination_fixture(ctx.organization, :datadog)
      set_destination(paused, enabled: false)
      halted = destination_fixture(ctx.organization, :datadog)
      set_destination(halted, halted_reason: :rejected_batch, state: :failing)
      backed_off = destination_fixture(ctx.organization, :datadog)

      for destination <- [paused, halted, backed_off],
          do: set_cursor(destination, last_txid: moved, last_event_id: 0, next_attempt_at: later)

      stub(200)
      due = AuditStream.due_for_dispatch(DateTime.utc_now())
      for destination <- [paused, backed_off], do: assert(destination.id in due)
      refute halted.id in due

      for destination <- [paused, halted, backed_off], do: run(destination)

      for destination <- [paused, backed_off] do
        assert %{state: :failing, halted_reason: :txid_reset} = fresh(destination)
        assert attempts(destination) == []
      end

      assert fresh(halted).halted_reason == :rejected_batch
      refute_received {:request, _, _, _}
      assert fresh(paused).enabled == false
      due = AuditStream.due_for_dispatch(DateTime.utc_now())
      for destination <- [paused, halted, backed_off], do: refute(destination.id in due)
    end

    # A committed row's txid is below every running transaction's on one
    # server, so a cursor equal to the worker's own txid is another server's.
    test "a cursor at the worker's own txid halts with txid_reset", ctx do
      set_cursor(ctx.destination, last_txid: own_txid(), last_event_id: 0)
      stub(200)

      run(ctx.destination)

      assert %{halted_reason: :txid_reset} = fresh(ctx.destination)
      refute_received {:request, _, _, _}
    end

    test "attempt error never contains response body text", ctx do
      attach_telemetry(@failed)
      event!(ctx.organization, 1)
      marker = "SECRET-BODY-MARKER <script>"

      for status <- [400, 401, 503] do
        make_due(ctx.destination)
        stub(status, body: marker)
        run(ctx.destination)
      end

      for attempt <- attempts(ctx.destination), do: refute(attempt.error =~ "MARKER")
      refute fresh(ctx.destination).state_reason =~ "MARKER"

      for _ <- 1..3 do
        assert_received {:telemetry_event, @failed, measurements, metadata}
        refute inspect({measurements, metadata}) =~ "MARKER"
      end
    end
  end

  describe "state" do
    test "healthy to retrying to failing to healthy records the two audit events", ctx do
      event!(ctx.organization, 1)
      stub(503)

      run(ctx.destination)
      destination = fresh(ctx.destination)
      assert destination.state == :retrying
      assert %DateTime{} = destination.failing_since

      # The run of failures began 31 minutes ago.
      set_destination(ctx.destination,
        failing_since: :second |> DateTime.utc_now() |> DateTime.add(-31, :minute)
      )

      make_due(ctx.destination)
      run(ctx.destination)
      assert fresh(ctx.destination).state == :failing

      make_due(ctx.destination)
      run(ctx.destination)
      assert fresh(ctx.destination).state == :failing

      assert [%{metadata: %{"reason" => "no_success"}}] =
               audit_actions(ctx.organization, "audit_stream_failing")

      make_due(ctx.destination)
      stub(200)
      run(ctx.destination)

      destination = fresh(ctx.destination)
      assert destination.state == :healthy
      assert destination.failing_since == nil
      assert destination.state_reason == nil
      assert destination.consecutive_failures == 0
      assert [_recovered] = audit_actions(ctx.organization, "audit_stream_recovered")
      assert [_failing] = audit_actions(ctx.organization, "audit_stream_failing")
    end

    test "retrying back to healthy records no audit event", ctx do
      event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      make_due(ctx.destination)
      stub(200)
      run(ctx.destination)

      assert fresh(ctx.destination).state == :healthy
      assert audit_actions(ctx.organization, "audit_stream_recovered") == []
      assert audit_actions(ctx.organization, "audit_stream_failing") == []
    end

    test "a paused or halted destination sends nothing", ctx do
      event!(ctx.organization, 1)
      stub(200)

      set_destination(ctx.destination, enabled: false)
      run(ctx.destination)
      set_destination(ctx.destination, enabled: true, halted_reason: :rejected_batch)
      run(ctx.destination)

      refute_received {:request, _, _, _}
      assert attempts(ctx.destination) == []
      assert cursor(ctx.destination).lease_token == nil
    end
  end

  describe "filter changes (D16)" do
    test "a pending batch with an older pending_filter_version is discarded and re-cut with a new batch_id",
         ctx do
      a = event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, old_id, [^a], old_body}
      assert old_body =~ "someone@example.com"

      set_destination(ctx.destination, include_personal_data: false, filter_version: 2)
      make_due(ctx.destination)
      run(ctx.destination)

      assert_received {:request, new_id, [^a], new_body}
      assert new_id != old_id
      refute new_body =~ "someone@example.com"
      assert cursor(ctx.destination).pending_batch_id == new_id
      assert cursor(ctx.destination).pending_filter_version == 2
    end

    test "the filter changes twice while a batch is pending: one re-cut, under the latest", ctx do
      event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, old_id, _, _}

      set_destination(ctx.destination, include_personal_data: false, filter_version: 2)
      set_destination(ctx.destination, include_personal_data: true, filter_version: 3)
      make_due(ctx.destination)
      run(ctx.destination)

      assert_received {:request, new_id, _, body}
      refute_received {:request, _, _, _}
      assert new_id != old_id
      assert body =~ "someone@example.com"
      assert cursor(ctx.destination).pending_filter_version == 3
    end

    test "the excluded actions now exclude every pending event: nothing is sent", ctx do
      event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, _, _, _}

      set_destination(ctx.destination,
        excluded_actions: ["organization_updated"],
        filter_version: 2
      )

      make_due(ctx.destination)
      stub(200)
      run(ctx.destination)

      refute_received {:request, _, _, _}
      cursor = cursor(ctx.destination)
      assert cursor.pending_batch_id == nil
      assert cursor.pending_filter_version == nil
      assert {cursor.last_txid, cursor.last_event_id} == {0, 0}
    end

    test "a batch in flight when the filter changes still advances the cursor on 2xx", ctx do
      a = event!(ctx.organization, 1)
      destination = ctx.destination

      stub(200,
        before: fn ->
          set_destination(destination, include_personal_data: false, filter_version: 2)
        end
      )

      run(destination)

      assert_received {:request, _, [^a], _}
      cursor = cursor(destination)
      assert {cursor.last_txid, cursor.last_event_id} == {1, a}
      assert cursor.pending_batch_id == nil
      assert [%{outcome: :delivered}] = attempts(destination)
    end

    test "a pending batch whose events are gone is re-cut with a new batch_id", ctx do
      a = event!(ctx.organization, 5)
      stale_id = Ecto.UUID.generate()

      set_cursor(ctx.destination,
        pending_batch_id: stale_id,
        pending_first_txid: 1,
        pending_first_id: 1,
        pending_last_txid: 2,
        pending_last_id: 2,
        pending_filter_version: 1
      )

      stub(200)
      run(ctx.destination)

      assert_received {:request, new_id, [^a], _}
      assert new_id != stale_id
    end

    test "retention removing a pending batch's first or last event re-cuts the survivors under a new batch_id",
         ctx do
      stale_id = Ecto.UUID.generate()
      b = event!(ctx.organization, 2)
      c = event!(ctx.organization, 3)
      stub(200)

      # The first event, (1, 1), is gone.
      set_cursor(ctx.destination,
        pending_batch_id: stale_id,
        pending_first_txid: 1,
        pending_first_id: 1,
        pending_last_txid: 3,
        pending_last_id: c,
        pending_filter_version: 1
      )

      run(ctx.destination)
      assert_received {:request, first_cut, [^b, ^c], _}
      assert first_cut != stale_id

      # The last event, (4, 1), is gone.
      d = event!(ctx.organization, 4)

      set_cursor(ctx.destination,
        last_txid: 3,
        last_event_id: c,
        pending_batch_id: stale_id,
        pending_first_txid: 4,
        pending_first_id: d,
        pending_last_txid: 5,
        pending_last_id: 1,
        pending_filter_version: 1
      )

      run(ctx.destination)
      assert_received {:request, second_cut, [^d], _}
      assert second_cut != stale_id
    end
  end

  describe "the Organization snapshot (D428)" do
    # Replies `status`, reporting each request's raw body and the `t` of its
    # signature, with the system time just before the request was signed and
    # just after it was answered.
    defp capture(status) do
      test = self()

      Req.Test.stub(Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [signature] = Plug.Conn.get_req_header(conn, "x-stride-signature")
        ["t=" <> t | _] = String.split(signature, ",")
        send(test, {:sent, batch_header(conn), body, String.to_integer(t)})
        Plug.Conn.send_resp(conn, status, "ok")
      end)
    end

    defp rename(organization, name) do
      from(o in Organization, where: o.id == ^organization.id)
      |> Repo.update_all(set: [name: name])
    end

    defp snapshot(destination) do
      cursor = cursor(destination)
      {cursor.pending_organization_id, cursor.pending_organization_name}
    end

    test "a first attempt stores the Organization snapshot with the pending batch", ctx do
      event!(ctx.organization, 1)
      stub(503)

      run(ctx.destination)

      assert_received {:request, batch_id, _, _}
      assert cursor(ctx.destination).pending_batch_id == batch_id
      assert snapshot(ctx.destination) == {ctx.organization.id, ctx.organization.name}
    end

    test "a retry after an Organization rename builds the same body", ctx do
      destination =
        destination_fixture(ctx.organization, :https, %{settings: %{"format" => "json"}})

      event!(ctx.organization, 1)
      event!(ctx.organization, 2)
      capture(503)

      before_first = System.system_time(:second)
      run(destination)
      assert_received {:sent, batch_id, first_body, first_t}
      assert first_t >= before_first and first_t <= System.system_time(:second)

      rename(ctx.organization, "Renamed between attempts")
      make_due(destination)
      capture(200)

      before_second = System.system_time(:second)
      run(destination)
      assert_received {:sent, ^batch_id, second_body, second_t}

      # The body is byte-identical; only the signature time is the attempt's.
      assert second_body == first_body
      assert second_t >= before_second and second_t <= System.system_time(:second)

      decoded = Jason.decode!(second_body)

      assert decoded["organization"] == %{
               "id" => ctx.organization.id,
               "name" => ctx.organization.name
             }

      assert Enum.all?(decoded["events"], &(&1["organization"]["name"] == ctx.organization.name))
      refute second_body =~ "Renamed between attempts"
    end

    test "the next batch uses the current Organization name", ctx do
      event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, first_id, _, _}

      rename(ctx.organization, "Current name")
      make_due(ctx.destination)
      stub(200)
      run(ctx.destination)
      assert_received {:request, ^first_id, _, delivered_body}
      refute delivered_body =~ "Current name"

      # Acknowledging the batch clears the snapshot.
      assert snapshot(ctx.destination) == {nil, nil}

      event!(ctx.organization, 2)
      stub(503)
      run(ctx.destination)

      assert_received {:request, next_id, _, next_body}
      assert next_id != first_id
      assert next_body =~ "Current name"
      assert snapshot(ctx.destination) == {ctx.organization.id, "Current name"}
    end

    test "a discarded pending batch clears the Organization snapshot", ctx do
      event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, old_id, _, _}

      # Discarded and re-cut: the new batch stores a fresh snapshot.
      rename(ctx.organization, "After the filter change")
      set_destination(ctx.destination, filter_version: 2)
      make_due(ctx.destination)
      run(ctx.destination)

      assert_received {:request, new_id, _, body}
      assert new_id != old_id
      assert body =~ "After the filter change"
      assert snapshot(ctx.destination) == {ctx.organization.id, "After the filter change"}

      # Discarded with nothing left to send: the snapshot goes with it.
      set_destination(ctx.destination,
        excluded_actions: ["organization_updated"],
        filter_version: 3
      )

      make_due(ctx.destination)
      run(ctx.destination)

      refute_received {:request, _, _, _}
      assert cursor(ctx.destination).pending_batch_id == nil
      assert snapshot(ctx.destination) == {nil, nil}
    end

    test "a pending batch discarded for a shrunk range stores a fresh snapshot", ctx do
      b = event!(ctx.organization, 2)
      c = event!(ctx.organization, 3)
      stub(503)

      # The first event, (1, 1), is gone; the stale snapshot goes with the batch.
      set_cursor(ctx.destination,
        pending_batch_id: Ecto.UUID.generate(),
        pending_first_txid: 1,
        pending_first_id: 1,
        pending_last_txid: 3,
        pending_last_id: c,
        pending_filter_version: 1,
        pending_organization_id: ctx.organization.id,
        pending_organization_name: "Stale name"
      )

      run(ctx.destination)

      assert_received {:request, _new_id, [^b, ^c], body}
      refute body =~ "Stale name"
      assert body =~ ctx.organization.name
      assert snapshot(ctx.destination) == {ctx.organization.id, ctx.organization.name}
    end

    test "a pending batch without a snapshot stores one", ctx do
      event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, batch_id, _, _}

      # As a batch cut before the snapshot columns existed.
      set_cursor(ctx.destination, pending_organization_id: nil, pending_organization_name: nil)
      rename(ctx.organization, "Read once")
      make_due(ctx.destination)
      run(ctx.destination)

      assert_received {:request, ^batch_id, _, fallback_body}
      assert fallback_body =~ "Read once"
      assert snapshot(ctx.destination) == {ctx.organization.id, "Read once"}

      rename(ctx.organization, "Read twice")
      make_due(ctx.destination)
      run(ctx.destination)

      assert_received {:request, ^batch_id, _, retried_body}
      assert retried_body == fallback_body
    end

    test "skip and reseed clear the Organization snapshot", ctx do
      admin = user_fixture()
      organization_member_fixture(ctx.organization, admin, :org_admin)
      event!(ctx.organization, 1)
      stub(503)
      run(ctx.destination)
      assert_received {:request, _, _, _}
      assert snapshot(ctx.destination) == {ctx.organization.id, ctx.organization.name}

      set_destination(ctx.destination, state: :failing, halted_reason: :rejected_batch)

      scope = Scope.for_user(admin)
      assert {:ok, _skipped} = AuditStream.skip_batch(scope, ctx.destination)
      assert snapshot(ctx.destination) == {nil, nil}

      other = destination_fixture(ctx.organization, :https)
      run(other)
      assert_received {:request, _, _, _}
      assert snapshot(other) == {ctx.organization.id, ctx.organization.name}

      # As after a logical database move: the re-seed finds it halted.
      set_destination(other, halted_reason: :txid_reset)

      assert {:ok, %{destinations: reseeded}} = Reseed.run()
      assert reseeded >= 1
      assert cursor(other).pending_batch_id == nil
      assert snapshot(other) == {nil, nil}
    end

    test "snapshot/2 reuses only a snapshot stored for the same Organization" do
      live = %{id: 7, name: "Live name"}

      stored = %Cursor{pending_organization_id: 7, pending_organization_name: "Stored name"}
      assert PendingBatch.snapshot(stored, live) == {%{id: 7, name: "Stored name"}, %{}}

      fields = %{pending_organization_id: 7, pending_organization_name: "Live name"}
      assert PendingBatch.snapshot(%Cursor{}, live) == {live, fields}

      # A snapshot recorded for another Organization is never reused.
      other = %Cursor{pending_organization_id: 8, pending_organization_name: "Other name"}
      assert PendingBatch.snapshot(other, live) == {live, fields}

      half = %Cursor{pending_organization_id: 7, pending_organization_name: nil}
      assert PendingBatch.snapshot(half, live) == {live, fields}
    end
  end

  describe "unreadable credentials (D17)" do
    test "an unreadable credential halts with credentials_unreadable, sends nothing and records no attempt",
         ctx do
      attach_telemetry([@delivered, @failed])
      event!(ctx.organization, 1)
      make_unreadable!(ctx.destination, :url)
      stub(200)

      assert :ok = run(ctx.destination)

      refute_received {:request, _, _, _}
      assert attempts(ctx.destination) == []
      destination = fresh(ctx.destination)
      assert destination.state == :failing
      assert destination.halted_reason == :credentials_unreadable
      assert destination.state_reason == "Credentials can't be read. Enter them again."
      assert follow_ups(ctx.destination) == []
      assert cursor(ctx.destination).lease_token == nil
      refute_received {:telemetry_event, _, _, _}

      assert [%{metadata: %{"reason" => "credentials_unreadable"}}] =
               audit_actions(ctx.organization, "audit_stream_failing")

      run(ctx.destination)
      assert length(audit_actions(ctx.organization, "audit_stream_failing")) == 1
    end

    test "an unreadable previous signing secret alone still sends", ctx do
      expires = :second |> DateTime.utc_now() |> DateTime.add(3_600, :second)

      ctx.destination
      |> Destination.signing_secret_changeset(%{
        previous_signing_secret: "assec_previous-secret-value",
        previous_secret_expires_at: expires
      })
      |> Repo.update!()

      make_unreadable!(ctx.destination, :previous_signing_secret)
      a = event!(ctx.organization, 1)
      stub(200)

      run(ctx.destination)

      assert_received {:request, _, [^a], _}
      assert fresh(ctx.destination).halted_reason == nil
    end
  end

  describe "the lease and the record step" do
    test "a live lease held by another run stops this one, which snoozes until it expires",
         ctx do
      event!(ctx.organization, 1)

      set_cursor(ctx.destination,
        lease_token: Ecto.UUID.generate(),
        leased_until: DateTime.add(DateTime.utc_now(), 40, :second)
      )

      stub(200)
      assert {:snooze, seconds} = run(ctx.destination)

      assert seconds in 40..42
      refute_received {:request, _, _, _}
      assert attempts(ctx.destination) == []
    end

    test "a run whose lease was taken during the POST records nothing", ctx do
      a = event!(ctx.organization, 1)
      destination = ctx.destination

      stub(200,
        before: fn ->
          set_cursor(destination,
            lease_token: Ecto.UUID.generate(),
            leased_until: DateTime.add(DateTime.utc_now(), 60, :second)
          )
        end
      )

      log = capture_log(fn -> assert :ok = run(destination) end)

      assert_received {:request, _, [^a], _}
      assert log =~ "not recorded: lease_lost"
      cursor = cursor(destination)
      assert {cursor.last_txid, cursor.last_event_id} == {0, 0}
      assert cursor.lease_token != nil
      assert attempts(destination) == []

      # The batch still needs a run, so one is queued now.
      assert [job] = follow_ups(destination)
      assert seconds_from_now(job.scheduled_at) in -2..1
    end

    test "a destination deleted mid-POST records nothing", ctx do
      event!(ctx.organization, 1)
      destination = ctx.destination
      stub(200, before: fn -> destination |> fresh() |> Repo.delete!() end)

      log = capture_log(fn -> assert :ok = run(destination) end)

      assert log =~ "not recorded: gone"
      assert Repo.get(Destination, destination.id) == nil
      assert attempts(destination) == []
    end

    test "a destination paused between lease and POST records the outcome and queues nothing",
         ctx do
      a = event!(ctx.organization, 1)
      destination = ctx.destination
      stub(200, before: fn -> set_destination(destination, enabled: false) end)

      run(destination)

      assert_received {:request, _, [^a], _}
      assert [%{outcome: :delivered}] = attempts(destination)
      assert cursor(destination).last_event_id == a
      assert follow_ups(destination) == []
    end

    test "a deleted destination's job ends at once" do
      assert :ok = perform_job(DispatchWorker, %{destination_id: -1})
    end

    test "a run whose lease expired before it prepares sends nothing and moves nothing", ctx do
      event!(ctx.organization, 1)
      stub(200)
      {:ok, token} = Lease.take(ctx.destination.id)
      set_cursor(ctx.destination, leased_until: DateTime.add(DateTime.utc_now(), -1, :second))

      assert :ok = DispatchWorker.run(ctx.destination.id, token)

      refute_received {:request, _, _, _}
      cursor = cursor(ctx.destination)
      assert {cursor.last_txid, cursor.last_event_id, cursor.pending_batch_id} == {0, 0, nil}
      assert cursor.lease_token == token
      assert attempts(ctx.destination) == []
    end

    test "a destination deleted between the lease and the prepare sends nothing", ctx do
      event!(ctx.organization, 1)
      stub(200)
      {:ok, token} = Lease.take(ctx.destination.id)
      Repo.delete!(ctx.destination)

      assert :ok = DispatchWorker.run(ctx.destination.id, token)

      refute_received {:request, _, _, _}
      assert Repo.get(Destination, ctx.destination.id) == nil
    end

    test "the response wait is half the lease, each send ends inside its lease, and the run outlasts the drain" do
      lease_ms = Lease.ttl() * 1_000
      assert DispatchWorker.send_timeout_ms() * 2 == lease_ms

      send_deadline = DispatchWorker.send_deadline_ms()
      run_timeout = DispatchWorker.timeout(%Oban.Job{})
      assert DispatchWorker.send_timeout_ms() < send_deadline
      assert send_deadline < lease_ms
      # A batch started at the end of the 30-second drain still sends and
      # records before Oban stops the run.
      assert Pacing.drain_ms() + send_deadline < run_timeout
      assert run_timeout == 85_000
    end

    test "a run that crashes is retried by Oban once the lease it may hold expires" do
      assert %{destination_id: 1}
             |> DispatchWorker.new()
             |> Ecto.Changeset.get_field(:max_attempts) == 20

      for attempt <- [1, 2, 20] do
        assert DispatchWorker.backoff(%Oban.Job{attempt: attempt}) == Lease.ttl() + 1
      end
    end
  end

  describe "Datadog's age limit" do
    @gap_recorded [:kanban, :audit_stream, :gap_recorded]

    setup ctx do
      test = self()

      Req.Test.stub(Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        ids = body |> Jason.decode!() |> Enum.map(&String.to_integer(&1["stride"]["id"]))
        send(test, {:datadog, ids})
        Plug.Conn.send_resp(conn, 202, "{}")
      end)

      %{datadog: destination_fixture(ctx.organization, :datadog)}
    end

    defp hours_ago(hours, extra_seconds \\ 0),
      do: NaiveDateTime.add(NaiveDateTime.utc_now(), -(hours * 3600 + extra_seconds), :second)

    defp gaps(destination),
      do: from(g in Gap, where: g.destination_id == ^destination.id, order_by: g.id) |> Repo.all()

    defp datadog_requests(acc \\ []) do
      receive do
        {:datadog, ids} -> datadog_requests([ids | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "Datadog events older than 17 hours become a too_old gap", ctx do
      attach_telemetry(@gap_recorded)
      oldest_at = hours_ago(18)
      old_at = hours_ago(17, 60)
      event!(ctx.organization, 1, "organization_updated", oldest_at)
      event!(ctx.organization, 2, "organization_updated", old_at)
      recent = event!(ctx.organization, 3, "organization_updated", hours_ago(17, -60))

      assert :ok = run(ctx.datadog)

      assert datadog_requests() == [[recent]]
      assert [gap] = gaps(ctx.datadog)
      assert gap.reason == :too_old
      assert gap.events == 2
      assert DateTime.to_naive(gap.first_occurred_at) == oldest_at
      assert DateTime.to_naive(gap.last_occurred_at) == old_at
      assert cursor(ctx.datadog).last_event_id == recent

      assert [audit] = audit_actions(ctx.organization, "audit_stream_gap")
      assert audit.metadata["reason"] == "too_old"
      assert audit.metadata["events"] == 2

      assert_receive {:telemetry_event, @gap_recorded, %{count: 1, events: 2},
                      %{kind: :datadog, reason: :too_old}}
    end

    test "every event of a Datadog batch too old sends nothing and moves the cursor past them",
         ctx do
      event!(ctx.organization, 1, "organization_updated", hours_ago(20))
      last_at = hours_ago(18)
      last = event!(ctx.organization, 2, "organization_updated", last_at)

      assert :ok = run(ctx.datadog)

      assert datadog_requests() == []
      assert attempts(ctx.datadog) == []
      cursor = cursor(ctx.datadog)
      assert {cursor.last_txid, cursor.last_event_id} == {2, last}
      assert DateTime.to_naive(cursor.last_inserted_at) == last_at
      assert cursor.lease_token == nil
      assert cursor.pending_batch_id == nil
      assert [%Gap{events: 2, reason: :too_old}] = gaps(ctx.datadog)
    end

    test "a too-old event after a recent one in commit order is never sent", ctx do
      first = event!(ctx.organization, 1, "organization_updated", hours_ago(1))
      event!(ctx.organization, 2, "organization_updated", hours_ago(18))
      third = event!(ctx.organization, 3, "organization_updated", hours_ago(1))

      assert :ok = run(ctx.datadog)
      make_due(ctx.datadog)
      assert :ok = run(ctx.datadog)

      assert datadog_requests() == [[first], [third]]
      assert [%Gap{events: 1, reason: :too_old}] = gaps(ctx.datadog)
    end

    test "a pending Datadog batch that aged past 17 hours is cut again under a new batch_id",
         ctx do
      old = event!(ctx.organization, 1, "organization_updated", hours_ago(18))
      recent = event!(ctx.organization, 2, "organization_updated", hours_ago(1))
      old_batch = Ecto.UUID.generate()

      set_cursor(ctx.datadog,
        pending_batch_id: old_batch,
        pending_first_txid: 1,
        pending_first_id: old,
        pending_last_txid: 2,
        pending_last_id: recent,
        pending_attempts: 1,
        pending_filter_version: ctx.datadog.filter_version
      )

      assert :ok = run(ctx.datadog)

      assert datadog_requests() == [[recent]]
      assert [attempt] = attempts(ctx.datadog)
      assert attempt.batch_id != old_batch
      assert [%Gap{events: 1}] = gaps(ctx.datadog)
    end

    test "a pending Datadog batch whose later event aged is cut again", ctx do
      first = event!(ctx.organization, 1, "organization_updated", hours_ago(1))
      aged = event!(ctx.organization, 2, "organization_updated", hours_ago(18))
      old_batch = Ecto.UUID.generate()

      set_cursor(ctx.datadog,
        pending_batch_id: old_batch,
        pending_first_txid: 1,
        pending_first_id: first,
        pending_last_txid: 2,
        pending_last_id: aged,
        pending_filter_version: ctx.datadog.filter_version
      )

      assert :ok = run(ctx.datadog)

      assert datadog_requests() == [[first]]
      assert [attempt] = attempts(ctx.datadog)
      assert attempt.batch_id != old_batch
    end

    test "repeated too-old losses extend the open gap with one audit event", ctx do
      event!(ctx.organization, 1, "organization_updated", hours_ago(18))
      assert :ok = run(ctx.datadog)
      event!(ctx.organization, 2, "organization_updated", hours_ago(19))
      make_due(ctx.datadog)
      assert :ok = run(ctx.datadog)

      assert [%Gap{events: 2}] = gaps(ctx.datadog)
      assert length(audit_actions(ctx.organization, "audit_stream_gap")) == 1
    end

    test "an HTTPS destination sends old events and records no gap", ctx do
      id = event!(ctx.organization, 1)
      stub(200)

      assert :ok = run(ctx.destination)

      assert_received {:request, _batch, [^id], _body}
      assert Repo.all(Gap) == []
    end
  end

  describe "kinds and the horizon seam" do
    test "a Datadog destination sends its batch to the site's intake as a JSON array", ctx do
      destination = destination_fixture(ctx.organization, :datadog)
      # Recent, so it is inside Datadog's 17-hour max_event_age.
      id = event!(ctx.organization, 1, "organization_updated", NaiveDateTime.utc_now())
      test = self()

      Req.Test.stub(Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:datadog, conn, body})
        Plug.Conn.send_resp(conn, 202, "{}")
      end)

      assert :ok = run(destination)

      assert_receive {:datadog, conn, body}
      assert conn.request_path == "/api/v2/logs"
      assert Plug.Conn.get_req_header(conn, "host") == ["http-intake.logs.datadoghq.eu"]
      assert [entry] = Jason.decode!(body)
      assert entry["stride"]["id"] == Integer.to_string(id)
      assert entry["ddtags"] == "source:stride,organization_id:#{ctx.organization.id}"
      assert cursor(destination).last_event_id == id
    end

    test "the configured horizon holds back an event at or above it", ctx do
      a = event!(ctx.organization, 5)
      stub(200)
      Application.put_env(:kanban, DispatchWorker, horizon: {__MODULE__, :horizon_five})
      on_exit(fn -> Application.delete_env(:kanban, DispatchWorker) end)

      assert :ok = run(ctx.destination)
      refute_received {:request, _, _, _}
      assert cursor(ctx.destination).pending_batch_id == nil

      Application.delete_env(:kanban, DispatchWorker)
      assert :ok = run(ctx.destination)
      assert_received {:request, _, [^a], _}
    end
  end

  @doc false
  def horizon_five, do: 5

  describe "draining and pacing" do
    setup do
      on_exit(fn -> Application.delete_env(:kanban, DispatchWorker) end)
    end

    defp recent!(organization, txid),
      do: event!(organization, txid, "organization_updated", NaiveDateTime.utc_now())

    test "draining stops after 30 seconds and queues a follow-up", ctx do
      assert Pacing.drain_ms() == 30_000
      Application.put_env(:kanban, DispatchWorker, batch_size: 1)
      [a, b, c] = for txid <- 1..3, do: recent!(ctx.organization, txid)
      stub(200)

      # Within the 30 seconds the run sends every batch itself.
      assert :ok = run(ctx.destination)

      assert_received {:request, first_id, [^a], _}
      assert_received {:request, second_id, [^b], _}
      assert_received {:request, third_id, [^c], _}
      assert Enum.uniq([first_id, second_id, third_id]) |> length() == 3

      assert [:delivered, :delivered, :delivered] =
               ctx.destination |> attempts() |> Enum.map(& &1.outcome)

      assert follow_ups(ctx.destination) == []

      cursor = cursor(ctx.destination)
      assert {cursor.last_txid, cursor.last_event_id} == {3, c}
      assert cursor.lease_token == nil and cursor.next_attempt_at == nil

      # Once the drain budget is spent, the run queues its own follow-up for
      # now and ends.
      Application.put_env(:kanban, DispatchWorker, batch_size: 1, drain_ms: 0)
      [d, _e] = for txid <- 4..5, do: recent!(ctx.organization, txid)

      assert :ok = run(ctx.destination)

      assert_received {:request, _, [^d], _}
      refute_received {:request, _, _, _}
      assert [job] = follow_ups(ctx.destination)
      assert seconds_from_now(job.scheduled_at) in -2..1
      assert cursor(ctx.destination).next_attempt_at == nil
    end

    test "a run past its drain deadline sends one batch and queues a follow-up", ctx do
      Application.put_env(:kanban, DispatchWorker, batch_size: 1)
      [a, _b] = for txid <- 1..2, do: recent!(ctx.organization, txid)
      stub(200)
      {:ok, token} = Lease.take(ctx.destination.id)

      assert :ok =
               DispatchWorker.run(ctx.destination.id, token, System.monotonic_time(:millisecond))

      assert_received {:request, _, [^a], _}
      refute_received {:request, _, _, _}
      assert [_follow_up] = follow_ups(ctx.destination)
    end

    test "a drained destination paused mid-run stops after the batch in flight", ctx do
      Application.put_env(:kanban, DispatchWorker, batch_size: 1)
      [a, _b] = for txid <- 1..2, do: recent!(ctx.organization, txid)
      destination = ctx.destination
      stub(200, before: fn -> set_destination(destination, enabled: false) end)

      assert :ok = run(destination)

      assert_received {:request, _, [^a], _}
      refute_received {:request, _, _, _}
      assert follow_ups(destination) == []
    end

    test "catch-up paces at one batch every 2 seconds", ctx do
      Application.put_env(:kanban, DispatchWorker, batch_size: 1)
      [a, b] = for txid <- 1..2, do: event!(ctx.organization, txid)
      stub(200)

      assert :ok = run(ctx.destination)

      assert_received {:request, _, [^a], _}
      refute_received {:request, _, _, _}
      assert [job] = follow_ups(ctx.destination)
      assert seconds_from_now(job.scheduled_at) in 0..2
      due = cursor(ctx.destination).next_attempt_at
      assert seconds_from_now(due) in 0..2
      assert DateTime.diff(job.scheduled_at, due, :millisecond) in -10..10

      # A run that comes early, the sweep's included, is not due yet.
      assert :ok = run(ctx.destination)
      refute_received {:request, _, _, _}

      make_due(ctx.destination)
      assert :ok = run(ctx.destination)
      assert_received {:request, _, [^b], _}

      cursor = cursor(ctx.destination)
      assert {cursor.last_txid, cursor.last_event_id} == {2, b}
      assert cursor.next_attempt_at == nil
    end
  end

  describe "enqueue_dispatch/2" do
    test "queues a run for the destination on the audit_stream queue", ctx do
      at = DateTime.add(DateTime.utc_now(), 30, :second)

      assert {:ok, job} = AuditStream.enqueue_dispatch(ctx.destination.id, scheduled_at: at)
      assert job.queue == "audit_stream"
      assert job.args == %{destination_id: ctx.destination.id}
      assert_enqueued(worker: DispatchWorker, args: %{destination_id: ctx.destination.id})
    end

    test "a run queued behind a snoozed one moves it to its own time", ctx do
      snoozed_until = DateTime.add(DateTime.utc_now(), 61, :second)

      assert {:ok, snoozed} =
               AuditStream.enqueue_dispatch(ctx.destination.id, scheduled_at: snoozed_until)

      assert {:ok, follow_up} = AuditStream.enqueue_dispatch(ctx.destination.id)
      assert follow_up.id == snoozed.id

      assert [job] = follow_ups(ctx.destination)
      assert seconds_from_now(job.scheduled_at) in -2..1
    end
  end
end
