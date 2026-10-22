defmodule Kanban.Retention.PurgeWorkerTest do
  # Not async: the tests change the worker's application config, which is
  # global, and replace the database purge function in one test.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Retention.PurgeWorker
  alias Kanban.Tasks.Task

  @day 24 * 60 * 60

  setup do
    original = Application.get_env(:kanban, PurgeWorker)
    on_exit(fn -> restore_config(original) end)
    put_config([])
    :ok
  end

  defp restore_config(nil), do: Application.delete_env(:kanban, PurgeWorker)
  defp restore_config(config), do: Application.put_env(:kanban, PurgeWorker, config)

  defp put_config(config), do: Application.put_env(:kanban, PurgeWorker, config)

  # The database floor is measured from the real now(), so the job runs at the
  # real current time too.
  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * @day, :second)

  defp run, do: perform_job(PurgeWorker, %{"now" => DateTime.to_iso8601(DateTime.utc_now())})

  defp audit_at!(days_old, organization_id \\ nil) do
    {1, [%{id: id}]} =
      Repo.insert_all(
        AuditEvent,
        [
          %{
            action: "backdated",
            metadata: %{},
            inserted_at: days_ago(days_old),
            organization_id: organization_id
          }
        ],
        returning: [:id]
      )

    id
  end

  defp audit_ids do
    from(e in AuditEvent, where: e.action == "backdated", order_by: e.id, select: e.id)
    |> Repo.all()
  end

  defp purge_events do
    from(e in AuditEvent, where: e.action == "retention_purge", order_by: e.id)
    |> Repo.all()
  end

  defp org_with_retention(days) do
    org = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(org, admin, :org_admin)

    {:ok, _} =
      SecurityPolicies.update_policy(admin, %{"audit_retention_days" => to_string(days)})

    org
  end

  defp column do
    user_fixture() |> board_fixture() |> column_fixture()
  end

  defp archive!(%Task{} = task, days_old) do
    from(t in Task, where: t.id == ^task.id)
    |> Repo.update_all(set: [archived_at: days_old |> days_ago() |> DateTime.truncate(:second)])

    task
  end

  defp task_exists?(task), do: Repo.get(Task, task.id) != nil

  describe "cron configuration" do
    test "runs daily on the :maintenance queue" do
      plugins = :kanban |> Application.fetch_env!(Oban) |> Keyword.fetch!(:plugins)
      {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)

      assert {"47 3 * * *", PurgeWorker} in Keyword.fetch!(opts, :crontab)
      assert PurgeWorker.__opts__()[:queue] == :maintenance
    end

    test "config.exs keeps site audit events for the 90 days /privacy promises, and archived tasks for ever" do
      config =
        "config/config.exs" |> Config.Reader.read!(env: :prod) |> get_in([:kanban, PurgeWorker])

      assert config[:site_audit_retention_days] == 90
      assert config[:archived_task_retention_days] == nil
      assert config[:batch_size] == 1_000
    end
  end

  describe "Organization audit retention" do
    test "removes each Organization's events older than its retention and nothing else" do
      org = org_with_retention(120)
      keep_forever = organization_fixture()
      old = audit_at!(200, org.id)
      recent = audit_at!(100, org.id)
      other_old = audit_at!(200, keep_forever.id)
      site_old = audit_at!(400)

      assert :ok = run()

      assert audit_ids() == Enum.sort([recent, other_old, site_old])
      refute old in audit_ids()

      assert [event] = purge_events()
      assert event.metadata["organization_counts"] == %{to_string(org.id) => 1}
      assert event.metadata["site_count"] == nil
      assert event.metadata["archived_task_count"] == nil
      assert event.metadata["failed_steps"] == []
    end

    test "removes in batches until a batch comes back short" do
      put_config(batch_size: 2)
      # 91, not the 90-day floor: the sandbox transaction pins the database's
      # now() to the start of the test, a moment before the job's own clock.
      org = org_with_retention(91)
      for _ <- 1..5, do: audit_at!(200, org.id)

      assert :ok = run()
      assert audit_ids() == []
      assert hd(purge_events()).metadata["organization_counts"] == %{to_string(org.id) => 5}
    end

    test "running twice in a row removes nothing the second time" do
      put_config(site_audit_retention_days: 91, archived_task_retention_days: 30)
      org = org_with_retention(91)
      audit_at!(200, org.id)
      audit_at!(200)
      task = column() |> task_fixture() |> archive!(60)

      assert :ok = run()
      refute task_exists?(task)
      assert :ok = run()

      [_first, second] = purge_events()
      assert second.metadata["organization_counts"] == %{to_string(org.id) => 0}
      assert second.metadata["site_count"] == 0
      assert second.metadata["archived_task_count"] == 0
    end

    test "a failing step is recorded and the other steps still run" do
      put_config(site_audit_retention_days: 91)
      org = org_with_retention(91)
      audit_at!(200, org.id)
      site_old = audit_at!(200)

      Repo.query!(
        "ALTER FUNCTION audit_events_purge_organization(bigint, timestamp with time zone, integer) " <>
          "RENAME TO audit_events_purge_organization_gone"
      )

      log = capture_log(fn -> assert :ok = run() end)

      assert log =~ "retention purge failed"
      assert site_old in audit_ids()
      [event] = purge_events()
      assert event.metadata["failed_steps"] == ["organization:#{org.id}", "site"]
    end
  end

  describe "site-level audit retention" do
    test "keeps rows with no Organization when the setting is unset" do
      site_old = audit_at!(400)
      assert :ok = run()
      assert audit_ids() == [site_old]
    end

    test "removes rows with no Organization older than the setting" do
      put_config(site_audit_retention_days: 180)
      org = organization_fixture()
      site_old = audit_at!(200)
      site_recent = audit_at!(100)
      org_old = audit_at!(200, org.id)

      assert :ok = run()
      assert audit_ids() == Enum.sort([site_recent, org_old])
      refute site_old in audit_ids()
      assert hd(purge_events()).metadata["site_count"] == 1
    end

    test "a 90-day setting removes rows past the floor even when the app's clock runs ahead" do
      put_config(site_audit_retention_days: 90)
      site_old = audit_at!(91)
      site_recent = audit_at!(89)

      # Ten seconds ahead of the database: a cutoff of exactly now - 90 days
      # would be inside the database's floor and refused.
      ahead = DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_iso8601()

      log = capture_log(fn -> assert :ok = perform_job(PurgeWorker, %{"now" => ahead}) end)

      refute log =~ "refused"
      assert audit_ids() == [site_recent]
      refute site_old in audit_ids()
    end

    test "a setting below the 90-day floor or not an integer removes nothing and warns" do
      site_old = audit_at!(400)

      for bad <- [30, "180", -1] do
        put_config(site_audit_retention_days: bad)
        log = capture_log(fn -> assert :ok = run() end)
        assert log =~ "site_audit_retention_days"
      end

      assert audit_ids() == [site_old]
    end
  end

  describe "archived-task retention" do
    test "keeps every archived task when the setting is unset" do
      task = column() |> task_fixture() |> archive!(1_000)
      assert :ok = run()
      assert task_exists?(task)
    end

    test "removes archived tasks older than the setting in batches, keeping newer and live ones" do
      put_config(archived_task_retention_days: 30, batch_size: 2)
      col = column()
      old = for _ <- 1..5, do: col |> task_fixture() |> archive!(60)
      newer = col |> task_fixture() |> archive!(10)
      live = task_fixture(col)

      assert :ok = run()

      refute Enum.any?(old, &task_exists?/1)
      assert task_exists?(newer)
      assert task_exists?(live)
      assert hd(purge_events()).metadata["archived_task_count"] == 5
    end

    test "an invalid setting removes nothing and warns" do
      put_config(archived_task_retention_days: 0)
      task = column() |> task_fixture() |> archive!(1_000)

      log = capture_log(fn -> assert :ok = run() end)
      assert log =~ "archived_task_retention_days"
      assert task_exists?(task)
    end
  end

  describe "expired SAML sign-in state" do
    test "removes expired SAML requests and assertion IDs in batches and keeps live ones" do
      put_config(batch_size: 2)

      connection =
        Kanban.SSOFixtures.saml_connection_fixture(
          organization_fixture(),
          Kanban.SAMLTestHelpers.idp().pem
        )

      now = DateTime.utc_now(:second)

      for n <- 1..3 do
        insert_saml_rows(connection, "expired-#{n}", DateTime.add(now, -60))
      end

      insert_saml_rows(connection, "live", DateTime.add(now, 600))

      assert :ok = run()

      assert saml_ids(Kanban.SSO.SAML.Request) == ["live"]
      assert saml_ids(Kanban.SSO.SAML.AssertionID) == ["live"]
      assert hd(purge_events()).metadata["saml_count"] == 6
      assert hd(purge_events()).metadata["failed_steps"] == []
    end
  end

  defp insert_saml_rows(connection, id, expires_at) do
    connection
    |> Kanban.SSO.SAML.Request.new_changeset(%{
      request_id: id,
      relay_token: id,
      return_to: nil,
      expires_at: expires_at
    })
    |> Repo.insert!()

    connection
    |> Kanban.SSO.SAML.AssertionID.new_changeset(id, expires_at)
    |> Repo.insert!()
  end

  defp saml_ids(Kanban.SSO.SAML.Request = schema),
    do: from(r in schema, select: r.request_id) |> Repo.all()

  defp saml_ids(schema), do: from(r in schema, select: r.assertion_id) |> Repo.all()
end
