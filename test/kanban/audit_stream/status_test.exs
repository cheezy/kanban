defmodule Kanban.AuditStream.StatusTest do
  @moduledoc """
  A destination's status, lag, attempts and pending batch, and the two ways
  out of a `rejected_batch` halt (`retry_now/2` and `skip_batch/2`), through
  `Kanban.AuditStream`. Events are inserted with a chosen small `txid`, below
  any real horizon, and the destination's cursor is set by hand.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.Organizations.OrganizationMember

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)

    %{
      organization: organization,
      admin: admin,
      scope: Scope.for_user(admin),
      destination: destination_fixture(organization, :https)
    }
  end

  # --- helpers ------------------------------------------------------------------

  defp event!(organization, txid, inserted_at) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ('organization_updated', $1, '{}', $2, $3) RETURNING id
        """,
        [organization.id, inserted_at, txid]
      )

    id
  end

  defp own_txid do
    %{rows: [[txid]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    txid
  end

  defp set_destination(destination, fields),
    do: from(d in Destination, where: d.id == ^destination.id) |> Repo.update_all(set: fields)

  defp set_cursor(destination, fields),
    do:
      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(set: fields)

  defp cursor(destination), do: Repo.get!(Cursor, destination.id)
  defp fresh(destination), do: Repo.get!(Destination, destination.id)

  defp attempts(destination),
    do: from(a in Attempt, where: a.destination_id == ^destination.id) |> Repo.all()

  defp skipped_events(organization) do
    from(e in AuditEvent,
      where: e.organization_id == ^organization.id and e.action == "audit_stream_batch_skipped"
    )
    |> Repo.all()
  end

  defp attempt!(destination, batch_id, started_at, fields \\ %{}) do
    %Attempt{}
    |> Attempt.changeset(
      Map.merge(
        %{
          destination_id: destination.id,
          batch_id: batch_id,
          started_at: started_at,
          outcome: :rejected,
          http_status: 400,
          error: "Rejected by the destination (HTTP 400)"
        },
        fields
      )
    )
    |> Repo.insert!()
  end

  # A batch of two events, rejected three times, with a third event after it.
  defp reject_batch!(ctx) do
    first = event!(ctx.organization, 5, ~N[2026-11-01 00:00:00.000000])
    last = event!(ctx.organization, 6, ~N[2026-11-01 00:05:00.000000])
    after_batch = event!(ctx.organization, 7, ~N[2026-11-01 00:10:00.000000])
    batch_id = Ecto.UUID.generate()

    set_cursor(ctx.destination,
      last_txid: 4,
      last_event_id: 0,
      pending_batch_id: batch_id,
      pending_first_txid: 5,
      pending_first_id: first,
      pending_last_txid: 6,
      pending_last_id: last,
      pending_attempts: 3,
      pending_filter_version: 1
    )

    set_destination(ctx.destination,
      state: :failing,
      state_reason: "Rejected by the destination (HTTP 400)",
      halted_reason: :rejected_batch
    )

    attempt!(ctx.destination, batch_id, ~U[2026-11-01 01:00:00.000000Z], %{http_status: 422})
    attempt!(ctx.destination, batch_id, ~U[2026-11-01 01:10:00.000000Z])

    %{batch_id: batch_id, first: first, last: last, after_batch: after_batch}
  end

  defp jobs(destination),
    do: all_enqueued(worker: DispatchWorker, args: %{destination_id: destination.id})

  # --- status -------------------------------------------------------------------

  describe "destination_status/3" do
    test "status values including paused and needs attention", ctx do
      d = ctx.destination

      states = fn ->
        AuditStream.destination_status(ctx.scope, d) |> elem(1) |> Map.get(:state)
      end

      assert states.() == :healthy

      set_destination(d, state: :retrying, state_reason: "HTTP 503 from the destination")
      assert states.() == :retrying

      set_destination(d, state: :failing)
      assert states.() == :failing

      set_destination(d, halted_reason: :blocked_address)
      assert states.() == :needs_attention

      assert {:ok, %{halted_reason: :blocked_address, state_reason: "HTTP 503" <> _}} =
               AuditStream.destination_status(ctx.scope, d)

      # Paused wins over a halt.
      set_destination(d, enabled: false)
      assert states.() == :paused
    end

    test "events above the horizon count as waiting", ctx do
      set_cursor(ctx.destination, last_txid: 4, last_event_id: 0)
      below = event!(ctx.organization, 5, ~N[2026-11-01 00:00:00.000000])
      held = own_txid()
      event!(ctx.organization, held, ~N[2026-11-01 00:01:00.000000])

      # Everything since the Organization was created is after txid 4; hold
      # the horizon at our own transaction so its events stay above it.
      assert {:ok, %{lag: lag}} =
               AuditStream.destination_status(ctx.scope, ctx.destination,
                 horizon: held,
                 now: ~U[2026-11-01 01:00:00Z]
               )

      assert lag.events_above_horizon >= 1
      assert lag.events_waiting == lag.events_above_horizon + 1
      assert lag.oldest_waiting_at == ~U[2026-11-01 00:00:00.000000Z]
      assert lag.oldest_age_seconds == 3600
      refute lag.up_to_date

      # Only events above the horizon: still waiting, never up to date.
      set_cursor(ctx.destination, last_txid: 5, last_event_id: below)

      assert {:ok, %{lag: held_back}} =
               AuditStream.destination_status(ctx.scope, ctx.destination, horizon: held)

      assert held_back.events_waiting == held_back.events_above_horizon
      assert held_back.events_waiting >= 1
      refute held_back.up_to_date
    end

    test "no attempts and up to date", ctx do
      set_cursor(ctx.destination, last_txid: own_txid() + 1, last_event_id: 0)

      assert {:ok, status} = AuditStream.destination_status(ctx.scope, ctx.destination)

      assert status.lag == %{
               events_waiting: 0,
               events_above_horizon: 0,
               oldest_waiting_at: nil,
               oldest_age_seconds: nil,
               up_to_date: true
             }

      assert status.last_success_at == nil
      assert {:ok, []} = AuditStream.list_attempts(ctx.scope, ctx.destination)
      assert {:ok, nil} = AuditStream.pending_batch_summary(ctx.scope, ctx.destination)
    end

    test "list_destinations_with_status lists each destination with its status, no secrets",
         ctx do
      second = destination_fixture(ctx.organization, :splunk_hec)
      set_destination(second, enabled: false)

      assert {:ok, [first_row, second_row]} = AuditStream.list_destinations_with_status(ctx.scope)
      assert first_row.destination.id == ctx.destination.id
      assert first_row.destination.signing_secret == nil
      assert first_row.status.state == :healthy
      assert {second_row.destination.id, second_row.status.state} == {second.id, :paused}
    end
  end

  describe "list_attempts/2" do
    test "list_attempts returns the newest 50", ctx do
      batch_id = Ecto.UUID.generate()
      base = ~U[2026-11-01 00:00:00.000000Z]

      for n <- 1..55,
          do:
            attempt!(ctx.destination, batch_id, DateTime.add(base, n, :second), %{event_count: n})

      assert {:ok, attempts} = AuditStream.list_attempts(ctx.scope, ctx.destination)
      assert length(attempts) == 50
      assert Enum.map(attempts, & &1.event_count) == Enum.to_list(55..6//-1)
    end
  end

  describe "pending_batch_summary/2" do
    test "a rejected batch gives its count, range, times and last answer", ctx do
      batch = reject_batch!(ctx)

      assert {:ok, summary} = AuditStream.pending_batch_summary(ctx.scope, ctx.destination)

      assert summary == %{
               batch_id: batch.batch_id,
               events: 2,
               first_event_id: batch.first,
               last_event_id: batch.last,
               first_at: ~U[2026-11-01 00:00:00.000000Z],
               last_at: ~U[2026-11-01 00:05:00.000000Z],
               http_status: 400,
               error: "Rejected by the destination (HTTP 400)"
             }

      # Another halt has no batch to show.
      set_destination(ctx.destination, halted_reason: :txid_reset)
      assert {:ok, nil} = AuditStream.pending_batch_summary(ctx.scope, ctx.destination)
    end
  end

  # --- retry now ----------------------------------------------------------------

  describe "retry_now/2" do
    test "retry_now clears rejected_batch and enqueues", ctx do
      batch = reject_batch!(ctx)
      set_cursor(ctx.destination, next_attempt_at: DateTime.add(DateTime.utc_now(), 3600))

      assert {:ok, %Destination{halted_reason: nil, signing_secret: nil}} =
               AuditStream.retry_now(ctx.scope, ctx.destination)

      cursor = cursor(ctx.destination)
      assert {cursor.pending_attempts, cursor.next_attempt_at} == {0, nil}
      # The same batch is resent, so the cursor and the batch stay.
      assert {cursor.pending_batch_id, cursor.last_txid} == {batch.batch_id, 4}
      assert {cursor.lease_token, cursor.leased_until} == {nil, nil}
      assert [_job] = jobs(ctx.destination)
      assert length(attempts(ctx.destination)) == 2
    end

    test "retry_now is refused for any other halt and while a run holds the lease", ctx do
      reject_batch!(ctx)

      for reason <- [:txid_reset, :blocked_address, :credentials_unreadable, nil] do
        set_destination(ctx.destination, halted_reason: reason)

        assert {reason, {:error, :not_rejected_batch}} ==
                 {reason, AuditStream.retry_now(ctx.scope, ctx.destination)}
      end

      set_destination(ctx.destination, halted_reason: :rejected_batch)
      token = Ecto.UUID.generate()
      set_cursor(ctx.destination, lease_token: token, leased_until: in_seconds(40))

      assert {:error, :busy} = AuditStream.retry_now(ctx.scope, ctx.destination)
      assert cursor(ctx.destination).pending_attempts == 3
      assert cursor(ctx.destination).lease_token == token
      assert fresh(ctx.destination).halted_reason == :rejected_batch
      assert jobs(ctx.destination) == []
    end
  end

  # --- skip this batch ----------------------------------------------------------

  describe "skip_batch/2" do
    test "skip_batch records the attempt and audit event and moves the cursor", ctx do
      batch = reject_batch!(ctx)

      assert {:ok, %Destination{halted_reason: nil} = skipped} =
               AuditStream.skip_batch(ctx.scope, ctx.destination)

      assert skipped.signing_secret == nil

      cursor = cursor(ctx.destination)
      assert {cursor.last_txid, cursor.last_event_id} == {6, batch.last}
      assert cursor.last_inserted_at == ~U[2026-11-01 00:05:00.000000Z]
      assert cursor.pending_batch_id == nil
      assert {cursor.pending_attempts, cursor.next_attempt_at} == {0, nil}
      assert {cursor.lease_token, cursor.leased_until} == {nil, nil}

      assert [%Attempt{} = attempt] =
               ctx.destination |> attempts() |> Enum.filter(&(&1.outcome == :skipped))

      assert {attempt.batch_id, attempt.event_count, attempt.http_status} ==
               {batch.batch_id, 2, 400}

      assert {attempt.first_event_id, attempt.last_event_id} == {batch.first, batch.last}

      assert [event] = skipped_events(ctx.organization)

      assert event.metadata == %{
               "user_id" => ctx.admin.id,
               "organization_id" => ctx.organization.id,
               "destination_id" => ctx.destination.id,
               "kind" => "https",
               "events" => 2,
               "http_status" => 400,
               "first_event_id" => batch.first,
               "last_event_id" => batch.last
             }

      assert [_job] = jobs(ctx.destination)

      # The event after the batch is still waiting.
      assert {:ok, %{lag: %{events_waiting: waiting}}} =
               AuditStream.destination_status(ctx.scope, ctx.destination)

      assert waiting >= 1
    end

    test "skip_batch refused for a config error halt", ctx do
      reject_batch!(ctx)
      before = cursor(ctx.destination)

      # A configuration error or an unauthorized answer leaves halted_reason
      # unset; the other halts can't be skipped either.
      for reason <- [nil, :blocked_address, :txid_reset, :credentials_unreadable] do
        set_destination(ctx.destination,
          halted_reason: reason,
          state_reason: "The destination reported a configuration error"
        )

        assert {reason, {:error, :not_rejected_batch}} ==
                 {reason, AuditStream.skip_batch(ctx.scope, ctx.destination)}
      end

      assert cursor(ctx.destination) == before
      refute ctx.destination |> attempts() |> Enum.any?(&(&1.outcome == :skipped))
      assert skipped_events(ctx.organization) == []
      assert jobs(ctx.destination) == []
    end

    test "two org-admins pressing Skip this batch move the cursor once", ctx do
      batch = reject_batch!(ctx)
      other_admin = user_fixture()
      organization_member_fixture(ctx.organization, other_admin, :org_admin)

      assert {:ok, _skipped} = AuditStream.skip_batch(ctx.scope, ctx.destination)

      assert {:error, :not_rejected_batch} =
               other_admin |> Scope.for_user() |> AuditStream.skip_batch(ctx.destination)

      assert {cursor(ctx.destination).last_txid, cursor(ctx.destination).last_event_id} ==
               {6, batch.last}

      assert length(skipped_events(ctx.organization)) == 1
    end

    test "an org-admin removed between loading the status and skipping is refused", ctx do
      reject_batch!(ctx)

      assert {:ok, %{state: :needs_attention}} =
               AuditStream.destination_status(ctx.scope, ctx.destination)

      from(m in OrganizationMember, where: m.user_id == ^ctx.admin.id) |> Repo.delete_all()

      assert {:error, :unauthorized} = AuditStream.skip_batch(ctx.scope, ctx.destination)
      assert {:error, :unauthorized} = AuditStream.retry_now(ctx.scope, ctx.destination)
      assert fresh(ctx.destination).halted_reason == :rejected_batch
      assert cursor(ctx.destination).lease_token == nil
    end
  end

  describe "authorization" do
    test "non-org-admins and other Organizations get nothing", ctx do
      reject_batch!(ctx)
      member = user_fixture()
      organization_member_fixture(ctx.organization, member, :member)

      other = organization_fixture()
      other_admin = user_fixture()
      organization_member_fixture(other, other_admin, :org_admin)

      calls = fn scope ->
        [
          status: fn -> AuditStream.destination_status(scope, ctx.destination) end,
          attempts: fn -> AuditStream.list_attempts(scope, ctx.destination) end,
          pending: fn -> AuditStream.pending_batch_summary(scope, ctx.destination) end,
          retry: fn -> AuditStream.retry_now(scope, ctx.destination) end,
          skip: fn -> AuditStream.skip_batch(scope, ctx.destination) end
        ]
      end

      for scope <- [Scope.for_user(member), Scope.for_user(admin_fixture()), nil],
          {name, call} <- calls.(scope) do
        assert {name, {:error, :unauthorized}} == {name, call.()}
      end

      for scope <- [Scope.for_user(member), Scope.for_user(admin_fixture()), nil] do
        assert {:error, :unauthorized} = AuditStream.list_destinations_with_status(scope)
      end

      other_scope = Scope.for_user(other_admin)

      for {name, call} <- calls.(other_scope) do
        assert {name, {:error, :not_found}} == {name, call.()}
      end

      assert {:ok, []} = AuditStream.list_destinations_with_status(other_scope)
      assert cursor(ctx.destination).lease_token == nil
      assert fresh(ctx.destination).halted_reason == :rejected_batch
    end
  end

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
end
