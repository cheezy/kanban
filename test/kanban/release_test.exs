defmodule Kanban.ReleaseTest do
  # async: false — these tests set an OS environment variable and the
  # :audit_log_boot_check application flag, both global to the VM, and harden
  # audit_events inside the sandbox, which locks the table until rollback.
  # setup/on_exit restore every value they touch.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.AuditLogRoleHelper
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Gap
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Announcement
  alias Kanban.Notifications.AnnouncementWorker
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Release
  alias Kanban.Tasks.Task

  @env "AUDIT_LOG_ADMIN_DATABASE_URL"
  # An obviously fake secret: the log assertions look for it verbatim.
  @fake_password "w2331-not-a-real-password"
  @other_role "kanban_release_test_role"

  setup do
    previous_url = System.get_env(@env)
    previous_flag = Application.fetch_env(:kanban, :audit_log_boot_check)

    on_exit(fn ->
      restore_env(previous_url)
      restore_flag(previous_flag)
    end)

    System.delete_env(@env)
    Application.delete_env(:kanban, :audit_log_boot_check)
    :ok
  end

  defp restore_env(nil), do: System.delete_env(@env)
  defp restore_env(value), do: System.put_env(@env, value)

  defp restore_flag(:error), do: Application.delete_env(:kanban, :audit_log_boot_check)
  defp restore_flag({:ok, value}), do: Application.put_env(:kanban, :audit_log_boot_check, value)

  # A work function that reports whether it ran, so a refusal can be shown to
  # happen before any connection is opened.
  defp tracking_work do
    test_pid = self()

    fn _runner, _app_role ->
      send(test_pid, :work_ran)
      {:ok, :hardened}
    end
  end

  # The test database, reached as its superuser over a fresh connection.
  defp test_database_url do
    config = Repo.config()

    "ecto://#{config[:username]}:#{config[:password]}@#{config[:hostname]}/#{config[:database]}"
  end

  # A local port nothing listens on: bind an ephemeral port, then close it.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  test "harden_audit_log refuses to run when the admin URL is missing or blank" do
    for value <- [nil, "", "   \n\t"] do
      if value, do: System.put_env(@env, value), else: System.delete_env(@env)

      log =
        capture_log(fn ->
          assert {:error, :admin_url_missing} =
                   Release.harden_audit_log(app_role: @other_role, work: tracking_work())
        end)

      assert log =~ "security_audit_harden_failed reason=admin_url_missing"
    end

    refute_received :work_ran
  end

  test "harden_audit_log refuses an admin URL whose user is the app role" do
    # The test Repo connects as "postgres", which is therefore the app role.
    assert Repo.config()[:username] == "postgres"
    url = "ecto://postgres:#{@fake_password}@localhost/kanban_test"
    System.put_env(@env, url)

    log =
      capture_log(fn ->
        assert {:error, :admin_is_app_role} = Release.harden_audit_log(work: tracking_work())
      end)

    refute_received :work_ran
    assert log =~ "reason=admin_is_app_role"
    refute log =~ @fake_password
    refute log =~ url
  end

  test "harden_audit_log refuses a malformed admin URL or one with no user, without logging it" do
    for url <- [
          "not a url #{@fake_password}",
          "ecto://localhost/kanban_test",
          "ecto://:#{@fake_password}@localhost/kanban_test"
        ] do
      System.put_env(@env, url)

      log =
        capture_log(fn ->
          assert {:error, :admin_url_invalid} =
                   Release.harden_audit_log(app_role: @other_role, work: tracking_work())
        end)

      refute log =~ @fake_password
    end

    refute_received :work_ran
  end

  test "harden_audit_log refuses another host when the app connects without TLS" do
    refute Repo.config()[:ssl]
    System.put_env(@env, "ecto://kanban_admin:#{@fake_password}@db.example.invalid/kanban")

    log =
      capture_log(fn ->
        assert {:error, :admin_host_differs_without_tls} =
                 Release.harden_audit_log(app_role: @other_role, work: tracking_work())
      end)

    refute_received :work_ran
    refute log =~ @fake_password
    refute log =~ "db.example.invalid"
  end

  test "harden_audit_log returns an error tuple for an unreachable admin host and never logs the URL or its password" do
    url = "ecto://kanban_admin:#{@fake_password}@localhost:#{closed_port()}/kanban_test"
    System.put_env(@env, url)

    {micros, log} =
      :timer.tc(fn ->
        capture_log(fn ->
          assert {:error, :admin_connection_failed} =
                   Release.harden_audit_log(work: tracking_work(), timeout: 5_000)
        end)
      end)

    assert micros < 5_000_000
    refute_received :work_ran
    # Proves the capture saw this run's lines before refuting the secrets.
    assert log =~ "security_audit_harden_failed reason=admin_connection_failed"
    refute log =~ @fake_password
    refute log =~ url
  end

  test "harden_audit_log runs the work over its own connection and stops it" do
    System.put_env(@env, test_database_url())
    test_pid = self()

    work = fn runner, app_role ->
      %{rows: [[lock_timeout]]} = runner.("SHOW lock_timeout")
      send(test_pid, {:worked, self(), app_role, lock_timeout})
      {:ok, :hardened}
    end

    log =
      capture_log(fn ->
        assert {:ok, :hardened} = Release.harden_audit_log(app_role: @other_role, work: work)
      end)

    # The admin session fails fast on a contended lock instead of queueing.
    assert_received {:worked, worker, @other_role, "10s"}
    refute worker == self()
    refute Process.alive?(worker)
    refute log =~ "security_audit_harden_failed"
  end

  test "harden_audit_log reports a failing statement by its code only" do
    System.put_env(@env, test_database_url())
    work = fn runner, _app_role -> runner.("SELECT * FROM w2331_no_such_table") end

    log =
      capture_log(fn ->
        assert {:error, :hardening_failed} =
                 Release.harden_audit_log(app_role: @other_role, work: work)
      end)

    assert log =~ "exception=Postgrex.Error code=undefined_table"
    refute log =~ "w2331_no_such_table"
  end

  test "harden_audit_log logs a raising work function by exception type only" do
    System.put_env(@env, test_database_url())
    work = fn _runner, _app_role -> raise ArgumentError, "leaked #{@fake_password}" end

    log =
      capture_log(fn ->
        assert {:error, :hardening_failed} =
                 Release.harden_audit_log(app_role: @other_role, work: work)
      end)

    assert log =~ "exception=ArgumentError"
    refute log =~ @fake_password
  end

  test "harden_audit_log gives up with an error tuple when the work does not finish in time" do
    System.put_env(@env, test_database_url())
    work = fn _runner, _app_role -> Process.sleep(:infinity) end

    capture_log(fn ->
      assert {:error, :admin_timeout} =
               Release.harden_audit_log(app_role: @other_role, work: work, timeout: 300)
    end)
  end

  test "hardening run twice succeeds both times and reports hardened" do
    role = AuditLogRoleHelper.create_app_like_role()
    runner = AuditLogRoleHelper.runner()

    assert {:ok, :hardened} = Release.apply_hardening(runner, role)
    assert {:ok, :hardened} = Release.apply_hardening(runner, role)
  end

  test "hardening installs the Organization purge function hardened, and status names it while it is not" do
    role = AuditLogRoleHelper.create_app_like_role()
    runner = AuditLogRoleHelper.runner()

    assert Purge.revert_organization(runner) == :reverted
    assert {:ok, :hardened} = Release.apply_hardening(runner, role)
    assert Purge.organization_status(runner, app_role: role) == :hardened

    # audit_log_status reads through the app Repo, so a missing function shows
    # up beside the superuser reason until hardening is run again.
    assert Purge.revert_organization(runner) == :reverted

    assert Release.audit_log_status() ==
             {:degraded, [:app_role_is_superuser, :organization_purge_function_missing]}
  end

  test "hardening refuses an admin role that is not a superuser" do
    not_superuser = fn _sql -> %{rows: [[false]]} end

    assert {:error, :admin_not_superuser} = Release.apply_hardening(not_superuser, @other_role)
  end

  test "audit_log_status combines the table and purge checks and names app_role_is_superuser against the superuser test database" do
    # The table check alone names app_role_is_superuser and the purge check is
    # hardened, so the combined status carries exactly that one reason.
    assert Release.audit_log_status() == {:degraded, [:app_role_is_superuser]}
  end

  test "scan_credential_considerations/0 starts the app, runs the scan and returns the report" do
    # Fake value only. The write path refuses it since W2382, so it is stored
    # directly, as a task written before that check would hold it.
    token = "ghp_abcdefghij0123456789"
    column = column_fixture(board_fixture(user_fixture()))
    clean = task_fixture(column)
    task = task_fixture(column)

    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [security_considerations: ["Scoped", "uses #{token}"]])

    report = Release.scan_credential_considerations()

    assert report == [%{identifier: task.identifier, task_id: task.id, positions: [2]}]
    refute Enum.any?(report, &(&1.task_id == clean.id))
    refute inspect(report) =~ token
  end

  test "report_over_cap_boards/0 returns the same list as Boards.over_cap_boards/0 and writes nothing" do
    owner = user_fixture()
    board = board_fixture(owner)
    under = board_fixture(user_fixture())

    for _ <- 1..3 do
      {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)
    end

    counts = fn -> {Repo.aggregate(Board, :count), Repo.aggregate(BoardUser, :count)} end
    before = counts.()

    report = Release.report_over_cap_boards()

    assert report == [%{board_id: board.id, owner_user_id: owner.id, member_count: 4}]
    assert report == Boards.over_cap_boards()
    refute Enum.any?(report, &(&1.board_id == under.id))
    refute inspect(report) =~ owner.email
    refute inspect(report) =~ board.name
    assert counts.() == before
  end

  describe "import_workspace/3" do
    setup do
      ctx = Kanban.WorkspaceExportFixtures.export_org_fixture()
      _dir = Kanban.WorkspaceExportFixtures.tmp_export_dir()
      {:ok, export} = Kanban.Workspaces.Export.request_export(ctx.org_admin, ctx.workspace)
      %{success: 1} = Oban.drain_queue(queue: :workspace_exports)
      path = Repo.get!(Kanban.Workspaces.Export.WorkspaceExport, export.id).file_path
      Map.put(ctx, :path, path)
    end

    test "a dry run of an exported archive reports the import and writes nothing", ctx do
      count = fn -> Repo.aggregate(Kanban.Workspaces.Workspace, :count) end
      before = count.()

      assert {:ok, %{dry_run: true, workspace_name: name}} =
               Release.import_workspace(ctx.path, ctx.org_admin.email, dry_run: true)

      assert name == "#{ctx.workspace.name} (imported)"
      assert count.() == before
    end

    test "an email that is not an org-admin is refused", ctx do
      assert Release.import_workspace(ctx.path, ctx.member.email) == {:error, :not_org_admin}
    end
  end

  describe "ensure_internal_organization/1" do
    defp internal_org_opts(admin, extra) do
      Keyword.merge(
        [
          acting_admin_email: admin.email,
          contact_name: "Stride Ops",
          contact_email: "ops@stride.example"
        ],
        extra
      )
    end

    defp org_write_counts do
      {Repo.aggregate(Organization, :count), Repo.aggregate(OrganizationMember, :count),
       Repo.aggregate(User, :count), length(AuditLog.list_events())}
    end

    defp disabled(user) do
      user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()
    end

    test "creates the Organization once, appoints the listed users and is a no-op on the second run" do
      admin = admin_fixture()
      lead = user_fixture()
      second = user_fixture()
      attach_telemetry([:kanban, :organization, :created])
      opts = internal_org_opts(admin, org_admin_emails: [lead.email, second.email])

      first = Release.ensure_internal_organization(opts)

      assert %{status: :ok, organization: %{name: "Stride", created: true, id: org_id}} = first
      assert first.appointed == [lead.email, second.email]
      assert first.already_org_admin == []
      assert first.skipped_unknown == []
      assert first.refused == []
      assert Organizations.org_admin?(lead, org_id)
      assert Organizations.org_admin?(second, org_id)

      assert_received {:telemetry_event, [:kanban, :organization, :created], %{count: 1},
                       %{organization_id: ^org_id, actor_user_id: actor_id}}

      assert actor_id == admin.id

      assert [created] = AuditLog.list_events(action: :organization_created)
      assert created.actor_user_id == admin.id
      assert created.metadata["organization_id"] == org_id

      appointed = AuditLog.list_events(action: :org_admin_appointed)
      assert length(appointed) == 2
      assert Enum.all?(appointed, &(&1.actor_user_id == admin.id))

      member_ids = appointed |> Enum.map(& &1.metadata["member_user_id"]) |> Enum.sort()
      assert member_ids == Enum.sort([lead.id, second.id])

      before = org_write_counts()

      again =
        opts
        |> Keyword.put(:contact_name, "Someone Else")
        |> Release.ensure_internal_organization()

      assert again.status == :ok
      assert again.organization == %{id: org_id, name: "Stride", created: false}
      assert again.appointed == []
      assert again.already_org_admin == [lead.email, second.email]
      assert org_write_counts() == before
      assert Repo.get!(Organization, org_id).contact_name == "Stride Ops"
    end

    test "refuses an unknown, non-admin, disabled or missing acting email and writes nothing" do
      user = user_fixture()
      admin = admin_fixture()
      disabled_admin = disabled(admin_fixture())
      appointee = user_fixture()
      before = org_write_counts()

      for {acting, reason} <- [
            {"nobody-#{System.unique_integer([:positive])}@example.com", :unknown_acting_user},
            {nil, :unknown_acting_user},
            {user.email, :not_site_admin},
            {disabled_admin.email, :not_site_admin}
          ] do
        result =
          admin
          |> internal_org_opts(acting_admin_email: acting, org_admin_emails: [appointee.email])
          |> Release.ensure_internal_organization()

        assert result == %{status: :refused, reason: reason}
      end

      assert org_write_counts() == before
      assert AuditLog.list_events(action: :organization_created) == []
      assert AuditLog.list_events(action: :org_admin_appointed) == []
    end

    test "reports unknown, disabled, invalid and other-Organization emails without creating accounts" do
      admin = admin_fixture()
      lead = user_fixture()
      member = user_fixture()
      disabled_user = disabled(user_fixture())
      elsewhere = user_fixture()
      organization_member_fixture(organization_fixture(), elsewhere, :org_admin)
      existing = organization_fixture(%{name: "Stride"})
      organization_member_fixture(existing, admin_fixture(), :org_admin)
      organization_member_fixture(existing, member, :member)
      unknown = "unknown-#{System.unique_integer([:positive])}@example.com"
      users_before = Repo.aggregate(User, :count)

      emails = [
        "  #{lead.email}  ",
        String.upcase(lead.email),
        "",
        member.email,
        unknown,
        disabled_user.email,
        elsewhere.email,
        42
      ]

      result =
        admin
        |> internal_org_opts(org_admin_emails: emails)
        |> Release.ensure_internal_organization()

      assert result.organization == %{id: existing.id, name: "Stride", created: false}
      assert result.appointed == [lead.email, member.email]
      assert result.skipped_unknown == [unknown]

      assert result.refused == [
               %{email: disabled_user.email, reason: :user_disabled},
               %{email: elsewhere.email, reason: :already_in_another_organization},
               %{email: "42", reason: :invalid_email}
             ]

      assert Repo.aggregate(User, :count) == users_before
      refute Kanban.Accounts.get_user_by_email(unknown)
      assert Organizations.org_admin?(member, existing)
      refute Organizations.member?(disabled_user, existing)
    end

    test "matches the name exactly, reusing the lowest id and never a similar name" do
      admin = admin_fixture()
      organization_fixture(%{name: "Stride Labs"})
      organization_fixture(%{name: "stride"})

      created = admin |> internal_org_opts([]) |> Release.ensure_internal_organization()

      assert %{status: :ok, organization: %{name: "Stride", created: true}} = created
      assert created.appointed == []
      assert created.already_org_admin == []
      assert created.skipped_unknown == []
      assert created.refused == []
      assert Repo.aggregate(Organization, :count) == 3

      organization_fixture(%{name: "Stride"})
      organization_member_fixture(%{id: created.organization.id}, admin_fixture(), :org_admin)

      reused =
        admin
        |> internal_org_opts(name: "  Stride  ", org_admin_emails: [])
        |> Release.ensure_internal_organization()

      assert reused.organization == %{id: created.organization.id, name: "Stride", created: false}
      assert Repo.aggregate(Organization, :count) == 4
    end

    test "refuses a same-named Organization with an unlisted customer org-admin and writes nothing" do
      admin = admin_fixture()
      lead = user_fixture()
      customer = organization_fixture(%{name: "Stride"})
      organization_member_fixture(customer, admin_fixture(), :org_admin)
      organization_member_fixture(customer, user_fixture(), :org_admin)
      before = org_write_counts()

      result =
        admin
        |> internal_org_opts(org_admin_emails: [lead.email])
        |> Release.ensure_internal_organization()

      assert result == %{status: :refused, reason: :name_taken}
      assert org_write_counts() == before
      refute Organizations.member?(lead, customer)
    end

    test "refuses a same-named Organization with members but no org-admin" do
      admin = admin_fixture()
      customer = organization_fixture(%{name: "Stride"})
      organization_member_fixture(customer, admin_fixture(), :member)

      result = admin |> internal_org_opts([]) |> Release.ensure_internal_organization()

      assert result == %{status: :refused, reason: :name_taken}
    end

    test "reuses a same-named Organization run by site admins and listed staff" do
      admin = admin_fixture()
      lead = user_fixture()
      staff_lead = user_fixture()
      staff_only = organization_fixture(%{name: "Stride"})
      organization_member_fixture(staff_only, admin_fixture(), :org_admin)
      organization_member_fixture(staff_only, staff_lead, :org_admin)
      organization_member_fixture(staff_only, user_fixture(), :member)

      result =
        admin
        |> internal_org_opts(
          org_admin_emails: [lead.email, " #{String.upcase(staff_lead.email)} "]
        )
        |> Release.ensure_internal_organization()

      assert result.organization == %{id: staff_only.id, name: "Stride", created: false}
      assert result.appointed == [lead.email]
      assert result.already_org_admin == [String.upcase(staff_lead.email)]

      assert %{status: :refused, reason: :name_taken} =
               admin
               |> internal_org_opts(org_admin_emails: [lead.email])
               |> Release.ensure_internal_organization()
    end

    test "refuses a same-named Organization with no members, so an unstaffed customer's is safe" do
      admin = admin_fixture()
      lead = user_fixture()
      customer = organization_fixture(%{name: "Stride"})
      before = org_write_counts()

      result =
        admin
        |> internal_org_opts(org_admin_emails: [lead.email])
        |> Release.ensure_internal_organization()

      assert result == %{status: :refused, reason: :name_taken}
      assert org_write_counts() == before
      refute Organizations.member?(lead, customer)
    end

    test "returns the changeset's messages and writes nothing when the details are invalid" do
      admin = admin_fixture()
      lead = user_fixture()
      before = org_write_counts()

      result =
        Release.ensure_internal_organization(
          acting_admin_email: admin.email,
          name: "Internal",
          contact_name: "Ops",
          org_admin_emails: [lead.email]
        )

      assert result == %{
               status: :refused,
               reason: :invalid_organization,
               errors: %{contact_email: ["can't be blank"]}
             }

      assert org_write_counts() == before
    end

    test "an explicit nil name falls back to Stride" do
      admin = admin_fixture()

      result = admin |> internal_org_opts(name: nil) |> Release.ensure_internal_organization()

      assert %{status: :ok, organization: %{name: "Stride", created: true}} = result
    end

    test "splits one comma-separated string of emails" do
      admin = admin_fixture()
      lead = user_fixture()
      second = user_fixture()

      result =
        admin
        |> internal_org_opts(org_admin_emails: " #{lead.email},#{second.email} , ")
        |> Release.ensure_internal_organization()

      assert result.appointed == [lead.email, second.email]
      assert result.skipped_unknown == []
    end

    test "refuses org_admin_emails that is neither a list nor a string and writes nothing" do
      admin = admin_fixture()
      lead = user_fixture()
      before = org_write_counts()

      for emails <- [%{email: lead.email}, :lead, 42] do
        result =
          admin
          |> internal_org_opts(org_admin_emails: emails)
          |> Release.ensure_internal_organization()

        assert result == %{status: :refused, reason: :invalid_org_admin_emails}
      end

      assert org_write_counts() == before
    end

    test "holds an advisory lock for the whole run, so concurrent runs cannot both create" do
      admin = admin_fixture()
      test_pid = self()
      handler = "internal-org-lock-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kanban, :repo, :query],
        fn _event, _measurements, %{query: query}, _ -> send(test_pid, {:query, query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      admin |> internal_org_opts([]) |> Release.ensure_internal_organization()

      queries = collect_queries([])
      lock_at = Enum.find_index(queries, &(&1 =~ "pg_advisory_lock"))
      insert_at = Enum.find_index(queries, &(&1 =~ ~s(INSERT INTO "organizations")))
      unlock_at = Enum.find_index(queries, &(&1 =~ "pg_advisory_unlock"))

      assert is_integer(lock_at)
      assert lock_at < insert_at
      assert insert_at < unlock_at
      assert unlock_at == length(queries) - 1
    end

    defp collect_queries(acc) do
      receive do
        {:query, query} -> collect_queries([query | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "never calls Mix, so it runs in a release" do
      for path <- [
            "../../lib/kanban/release.ex",
            "../../lib/kanban/release/internal_organization.ex"
          ] do
        source = path |> Path.expand(__DIR__) |> File.read!()
        refute source =~ ~r/\bMix\./, "#{path} calls Mix"
      end
    end
  end

  test "audit_log_boot_check logs one warning naming the reasons when degraded and nothing when hardened" do
    Application.put_env(:kanban, :audit_log_boot_check, true)
    degraded = {:degraded, [:not_superuser, :owner_role_missing]}

    log =
      capture_log(fn -> assert Release.audit_log_boot_check(fn -> degraded end) == degraded end)

    assert length(String.split(log, "security_audit_boot_check_degraded")) == 2
    assert log =~ "security_audit_boot_check_degraded reason=not_superuser,owner_role_missing"

    quiet =
      capture_log(fn -> assert Release.audit_log_boot_check(fn -> :hardened end) == :hardened end)

    refute quiet =~ "security_audit"
  end

  test "audit_log_boot_check is a no-op when the flag is unset and swallows a failing status check" do
    test_pid = self()
    tracked = fn -> send(test_pid, :status_checked) end

    assert Release.audit_log_boot_check(tracked) == :skipped
    Application.put_env(:kanban, :audit_log_boot_check, false)
    assert Release.audit_log_boot_check(tracked) == :skipped
    refute_received :status_checked

    Application.put_env(:kanban, :audit_log_boot_check, true)

    raising =
      capture_log(fn ->
        assert Release.audit_log_boot_check(fn -> raise RuntimeError, @fake_password end) ==
                 :failed
      end)

    assert raising =~ "security_audit_boot_check_failed exception=RuntimeError"
    refute raising =~ @fake_password

    exiting =
      capture_log(fn ->
        assert Release.audit_log_boot_check(fn -> exit(@fake_password) end) == :failed
      end)

    assert exiting =~ "security_audit_boot_check_failed kind=exit"
    refute exiting =~ @fake_password

    throwing =
      capture_log(fn ->
        assert Release.audit_log_boot_check(fn -> throw(@fake_password) end) == :failed
      end)

    assert throwing =~ "security_audit_boot_check_failed kind=throw"
    refute throwing =~ @fake_password
  end

  test "config/prod.exs enables the audit log boot check" do
    source = "../../config/prod.exs" |> Path.expand(__DIR__) |> File.read!()

    assert source =~ ~r/^config :kanban, :audit_log_boot_check, true$/m

    for env <- ["dev", "test"] do
      other = "../../config/#{env}.exs" |> Path.expand(__DIR__) |> File.read!()
      refute other =~ "audit_log_boot_check"
    end
  end

  describe "send_launch_announcement/1" do
    @key "organizations-launch"

    defp disable_user(user) do
      User
      |> where(id: ^user.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])
    end

    test "a dry run returns the eligible recipient count and enqueues nothing" do
      user = user_fixture()
      attach_telemetry([:kanban, :announcement, :fanout_completed])

      assert {:ok, result} = Release.send_launch_announcement(key: @key, dry_run: true)

      assert %{announcement: @key, dry_run: true, enqueued: 0} = result
      assert result.recipients == length(Announcement.list_recipients())
      assert user.id in Announcement.list_recipients()
      assert all_enqueued(worker: AnnouncementWorker) == []
      refute_received {:telemetry_event, [:kanban, :announcement, :fanout_completed], _, _}
    end

    test "enqueues one job per confirmed, enabled user, and a re-run adds none" do
      user = user_fixture()
      disabled = user_fixture()
      disable_user(disabled)
      unconfirmed = unconfirmed_user_fixture()

      assert {:ok, first} = Release.send_launch_announcement(key: @key)
      recipients = first.recipients

      assert %{dry_run: false, enqueued: ^recipients, already_enqueued: 0} = first
      assert_enqueued(worker: AnnouncementWorker, args: %{user_id: user.id, key: @key})
      refute_enqueued(worker: AnnouncementWorker, args: %{user_id: disabled.id, key: @key})
      refute_enqueued(worker: AnnouncementWorker, args: %{user_id: unconfirmed.id, key: @key})

      assert {:ok, %{enqueued: 0, already_enqueued: ^recipients}} =
               Release.send_launch_announcement(key: @key)

      assert length(all_enqueued(worker: AnnouncementWorker)) == recipients
    end

    test "a misspelled option or a non-boolean dry_run raises and enqueues nothing" do
      user_fixture()

      for opts <- [[dryrun: true], [dry: true], [dry_run: "true"]] do
        assert_raise ArgumentError, fn ->
          Release.send_launch_announcement([key: @key] ++ opts)
        end
      end

      assert all_enqueued(worker: AnnouncementWorker) == []
    end

    test "refuses an unknown or missing key and enqueues nothing" do
      user_fixture()

      assert Release.send_launch_announcement(key: "nope") == {:error, :unknown_announcement}
      assert Release.send_launch_announcement([]) == {:error, :unknown_announcement}
      assert all_enqueued(worker: AnnouncementWorker) == []
    end

    test "starts an insert-only Oban when none runs and stops it afterwards" do
      user = user_fixture()
      name = :w2416_release_oban
      assert Oban.whereis(name) == nil

      assert {:ok, %{enqueued: enqueued}} =
               Release.send_launch_announcement(key: @key, oban: name)

      assert enqueued == length(Announcement.list_recipients())
      assert_enqueued(worker: AnnouncementWorker, args: %{user_id: user.id, key: @key})
      assert Oban.whereis(name) == nil
    end
  end

  describe "reseed_audit_stream_cursors/0" do
    @reseeded "audit_stream_cursors_reseeded"
    @last_at ~U[2026-11-05 10:00:00.123456Z]

    # A cursor as a destination's would be on the old server: well past
    # every new txid, with a pending batch and a stale lease.
    defp moved_cursor(destination, fields \\ []) do
      defaults = [
        last_txid: 900_000_000,
        last_event_id: 4_242,
        last_inserted_at: @last_at,
        pending_batch_id: Ecto.UUID.generate(),
        pending_first_txid: 900_000_001,
        pending_first_id: 4_243,
        pending_last_txid: 900_000_009,
        pending_last_id: 4_250,
        pending_attempts: 3,
        pending_filter_version: 1,
        next_attempt_at: ~U[2026-11-05 11:00:00.000000Z]
      ]

      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(set: Keyword.merge(defaults, fields))
    end

    defp set_destination(destination, fields),
      do: from(d in Destination, where: d.id == ^destination.id) |> Repo.update_all(set: fields)

    defp cursor(destination), do: Repo.get!(Cursor, destination.id)
    defp fresh(destination), do: Repo.get!(Destination, destination.id)

    defp reseeded_events(organization) do
      from(e in AuditEvent,
        where: e.organization_id == ^organization.id and e.action == @reseeded,
        order_by: e.id
      )
      |> Repo.all()
    end

    # `txid` can only be chosen with raw SQL: the schema never writes it.
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

    # One past the latest completed transaction: every committed row of this
    # server has a lower txid, so a row below it is never taken as restored.
    # Unlike own_txid/0 it is safe under concurrent transactions, whose ids
    # can sit on either side of the test's own.
    defp xmax do
      %{rows: [[xmax]]} =
        Repo.query!("SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint")

      xmax
    end

    test "reseed sets (0, 0) and not_before from last_inserted_at" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      moved_cursor(destination, lease_token: Ecto.UUID.generate(), leased_until: nil)

      assert {:ok, %{organizations: 1, destinations: 1, busy: 0}} =
               Release.reseed_audit_stream_cursors()

      cursor = cursor(destination)
      assert {cursor.last_txid, cursor.last_event_id} == {0, 0}
      assert cursor.not_before == @last_at
      assert cursor.last_inserted_at == @last_at

      for field <- [
            :pending_batch_id,
            :pending_first_txid,
            :pending_first_id,
            :pending_last_txid,
            :pending_last_id,
            :pending_filter_version,
            :next_attempt_at,
            :lease_token,
            :leased_until
          ] do
        assert Map.fetch!(cursor, field) == nil, "#{field} was not cleared"
      end

      assert cursor.pending_attempts == 0
    end

    test "destination never delivered uses its inserted_at" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :splunk_hec)
      moved_cursor(destination, last_inserted_at: nil)

      assert {:ok, %{destinations: 1}} = Release.reseed_audit_stream_cursors()

      assert DateTime.compare(cursor(destination).not_before, destination.inserted_at) == :eq
    end

    test "clears txid_reset and keeps rejected_batch" do
      organization = organization_fixture()
      moved = destination_fixture(organization, :https)
      rejected = destination_fixture(organization, :datadog)
      blocked = destination_fixture(organization, :splunk_hec)

      for {destination, reason} <- [
            {moved, :txid_reset},
            {rejected, :rejected_batch},
            {blocked, :blocked_address}
          ] do
        moved_cursor(destination)
        set_destination(destination, halted_reason: reason, state: :failing)
      end

      assert {:ok, %{organizations: 1, destinations: 3, busy: 0}} =
               Release.reseed_audit_stream_cursors()

      assert fresh(moved).halted_reason == nil
      assert fresh(rejected).halted_reason == :rejected_batch
      assert fresh(blocked).halted_reason == :blocked_address

      # The state stays Failing until the next delivery recovers it, and no
      # longer asks for a re-seed.
      assert fresh(moved).state == :failing
      assert fresh(moved).state_reason == Kanban.AuditStream.Outcome.reseeded_reason()

      # Every cursor moves, so a halt a person clears later starts right.
      for destination <- [moved, rejected, blocked] do
        assert {cursor(destination).last_txid, cursor(destination).pending_batch_id} == {0, nil}
      end
    end

    test "no destinations returns zero counts" do
      organization = organization_fixture()

      assert {:ok, %{organizations: 0, destinations: 0, busy: 0}} =
               Release.reseed_audit_stream_cursors()

      assert reseeded_events(organization) == []
      assert AuditLog.list_events(action: :audit_stream_cursors_reseeded) == []
    end

    test "records one audit event per Organization" do
      attach_telemetry([:kanban, :audit, :audit_stream_cursors_reseeded])
      first = organization_fixture()
      second = organization_fixture()
      _none = organization_fixture()

      for destination <- [
            destination_fixture(first, :https),
            destination_fixture(first, :datadog),
            destination_fixture(second, :splunk_hec)
          ],
          do: moved_cursor(destination)

      assert {:ok, %{organizations: 2, destinations: 3, busy: 0}} =
               Release.reseed_audit_stream_cursors()

      assert [%AuditEvent{actor_user_id: nil, metadata: %{"destinations" => 2}}] =
               reseeded_events(first)

      assert [%AuditEvent{actor_user_id: nil, metadata: %{"destinations" => 1}}] =
               reseeded_events(second)

      first_id = first.id
      second_id = second.id

      assert_receive {:telemetry_event, [:kanban, :audit, :audit_stream_cursors_reseeded], _,
                      %{organization_id: ^first_id, destinations: 2}}

      assert_receive {:telemetry_event, [:kanban, :audit, :audit_stream_cursors_reseeded], _,
                      %{organization_id: ^second_id, destinations: 1}}
    end

    test "after reseed Reader.next_batch starts at the last delivered event's time" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)

      # The sandbox's own txid stands for the new server's horizon, so rows
      # this test writes through Repo (the fixtures, the re-seed's own event)
      # stay above it. Restored rows keep the old server's higher txids; a
      # row written on the new server after the move gets a lower one.
      horizon = own_txid()
      _older = event!(organization, horizon - 2, ~N[2026-11-05 09:00:00.000000])
      last = event!(organization, horizon - 1, ~N[2026-11-05 10:00:00.123456])
      newer = event!(organization, 2, ~N[2026-11-05 12:00:00.000000])
      moved_cursor(destination, last_txid: horizon - 1, last_event_id: last)

      before = cursor(destination)

      assert Reader.next_batch(organization.id, {before.last_txid, before.last_event_id},
               horizon: horizon
             ) == []

      assert {:ok, %{destinations: 1}} = Release.reseed_audit_stream_cursors()

      after_reseed = cursor(destination)

      ids =
        organization.id
        |> Reader.next_batch({after_reseed.last_txid, after_reseed.last_event_id},
          horizon: horizon,
          not_before: after_reseed.not_before
        )
        |> Enum.map(& &1.id)

      # The new row first (lower txid), then the last delivered one again;
      # nothing before the move point.
      assert ids == [newer, last]
    end

    defp gaps(destination),
      do: from(g in Gap, where: g.destination_id == ^destination.id) |> Repo.all()

    # Every id the re-seeded cursor reads once the new server's txids are far
    # past the restored ones.
    defp readable_ids(organization, destination) do
      cursor = cursor(destination)
      filters = destination |> fresh() |> PendingBatch.filters(cursor)

      organization.id
      |> Reader.next_batch(
        {cursor.last_txid, cursor.last_event_id},
        [horizon: own_txid() + 10_000_000, batch_size: 1_000] ++ filters
      )
      |> Enum.map(& &1.id)
    end

    test "restored events not delivered before the dump are recorded as a gap and never read" do
      attach_telemetry([:kanban, :audit_stream, :gap_recorded])
      organization = organization_fixture()
      destination = destination_fixture(organization, :datadog)
      caught_up = destination_fixture(organization, :https)

      # Restored rows keep the old server's txids, above every new one.
      old = own_txid() + 1_000_000
      delivered = event!(organization, old, @last_at)
      # One microsecond older than the last delivered event, committed after it.
      older = event!(organization, old + 3, ~N[2026-11-05 10:00:00.123455])
      held = event!(organization, old + 5, ~N[2026-11-05 11:00:00.000000])
      # Written on the new server after the move.
      written_after = event!(organization, 2, ~N[2026-11-06 09:00:00.000000])

      moved_cursor(destination, last_txid: old, last_event_id: delivered)

      moved_cursor(caught_up,
        last_txid: old + 5,
        last_event_id: held,
        last_inserted_at: ~U[2026-11-05 11:00:00.000000Z],
        pending_batch_id: nil
      )

      assert {:ok, %{organizations: 1, destinations: 2, busy: 0}} =
               Release.reseed_audit_stream_cursors()

      assert [gap] = gaps(destination)
      assert gap.reason == :database_move
      assert gap.events == 2
      assert gap.first_occurred_at == ~U[2026-11-05 10:00:00.123455Z]
      assert gap.last_occurred_at == ~U[2026-11-05 11:00:00.000000Z]
      assert gaps(caught_up) == []

      destination_id = destination.id

      assert [%AuditEvent{metadata: %{"events" => 2, "reason" => "database_move"}}] =
               from(e in AuditEvent,
                 where:
                   e.action == "audit_stream_gap" and
                     fragment("(?->>'destination_id')::bigint", e.metadata) == ^destination_id
               )
               |> Repo.all()

      assert_receive {:telemetry_event, [:kanban, :audit_stream, :gap_recorded], %{events: 2},
                      %{kind: :datadog, reason: :database_move}}

      refute_receive {:telemetry_event, [:kanban, :audit_stream, :gap_recorded], _,
                      %{kind: :https}}

      for target <- [destination, caught_up] do
        cursor = cursor(target)
        assert cursor.restored_max_event_id == held
        # The snapshot's xmax: below every restored txid.
        assert cursor.restored_min_txid in 1..old

        ids = readable_ids(organization, target)
        assert written_after in ids
        for restored <- [delivered, older, held], do: refute(restored in ids)
      end
    end

    test "an undelivered event older than the last delivered one is a gap, not a skip" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)

      # No restored txid above the new ones: the move kept the txids low, so
      # only not_before can leave an event behind.
      horizon = xmax()
      delivered = event!(organization, horizon - 3, @last_at)
      older = event!(organization, horizon - 2, ~N[2026-11-05 10:00:00.123455])
      newer = event!(organization, horizon - 1, ~N[2026-11-05 12:00:00.000000])
      moved_cursor(destination, last_txid: horizon - 3, last_event_id: delivered)

      assert {:ok, %{destinations: 1}} = Release.reseed_audit_stream_cursors()

      assert [%Gap{reason: :database_move, events: 1, first_occurred_at: first_at}] =
               gaps(destination)

      assert first_at == ~U[2026-11-05 10:00:00.123455Z]
      assert cursor(destination).restored_max_event_id == nil

      ids = readable_ids(organization, destination)
      assert newer in ids
      refute older in ids
    end

    # Created on the new server (or already re-seeded and delivering there),
    # nothing about the move is behind its cursor.
    test "a cursor the move did not leave behind is left as it was" do
      organization = organization_fixture()
      old = own_txid() + 1_000_000
      event!(organization, old, @last_at)
      created_after = destination_fixture(organization, :https)
      delivering = destination_fixture(organization, :datadog)
      new_event = event!(organization, xmax() - 5, ~N[2026-11-05 09:00:00.000000])
      at = xmax() - 10

      from(c in Cursor, where: c.destination_id == ^created_after.id)
      |> Repo.update_all(set: [last_txid: at, last_event_id: 0])

      moved_cursor(delivering,
        last_txid: xmax() - 6,
        last_event_id: new_event - 1,
        pending_batch_id: nil,
        pending_first_txid: nil,
        pending_first_id: nil,
        pending_last_txid: nil,
        pending_last_id: nil,
        pending_attempts: 0,
        pending_filter_version: nil
      )

      before = {cursor(created_after), cursor(delivering)}

      assert {:ok, %{organizations: 0, destinations: 0, busy: 0}} =
               Release.reseed_audit_stream_cursors(dry_run: true)

      assert {:ok, %{organizations: 0, destinations: 0, busy: 0}} =
               Release.reseed_audit_stream_cursors()

      assert {cursor(created_after), cursor(delivering)} == before
      assert gaps(created_after) == [] and gaps(delivering) == []
      assert new_event in readable_ids(organization, delivering)
      assert reseeded_events(organization) == []
    end

    # A clock behind the old server's stamps a new event before not_before;
    # its txid sorts before the old position, so only its id tells it apart.
    test "a new-server event stamped before the restart time is in the gap" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      old = own_txid() + 1_000_000
      delivered = event!(organization, old, @last_at)
      moved_cursor(destination, last_txid: old, last_event_id: delivered)
      skewed = event!(organization, xmax() - 5, ~N[2026-11-05 10:00:00.123455])
      later = event!(organization, xmax() - 4, ~N[2026-11-05 12:00:00.000000])

      assert {:ok, %{destinations: 1}} = Release.reseed_audit_stream_cursors()

      assert [%Gap{reason: :database_move, events: 1, first_occurred_at: first_at}] =
               gaps(destination)

      assert first_at == ~U[2026-11-05 10:00:00.123455Z]
      ids = readable_ids(organization, destination)
      assert later in ids
      refute skewed in ids
    end

    # A second move: the earlier bound's rows predate the new not_before, so
    # the new bound replaces it rather than spanning the ids between them.
    test "a later move replaces the bound instead of widening it" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      earlier = event!(organization, 1, ~N[2026-11-01 10:00:00.000000])
      between = event!(organization, xmax() - 5, ~N[2026-11-06 10:00:00.000000])
      old = own_txid() + 1_000_000
      restored = event!(organization, old + 5, ~N[2026-11-06 11:00:00.000000])

      moved_cursor(destination,
        last_txid: old,
        last_event_id: 0,
        last_inserted_at: ~U[2026-11-06 09:00:00.000000Z],
        restored_max_event_id: earlier,
        restored_min_txid: xmax() - 50
      )

      assert {:ok, %{destinations: 1}} = Release.reseed_audit_stream_cursors()

      cursor = cursor(destination)
      assert cursor.restored_max_event_id == restored
      assert cursor.restored_min_txid > xmax() - 50
      assert [%Gap{events: 1}] = gaps(destination)
      assert between in readable_ids(organization, destination)
    end

    test "running the re-seed again records nothing twice and keeps the bound" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      old = own_txid() + 1_000_000
      delivered = event!(organization, old, @last_at)
      held = event!(organization, old + 5, ~N[2026-11-05 11:00:00.000000])
      moved_cursor(destination, last_txid: old, last_event_id: delivered)

      assert {:ok, %{destinations: 1}} = Release.reseed_audit_stream_cursors()
      first = cursor(destination)
      # Re-seeded to (0, 0), it is no longer left behind.
      assert {:ok, %{destinations: 0}} = Release.reseed_audit_stream_cursors()

      assert [%Gap{events: 1}] = gaps(destination)
      second = cursor(destination)

      assert {second.restored_max_event_id, second.restored_min_txid} ==
               {first.restored_max_event_id, first.restored_min_txid}

      assert second.restored_max_event_id == held
    end

    test "waits for a live lease and counts the destination as busy when it stays held" do
      organization = organization_fixture()
      held = destination_fixture(organization, :https)
      free = destination_fixture(organization, :datadog)
      moved_cursor(held)
      moved_cursor(free)
      {:ok, token} = Lease.take(held.id)

      log =
        capture_log(fn ->
          assert {:ok, %{organizations: 1, destinations: 1, busy: 1}} =
                   Release.reseed_audit_stream_cursors(lease_wait_ms: 30, lease_poll_ms: 10)
        end)

      assert log =~ "busy=1"
      assert cursor(held).last_txid == 900_000_000
      assert cursor(held).lease_token == token
      assert cursor(free).last_txid == 0
      assert [%AuditEvent{metadata: %{"destinations" => 1}}] = reseeded_events(organization)
    end

    test "takes a lease a stuck run left past leased_until" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)

      moved_cursor(destination,
        lease_token: Ecto.UUID.generate(),
        leased_until: ~U[2026-11-01 00:00:00.000000Z]
      )

      assert {:ok, %{destinations: 1, busy: 0}} =
               Release.reseed_audit_stream_cursors(lease_wait_ms: 30, lease_poll_ms: 10)

      assert cursor(destination).last_txid == 0
      assert cursor(destination).lease_token == nil
    end

    test "dry_run counts and writes nothing" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      moved_cursor(destination)
      set_destination(destination, halted_reason: :txid_reset)

      assert {:ok, %{organizations: 1, destinations: 1, busy: 0}} =
               Release.reseed_audit_stream_cursors(dry_run: true)

      assert cursor(destination).last_txid == 900_000_000
      assert fresh(destination).halted_reason == :txid_reset
      assert reseeded_events(organization) == []
    end

    test "logs counts only, never a URL, name or credential" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :splunk_hec)
      moved_cursor(destination)
      attrs = destination_attrs(:splunk_hec)
      # async: false, so the global level can be lowered for this test.
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, _} = Release.reseed_audit_stream_cursors()
        end)

      assert log =~
               "audit_stream_cursors_reseeded dry_run=false organizations=1 destinations=1 busy=0"

      refute log =~ destination.name
      refute log =~ "collector.example.com"
      refute log =~ "splunk-hec-token"
      refute log =~ attrs.url
    end

    test "an unknown option or a non-boolean dry_run raises and writes nothing" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      moved_cursor(destination)

      for opts <- [[dryrun: true], [dry: true], [dry_run: "true"], [lease_wait_ms: -1]] do
        assert_raise ArgumentError, fn -> Release.reseed_audit_stream_cursors(opts) end
      end

      assert cursor(destination).last_txid == 900_000_000
      assert reseeded_events(organization) == []
    end

    test "skips a destination deleted while waiting for its lease" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      moved_cursor(destination)
      {:ok, _token} = Lease.take(destination.id)

      # Shared sandbox (async: false): this process deletes the destination,
      # and so its cursor, while the re-seed waits on the lease.
      deleter =
        Elixir.Task.async(fn ->
          Process.sleep(50)
          from(d in Destination, where: d.id == ^destination.id) |> Repo.delete_all()
        end)

      assert {:ok, %{organizations: 0, destinations: 0, busy: 0}} =
               Release.reseed_audit_stream_cursors(lease_wait_ms: 5_000, lease_poll_ms: 10)

      assert {1, _} = Elixir.Task.await(deleter)
      assert reseeded_events(organization) == []
    end

    test "counts as busy a destination whose lease another run takes before the write" do
      organization = organization_fixture()
      taken = destination_fixture(organization, :https)
      held = destination_fixture(organization, :datadog)
      moved_cursor(taken)
      moved_cursor(held)
      {:ok, held_token} = Lease.take(held.id)
      other_run = Ecto.UUID.generate()

      # While the re-seed waits on `held`, another run takes over the lease it
      # already holds on `taken`, then the holder of `held` lets go.
      intruder =
        Elixir.Task.async(fn ->
          Process.sleep(50)

          from(c in Cursor, where: c.destination_id == ^taken.id)
          |> Repo.update_all(set: [lease_token: other_run])

          Lease.release(held.id, held_token)
        end)

      assert {:ok, %{organizations: 1, destinations: 1, busy: 1}} =
               Release.reseed_audit_stream_cursors(lease_wait_ms: 5_000, lease_poll_ms: 10)

      assert :ok = Elixir.Task.await(intruder)
      assert cursor(taken).last_txid == 900_000_000
      assert cursor(taken).lease_token == other_run
      assert cursor(held).last_txid == 0
      assert [%AuditEvent{metadata: %{"destinations" => 1}}] = reseeded_events(organization)
    end

    # The restored bound hides ids at or below it, so an id sequence that was
    # not restored would hide the new server's events and count them nowhere.
    test "refuses, changing nothing, when the id sequence is behind the highest event id" do
      organization = organization_fixture()
      destination = destination_fixture(organization, :https)
      moved_cursor(destination)

      %{rows: [[ahead]]} =
        Repo.query!("""
        SELECT COALESCE(pg_sequence_last_value(pg_get_serial_sequence('audit_events', 'id')::regclass), 0)
        """)

      # As if restored without its sequence: an id the sequence never drew.
      Repo.query!(
        """
        INSERT INTO audit_events (id, action, organization_id, metadata, inserted_at)
        VALUES ($1, 'organization_updated', $2, '{}', now())
        """,
        [ahead + 1_000_000_000, organization.id]
      )

      for opts <- [[dry_run: true], []] do
        assert_raise RuntimeError, ~r/id sequence is behind/, fn ->
          Release.reseed_audit_stream_cursors(opts)
        end
      end

      assert cursor(destination).last_txid == 900_000_000
      assert cursor(destination).lease_token == nil
      assert reseeded_events(organization) == []
      assert gaps(destination) == []
    end

    test "the roles doc has the re-seed runbook section" do
      doc = File.read!("docs/audit-log-database-roles.md")

      [_, section] =
        String.split(doc, "\n## Re-seeding audit streaming after a logical database move\n")

      [section | _] = String.split(section, "\n## ")
      prose = String.replace(section, ~r/\s+/, " ")

      assert section =~ "Kanban.Release.reseed_audit_stream_cursors(dry_run: true)"
      assert section =~ "Kanban.Release.reseed_audit_stream_cursors() |> IO.inspect()"
      assert prose =~ "a Fly Managed Postgres failover keeps them, so neither needs this step"

      assert prose =~
               "make the re-seed a step of every logical move, whatever the destinations show"

      assert prose =~ "**Before the dump**"
      assert prose =~ "events at the exact time of its last delivery may arrive twice"
    end
  end
end
