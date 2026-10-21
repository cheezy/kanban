defmodule Kanban.AuditLog.Hardening.OrganizationPurge do
  @moduledoc """
  The database side of the Organization-scoped audit retention purge, installed
  beside `audit_events_purge` and reached through
  `Kanban.AuditLog.Hardening.Purge`'s `*_organization` functions.

  `audit_events_purge_organization(org_id bigint, cutoff timestamptz,
  batch_limit integer)` removes at most `batch_limit` rows whose `inserted_at`
  is strictly older than `cutoff`: the rows of Organization `org_id`, or, when
  `org_id` is `NULL`, only the rows that have no Organization. It never removes
  another Organization's rows. It returns how many rows it removed, so a caller
  loops until a batch comes back short.

  Like `audit_events_purge` it refuses (SQLSTATE `KAP01`) a cutoff that is
  `NULL` or newer than `now()` minus the 90-day retention floor, and refuses
  (SQLSTATE `22023`) a batch limit that is `NULL` or below 1. The floor lives in
  the function body, so even a compromised application cannot erase recent
  history through it. It runs with its owner's rights (`SECURITY DEFINER`), its
  `search_path` is pinned to `pg_catalog, pg_temp` with the table
  schema-qualified, and `PUBLIC` loses `EXECUTE` so only the application role
  can call it.

  It works under both trigger bodies `Kanban.AuditLog.Hardening.Purge`
  installs, and never replaces the trigger itself: in hardened mode the owner
  role owns it, so its delete runs as the table owner, which the owner-aware
  trigger admits; in degraded mode it sets the transaction-local
  `kanban.audit_purge` flag around its delete, as `audit_events_purge` does, and
  restores the previous value afterwards.

  The migration `add_audit_events_organization_purge_function` calls this live
  code, so a statement added here must not depend on an object a later
  migration creates.
  """

  import Kernel, except: [apply: 3]

  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLog.Hardening.Purge

  require Logger

  @table "audit_events"
  @function_name "audit_events_purge_organization"
  @signature "#{@function_name}(bigint, timestamp with time zone, integer)"
  @flag "kanban.audit_purge"
  @pinned_search_path "pg_catalog, pg_temp"
  @invalid_batch_code "22023"

  @type mode :: Purge.mode()

  @typedoc "Why the Organization-scoped purge is not hardened."
  @type reason ::
          :not_superuser
          | :table_not_owned_by_owner_role
          | :schema_create_denied
          | :organization_purge_function_missing
          | :organization_purge_function_not_owned_by_owner_role
          | :organization_purge_function_not_security_definer
          | :organization_purge_function_search_path_not_pinned
          | :organization_purge_function_executable_by_public
          | :app_role_cannot_execute_organization_purge_function
          | :organization_purge_function_not_replaceable
          | :organization_purge_function_not_droppable

  @doc "The name of the database function."
  @spec function_name() :: String.t()
  def function_name, do: @function_name

  @doc """
  Installs the function for `:app_role`, idempotently, in `mode`.

  In `:hardened` mode the owner role (option `:owner_role`, default
  `Kanban.AuditLog.Hardening.owner_role/0`) owns it, which needs a superuser
  connection; in `:degraded` mode the app role does. In both modes `PUBLIC`
  loses `EXECUTE` and the app role is given it.
  """
  @spec apply(Hardening.runner(), mode(), keyword()) :: :ok
  def apply(runner, mode, opts) when mode in [:hardened, :degraded] do
    app = opts |> Keyword.fetch!(:app_role) |> Hardening.quote_ident()

    owner =
      if mode == :hardened,
        do: opts |> Keyword.get(:owner_role, Hardening.owner_role()) |> Hardening.quote_ident(),
        else: app

    schema = Purge.table_schema(runner)
    function = "#{schema}.#{@signature}"

    Enum.each(
      [
        function_statement(schema),
        "ALTER FUNCTION #{function} OWNER TO #{owner}",
        "REVOKE ALL ON FUNCTION #{function} FROM PUBLIC",
        "GRANT EXECUTE ON FUNCTION #{function} TO #{app}"
      ],
      runner
    )
  end

  @doc """
  Installs the hardened function when the connection is a superuser and the
  table already belongs to the owner role, then confirms it with `status/2`.
  Otherwise installs the degraded function when the connection may (it can
  create in the table's schema and the function is absent or already its own),
  and logs one degraded notice naming why. Never raises for lack of privilege.
  """
  @spec migrate_or_degrade(Hardening.runner(), keyword()) ::
          :hardened | {:degraded, [reason()]}
  def migrate_or_degrade(runner, opts) do
    superuser? = Hardening.hardenable?(runner)

    if superuser? and Purge.table_owned_by_owner_role?(runner, opts) do
      :ok = __MODULE__.apply(runner, :hardened, opts)

      case status(runner, opts) do
        :hardened -> :hardened
        {:degraded, reasons} -> degrade(reasons)
      end
    else
      reason = if superuser?, do: :table_not_owned_by_owner_role, else: :not_superuser
      install_degraded(runner, opts, reason)
    end
  end

  defp install_degraded(runner, opts, reason) do
    case install_blockers(runner) do
      [] ->
        :ok = __MODULE__.apply(runner, :degraded, opts)
        degrade([reason])

      blockers ->
        degrade([reason | blockers])
    end
  end

  @doc """
  The migration's down step: drops the function when the connection may. A
  function it cannot drop is left in place and named in one degraded notice.
  """
  @spec revert(Hardening.runner()) :: :reverted | {:degraded, [reason()]}
  def revert(runner) do
    function = "#{Purge.table_schema(runner)}.#{@signature}"

    [[exists?, ownable?]] =
      runner.("""
      SELECT to_regprocedure('#{function}') IS NOT NULL,
             #{Purge.ownable_sql("to_regprocedure('#{function}')")}
      """).rows

    cond do
      not exists? ->
        :reverted

      ownable? ->
        runner.("DROP FUNCTION #{function}")
        :reverted

      true ->
        degrade([:organization_purge_function_not_droppable])
    end
  end

  @doc """
  Reports whether the function is hardened for `:app_role`: the owner role
  (option `:owner_role`) owns it, it is `SECURITY DEFINER` with its
  `search_path` pinned, and `PUBLIC` cannot execute it but the app role can.
  A missing function reports only `:organization_purge_function_missing`.
  """
  @spec status(Hardening.runner(), keyword()) :: :hardened | {:degraded, [reason()]}
  def status(runner, opts) do
    app = Keyword.fetch!(opts, :app_role)
    owner = Keyword.get(opts, :owner_role, Hardening.owner_role())

    %{rows: [row]} = runner |> Purge.table_schema() |> status_sql(app, owner) |> runner.()

    case status_reasons(row) do
      [] -> :hardened
      reasons -> {:degraded, reasons}
    end
  end

  defp status_reasons([false = _exists?, _, _, _, _, _]),
    do: [:organization_purge_function_missing]

  defp status_reasons([true, owned?, definer?, pinned?, public?, app_can?]) do
    collect([
      {owned? != true, :organization_purge_function_not_owned_by_owner_role},
      {not definer?, :organization_purge_function_not_security_definer},
      {not pinned?, :organization_purge_function_search_path_not_pinned},
      {public?, :organization_purge_function_executable_by_public},
      {not app_can?, :app_role_cannot_execute_organization_purge_function}
    ])
  end

  # Two DELETE branches rather than `IS NOT DISTINCT FROM`, so each can use the
  # (organization_id, inserted_at) index. The flag is set with set_config, as
  # in audit_events_purge, because a non-superuser cannot attach a SET clause
  # for a custom setting.
  defp function_statement(schema) do
    floor = Purge.retention_floor_days()

    """
    CREATE OR REPLACE FUNCTION #{schema}.#{@function_name}(
      org_id bigint, cutoff timestamp with time zone, batch_limit integer)
    RETURNS bigint
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = #{@pinned_search_path}
    AS $purge_org$
    DECLARE
      prior_flag text := current_setting('#{@flag}', true);
      removed bigint;
    BEGIN
      IF cutoff IS NULL OR cutoff > now() - interval '#{floor} days' THEN
        RAISE EXCEPTION 'audit_events purge refused: the cutoff must be at least #{floor} days old'
          USING ERRCODE = '#{Purge.cutoff_too_recent_code()}';
      END IF;

      IF batch_limit IS NULL OR batch_limit < 1 THEN
        RAISE EXCEPTION 'audit_events purge refused: the batch limit must be at least 1'
          USING ERRCODE = '#{@invalid_batch_code}';
      END IF;

      PERFORM set_config('#{@flag}', 'on', true);

      IF org_id IS NULL THEN
        DELETE FROM #{schema}.#{@table} WHERE id IN (
          SELECT e.id FROM #{schema}.#{@table} AS e
          WHERE e.organization_id IS NULL AND e.inserted_at < (cutoff AT TIME ZONE 'UTC')
          ORDER BY e.inserted_at, e.id
          LIMIT batch_limit);
      ELSE
        DELETE FROM #{schema}.#{@table} WHERE id IN (
          SELECT e.id FROM #{schema}.#{@table} AS e
          WHERE e.organization_id = org_id AND e.inserted_at < (cutoff AT TIME ZONE 'UTC')
          ORDER BY e.inserted_at, e.id
          LIMIT batch_limit);
      END IF;

      GET DIAGNOSTICS removed = ROW_COUNT;
      PERFORM set_config('#{@flag}', coalesce(prior_flag, ''), true);

      RETURN removed;
    END;
    $purge_org$
    """
  end

  defp status_sql(schema, app, owner) do
    role = Hardening.quote_literal(app)

    """
    SELECT
      p.oid IS NOT NULL,
      p.proowner = (SELECT oid FROM pg_roles WHERE rolname = #{Hardening.quote_literal(owner)}),
      coalesce(p.prosecdef, false),
      coalesce((SELECT bool_or(setting = 'search_path=#{@pinned_search_path}')
                FROM unnest(p.proconfig) AS setting), false),
      coalesce((SELECT bool_or(acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
                FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS acl), false),
      CASE
        WHEN p.oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{role}) THEN false
        ELSE has_function_privilege(#{role}, p.oid, 'EXECUTE')
      END
    FROM (SELECT to_regprocedure('#{schema}.#{@signature}') AS oid) AS f
    LEFT JOIN pg_proc AS p ON p.oid = f.oid
    """
  end

  defp install_blockers(runner) do
    [[create?, ownable?]] =
      runner.("""
      SELECT
        has_schema_privilege(current_user,
          (SELECT relnamespace FROM pg_class WHERE oid = to_regclass('#{@table}')), 'CREATE'),
        #{Purge.ownable_sql("to_regprocedure('#{Purge.table_schema(runner)}.#{@signature}')")}
      """).rows

    collect([
      {create? != true, :schema_create_denied},
      {ownable? != true, :organization_purge_function_not_replaceable}
    ])
  end

  defp collect(checks), do: for({true, reason} <- checks, do: reason)

  # Reasons are code-defined atoms, so they are safe in the message.
  defp degrade(reasons) do
    Logger.warning("security_audit_organization_purge_degraded reason=#{Enum.join(reasons, ",")}")

    {:degraded, reasons}
  end
end
