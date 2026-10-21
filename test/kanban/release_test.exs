defmodule Kanban.ReleaseTest do
  # async: false — these tests set an OS environment variable and the
  # :audit_log_boot_check application flag, both global to the VM, and harden
  # audit_events inside the sandbox, which locks the table until rollback.
  # setup/on_exit restore every value they touch.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.AuditLogRoleHelper
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
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
end
