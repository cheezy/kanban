defmodule Kanban.ReleaseTest do
  # async: false — these tests set an OS environment variable and the
  # :audit_log_boot_check application flag, both global to the VM, and harden
  # audit_events inside the sandbox, which locks the table until rollback.
  # setup/on_exit restore every value they touch.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog

  alias Kanban.AuditLogRoleHelper
  alias Kanban.Release

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

  test "hardening refuses an admin role that is not a superuser" do
    not_superuser = fn _sql -> %{rows: [[false]]} end

    assert {:error, :admin_not_superuser} = Release.apply_hardening(not_superuser, @other_role)
  end

  test "audit_log_status combines the table and purge checks and names app_role_is_superuser against the superuser test database" do
    # The table check alone names app_role_is_superuser and the purge check is
    # hardened, so the combined status carries exactly that one reason.
    assert Release.audit_log_status() == {:degraded, [:app_role_is_superuser]}
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
