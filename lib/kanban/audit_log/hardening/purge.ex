defmodule Kanban.AuditLog.Hardening.Purge do
  @moduledoc """
  The one sanctioned way to remove old rows from `audit_events`.

  The append-only trigger (see `Kanban.AuditLog.AuditEvent`) rejects every
  delete except a retention purge. This module installs the database side of
  that purge, sharing its runner shape and quoting with
  `Kanban.AuditLog.Hardening`:

    * **the purge function** `audit_events_purge(cutoff timestamptz)`. It
      refuses (SQLSTATE `KAP01`) a cutoff that is `NULL` or newer than
      `now()` minus the retention floor of 90 days, removes the rows whose
      `inserted_at` is strictly older than the cutoff, and returns how many it
      removed. The floor lives in the function body, so even a compromised
      application cannot erase recent history through it. It runs with its
      owner's rights (`SECURITY DEFINER`), its `search_path` is pinned to
      `pg_catalog, pg_temp` with the table schema-qualified (the application
      role may create objects in the table's schema, so that schema must not
      be on the path of code running with another role's rights), and the
      default `EXECUTE` right of `PUBLIC` is removed so only the application
      role can call it. It also sets the transaction-local `kanban.audit_purge`
      flag around its delete, which is what lets it through the degraded
      trigger, and restores the previous value afterwards.
    * **the owner-aware trigger body**, hardened mode only. A delete is allowed
      only when the current role is the role that owns `audit_events` (read
      from the catalog at run time, so no role name is embedded) and the
      delete is not itself fired from another trigger. The application cannot
      become the owner role, so in practice the owner-owned purge function is
      the only path; the purge flag is ignored. The update branch with its
      foreign-key nilify exception and the always-rejected `TRUNCATE` are
      unchanged.

  Changing the retention floor means replacing the function, which in hardened
  mode only the owner role or a superuser can do.

  ## Modes

    * `:hardened` — the owner role owns the purge function and the trigger
      uses the owner-aware body. Needs a superuser connection, like
      `Kanban.AuditLog.Hardening.apply/2`.
    * `:degraded` — the application role owns the purge function and the
      flag-based trigger body is left as it is, so `Kanban.AuditLog.purge_before/1`
      works in both modes.

  The migration `add_audit_events_purge_function` calls this live code through
  `migrate_or_degrade/2`, so a statement added here must not depend on an
  object a later migration creates.
  """

  import Kernel, except: [apply: 3]

  alias Kanban.AuditLog.Hardening

  require Logger

  @table "audit_events"
  @function_name "audit_events_purge"
  @signature "#{@function_name}(timestamp with time zone)"
  @trigger_function "audit_events_append_only()"
  @flag "kanban.audit_purge"
  @pinned_search_path "pg_catalog, pg_temp"
  @retention_floor_days 90
  @cutoff_too_recent_code "KAP01"

  @type mode :: :hardened | :degraded

  @typedoc "Why the purge is not hardened."
  @type reason ::
          :not_superuser
          | :table_not_owned_by_owner_role
          | :purge_function_missing
          | :purge_function_not_owned_by_owner_role
          | :purge_function_not_security_definer
          | :purge_function_search_path_not_pinned
          | :purge_function_executable_by_public
          | :app_role_cannot_execute_purge_function
          | :trigger_function_honors_flag
          | :purge_function_not_replaceable
          | :schema_create_denied
          | :purge_function_not_droppable
          | :trigger_function_not_replaceable

  @doc "Days of history the purge function always keeps."
  @spec retention_floor_days() :: pos_integer()
  def retention_floor_days, do: @retention_floor_days

  @doc "The SQLSTATE the purge function raises for a cutoff inside the retention floor."
  @spec cutoff_too_recent_code() :: String.t()
  def cutoff_too_recent_code, do: @cutoff_too_recent_code

  @doc """
  Installs the purge function for `:app_role`, idempotently, in `mode`.

  In `:hardened` mode the function is owned by the owner role (option
  `:owner_role`, default `Kanban.AuditLog.Hardening.owner_role/0`) and the
  trigger function gets the owner-aware body; this needs a superuser
  connection. In `:degraded` mode the function is owned by the app role and
  the trigger is not touched. In both modes `PUBLIC` loses `EXECUTE` and the
  app role is given it.
  """
  @spec apply(Hardening.runner(), mode(), keyword()) :: :ok
  def apply(runner, mode, opts) when mode in [:hardened, :degraded] do
    app = opts |> Keyword.fetch!(:app_role) |> Hardening.quote_ident()

    owner =
      if mode == :hardened,
        do: opts |> Keyword.get(:owner_role, Hardening.owner_role()) |> Hardening.quote_ident(),
        else: app

    schema = table_schema(runner)
    purge = "#{schema}.#{@signature}"

    Enum.each(
      [
        purge_function_statement(schema),
        "ALTER FUNCTION #{purge} OWNER TO #{owner}",
        "REVOKE ALL ON FUNCTION #{purge} FROM PUBLIC",
        "GRANT EXECUTE ON FUNCTION #{purge} TO #{app}"
      ] ++ trigger_statements(mode, runner),
      runner
    )
  end

  @doc """
  Installs the hardened purge when the connection is a superuser and the table
  already belongs to the owner role, then confirms it with `status/2`.
  Otherwise installs the degraded purge when the connection may (it can create
  in the table's schema and the function is absent or already its own), and
  logs one degraded notice naming why; when it may not, it changes nothing and
  the notice also names `:schema_create_denied` and/or
  `:purge_function_not_replaceable`. Never raises for lack of privilege.
  """
  @spec migrate_or_degrade(Hardening.runner(), keyword()) :: :hardened | {:degraded, [reason()]}
  def migrate_or_degrade(runner, opts) do
    superuser? = Hardening.hardenable?(runner)
    owned? = table_owned_by_owner_role?(runner, opts)

    if superuser? and owned? do
      :ok = __MODULE__.apply(runner, :hardened, opts)

      case status(runner, opts) do
        :hardened -> :hardened
        {:degraded, reasons} -> degrade(reasons)
      end
    else
      install_degraded(runner, opts, degraded_reason(superuser?))
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
  The migration's down step: drops the purge function and, when the trigger
  body is the owner-aware one, restores the flag-based body (the one
  `20261006153642_fix_audit_events_truncate_message` installed, with the
  search_path pin kept). Whatever the connection cannot own is left in place
  and named in one degraded notice instead of raising.
  """
  @spec revert(Hardening.runner()) :: :reverted | {:degraded, [reason()]}
  def revert(runner) do
    purge = "#{table_schema(runner)}.#{@signature}"
    facts = revert_facts(runner, purge)

    drop? = facts.purge_exists? and facts.purge_ownable?
    restore? = not facts.honors_flag? and facts.trigger_ownable?

    if drop?, do: runner.("DROP FUNCTION #{purge}")
    if restore?, do: runner |> trigger_schema() |> flag_trigger_statement() |> runner.()

    case collect([
           {facts.purge_exists? and not drop?, :purge_function_not_droppable},
           {not facts.honors_flag? and not restore?, :trigger_function_not_replaceable}
         ]) do
      [] -> :reverted
      reasons -> degrade(reasons)
    end
  end

  @doc """
  Reports whether the purge is hardened for `:app_role`.

  Returns `:hardened`, or `{:degraded, reasons}`. A missing purge function
  reports only `:purge_function_missing` (plus `:trigger_function_honors_flag`
  when the trigger still trusts the flag). Otherwise it checks that the owner
  role (option `:owner_role`) owns the function, that it is `SECURITY
  DEFINER` with its `search_path` pinned, that `PUBLIC` cannot execute it but
  the app role can, and that the trigger body no longer honours the flag.
  """
  @spec status(Hardening.runner(), keyword()) :: :hardened | {:degraded, [reason()]}
  def status(runner, opts) do
    app = Keyword.fetch!(opts, :app_role)
    owner = Keyword.get(opts, :owner_role, Hardening.owner_role())

    %{rows: [row]} = runner |> table_schema() |> status_sql(app, owner) |> runner.()

    case status_reasons(row) do
      [] -> :hardened
      reasons -> {:degraded, reasons}
    end
  end

  defp status_reasons([false = _exists?, _, _, _, _, _, honors_flag?]),
    do: collect([{true, :purge_function_missing}, {honors_flag?, :trigger_function_honors_flag}])

  defp status_reasons([true, owned?, definer?, pinned?, public?, app_can?, honors_flag?]) do
    collect([
      {owned? != true, :purge_function_not_owned_by_owner_role},
      {not definer?, :purge_function_not_security_definer},
      {not pinned?, :purge_function_search_path_not_pinned},
      {public?, :purge_function_executable_by_public},
      {not app_can?, :app_role_cannot_execute_purge_function},
      {honors_flag?, :trigger_function_honors_flag}
    ])
  end

  # --- statements ------------------------------------------------------------

  # The table is schema-qualified because the pinned path leaves its schema
  # out. The flag is set with set_config rather than a SET clause, which a
  # non-superuser cannot attach for a custom setting on Postgres 15 and later.
  defp purge_function_statement(schema) do
    """
    CREATE OR REPLACE FUNCTION #{schema}.#{@function_name}(cutoff timestamp with time zone)
    RETURNS bigint
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = #{@pinned_search_path}
    AS $purge$
    DECLARE
      prior_flag text := current_setting('#{@flag}', true);
      removed bigint;
    BEGIN
      IF cutoff IS NULL OR cutoff > now() - interval '#{@retention_floor_days} days' THEN
        RAISE EXCEPTION 'audit_events purge refused: the cutoff must be at least #{@retention_floor_days} days old'
          USING ERRCODE = '#{@cutoff_too_recent_code}';
      END IF;

      PERFORM set_config('#{@flag}', 'on', true);
      DELETE FROM #{schema}.#{@table} WHERE inserted_at < (cutoff AT TIME ZONE 'UTC');
      GET DIAGNOSTICS removed = ROW_COUNT;
      PERFORM set_config('#{@flag}', coalesce(prior_flag, ''), true);

      RETURN removed;
    END;
    $purge$
    """
  end

  defp trigger_statements(:degraded, _runner), do: []

  defp trigger_statements(:hardened, runner),
    do: [trigger_statement(trigger_schema(runner), owner_delete_branch())]

  defp flag_trigger_statement(schema), do: trigger_statement(schema, flag_delete_branch())

  # CREATE OR REPLACE keeps the owner and the grants but clears the function's
  # settings, so the search_path pin must be restated here. The update and
  # truncate branches and every message are those of
  # 20261006153642_fix_audit_events_truncate_message.
  defp trigger_statement(schema, delete_branch) do
    """
    CREATE OR REPLACE FUNCTION #{schema}.#{@trigger_function}
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = #{@pinned_search_path}
    AS $append_only$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF pg_trigger_depth() > 1
           AND OLD.actor_user_id IS NOT NULL
           AND NEW.actor_user_id IS NULL
           AND (to_jsonb(NEW) - 'actor_user_id') = (to_jsonb(OLD) - 'actor_user_id') THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'audit_events is append-only: UPDATE is not permitted';
      END IF;

    #{delete_branch}
      IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'audit_events is append-only: TRUNCATE is not permitted';
      END IF;

      RAISE EXCEPTION 'audit_events is append-only: % is not permitted outside the retention purge', TG_OP;
    END;
    $append_only$
    """
  end

  # The foreign-key cascade runs as the table owner, so a delete fired from
  # another trigger is refused even for the owner. Nothing here may name the
  # flag: status/2 detects the flag-based body by that name.
  defp owner_delete_branch do
    """
      IF TG_OP = 'DELETE'
         AND pg_trigger_depth() = 1
         AND current_user = (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = TG_RELID) THEN
        RETURN OLD;
      END IF;
    """
  end

  defp flag_delete_branch do
    """
      IF TG_OP = 'DELETE'
         AND coalesce(current_setting('#{@flag}', true), '') = 'on' THEN
        RETURN OLD;
      END IF;
    """
  end

  # --- queries ---------------------------------------------------------------

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
      END,
      #{honors_flag_sql()}
    FROM (SELECT to_regprocedure('#{schema}.#{@signature}') AS oid) AS f
    LEFT JOIN pg_proc AS p ON p.oid = f.oid
    """
  end

  defp revert_facts(runner, purge) do
    [[purge_exists?, purge_ownable?, honors_flag?, trigger_ownable?]] =
      runner.("""
      SELECT
        to_regprocedure('#{purge}') IS NOT NULL,
        #{ownable_sql("to_regprocedure('#{purge}')")},
        #{honors_flag_sql()},
        #{ownable_sql("to_regprocedure('#{@trigger_function}')")}
      """).rows

    %{
      purge_exists?: purge_exists?,
      purge_ownable?: purge_ownable?,
      honors_flag?: honors_flag?,
      trigger_ownable?: trigger_ownable?
    }
  end

  defp honors_flag_sql do
    "coalesce((SELECT position('#{@flag}' IN prosrc) > 0 FROM pg_proc " <>
      "WHERE oid = to_regprocedure('#{@trigger_function}')), false)"
  end

  # Whether the connection may replace or drop the function: it owns it, holds
  # the rights of its owner, or is a superuser. An absent function counts as
  # ownable.
  defp ownable_sql(procedure) do
    "coalesce((SELECT pg_has_role(current_user, proowner, 'USAGE') FROM pg_proc " <>
      "WHERE oid = #{procedure}), true)"
  end

  # Why the connection cannot install the degraded purge: it cannot create in
  # the table's schema, or a purge function exists that it does not own.
  defp install_blockers(runner) do
    [[create?, ownable?]] =
      runner.("""
      SELECT
        has_schema_privilege(current_user,
          (SELECT relnamespace FROM pg_class WHERE oid = to_regclass('#{@table}')), 'CREATE'),
        #{ownable_sql("to_regprocedure('#{table_schema(runner)}.#{@signature}')")}
      """).rows

    collect([
      {create? != true, :schema_create_denied},
      {ownable? != true, :purge_function_not_replaceable}
    ])
  end

  defp table_owned_by_owner_role?(runner, opts) do
    owner = Keyword.get(opts, :owner_role, Hardening.owner_role())

    Hardening.scalar(runner, """
    SELECT (SELECT relowner FROM pg_class WHERE oid = to_regclass('#{@table}'))
           = (SELECT oid FROM pg_roles WHERE rolname = #{Hardening.quote_literal(owner)})
    """) == true
  end

  # The schemas holding the table and the trigger function, quoted by Postgres.
  defp table_schema(runner) do
    Hardening.scalar(runner, """
    SELECT quote_ident(nspname) FROM pg_namespace
    WHERE oid = (SELECT relnamespace FROM pg_class WHERE oid = to_regclass('#{@table}'))
    """)
  end

  defp trigger_schema(runner) do
    Hardening.scalar(runner, """
    SELECT quote_ident(nspname) FROM pg_namespace
    WHERE oid = (SELECT pronamespace FROM pg_proc WHERE oid = to_regprocedure('#{@trigger_function}'))
    """)
  end

  # A superuser is degraded only because the table is not the owner role's.
  defp degraded_reason(true), do: :table_not_owned_by_owner_role
  defp degraded_reason(false), do: :not_superuser

  defp collect(checks), do: for({true, reason} <- checks, do: reason)

  # Reasons are code-defined atoms, so they are safe in the message.
  defp degrade(reasons) do
    Logger.warning("security_audit_purge_degraded reason=#{Enum.join(reasons, ",")}")
    {:degraded, reasons}
  end
end
