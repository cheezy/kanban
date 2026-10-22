defmodule Kanban.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  Besides `migrate/0` and `rollback/2`, this module carries the operator path
  for the audit log ownership hardening described in
  `docs/audit-log-database-roles.md`:

    * `harden_audit_log/0` hardens `audit_events` and its purge function over a
      separate, short-lived connection opened from an admin URL supplied only
      in the environment of that one command;
    * `audit_log_status/0` reports `:hardened` or `{:degraded, reasons}` for the
      application role through the app Repo;
    * `audit_log_boot_check/1` is started once after boot and logs one warning
      when the status is degraded. It is a no-op unless the
      `:audit_log_boot_check` flag is set, which only `config/prod.exs` does.

  It also carries `scan_credential_considerations/0`, the read-only report of
  stored `security_considerations` entries shaped like a credential (W2384),
  described in `docs/matrix-row-refusal-contract.md`, and
  `report_over_cap_boards/0`, the read-only report of personal-workspace boards
  over the free member cap (W2402), and `ensure_internal_organization/1`, which
  creates Stride's own Organization and appoints its org-admins (W2403), and
  `import_workspace/3`, the release counterpart of `mix kanban.import_workspace`
  (W2222), and `send_launch_announcement/1`, the one-time service announcement
  email (W2416).

  Log lines from this module carry reason atoms and exception types only,
  never the admin URL, its host or its password.
  """

  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.Boards
  alias Kanban.Boards.Membership
  alias Kanban.Notifications.Announcement
  alias Kanban.Release.InternalOrganization
  alias Kanban.Release.LaunchAnnouncement
  alias Kanban.Repo
  alias Kanban.Tasks.SecurityConsiderationsScan
  alias Kanban.Workspaces.Export.Importer

  require Logger

  @app :kanban
  @admin_url_env "AUDIT_LOG_ADMIN_DATABASE_URL"
  @admin_keys [:hostname, :port, :database, :username, :password]
  @harden_timeout :timer.minutes(5)
  @statement_timeout :timer.minutes(2)
  @connect_timeout :timer.seconds(10)
  # A contended lock fails fast as lock_not_available instead of queueing every
  # audit insert behind ALTER TABLE ... OWNER until the statement timeout.
  @lock_timeout "10s"

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Hardens the audit table and its purge function for the application role.

  Reads the admin URL from the `#{@admin_url_env}` environment variable, which
  the operator sets for this one command only — it is never stored as a Fly
  secret. Opens its own connection (one connection, no reconnect, never the
  app pool), runs `Kanban.AuditLog.Hardening.apply/2`, then
  `Kanban.AuditLog.Hardening.Purge.apply/3` and
  `Kanban.AuditLog.Hardening.Purge.apply_organization/3` in hardened mode inside
  one transaction, and stops the connection in every outcome. Safe to run again.

  Returns `{:ok, :hardened}` or `{:ok, {:degraded, reasons}}` with the status
  after hardening, or `{:error, tag}` where tag is one of:

    * `:admin_url_missing` — the variable is unset or blank;
    * `:admin_url_invalid` — the URL cannot be parsed, or names no user or host;
    * `:app_role_unknown` — the app Repo's user cannot be determined;
    * `:admin_is_app_role` — the admin URL's user is the application role;
    * `:admin_host_differs_without_tls` — the app connects without TLS and the
      admin URL names a different host, so the admin password would cross a
      network the app's own connection was never checked against;
    * `:admin_not_superuser` — the admin role is not a superuser;
    * `:admin_connection_failed` — the admin host could not be reached;
    * `:admin_timeout` — the command did not finish in time;
    * `:hardening_failed` — a statement failed; nothing was changed.

  `opts` are test seams only: `:app_role`, `:work` (a function of a runner and
  the app role) and `:timeout`.
  """
  @spec harden_audit_log(keyword()) ::
          {:ok, :hardened | {:degraded, [atom()]}} | {:error, atom()}
  def harden_audit_log(opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:postgrex)
    app_role = Keyword.get_lazy(opts, :app_role, &app_role/0)

    app_role
    |> admin_connection()
    |> run_hardening(app_role, opts)
    |> log_harden_result()
  end

  defp run_hardening({:ok, conn_opts}, app_role, opts) do
    work = Keyword.get(opts, :work, &apply_hardening/2)
    timeout = Keyword.get(opts, :timeout, @harden_timeout)
    run_isolated(fn -> admin_session(conn_opts, app_role, work) end, timeout)
  end

  defp run_hardening({:error, _tag} = refused, _app_role, _opts), do: refused

  # Every refusal happens here, before any connection is opened.
  defp admin_connection(app_role) do
    with {:ok, url} <- fetch_admin_url(),
         {:ok, admin} <- parse_admin_url(url),
         :ok <- check_roles(admin[:username], app_role),
         :ok <- check_transport(admin[:hostname]) do
      {:ok, admin_connection_opts(admin)}
    end
  end

  @doc """
  Reports whether the audit table and its purge function are hardened for the
  application role, checked through the app Repo.

  Returns `:hardened`, or `{:degraded, reasons}` combining the reasons from
  `Kanban.AuditLog.Hardening.status/2`,
  `Kanban.AuditLog.Hardening.Purge.status/2` and
  `Kanban.AuditLog.Hardening.Purge.organization_status/2`. Dev and test connect as a
  superuser, so there it reports `:app_role_is_superuser`.
  """
  @spec audit_log_status() :: :hardened | {:degraded, [atom()]}
  def audit_log_status do
    load_app()

    {:ok, status, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        combined_status(fn sql -> repo.query!(sql) end, app_role())
      end)

    status
  end

  @doc """
  Reports every stored task whose `security_considerations` carries a
  credential-shaped entry, through the app Repo.

  Runs `Kanban.Tasks.SecurityConsiderationsScan.scan_stored/0` and returns its
  report: one map per matching task with `:identifier`, `:task_id` and the
  1-based `:positions` of the matching entries, or `[]`. Read-only — it never
  writes or prints, and neither the report nor a log line carries a matched
  value. Run it
  with `bin/kanban eval` and pipe the result to `IO.inspect/1`; an operator
  edits any hit by hand.
  """
  @spec scan_credential_considerations() :: [SecurityConsiderationsScan.stored_hit()]
  def scan_credential_considerations do
    load_app()

    {:ok, report, _} =
      Ecto.Migrator.with_repo(Repo, fn _repo -> SecurityConsiderationsScan.scan_stored() end)

    report
  end

  @doc """
  Reports every personal-workspace board with more members than
  `Kanban.Plans.free_board_member_cap/0`, through the app Repo — the release
  counterpart of `mix kanban.over_cap_boards`, which a release cannot run.

  Runs `Kanban.Boards.over_cap_boards/0` and returns its list: one map per
  board with `:board_id`, `:owner_user_id` (or `nil`) and `:member_count`, or
  `[]`. Read-only — it never writes or prints, and carries no board name, user
  name or email. Run it with `bin/kanban eval` and pipe the result to
  `IO.inspect/1`.
  """
  @spec report_over_cap_boards() :: [Membership.over_cap_board()]
  def report_over_cap_boards do
    load_app()

    {:ok, report, _} = Ecto.Migrator.with_repo(Repo, fn _repo -> Boards.over_cap_boards() end)

    report
  end

  @doc """
  Creates Stride's internal Organization once and appoints the listed existing
  users as its org-admins, acting as the named site admin, through the app
  Repo.

  Runs `Kanban.Release.InternalOrganization.ensure/1` and returns its summary
  map; that function documents the options and every result. All writes go
  through `Kanban.Organizations`, so its authorization check, telemetry and
  audit events apply. It provisions no accounts, and running it again with the
  same org-admin emails, or more, creates nothing and reports what already
  exists. An existing Organization of that name with no org-admin, or whose
  org-admins are not all site admins or listed emails, is refused with
  `:name_taken`. Run it with
  `bin/kanban eval`, for example:

      Kanban.Release.ensure_internal_organization(
        acting_admin_email: "admin@example.com",
        contact_name: "Ops",
        contact_email: "ops@example.com",
        org_admin_emails: ["lead@example.com"]
      )
      |> IO.inspect()

  Moving Stride's boards into the Organization's workspace is a separate step
  (the board move, G442 W2218), to be described in the launch runbook that
  W2417 adds.
  """
  @spec ensure_internal_organization(keyword() | map()) :: InternalOrganization.summary()
  def ensure_internal_organization(opts) do
    load_app()

    {:ok, summary, _} =
      Ecto.Migrator.with_repo(Repo, fn _repo -> InternalOrganization.ensure(opts) end)

    summary
  end

  @doc """
  Restores a workspace export archive into a new workspace of the
  Organization of the org-admin with `org_admin_email`, through the app Repo —
  the release counterpart of `mix kanban.import_workspace`, which a release
  cannot run.

  Runs `Kanban.Workspaces.Export.Importer.import_archive/3` and returns its
  result: `{:ok, report}` or `{:error, reason}`. Pass `dry_run: true` to check
  and count without writing. Only the database connection is started, so no
  job, broadcast or notification runs. Run it with `bin/kanban eval`, for
  example:

      Kanban.Release.import_workspace("/data/export.zip", "admin@example.com", dry_run: true)
      |> IO.inspect()
  """
  @spec import_workspace(String.t(), String.t(), keyword()) ::
          {:ok, Importer.report()} | {:error, term()}
  def import_workspace(path, org_admin_email, opts \\ []) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        Importer.import_archive(path, org_admin_email, opts)
      end)

    result
  end

  @doc """
  Emails the service announcement `opts[:key]` (such as
  `"organizations-launch"`) to every confirmed, enabled user, through the app
  Repo: one unique job per user, so running it again sends nothing twice.

  Runs `Kanban.Release.LaunchAnnouncement.send/1` and returns its result:
  `{:ok, counts}` or `{:error, :unknown_announcement}`. Pass `dry_run: true`
  to count the recipients and enqueue nothing; an unknown option or a
  non-boolean `:dry_run` raises first. Run it once with `bin/kanban rpc`:

      Kanban.Release.send_launch_announcement(key: "organizations-launch", dry_run: true)
      |> IO.inspect()
  """
  @spec send_launch_announcement(keyword()) ::
          {:ok, Announcement.result()} | {:error, :unknown_announcement}
  def send_launch_announcement(opts) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Repo, fn _repo -> LaunchAnnouncement.send(opts) end)

    result
  end

  @doc """
  Logs one warning naming the reasons when the audit log is degraded.

  Does nothing and returns `:skipped` unless the `:audit_log_boot_check`
  application flag is `true` (only `config/prod.exs` sets it). Never raises:
  a failing status check is logged by exception type or exit kind and
  returns `:failed`. `status_fun` is injectable for tests.
  """
  @spec audit_log_boot_check((-> :hardened | {:degraded, [atom()]})) ::
          :skipped | :hardened | {:degraded, [atom()]} | :failed
  def audit_log_boot_check(status_fun \\ &audit_log_status/0) do
    if Application.get_env(@app, :audit_log_boot_check, false) == true,
      do: run_boot_check(status_fun),
      else: :skipped
  end

  @doc false
  # The default hardening work, public only so the test can run it twice over
  # the sandbox. Table first: the hardened purge needs the owner role to own
  # the table already.
  @spec apply_hardening(Hardening.runner(), String.t()) ::
          {:ok, :hardened | {:degraded, [atom()]}} | {:error, :admin_not_superuser}
  def apply_hardening(runner, app_role) do
    if Hardening.hardenable?(runner) do
      :ok = Hardening.apply(runner, app_role: app_role)
      :ok = Purge.apply(runner, :hardened, app_role: app_role)
      :ok = Purge.apply_organization(runner, :hardened, app_role: app_role)
      {:ok, combined_status(runner, app_role)}
    else
      {:error, :admin_not_superuser}
    end
  end

  defp combined_status(runner, app_role) do
    reasons =
      [
        Hardening.status(runner, app_role: app_role),
        Purge.status(runner, app_role: app_role),
        Purge.organization_status(runner, app_role: app_role)
      ]
      |> Enum.flat_map(&status_reasons/1)
      |> Enum.uniq()

    if reasons == [], do: :hardened, else: {:degraded, reasons}
  end

  defp status_reasons(:hardened), do: []
  defp status_reasons({:degraded, reasons}), do: reasons

  defp run_boot_check(status_fun) do
    case status_fun.() do
      :hardened ->
        :hardened

      {:degraded, reasons} = degraded ->
        Logger.warning("security_audit_boot_check_degraded reason=#{Enum.join(reasons, ",")}")
        degraded
    end
  rescue
    exception ->
      Logger.warning(
        "security_audit_boot_check_failed exception=#{inspect(exception.__struct__)}"
      )

      :failed
  catch
    kind, _value ->
      Logger.warning("security_audit_boot_check_failed kind=#{kind}")
      :failed
  end

  defp fetch_admin_url do
    case System.get_env(@admin_url_env) do
      nil -> {:error, :admin_url_missing}
      url -> if String.trim(url) == "", do: {:error, :admin_url_missing}, else: {:ok, url}
    end
  end

  # Ecto.InvalidURLError carries the whole URL, password included, in its
  # message, so the exception is never bound, logged or inspected.
  defp parse_admin_url(url) do
    admin = url |> Ecto.Repo.Supervisor.parse_url() |> Keyword.take(@admin_keys)

    if present?(admin[:username]) and present?(admin[:hostname]),
      do: {:ok, admin},
      else: {:error, :admin_url_invalid}
  rescue
    _ -> {:error, :admin_url_invalid}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp check_roles(_admin_user, nil), do: {:error, :app_role_unknown}
  defp check_roles(same, same), do: {:error, :admin_is_app_role}
  defp check_roles(_admin_user, _app_role), do: :ok

  # The app's own host passed the plaintext guard in config/runtime.exs; any
  # other host has not, so without TLS the admin URL must name the same host.
  defp check_transport(admin_host) do
    config = Repo.config()

    if config[:ssl] in [nil, false] and admin_host != config[:hostname],
      do: {:error, :admin_host_differs_without_tls},
      else: :ok
  end

  defp admin_connection_opts(admin) do
    config = Repo.config()

    admin ++
      [
        ssl: config[:ssl] || false,
        socket_options: config[:socket_options] || [],
        pool_size: 1,
        backoff_type: :stop,
        max_restarts: 0,
        connect_timeout: @connect_timeout,
        queue_target: @connect_timeout,
        queue_interval: @connect_timeout,
        parameters: [application_name: "kanban_audit_harden", lock_timeout: @lock_timeout]
      ]
  end

  # Postgrex.start_link links the connection pool to its caller, and with
  # backoff_type: :stop a failed connect takes the pool down — so the session
  # runs in an unlinked, monitored process and its crash becomes an error tag.
  # The exit reason is never inspected.
  defp run_isolated(fun, timeout) do
    caller = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(caller, {ref, fun.()}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :admin_connection_failed}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :admin_timeout}
    end
  end

  defp admin_session(conn_opts, app_role, work) do
    case Postgrex.start_link(conn_opts) do
      {:ok, conn} -> run_admin_work(conn, app_role, work)
      {:error, _reason} -> {:error, :admin_connection_failed}
    end
  end

  defp run_admin_work(conn, app_role, work) do
    # One transaction: a failing statement leaves the database as it was.
    {:ok, result} =
      Postgrex.transaction(conn, fn tx -> work.(admin_runner(tx), app_role) end,
        timeout: @statement_timeout
      )

    result
  rescue
    DBConnection.ConnectionError ->
      {:error, :admin_connection_failed}

    exception ->
      Logger.error("security_audit_harden_failed #{describe_exception(exception)}")
      {:error, :hardening_failed}
  catch
    :exit, _reason -> {:error, :admin_connection_failed}
  after
    stop_connection(conn)
  end

  defp admin_runner(tx),
    do: fn sql -> Postgrex.query!(tx, sql, [], timeout: @statement_timeout) end

  defp describe_exception(%Postgrex.Error{postgres: %{code: code}}),
    do: "exception=Postgrex.Error code=#{code}"

  defp describe_exception(exception), do: "exception=#{inspect(exception.__struct__)}"

  defp stop_connection(conn) do
    GenServer.stop(conn)
  catch
    :exit, _reason -> :ok
  end

  defp log_harden_result({:ok, :hardened} = result) do
    Logger.info("security_audit_harden_result status=hardened")
    result
  end

  defp log_harden_result({:ok, {:degraded, reasons}} = result) do
    Logger.warning(
      "security_audit_harden_result status=degraded reason=#{Enum.join(reasons, ",")}"
    )

    result
  end

  defp log_harden_result({:error, tag} = result) do
    Logger.error("security_audit_harden_failed reason=#{tag}")
    result
  end

  defp app_role, do: Repo.config()[:username]

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
