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

  Log lines from this module carry reason atoms and exception types only,
  never the admin URL, its host or its password.
  """

  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.Repo

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
  app pool), runs `Kanban.AuditLog.Hardening.apply/2` and then
  `Kanban.AuditLog.Hardening.Purge.apply/3` in hardened mode inside one
  transaction, and stops the connection in every outcome. Safe to run again.

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
  `Kanban.AuditLog.Hardening.status/2` and
  `Kanban.AuditLog.Hardening.Purge.status/2`. Dev and test connect as a
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
      {:ok, combined_status(runner, app_role)}
    else
      {:error, :admin_not_superuser}
    end
  end

  defp combined_status(runner, app_role) do
    reasons =
      [Hardening.status(runner, app_role: app_role), Purge.status(runner, app_role: app_role)]
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
