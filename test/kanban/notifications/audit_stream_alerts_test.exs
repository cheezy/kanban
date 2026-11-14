defmodule Kanban.Notifications.AuditStreamAlertsTest do
  @moduledoc """
  The fan-out of the audit stream security emails: recipients, which changes
  email, the throttles, the call sites in `Kanban.AuditStream`, its dispatch
  worker and its gaps, and what the job args may carry.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchRows
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Outcome
  alias Kanban.Notifications
  alias Kanban.Notifications.AuditStreamAlerts
  alias Kanban.Notifications.AuditStreamEmailWorker
  alias Kanban.Webhooks.Transport

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    other_admin = user_fixture()
    disabled_admin = user_fixture()
    member = user_fixture()

    organization_member_fixture(organization, admin, :org_admin)
    organization_member_fixture(organization, other_admin, :org_admin)
    organization_member_fixture(organization, disabled_admin, :org_admin)
    organization_member_fixture(organization, member, :member)
    disable(disabled_admin)

    %{
      organization: organization,
      admin: admin,
      other_admin: other_admin,
      disabled_admin: disabled_admin,
      member: member,
      scope: Scope.for_user(admin)
    }
  end

  # --- helpers ------------------------------------------------------------------

  defp disable(user) do
    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])
  end

  defp jobs, do: all_enqueued(worker: AuditStreamEmailWorker)

  defp jobs(alert), do: Enum.filter(jobs(), &(&1.args["alert"] == alert))

  defp recipients(jobs), do: jobs |> Enum.map(& &1.args["user_id"]) |> Enum.sort()

  defp clear_jobs, do: Repo.delete_all(Oban.Job)

  defp create!(ctx, kind, overrides \\ %{}) do
    {:ok, {destination, _secret}} =
      AuditStream.create_destination(ctx.scope, destination_attrs(kind, overrides))

    destination
  end

  defp reload(destination), do: Repo.get!(Destination, destination.id)

  defp update!(ctx, destination, attrs) do
    {:ok, updated} = AuditStream.update_destination(ctx.scope, reload(destination), attrs)
    updated
  end

  defp set_destination(destination, fields),
    do: from(d in Destination, where: d.id == ^destination.id) |> Repo.update_all(set: fields)

  defp set_cursor(destination, fields),
    do:
      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(set: fields)

  defp minutes_ago(minutes),
    do: :second |> DateTime.utc_now() |> DateTime.add(-minutes, :minute)

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  defp event!(organization, txid) do
    Repo.query!(
      """
      INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
      VALUES ('organization_updated', $1, '{}', $2, $3)
      """,
      [organization.id, ~N[2026-11-01 00:00:00.000000], txid]
    )
  end

  defp stub(status) do
    Req.Test.stub(Transport, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, status, "ok")
    end)
  end

  defp run(destination), do: perform_job(DispatchWorker, %{destination_id: destination.id})

  defp failing_plan(destination),
    do: Outcome.plan(:unauthorized, "refused", destination, nil, DateTime.utc_now())

  defp recovered_plan,
    do: %{
      destination: %{state: :healthy, state_reason: nil, failing_since: nil},
      audit: :recovered
    }

  # --- recipients -------------------------------------------------------------

  describe "recipients" do
    test "enqueues one job per enabled org-admin and none for members or disabled org-admins",
         ctx do
      destination = create!(ctx, :splunk_hec)

      assert [first | _] = created = jobs("created")
      assert recipients(created) == Enum.sort([ctx.admin.id, ctx.other_admin.id])

      args = first.args
      assert args["actor_id"] == ctx.admin.id
      assert args["organization_id"] == ctx.organization.id
      assert args["destination"]["id"] == destination.id
      assert args["destination"]["name"] == destination.name
      assert args["destination"]["kind"] == "splunk_hec"
      assert args["destination"]["url_host"] == "collector.example.com"
      assert args["destination"]["credential_hint"] == destination.credential_hint
      assert args["details"] == %{"start_from" => "now"}

      # Every recipient's job shares the occurrence's ref.
      assert created |> Enum.map(& &1.args["ref"]) |> Enum.uniq() |> length() == 1
    end

    test "the only org-admin, who acted, still gets the email" do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)

      scope = Scope.for_user(admin)
      {:ok, _created} = AuditStream.create_destination(scope, destination_attrs(:https))

      assert [%{args: %{"user_id" => user_id, "actor_id" => user_id}}] = jobs("created")
      assert user_id == admin.id
    end

    test "an Organization with no enabled org-admin enqueues nothing" do
      organization = organization_fixture()
      disabled = user_fixture()
      organization_member_fixture(organization, disabled, :org_admin)
      organization_member_fixture(organization, user_fixture(), :member)
      disable(disabled)
      destination = destination_fixture(organization, :https)

      assert :ok = Notifications.enqueue_audit_stream_email(:paused, destination, nil)
      assert jobs() == []
    end

    test "a destination that no longer exists enqueues nothing", ctx do
      destination = destination_fixture(ctx.organization, :https)
      Repo.delete!(destination)

      assert :ok =
               AuditStreamAlerts.enqueue(:failing, destination.id, nil, %{reason: :no_success})

      assert jobs() == []
      assert :ok = AuditStreamAlerts.enqueue(:resumed, destination.id, nil)
      assert jobs() == []
    end

    test "list_enabled_org_admins/1 returns the enabled org-admins by id", ctx do
      ids =
        ctx.organization |> Kanban.Organizations.list_enabled_org_admins() |> Enum.map(& &1.id)

      assert ids == Enum.sort([ctx.admin.id, ctx.other_admin.id])
      assert Kanban.Organizations.list_enabled_org_admins(organization_fixture().id) == []
    end
  end

  # --- changes ----------------------------------------------------------------

  describe "changes" do
    test "creating, pausing and deleting through Kanban.AuditStream enqueue the emails; a rolled-back change enqueues none",
         ctx do
      destination = create!(ctx, :https, %{start_from: "7d"})
      assert [%{args: %{"details" => %{"start_from" => "7d"}}} | _] = jobs("created")

      {:ok, paused} = AuditStream.pause_destination(ctx.scope, destination)
      assert length(jobs("paused")) == 2

      # Pausing a paused destination records its event but sends no email.
      {:ok, paused} = AuditStream.pause_destination(ctx.scope, paused)
      assert length(jobs("paused")) == 2

      {:ok, resumed} = AuditStream.resume_destination(ctx.scope, paused)
      assert length(jobs("resumed")) == 2

      clear_jobs()

      {:error, :undo} =
        Repo.transaction(fn ->
          {:ok, _paused} = AuditStream.pause_destination(ctx.scope, resumed)
          Repo.rollback(:undo)
        end)

      assert jobs() == []

      {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, resumed)
      assert [deleted | _] = jobs("deleted")
      assert deleted.args["destination"]["name"] == destination.name
      refute Repo.get(Destination, destination.id)
    end

    test "emails only for the listed setting changes", ctx do
      splunk = create!(ctx, :splunk_hec)
      clear_jobs()

      update!(ctx, splunk, %{name: "Renamed"})
      assert jobs() == []
      update!(ctx, splunk, %{settings: %{"index" => "main", "source_type" => "stride"}})
      assert jobs() == []
      [action | _] = Destination.excludable_actions()
      update!(ctx, splunk, %{excluded_actions: [action]})
      assert [%{args: %{"details" => %{"changed" => ["excluded_actions"]}}} | _] = jobs("updated")
      clear_jobs()

      update!(ctx, splunk, %{settings: %{"index" => "security", "source_type" => "stride"}})
      assert [%{args: %{"details" => %{"changed" => ["index"]}}} | _] = jobs("updated")
      clear_jobs()

      update!(ctx, splunk, %{
        url: "https://collector.example.com/services/collector",
        credential: "another-splunk-token-1234",
        include_personal_data: false
      })

      assert [%{args: %{"details" => %{"changed" => changed}}} | _] = jobs("updated")
      assert changed == ["url", "credential", "include_personal_data"]
      clear_jobs()

      datadog = create!(ctx, :datadog)
      clear_jobs()

      update!(ctx, datadog, %{
        settings: %{"site" => "datadoghq.com", "service" => "x", "tags" => ["env:prod"]}
      })

      assert [%{args: %{"details" => %{"changed" => ["site", "service", "tags"]}}} | _] =
               jobs("updated")

      clear_jobs()

      https =
        create!(ctx, :https, %{
          credential: "header-value-5678",
          settings: %{"format" => "ndjson", "header_name" => "X-Api-Key"}
        })

      clear_jobs()
      update!(ctx, https, %{settings: %{"format" => "json", "header_name" => "X-Api-Key"}})
      assert jobs() == []
      update!(ctx, https, %{settings: %{"format" => "json", "header_name" => "X-Other-Key"}})
      assert [%{args: %{"details" => %{"changed" => ["header_name"]}}} | _] = jobs("updated")
    end

    test "job args never contain a secret", ctx do
      url = "https://siem.example.org/ingest/42?path-token=s3cr3t-path"

      https =
        create!(ctx, :https, %{
          url: url,
          credential: "top-secret-header-value",
          settings: %{"format" => "ndjson", "header_name" => "X-Api-Key"}
        })

      splunk = create!(ctx, :splunk_hec, %{credential: "splunk-hec-token-secret-wxyz"})
      stored = reload(https)

      {:ok, _paused} = AuditStream.pause_destination(ctx.scope, https)
      {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, splunk)

      encoded = jobs() |> Enum.map(& &1.args) |> Jason.encode!()

      for secret <- [url, "s3cr3t-path", "top-secret-header-value", "splunk-hec-token-secret"] do
        refute encoded =~ secret
      end

      refute encoded =~ stored.signing_secret
      refute encoded =~ ctx.admin.email
      assert encoded =~ "siem.example.org"
      assert encoded =~ stored.credential_hint
    end
  end

  # --- throttles --------------------------------------------------------------

  describe "throttles" do
    test "failing and recovered are throttled to once an hour; a growing gap to once every 7 days",
         ctx do
      destination = destination_fixture(ctx.organization, :https)

      {:ok, failing} = DispatchRows.apply_status(destination, failing_plan(destination))
      assert [%{args: %{"details" => %{"reason" => "unauthorized"}}} | _] = jobs("failing")
      assert %DateTime{} = failing.failing_emailed_at
      clear_jobs()

      set_destination(destination, state: :healthy, failing_emailed_at: minutes_ago(30))
      healthy = reload(destination)
      {:ok, _failing} = DispatchRows.apply_status(healthy, failing_plan(healthy))
      assert jobs() == []

      set_destination(destination, state: :healthy, failing_emailed_at: minutes_ago(61))
      healthy = reload(destination)
      {:ok, _failing} = DispatchRows.apply_status(healthy, failing_plan(healthy))
      assert length(jobs("failing")) == 2
      clear_jobs()

      set_destination(destination, state: :failing, recovered_emailed_at: minutes_ago(30))
      {:ok, _healthy} = destination |> reload() |> DispatchRows.apply_status(recovered_plan())
      assert jobs() == []

      set_destination(destination, state: :failing, recovered_emailed_at: minutes_ago(61))
      {:ok, recovered} = destination |> reload() |> DispatchRows.apply_status(recovered_plan())
      assert length(jobs("recovered")) == 2
      assert DateTime.diff(DateTime.utc_now(), recovered.recovered_emailed_at) < 5
      clear_jobs()

      loss = %{events: 2, first_at: days_ago(200), last_at: days_ago(199)}
      gap = gap_fixture(destination, %{emailed_at: days_ago(6)})
      {:ok, _recorded} = Gaps.record(destination, :retention, loss, DateTime.utc_now())
      assert jobs() == []
      assert Repo.get!(Gap, gap.id).emailed_at == gap.emailed_at

      from(g in Gap, where: g.id == ^gap.id) |> Repo.update_all(set: [emailed_at: days_ago(8)])
      {:ok, _recorded} = Gaps.record(destination, :retention, loss, DateTime.utc_now())

      assert [%{args: %{"details" => %{"gap" => %{"opened" => false, "events" => 16}}}} | _] =
               jobs("gap")

      assert DateTime.diff(DateTime.utc_now(), Repo.get!(Gap, gap.id).emailed_at) < 5
    end

    test "status_alert/3 decides the email and the timestamp it sets" do
      now = ~U[2026-11-13 12:00:00Z]
      healthy = %Destination{state: :healthy}
      failing = %Destination{state: :failing, failing_emailed_at: ~U[2026-11-13 11:50:00Z]}

      assert {:failing, %{reason: :no_success}, %{failing_emailed_at: ^now}} =
               AuditStreamAlerts.status_alert(
                 healthy,
                 %{destination: %{}, audit: {:failing, :no_success}},
                 now
               )

      assert nil == AuditStreamAlerts.status_alert(healthy, %{destination: %{}, audit: nil}, now)

      # A re-seed halt emails even on a Failing destination emailed minutes ago.
      txid = %{destination: %{halted_reason: :txid_reset}, audit: nil}

      assert {:txid_reset, %{}, %{failing_emailed_at: ^now}} =
               AuditStreamAlerts.status_alert(failing, txid, now)

      # Unreadable credentials need an org-admin: emailed once the hour has passed.
      unreadable = %{destination: %{halted_reason: :credentials_unreadable}, audit: nil}
      assert nil == AuditStreamAlerts.status_alert(failing, unreadable, now)

      earlier = %{failing | failing_emailed_at: ~U[2026-11-13 10:00:00Z]}

      assert {:failing, %{reason: :credentials_unreadable}, _at} =
               AuditStreamAlerts.status_alert(earlier, unreadable, now)

      halted = %{earlier | halted_reason: :credentials_unreadable}
      assert nil == AuditStreamAlerts.status_alert(halted, unreadable, now)
    end

    test "gap_email_due?/2 is true when never emailed or at least 7 days ago" do
      now = ~U[2026-11-13 12:00:00Z]
      assert AuditStreamAlerts.gap_email_due?(nil, now)
      seven_days_ago = DateTime.add(now, -7 * 86_400, :second)
      assert AuditStreamAlerts.gap_email_due?(seven_days_ago, now)
      a_second_later = DateTime.add(seven_days_ago, 1, :second)
      refute AuditStreamAlerts.gap_email_due?(a_second_later, now)
    end
  end

  # --- dispatch and gaps ------------------------------------------------------

  describe "dispatch and gaps" do
    test "a DispatchWorker run that turns a destination Failing, then a successful one, each enqueue once",
         ctx do
      destination = destination_fixture(ctx.organization, :https)
      event!(ctx.organization, 1)

      stub(401)
      run(destination)
      assert reload(destination).state == :failing
      assert length(jobs("failing")) == 2

      # Still failing: no second email.
      set_cursor(destination, next_attempt_at: nil)
      run(destination)
      assert length(jobs("failing")) == 2

      set_cursor(destination, next_attempt_at: nil)
      stub(200)
      run(destination)
      assert reload(destination).state == :healthy
      assert length(jobs("recovered")) == 2
      assert length(jobs("failing")) == 2
    end

    test "a retention gap and a txid_reset halt enqueue their emails", ctx do
      destination = destination_fixture(ctx.organization, :https)

      # Retention passes only the id, Organization and kind.
      losses_shape = Map.take(destination, [:id, :organization_id, :kind])
      loss = %{events: 4, first_at: days_ago(200), last_at: days_ago(199)}
      {:ok, _recorded} = Gaps.record(losses_shape, :retention, loss, DateTime.utc_now())

      assert [%{args: args} | _] = gap_jobs = jobs("gap")
      assert length(gap_jobs) == 2
      assert args["actor_id"] == nil
      assert args["destination"]["name"] == destination.name
      assert %{"reason" => "retention", "events" => 4, "opened" => true} = args["details"]["gap"]

      # Already Failing and emailed ten minutes ago: the re-seed still emails.
      set_destination(destination, state: :failing, failing_emailed_at: minutes_ago(10))
      event!(ctx.organization, 1)
      set_cursor(destination, last_txid: 9_000_000_000_000)
      run(destination)

      assert reload(destination).halted_reason == :txid_reset
      assert length(jobs("txid_reset")) == 2
    end
  end
end
