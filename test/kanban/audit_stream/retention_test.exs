defmodule Kanban.AuditStream.RetentionTest do
  @moduledoc """
  The audit stream gap steps around an Organization's retention purge
  (§8.6), run through `Kanban.AuditStream.Retention.purge/4` with the real
  purge function, and the org-admin's gap list and dismissal. Events are
  inserted with a chosen small `txid` and `inserted_at`; a purge removes
  rows whatever their `txid`, so no horizon is involved.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog

  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Retention
  alias Kanban.Webhooks.Transport

  @day 24 * 60 * 60
  @gap_recorded [:kanban, :audit_stream, :gap_recorded]

  setup do
    organization = organization_fixture()
    %{organization: organization, destination: destination_fixture(organization, :https)}
  end

  # --- helpers ------------------------------------------------------------------

  defp days_ago(days),
    do: NaiveDateTime.add(NaiveDateTime.utc_now(), -days * @day, :second)

  defp event!(organization, txid, inserted_at, action \\ "organization_updated") do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ($1, $2, $3, $4, $5) RETURNING id
        """,
        [action, organization.id, %{}, inserted_at, txid]
      )

    id
  end

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -120 * @day, :second)

  # The real purge, renewing the leases before each batch as the worker does.
  defp purge(organization, opts \\ []) do
    cutoff = cutoff()

    Retention.purge(
      organization.id,
      cutoff,
      fn keep_alive ->
        keep_alive.()
        AuditLog.purge_organization_before(organization.id, cutoff, 1_000)
      end,
      Keyword.put_new(opts, :lease_wait_ms, 0)
    )
  end

  defp gaps(destination),
    do: from(g in Gap, where: g.destination_id == ^destination.id, order_by: g.id) |> Repo.all()

  defp audit_actions(organization, action) do
    from(e in AuditEvent,
      where: e.organization_id == ^organization.id and e.action == ^action,
      order_by: e.id
    )
    |> Repo.all()
  end

  defp cursor(destination), do: Repo.get!(Cursor, destination.id)

  defp set_destination(destination, fields),
    do: from(d in Destination, where: d.id == ^destination.id) |> Repo.update_all(set: fields)

  defp set_cursor(destination, fields),
    do:
      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(set: fields)

  defp exists?(id), do: Repo.get(AuditEvent, id) != nil

  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)

  defp org_admin_scope(organization) do
    user = user_fixture()
    organization_member_fixture(organization, user, :org_admin)
    Scope.for_user(user)
  end

  # --- recording a loss -----------------------------------------------------------

  describe "a destination behind the cutoff" do
    test "destination behind the cutoff records a gap", ctx do
      attach_telemetry(@gap_recorded)
      first_at = days_ago(200)
      last_at = days_ago(150)
      old_a = event!(ctx.organization, 1, first_at)
      old_b = event!(ctx.organization, 2, last_at)
      recent = event!(ctx.organization, 3, days_ago(10))

      assert {:ok, 2} = purge(ctx.organization)

      refute exists?(old_a) or exists?(old_b)
      assert exists?(recent)

      assert [gap] = gaps(ctx.destination)
      assert gap.reason == :retention
      assert gap.events == 2
      assert to_naive(gap.first_occurred_at) == first_at
      assert to_naive(gap.last_occurred_at) == last_at
      assert gap.emailed_at == nil
      assert gap.dismissed_at == nil
      assert gap.audited_at == gap.opened_at

      assert [event] = audit_actions(ctx.organization, "audit_stream_gap")
      assert event.actor_user_id == nil

      assert Map.keys(event.metadata) |> Enum.sort() ==
               ~w(destination_id events from organization_id reason to)

      assert event.metadata["destination_id"] == ctx.destination.id
      assert event.metadata["events"] == 2
      assert event.metadata["reason"] == "retention"

      assert_receive {:telemetry_event, @gap_recorded, %{count: 1, events: 2},
                      %{kind: :https, reason: :retention} = metadata}

      assert map_size(metadata) == 2
      # The lease is released.
      assert cursor(ctx.destination).lease_token == nil
    end

    test "paused and halted destinations also record a gap", ctx do
      set_destination(ctx.destination, enabled: false)
      halted = destination_fixture(ctx.organization, :https)
      set_destination(halted, halted_reason: :rejected_batch)
      event!(ctx.organization, 1, days_ago(200))

      assert {:ok, 1} = purge(ctx.organization)
      assert [%Gap{events: 1}] = gaps(ctx.destination)
      assert [%Gap{events: 1}] = gaps(halted)
    end

    test "excluded actions, events at or before the cursor and events before not_before are not counted",
         ctx do
      set_destination(ctx.destination, excluded_actions: ["member_added"])
      sent = event!(ctx.organization, 1, days_ago(300))
      set_cursor(ctx.destination, last_txid: 1, last_event_id: sent)
      event!(ctx.organization, 2, days_ago(250), "member_added")
      counted = days_ago(200)
      event!(ctx.organization, 3, counted)

      assert {:ok, 3} = purge(ctx.organization)
      assert [%Gap{events: 1} = gap] = gaps(ctx.destination)
      assert to_naive(gap.first_occurred_at) == counted
    end

    test "events before the cursor's not_before are not counted", ctx do
      set_cursor(ctx.destination, not_before: DateTime.add(DateTime.utc_now(), -180 * @day))
      event!(ctx.organization, 1, days_ago(200))

      assert {:ok, 1} = purge(ctx.organization)
      assert gaps(ctx.destination) == []
    end

    test "destination with nothing behind the cutoff records no gap", ctx do
      event!(ctx.organization, 1, days_ago(10))

      assert {:ok, 0} = purge(ctx.organization)
      assert gaps(ctx.destination) == []
      assert audit_actions(ctx.organization, "audit_stream_gap") == []
    end

    test "a purge that removes nothing records no gap even with events behind the cutoff", ctx do
      event!(ctx.organization, 1, days_ago(200))

      assert {:ok, 0} =
               Retention.purge(ctx.organization.id, cutoff(), fn _keep_alive -> {:ok, 0} end,
                 lease_wait_ms: 0
               )

      assert gaps(ctx.destination) == []
    end

    test "another Organization's old events are not counted", ctx do
      other = organization_fixture()
      event!(other, 1, days_ago(200))

      assert {:ok, 0} = purge(ctx.organization)
      assert gaps(ctx.destination) == []
    end

    test "another Organization's events purged at the same time stay out of the gap", ctx do
      other = organization_fixture()
      event!(other, 1, days_ago(300))
      own_at = days_ago(200)
      event!(ctx.organization, 2, own_at)
      cutoff = cutoff()

      assert {:ok, 1} =
               Retention.purge(
                 ctx.organization.id,
                 cutoff,
                 fn _keep_alive ->
                   {:ok, 1} = AuditLog.purge_organization_before(other.id, cutoff, 1_000)
                   AuditLog.purge_organization_before(ctx.organization.id, cutoff, 1_000)
                 end,
                 lease_wait_ms: 0
               )

      assert [%Gap{events: 1} = gap] = gaps(ctx.destination)
      own = DateTime.from_naive!(own_at, "Etc/UTC")
      assert abs(DateTime.diff(gap.first_occurred_at, own)) <= 1
    end
  end

  describe "a refused or failed purge" do
    test "refused purge records no gap", ctx do
      old = event!(ctx.organization, 1, days_ago(200))
      too_recent = DateTime.add(DateTime.utc_now(), -@day, :second)

      # The worker turns a refusal into {:ok, removed}, as here.
      assert {:ok, 0} =
               Retention.purge(
                 ctx.organization.id,
                 too_recent,
                 fn _keep_alive ->
                   with {:error, :cutoff_too_recent} <-
                          AuditLog.purge_organization_before(
                            ctx.organization.id,
                            too_recent,
                            1_000
                          ),
                        do: {:ok, 0}
                 end,
                 lease_wait_ms: 0
               )

      assert exists?(old)
      assert gaps(ctx.destination) == []
      assert cursor(ctx.destination).lease_token == nil
    end

    test "a purge that fails part way bounds the gap's last time by the first event left",
         ctx do
      first_at = days_ago(300)
      event!(ctx.organization, 1, first_at)
      event!(ctx.organization, 2, days_ago(250))
      left_at = days_ago(200)
      left = event!(ctx.organization, 3, left_at)
      event!(ctx.organization, 4, days_ago(180))
      cutoff = cutoff()

      assert_raise RuntimeError, fn ->
        Retention.purge(
          ctx.organization.id,
          cutoff,
          fn _keep_alive ->
            {:ok, 2} = AuditLog.purge_organization_before(ctx.organization.id, cutoff, 2)
            raise "purge failed"
          end,
          lease_wait_ms: 0
        )
      end

      assert exists?(left)
      assert [%Gap{events: 2} = gap] = gaps(ctx.destination)

      assert abs(DateTime.diff(gap.first_occurred_at, DateTime.from_naive!(first_at, "Etc/UTC"))) <=
               1

      assert abs(DateTime.diff(gap.last_occurred_at, DateTime.from_naive!(left_at, "Etc/UTC"))) <=
               1
    end

    test "a purge that raises records no gap, releases the leases and re-raises", ctx do
      event!(ctx.organization, 1, days_ago(200))

      assert_raise RuntimeError, "boom", fn ->
        Retention.purge(ctx.organization.id, cutoff(), fn _ -> raise "boom" end, lease_wait_ms: 0)
      end

      assert gaps(ctx.destination) == []
      assert cursor(ctx.destination).lease_token == nil
    end
  end

  describe "the pending batch" do
    test "pending batch that lost events is discarded", ctx do
      old = event!(ctx.organization, 1, days_ago(200))
      recent = event!(ctx.organization, 2, days_ago(10))
      old_batch = Ecto.UUID.generate()

      set_cursor(ctx.destination,
        pending_batch_id: old_batch,
        pending_first_txid: 1,
        pending_first_id: old,
        pending_last_txid: 2,
        pending_last_id: recent,
        pending_filter_version: ctx.destination.filter_version
      )

      assert {:ok, 1} = purge(ctx.organization)
      assert cursor(ctx.destination).pending_batch_id == nil

      test = self()

      Req.Test.stub(Transport, fn conn ->
        batch = conn |> Plug.Conn.get_req_header("x-stride-batch") |> List.first()
        send(test, {:batch, batch})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert :ok = perform_job(DispatchWorker, %{destination_id: ctx.destination.id})
      assert_receive {:batch, new_batch}
      assert new_batch != old_batch
      assert [%Attempt{batch_id: ^new_batch}] = Repo.all(Attempt)
    end

    test "a pending batch that lost nothing is kept", ctx do
      first = event!(ctx.organization, 1, days_ago(10))
      event!(ctx.organization, 2, days_ago(200))
      batch_id = Ecto.UUID.generate()

      set_cursor(ctx.destination,
        pending_batch_id: batch_id,
        pending_first_txid: 1,
        pending_first_id: first,
        pending_last_txid: 1,
        pending_last_id: first,
        pending_filter_version: ctx.destination.filter_version
      )

      assert {:ok, 1} = purge(ctx.organization)
      assert [%Gap{events: 1}] = gaps(ctx.destination)
      assert cursor(ctx.destination).pending_batch_id == batch_id
    end
  end

  describe "an open gap" do
    test "second loss extends the open gap without a second audit event", ctx do
      attach_telemetry(@gap_recorded)
      event!(ctx.organization, 1, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)
      [opened] = gaps(ctx.destination)

      event!(ctx.organization, 2, days_ago(300))
      event!(ctx.organization, 3, days_ago(130))
      assert {:ok, 2} = purge(ctx.organization)

      assert [gap] = gaps(ctx.destination)
      assert gap.id == opened.id
      assert gap.events == 3
      assert DateTime.compare(gap.first_occurred_at, opened.first_occurred_at) == :lt
      assert DateTime.compare(gap.last_occurred_at, opened.last_occurred_at) == :gt
      assert DateTime.compare(gap.last_extended_at, opened.last_extended_at) == :gt
      assert gap.audited_at == opened.audited_at
      assert ctx.organization |> audit_actions("audit_stream_gap") |> length() == 1

      # gap_recorded is emitted for every loss, not throttled.
      assert_receive {:telemetry_event, @gap_recorded, %{events: 1}, _}
      assert_receive {:telemetry_event, @gap_recorded, %{events: 2}, _}
    end

    test "a loss a day after the gap's last audit event records another", ctx do
      event!(ctx.organization, 1, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)
      [gap] = gaps(ctx.destination)

      backdated = DateTime.add(gap.audited_at, -25 * 60 * 60, :second)
      from(g in Gap, where: g.id == ^gap.id) |> Repo.update_all(set: [audited_at: backdated])

      event!(ctx.organization, 2, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)

      assert [second, _first] =
               audit_actions(ctx.organization, "audit_stream_gap") |> Enum.reverse()

      assert second.metadata["events"] == 2
      assert [%Gap{events: 2, emailed_at: nil} = extended] = gaps(ctx.destination)
      assert DateTime.compare(extended.audited_at, backdated) == :gt
    end

    test "a loss inside the gap's audit day reaches the stream once the day has passed", ctx do
      event!(ctx.organization, 1, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)
      event!(ctx.organization, 2, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)
      [gap] = gaps(ctx.destination)
      assert ctx.organization |> audit_actions("audit_stream_gap") |> length() == 1

      # Inside the day, the sweep records nothing.
      assert AuditStream.audit_due_gaps(DateTime.utc_now()) == 0

      later = DateTime.add(gap.audited_at, 24 * 60 * 60, :second)
      assert AuditStream.audit_due_gaps(later) == 1

      assert [_first, second] = audit_actions(ctx.organization, "audit_stream_gap")
      assert second.metadata["events"] == 2
      assert [%Gap{audited_at: ^later, emailed_at: nil}] = gaps(ctx.destination)

      # The gap has not grown since, so the next sweep records nothing.
      two_days_on = DateTime.add(later, 2 * 24 * 60 * 60, :second)
      assert AuditStream.audit_due_gaps(two_days_on) == 0
      assert ctx.organization |> audit_actions("audit_stream_gap") |> length() == 2
    end

    test "the sweep skips a gap that has not grown and a dismissed gap", ctx do
      event!(ctx.organization, 1, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)
      [gap] = gaps(ctx.destination)
      later = DateTime.add(DateTime.utc_now(), 3 * 24 * 60 * 60, :second)

      assert AuditStream.audit_due_gaps(later) == 0

      scope = org_admin_scope(ctx.organization)
      {:ok, dismissed} = AuditStream.dismiss_gap(scope, gap)

      # Even marked as grown, a dismissed gap is never swept.
      from(g in Gap, where: g.id == ^gap.id)
      |> Repo.update_all(set: [last_extended_at: DateTime.add(dismissed.audited_at, 60, :second)])

      assert AuditStream.audit_due_gaps(later) == 0
      assert ctx.organization |> audit_actions("audit_stream_gap") |> length() == 1
    end

    test "a dismissed gap stays dismissed and a new loss opens a new gap", ctx do
      event!(ctx.organization, 1, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)
      [gap] = gaps(ctx.destination)
      scope = org_admin_scope(ctx.organization)
      assert {:ok, _dismissed} = AuditStream.dismiss_gap(scope, gap)

      event!(ctx.organization, 2, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)

      assert [dismissed, opened] = gaps(ctx.destination)
      assert dismissed.events == 1 and dismissed.dismissed_at != nil
      assert opened.events == 1 and opened.dismissed_at == nil
      assert ctx.organization |> audit_actions("audit_stream_gap") |> length() == 2
    end
  end

  describe "leases" do
    test "a lease held past the wait skips the purge and releases the leases taken", ctx do
      first = destination_fixture(ctx.organization, :https)
      # ctx.destination has the lower id, so it is taken first; hold the second.
      {:ok, _token} = Lease.take(first.id)
      old = event!(ctx.organization, 1, days_ago(200))

      assert :lease_held =
               Retention.purge(
                 ctx.organization.id,
                 cutoff(),
                 fn _ -> flunk("the purge must not run") end,
                 lease_wait_ms: 0
               )

      assert exists?(old)
      assert cursor(ctx.destination).lease_token == nil
      assert gaps(ctx.destination) == []
    end

    test "a lease released during the wait is taken", ctx do
      {:ok, token} = Lease.take(ctx.destination.id)
      test = self()

      Task.start(fn ->
        Process.sleep(50)
        Lease.release(ctx.destination.id, token)
        send(test, :released)
      end)

      assert {:ok, 0} = purge(ctx.organization, lease_wait_ms: 2_000, lease_poll_ms: 10)
      assert_received :released
    end

    test "the purge runs while the leases are held and renewed", ctx do
      test = self()

      assert {:ok, 0} =
               Retention.purge(
                 ctx.organization.id,
                 cutoff(),
                 fn keep_alive ->
                   held = cursor(ctx.destination)
                   send(test, {:held, held.lease_token})
                   assert :ok = keep_alive.()
                   {:ok, 0}
                 end,
                 lease_wait_ms: 0
               )

      assert_received {:held, token}
      assert is_binary(token)
      assert cursor(ctx.destination).lease_token == nil
    end

    test "a lease that expired with no other run still discards the pending batch", ctx do
      old = event!(ctx.organization, 1, days_ago(200))

      set_cursor(ctx.destination,
        pending_batch_id: Ecto.UUID.generate(),
        pending_first_txid: 1,
        pending_first_id: old,
        pending_last_txid: 1,
        pending_last_id: old,
        pending_filter_version: ctx.destination.filter_version
      )

      cutoff = cutoff()

      assert {:ok, 1} =
               Retention.purge(
                 ctx.organization.id,
                 cutoff,
                 fn _keep_alive ->
                   # The lease runs out, but its token is untouched.
                   set_cursor(ctx.destination,
                     leased_until: DateTime.add(DateTime.utc_now(), -5, :second)
                   )

                   AuditLog.purge_organization_before(ctx.organization.id, cutoff, 1_000)
                 end,
                 lease_wait_ms: 0
               )

      assert [%Gap{events: 1}] = gaps(ctx.destination)
      assert cursor(ctx.destination).pending_batch_id == nil
    end

    test "a lease lost during the purge still records the gap and keeps the pending batch",
         ctx do
      old = event!(ctx.organization, 1, days_ago(200))
      batch_id = Ecto.UUID.generate()

      set_cursor(ctx.destination,
        pending_batch_id: batch_id,
        pending_first_txid: 1,
        pending_first_id: old,
        pending_last_txid: 1,
        pending_last_id: old,
        pending_filter_version: ctx.destination.filter_version
      )

      cutoff = cutoff()

      log =
        capture_log(fn ->
          assert {:ok, 1} =
                   Retention.purge(
                     ctx.organization.id,
                     cutoff,
                     fn _keep_alive ->
                       # Another run takes the cursor, as after a lease expired.
                       set_cursor(ctx.destination, lease_token: Ecto.UUID.generate())
                       AuditLog.purge_organization_before(ctx.organization.id, cutoff, 1_000)
                     end,
                     lease_wait_ms: 0
                   )
        end)

      assert log =~
               "audit stream lease lost during retention destination_id=#{ctx.destination.id}"

      assert [%Gap{events: 1}] = gaps(ctx.destination)
      # The other run owns the cursor, so its pending batch is left to it.
      assert cursor(ctx.destination).pending_batch_id == batch_id
    end

    test "an Organization with no destinations purges exactly as before" do
      bare = organization_fixture()
      old = event!(bare, 1, days_ago(200))

      assert {:ok, 1} = purge(bare)
      refute exists?(old)
      assert Repo.all(Gap) == []
    end

    test "a destination whose cursor is gone is skipped rather than waited for", ctx do
      old = event!(ctx.organization, 1, days_ago(200))
      from(c in Cursor, where: c.destination_id == ^ctx.destination.id) |> Repo.delete_all()

      assert {:ok, 1} = purge(ctx.organization, lease_wait_ms: 0)
      refute exists?(old)
      assert Repo.all(Gap) == []
    end

    test "a destination deleted during the purge records nothing", ctx do
      event!(ctx.organization, 1, days_ago(200))
      cutoff = cutoff()

      assert {:ok, 1} =
               Retention.purge(
                 ctx.organization.id,
                 cutoff,
                 fn _keep_alive ->
                   Repo.delete_all(from(d in Destination, where: d.id == ^ctx.destination.id))
                   AuditLog.purge_organization_before(ctx.organization.id, cutoff, 1_000)
                 end,
                 lease_wait_ms: 0
               )

      assert Repo.all(Gap) == []
    end

    test "a destination created during the purge from now records nothing", ctx do
      event!(ctx.organization, 1, days_ago(200))
      cutoff = cutoff()
      test = self()

      assert {:ok, 1} =
               Retention.purge(
                 ctx.organization.id,
                 cutoff,
                 fn _keep_alive ->
                   created = destination_fixture(ctx.organization, :https)
                   set_cursor(created, last_txid: 999_999_999)
                   send(test, {:created, created})
                   AuditLog.purge_organization_before(ctx.organization.id, cutoff, 1_000)
                 end,
                 lease_wait_ms: 0
               )

      assert_received {:created, created}
      assert gaps(created) == []
      assert [%Gap{}] = gaps(ctx.destination)
    end

    test "a destination created during the purge from everything gets a gap by action", ctx do
      own_at = days_ago(200)
      event!(ctx.organization, 1, own_at)
      event!(ctx.organization, 2, days_ago(150), "org_member_added")
      cutoff = cutoff()
      test = self()

      log =
        capture_log(fn ->
          assert {:ok, 2} =
                   Retention.purge(
                     ctx.organization.id,
                     cutoff,
                     fn _keep_alive ->
                       created =
                         destination_fixture(ctx.organization, :https, %{
                           excluded_actions: ["org_member_added"]
                         })

                       send(test, {:created, created})
                       AuditLog.purge_organization_before(ctx.organization.id, cutoff, 1_000)
                     end,
                     lease_wait_ms: 0
                   )
        end)

      assert_received {:created, created}

      assert log =~
               "audit stream destination created during retention destination_id=#{created.id}"

      # Only the action it does not exclude counts.
      assert [%Gap{reason: :retention, events: 1} = gap] = gaps(created)

      assert abs(DateTime.diff(gap.first_occurred_at, DateTime.from_naive!(own_at, "Etc/UTC"))) <=
               1

      assert [_one] =
               audit_actions(ctx.organization, "audit_stream_gap")
               |> Enum.filter(&(&1.metadata["destination_id"] == created.id))
    end

    test "a first destination created while an Organization with none purges gets a gap" do
      bare = organization_fixture()
      event!(bare, 1, days_ago(200))
      cutoff = cutoff()
      test = self()

      capture_log(fn ->
        assert {:ok, 1} =
                 Retention.purge(
                   bare.id,
                   cutoff,
                   fn _keep_alive ->
                     send(test, {:created, destination_fixture(bare, :https)})
                     AuditLog.purge_organization_before(bare.id, cutoff, 1_000)
                   end,
                   lease_wait_ms: 0
                 )
      end)

      assert_received {:created, created}
      assert [%Gap{events: 1}] = gaps(created)
    end
  end

  # --- list and dismiss -------------------------------------------------------------

  describe "list_gaps/2 and dismiss_gap/2" do
    setup ctx do
      event!(ctx.organization, 1, days_ago(200))
      {:ok, 1} = purge(ctx.organization)
      [gap] = gaps(ctx.destination)
      %{gap: gap, scope: org_admin_scope(ctx.organization)}
    end

    test "an org-admin lists the destination's gaps", ctx do
      assert {:ok, [listed]} = AuditStream.list_gaps(ctx.scope, ctx.destination)
      assert listed.id == ctx.gap.id
    end

    test "dismiss_gap records audit_stream_gap_dismissed once", ctx do
      assert {:ok, dismissed} = AuditStream.dismiss_gap(ctx.scope, ctx.gap)
      assert dismissed.dismissed_at != nil
      assert dismissed.dismissed_by_id == ctx.scope.user.id

      assert [event] = audit_actions(ctx.organization, "audit_stream_gap_dismissed")
      assert event.actor_user_id == ctx.scope.user.id

      assert event.metadata == %{
               "destination_id" => ctx.destination.id,
               "gap_id" => ctx.gap.id,
               "organization_id" => ctx.organization.id,
               "user_id" => ctx.scope.user.id
             }

      assert {:ok, again} = AuditStream.dismiss_gap(ctx.scope, ctx.gap)
      assert again.dismissed_at == dismissed.dismissed_at
      assert length(audit_actions(ctx.organization, "audit_stream_gap_dismissed")) == 1
      # The gap did not grow after its audit event, so none is added.
      assert ctx.organization |> audit_actions("audit_stream_gap") |> length() == 1
    end

    test "dismissing a gap that grew inside its audit day streams the final count first", ctx do
      event!(ctx.organization, 2, days_ago(200))
      assert {:ok, 1} = purge(ctx.organization)
      assert [%Gap{events: 2}] = gaps(ctx.destination)
      assert ctx.organization |> audit_actions("audit_stream_gap") |> length() == 1

      assert {:ok, dismissed} = AuditStream.dismiss_gap(ctx.scope, ctx.gap)
      assert dismissed.dismissed_at

      assert [_first, final] = audit_actions(ctx.organization, "audit_stream_gap")
      assert final.metadata["events"] == 2
      assert [_dismissal] = audit_actions(ctx.organization, "audit_stream_gap_dismissed")
    end

    test "a member, a site admin and no scope are refused", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)

      for scope <- [Scope.for_user(member), Scope.for_user(admin_fixture()), nil] do
        assert {:error, :unauthorized} = AuditStream.list_gaps(scope, ctx.destination)
        assert {:error, :unauthorized} = AuditStream.dismiss_gap(scope, ctx.gap)
      end

      assert [%Gap{dismissed_at: nil}] = gaps(ctx.destination)
      assert audit_actions(ctx.organization, "audit_stream_gap_dismissed") == []
    end

    test "another Organization's org-admin gets :not_found", ctx do
      other_scope = org_admin_scope(organization_fixture())

      assert {:error, :not_found} = AuditStream.list_gaps(other_scope, ctx.destination)
      assert {:error, :not_found} = AuditStream.dismiss_gap(other_scope, ctx.gap)
      assert [%Gap{dismissed_at: nil}] = gaps(ctx.destination)
    end

    test "a gap that does not exist gets :not_found", ctx do
      assert {:error, :not_found} = AuditStream.dismiss_gap(ctx.scope, %Gap{id: -1})
    end
  end
end
