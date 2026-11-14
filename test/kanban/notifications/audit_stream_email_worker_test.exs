defmodule Kanban.Notifications.AuditStreamEmailWorkerTest do
  # async: false — one test swaps the global mailer adapter.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures
  import Swoosh.TestAssertions

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Destination
  alias Kanban.Notifications.AuditStreamAlerts
  alias Kanban.Notifications.AuditStreamEmailWorker
  alias Kanban.Organizations.OrganizationMember

  defmodule FailingMailbox do
    @moduledoc false
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config),
      do: {:error, {:permanent_failure, ~c"mx.example.test", "550 no such mailbox"}}
  end

  # user_fixture/1 sends an account-confirmation email to the test process;
  # drop those so the assertions below only see audit stream emails.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    actor = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    organization_member_fixture(organization, actor, :org_admin)
    destination = destination_fixture(organization, :splunk_hec)
    flush_emails()

    %{organization: organization, admin: admin, actor: actor, destination: destination}
  end

  # The args AuditStreamAlerts enqueued for `recipient`.
  defp enqueued_args(kind, destination, actor, recipient, details \\ %{}) do
    :ok = AuditStreamAlerts.enqueue(kind, destination, actor, details)

    [job] =
      [worker: AuditStreamEmailWorker]
      |> all_enqueued()
      |> Enum.filter(&(&1.args["user_id"] == recipient.id))

    Repo.delete_all(Oban.Job)
    job.args
  end

  test "sends the email to the recipient, naming the actor and the destination", ctx do
    args = enqueued_args(:paused, ctx.destination, ctx.actor, ctx.admin)

    assert :ok = perform_job(AuditStreamEmailWorker, args)

    assert_email_sent(fn email ->
      assert email.to == [{"", ctx.admin.email}]

      assert email.subject ==
               "[Stride] Audit streaming destination paused: \u2068#{ctx.destination.name}\u2069"

      assert email.text_body =~ "#{ctx.actor.email} paused the audit streaming destination"
      assert email.text_body =~ "/org/audit/streaming/#{ctx.destination.id}"
    end)
  end

  test "skips a recipient no longer an enabled org-admin", ctx do
    args = enqueued_args(:resumed, ctx.destination, ctx.actor, ctx.admin)
    membership = Repo.get_by!(OrganizationMember, user_id: ctx.admin.id)

    # Demoted.
    membership |> Ecto.Changeset.change(role: :member) |> Repo.update!()
    assert :ok = perform_job(AuditStreamEmailWorker, args)
    assert_no_email_sent()

    # Promoted again, then disabled.
    from(m in OrganizationMember, where: m.id == ^membership.id)
    |> Repo.update_all(set: [role: :org_admin])

    from(u in User, where: u.id == ^ctx.admin.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

    assert :ok = perform_job(AuditStreamEmailWorker, args)
    assert_no_email_sent()

    # Removed from the Organization.
    from(u in User, where: u.id == ^ctx.admin.id) |> Repo.update_all(set: [disabled_at: nil])
    from(m in OrganizationMember, where: m.id == ^membership.id) |> Repo.delete_all()
    assert :ok = perform_job(AuditStreamEmailWorker, args)
    assert_no_email_sent()
  end

  test "renders in the recipient's locale and falls back to English", ctx do
    {:ok, _user} = Accounts.update_user_locale(ctx.admin, "fr")
    args = enqueued_args(:resumed, ctx.destination, ctx.actor, ctx.admin)
    assert :ok = perform_job(AuditStreamEmailWorker, args)

    assert_email_sent(fn email ->
      refute email.subject =~ "Audit streaming destination resumed"
      assert email.text_body =~ "?locale=fr"
    end)

    from(u in User, where: u.id == ^ctx.admin.id) |> Repo.update_all(set: [locale: "xx"])
    assert :ok = perform_job(AuditStreamEmailWorker, args)

    assert_email_sent(fn email ->
      assert email.subject =~ "Audit streaming destination resumed"
      refute email.text_body =~ "?locale="
      true
    end)
  end

  test "sends the deleted email after the destination is gone", ctx do
    args = enqueued_args(:deleted, ctx.destination, ctx.actor, ctx.admin)
    Destination |> Repo.get!(ctx.destination.id) |> Repo.delete!()

    assert :ok = perform_job(AuditStreamEmailWorker, args)

    assert_email_sent(fn email ->
      assert email.subject =~ "deleted"
      assert email.text_body =~ ctx.destination.name
      assert email.text_body =~ "collector.example.com"
    end)
  end

  test "names Stride when no one acted and a deleted account when the actor is gone", ctx do
    args =
      enqueued_args(:failing, ctx.destination, nil, ctx.admin, %{reason: :credentials_unreadable})

    assert :ok = perform_job(AuditStreamEmailWorker, args)

    assert_email_sent(fn email ->
      assert email.text_body =~ "By: Stride recorded this"
      assert email.text_body =~ "enter them again"
    end)

    gone = enqueued_args(:updated, ctx.destination, ctx.actor, ctx.admin, %{changed: ["url"]})
    User |> Repo.get!(ctx.actor.id) |> Repo.delete!()
    assert :ok = perform_job(AuditStreamEmailWorker, gone)

    assert_email_sent(fn email ->
      assert email.text_body =~ "A deleted account changed the audit streaming destination"
      refute email.text_body =~ ctx.actor.email
      true
    end)
  end

  test "a gap job renders its counts and dates", ctx do
    gap = %{
      reason: :too_old,
      events: 2,
      first_at: ~U[2026-11-01 00:00:00Z],
      last_at: ~U[2026-11-02 00:00:00Z],
      opened: true
    }

    args = enqueued_args(:gap, ctx.destination, nil, ctx.admin, %{gap: gap})
    assert :ok = perform_job(AuditStreamEmailWorker, args)

    assert_email_sent(fn email ->
      assert email.text_body =~ "2 audit events will never reach this destination."
      assert email.text_body =~ "Reason: Too old for Datadog"
    end)
  end

  test "skips args it does not recognise without creating an atom", ctx do
    args = enqueued_args(:resumed, ctx.destination, ctx.actor, ctx.admin)

    for bad <- [
          %{args | "alert" => "not_an_alert_kind_w2719"},
          put_in(args, ["destination", "kind"], "not_a_kind_w2719"),
          Map.delete(args, "ref")
        ] do
      assert :ok = perform_job(AuditStreamEmailWorker, bad)
    end

    assert_no_email_sent()
    assert_raise ArgumentError, fn -> String.to_existing_atom("not_an_alert_kind_w2719") end
  end

  test "a created job names its start point", ctx do
    args = enqueued_args(:created, ctx.destination, ctx.actor, ctx.admin, %{start_from: "all"})
    assert :ok = perform_job(AuditStreamEmailWorker, args)
    assert_email_sent(fn email -> assert email.subject =~ "sending the whole audit log" end)

    assert :ok = perform_job(AuditStreamEmailWorker, put_in(args, ["details", "start_from"], 7))

    assert_email_sent(fn email ->
      assert email.subject =~ "Audit streaming destination created:"
    end)
  end

  test "an unknown failing reason and an unusable actor id still send, without naming Stride",
       ctx do
    args = enqueued_args(:failing, ctx.destination, nil, ctx.admin, %{reason: :no_success})
    assert :ok = perform_job(AuditStreamEmailWorker, put_in(args, ["details", "reason"], "zzz"))

    assert_email_sent(fn email ->
      assert email.text_body =~ "Deliveries to the destination are failing"
    end)

    paused = enqueued_args(:paused, ctx.destination, ctx.actor, ctx.admin)
    assert :ok = perform_job(AuditStreamEmailWorker, %{paused | "actor_id" => "x"})
    assert_email_sent(fn email -> assert email.text_body =~ "A deleted account paused" end)
  end

  test "skips a gap job whose gap is missing or malformed", ctx do
    gap = %{
      reason: :retention,
      events: 2,
      first_at: ~U[2026-11-01 00:00:00Z],
      last_at: ~U[2026-11-02 00:00:00Z],
      opened: false
    }

    args = enqueued_args(:gap, ctx.destination, nil, ctx.admin, %{gap: gap})

    for bad <- [
          put_in(args, ["details"], %{}),
          put_in(args, ["details", "gap"], "not a map"),
          put_in(args, ["details", "gap", "reason"], "zzz"),
          put_in(args, ["details", "gap", "reason"], 1),
          put_in(args, ["details", "gap", "first_at"], "yesterday"),
          put_in(args, ["destination"], "not a map")
        ] do
      assert :ok = perform_job(AuditStreamEmailWorker, bad)
    end

    assert_no_email_sent()
  end

  test "a mailer failure returns a bounded failure kind and logs no address", ctx do
    args = enqueued_args(:resumed, ctx.destination, ctx.actor, ctx.admin)
    original = Application.get_env(:kanban, Kanban.Mailer)
    Application.put_env(:kanban, Kanban.Mailer, adapter: FailingMailbox)
    on_exit(fn -> Application.put_env(:kanban, Kanban.Mailer, original) end)

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :permanent_failure} = perform_job(AuditStreamEmailWorker, args)
      end)

    assert log =~
             "audit stream resumed email delivery failed (user_id=#{ctx.admin.id}): permanent_failure"

    refute log =~ ctx.admin.email
    refute log =~ "no such mailbox"
    refute log =~ "mx.example.test"
  end
end
