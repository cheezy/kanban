defmodule Kanban.AuditLog.Hardening do
  @moduledoc """
  Moves the security audit table out of the application's reach.

  The append-only trigger on `audit_events` (see `Kanban.AuditLog.AuditEvent`)
  only protects the table from a role that cannot disable, drop or replace it.
  In Postgres the owner of a table can do all three, and the owner of the
  schema holding it can drop it and its trigger function whoever owns them.
  This module is the single home for the statements that take that ownership
  away from the application:

    * a cluster-wide owner role (`"kanban_audit_owner"`) is created
      when absent, with no login, and the application role is **never** made a
      member of it;
    * `audit_events` (its id sequence follows), the trigger function
      `audit_events_append_only()`, and the schema holding them (normally
      `public`) are handed to that owner role, and the function's
      `search_path` is pinned to `pg_catalog, pg_temp` — the foreign-key
      cascade that nulls `actor_user_id` runs it as the owner role, so an
      unpinned path would let a function the application plants in the schema
      run with the owner's rights;
    * the application role is left with `INSERT` and `SELECT` on the table,
      `USAGE` on its id sequence, and `USAGE` and `CREATE` on that schema, so it
      can still create and drop its own tables there — every other right on
      the table is removed.

  Every public function takes a **runner**: a one-argument function that
  executes one SQL statement and returns its `Postgrex.Result` (raising on
  error), such as `fn sql -> Repo.query!(sql) end`. The migration, the release
  tooling and the tests therefore share one set of statements.

  The migration `20261006155407_move_audit_events_ownership` calls this live
  code, so on a fresh database every statement added to `apply/2` runs at that
  migration's position: it must not depend on an object a later migration
  creates.

  ## Modes

    * `:hardened` — the owner role owns the table, its id sequence, the
      trigger function and their schema, and the application role holds only
      the rights above.
    * `{:degraded, reasons}` — anything else; `status/2` says why with reason
      atoms. Moving ownership to a role you cannot switch into needs a
      superuser, so a migration run by an ordinary role (production deploys run
      the migration as the application role) degrades instead of failing.

  `migrate_or_degrade/2` only knows the role it runs as. Dev and test connect
  as a superuser, so ownership moves there but the result is
  `{:degraded, [:app_role_is_superuser]}` — a superuser bypasses every right
  this module manages. Where migrations run as a superuser but the application
  connects as another role, that role must be hardened by calling `apply/2`
  with its name; until then `status/2` for it reports what it still holds.

  Role names are taken only from the module attribute or from the caller (the
  migration's own `current_user`, a test's generated name), and are always
  quoted as identifiers, never spliced raw. Failures and the degraded notice
  are logged by reason atom only, never connection details.
  """

  import Kernel, except: [apply: 2]

  require Logger

  @owner_role "kanban_audit_owner"
  @table "audit_events"
  @trigger_function "audit_events_append_only()"
  @extra_table_rights "UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER"
  @max_role_name_bytes 63
  @pinned_search_path "pg_catalog, pg_temp"
  @triggers ["audit_events_append_only_rows", "audit_events_append_only_truncate"]

  @typedoc "Executes one SQL statement and returns its result, raising on error."
  @type runner :: (String.t() -> %{rows: [[term()]]})

  @typedoc "Why the table is not hardened."
  @type reason ::
          :not_superuser
          | :owner_role_missing
          | :owner_role_can_login
          | :table_not_owned_by_owner_role
          | :trigger_function_not_owned_by_owner_role
          | :app_role_missing
          | :app_role_is_superuser
          | :app_role_member_of_owner_role
          | :app_role_missing_insert
          | :app_role_missing_select
          | :app_role_missing_sequence_usage
          | :app_role_has_extra_table_rights
          | :app_role_owns_schema
          | :app_role_can_create_roles
          | :trigger_function_search_path_not_pinned
          | :append_only_triggers_missing_or_disabled
          | :rewrite_rule_on_table
          | :unexpected_trigger_on_table
          | :row_security_enabled
          | :foreign_code_on_table

  @doc "The default name of the cluster-wide audit owner role."
  @spec owner_role() :: String.t()
  def owner_role, do: @owner_role

  @doc """
  True only when the role the runner's connection currently acts as is a
  superuser — the only kind of role that can hand ownership to a role it is not
  a member of.
  """
  @spec hardenable?(runner()) :: boolean()
  def hardenable?(runner) do
    scalar(runner, "SELECT rolsuper FROM pg_roles WHERE rolname = current_user") == true
  end

  @doc """
  Hardens `audit_events` for `:app_role`, idempotently.

  Creates the owner role (option `:owner_role`, default `"kanban_audit_owner"`)
  only when absent, tolerating a concurrent creator; hands the table, its id
  sequence, the trigger function and the schema holding them to it; removes
  every table right from the app role and gives back `INSERT` and `SELECT`,
  plus `USAGE` on the id sequence and `USAGE` and `CREATE` on the schema.
  Requires a superuser connection — call `migrate_or_degrade/2` when that is
  not known.

  An owner role that already exists is not altered (concurrent `ALTER ROLE`
  from databases sharing the cluster can fail), so `status/2` is what reports
  one that can log in.
  """
  @spec apply(runner(), keyword()) :: :ok
  def apply(runner, opts) do
    app = opts |> Keyword.fetch!(:app_role) |> quote_ident()
    owner_name = Keyword.get(opts, :owner_role, @owner_role)
    owner = quote_ident(owner_name)
    sequence = sequence_name(runner)
    schemas = schema_names(runner)

    Enum.each(
      [create_owner_role_statement(owner_name)] ++
        Enum.map(schemas, &"ALTER SCHEMA #{&1} OWNER TO #{owner}") ++
        [
          "ALTER TABLE #{@table} OWNER TO #{owner}",
          "ALTER FUNCTION #{@trigger_function} OWNER TO #{owner}",
          # The FK cascade that nulls actor_user_id runs the trigger as the
          # owner role, under the session's search_path. Pinning it stops an
          # app role that can create in the schema from shadowing a function
          # the body calls and running its own code with the owner's rights.
          "ALTER FUNCTION #{@trigger_function} SET search_path = #{@pinned_search_path}",
          # PUBLIC holds no right on a new table or sequence; revoking from it
          # removes any grant, column-level ones included, left behind while
          # the application owned them.
          "REVOKE ALL ON TABLE #{@table} FROM PUBLIC",
          "REVOKE ALL ON TABLE #{@table} FROM #{app}",
          "GRANT INSERT, SELECT ON TABLE #{@table} TO #{app}",
          "REVOKE ALL ON SEQUENCE #{sequence} FROM PUBLIC",
          "REVOKE ALL ON SEQUENCE #{sequence} FROM #{app}",
          "GRANT USAGE ON SEQUENCE #{sequence} TO #{app}"
        ] ++
        Enum.map(schemas, &"GRANT USAGE, CREATE ON SCHEMA #{&1} TO #{app}"),
      runner
    )
  end

  @doc """
  Hardens with `apply/2` when the connection is a superuser, then confirms the
  result with `status/2`: `:hardened` only when the status says so, otherwise
  one degraded notice naming its reasons. When the connection is not a
  superuser it logs one degraded notice and returns
  `{:degraded, [:not_superuser]}`, leaving the table untouched. Never raises
  for lack of privilege.
  """
  @spec migrate_or_degrade(runner(), keyword()) :: :hardened | {:degraded, [reason()]}
  def migrate_or_degrade(runner, opts) do
    if hardenable?(runner) do
      :ok = __MODULE__.apply(runner, opts)

      case status(runner, opts) do
        :hardened -> :hardened
        {:degraded, reasons} -> degrade(reasons)
      end
    else
      degrade([:not_superuser])
    end
  end

  @doc """
  Hands the table, its id sequence, the trigger function and their schema back
  to the role the connection acts as — the migration's down step. The schema
  goes to that role, not to whichever role owned it before `apply/2` (on
  Postgres 15 and later `public` starts out owned by `pg_database_owner`), and
  the trigger function keeps its pinned search_path, which is harmless. Like
  `migrate_or_degrade/2` it degrades instead of raising when the connection is
  not a superuser. It never removes the owner role: roles are cluster-wide, and
  other databases on the cluster may still use it.
  """
  @spec revert(runner()) :: :reverted | {:degraded, [reason()]}
  def revert(runner) do
    if hardenable?(runner) do
      schemas = schema_names(runner)

      Enum.each(
        [
          "ALTER TABLE #{@table} OWNER TO CURRENT_USER",
          "ALTER FUNCTION #{@trigger_function} OWNER TO CURRENT_USER"
        ] ++ Enum.map(schemas, &"ALTER SCHEMA #{&1} OWNER TO CURRENT_USER"),
        runner
      )

      :reverted
    else
      degrade([:not_superuser])
    end
  end

  @doc """
  Reports whether `audit_events` is hardened for `:app_role`.

  Returns `:hardened`, or `{:degraded, reasons}` with every reason that applies.
  The `:owner_role` option (default `"kanban_audit_owner"`) names
  the role expected to own the table. A superuser app role reports only
  `:app_role_is_superuser` among the app-role reasons, since a superuser
  bypasses every right this module manages. An app role that owns (or is a
  member of the owner of) the schema holding the table or the trigger function
  reports `:app_role_owns_schema`, because a schema owner can drop both; one
  that can create roles reports `:app_role_can_create_roles`, because it could
  grant itself the owner role. It also checks what is attached to the table:
  both append-only triggers firing, the trigger function's search_path pinned,
  and no other trigger, rule, row security, or code the owner role would run
  from a function another role owns.
  """
  @spec status(runner(), keyword()) :: :hardened | {:degraded, [reason()]}
  def status(runner, opts) do
    app = Keyword.fetch!(opts, :app_role)
    owner = Keyword.get(opts, :owner_role, @owner_role)
    facts = ownership_facts(runner, app, owner)

    case owner_reasons(facts) ++
           integrity_reasons(runner, owner) ++ app_reasons(runner, facts, app, owner) do
      [] -> :hardened
      reasons -> {:degraded, reasons}
    end
  end

  @doc """
  Quotes a role name as an SQL identifier, doubling any embedded `"`.

  Raises `ArgumentError` for a name Postgres could not hold (empty, longer
  than #{@max_role_name_bytes} bytes, or containing a NUL) or one containing
  `$`, which could end the dollar-quoted block the owner role is created in.
  """
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(name) do
    ~s("#{name |> validate_role_name!() |> String.replace(~s("), ~s(""))}")
  end

  # --- statements ------------------------------------------------------------

  # CREATE ROLE has no IF NOT EXISTS, and two databases on one cluster (test
  # partitions, review apps) can migrate at once: the existence check can pass
  # in both, so the loser's duplicate is swallowed. The exception block runs as
  # a subtransaction, so it never aborts the migration's transaction.
  defp create_owner_role_statement(owner_name) do
    """
    DO $hardening$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{quote_literal(owner_name)}) THEN
        CREATE ROLE #{quote_ident(owner_name)} NOLOGIN;
      END IF;
    EXCEPTION
      WHEN duplicate_object OR unique_violation THEN NULL;
    END
    $hardening$
    """
  end

  # pg_get_serial_sequence returns the name already quoted as needed.
  defp sequence_name(runner) do
    scalar(runner, "SELECT pg_get_serial_sequence('#{@table}', 'id')")
  end

  # The schemas holding the table and the trigger function (normally one,
  # public), quoted by Postgres itself.
  defp schema_names(runner) do
    runner.("SELECT DISTINCT quote_ident(nspname) FROM pg_namespace WHERE #{schema_filter()}").rows
    |> List.flatten()
    |> Enum.sort()
  end

  defp schema_filter do
    "oid IN ((SELECT relnamespace FROM pg_class WHERE oid = to_regclass('#{@table}')), " <>
      "(SELECT pronamespace FROM pg_proc WHERE oid = to_regprocedure('#{@trigger_function}')))"
  end

  # --- status ----------------------------------------------------------------

  defp ownership_facts(runner, app, owner) do
    [[owner_oid, owner_can_login, app_super, app_createrole, table_owner, function_owner]] =
      runner.("""
      SELECT
        (SELECT oid FROM pg_roles WHERE rolname = #{quote_literal(owner)}),
        (SELECT rolcanlogin FROM pg_roles WHERE rolname = #{quote_literal(owner)}),
        (SELECT rolsuper FROM pg_roles WHERE rolname = #{quote_literal(app)}),
        (SELECT rolcreaterole FROM pg_roles WHERE rolname = #{quote_literal(app)}),
        (SELECT relowner FROM pg_class WHERE oid = to_regclass('#{@table}')),
        (SELECT proowner FROM pg_proc WHERE oid = to_regprocedure('#{@trigger_function}'))
      """).rows

    %{
      owner_oid: owner_oid,
      owner_can_login: owner_can_login,
      app_super: app_super,
      app_createrole: app_createrole,
      table_owner: table_owner,
      function_owner: function_owner
    }
  end

  defp owner_reasons(facts) do
    owned? = fn owner -> facts.owner_oid != nil and owner == facts.owner_oid end

    collect([
      {facts.owner_oid == nil, :owner_role_missing},
      {facts.owner_can_login == true, :owner_role_can_login},
      {not owned?.(facts.table_owner), :table_not_owned_by_owner_role},
      {not owned?.(facts.function_owner), :trigger_function_not_owned_by_owner_role}
    ])
  end

  # Ownership alone is not enough. The protection also needs both append-only
  # triggers present and firing and no other trigger, no rewrite rule or row
  # security diverting or hiding rows, the trigger function's search_path
  # pinned, and no code on the table that the owner role would run (during the
  # FK cascade) from a function some other role owns and can rewrite.
  defp integrity_reasons(runner, owner) do
    triggers = Enum.map_join(@triggers, ", ", &"'#{&1}'")

    [[pinned?, live_triggers, other_triggers, rules, row_security?, foreign_code]] =
      runner.("""
      SELECT
        coalesce((SELECT bool_or(setting = 'search_path=#{@pinned_search_path}')
                  FROM pg_proc, unnest(proconfig) AS setting
                  WHERE oid = to_regprocedure('#{@trigger_function}')), false),
        (SELECT count(*) FROM pg_trigger
         WHERE tgrelid = to_regclass('#{@table}') AND tgname IN (#{triggers})
           AND tgenabled IN ('O', 'A') AND tgfoid = to_regprocedure('#{@trigger_function}')),
        (SELECT count(*) FROM pg_trigger
         WHERE tgrelid = to_regclass('#{@table}') AND NOT tgisinternal
           AND tgname NOT IN (#{triggers})),
        (SELECT count(*) FROM pg_rewrite
         WHERE ev_class = to_regclass('#{@table}') AND rulename <> '_RETURN'),
        coalesce((SELECT relrowsecurity OR relforcerowsecurity FROM pg_class
                  WHERE oid = to_regclass('#{@table}')), false),
        (#{foreign_code_query(owner)})
      """).rows

    collect([
      {not pinned?, :trigger_function_search_path_not_pinned},
      {live_triggers != length(@triggers), :append_only_triggers_missing_or_disabled},
      {other_triggers > 0, :unexpected_trigger_on_table},
      {rules > 0, :rewrite_rule_on_table},
      {row_security?, :row_security_enabled},
      {foreign_code > 0, :foreign_code_on_table}
    ])
  end

  # Functions that the table's defaults and generated columns, constraints,
  # indexes, triggers, policies and rules depend on, other than built-ins and
  # the append-only trigger function, that the owner role does not own.
  defp foreign_code_query(owner) do
    table = "to_regclass('#{@table}')"

    """
    SELECT count(*) FROM pg_depend AS d JOIN pg_proc AS p ON p.oid = d.refobjid
    WHERE d.refclassid = 'pg_proc'::regclass
      AND p.pronamespace <> 'pg_catalog'::regnamespace
      AND p.oid IS DISTINCT FROM to_regprocedure('#{@trigger_function}')
      AND p.proowner IS DISTINCT FROM (SELECT oid FROM pg_roles WHERE rolname = #{quote_literal(owner)})
      AND ((d.classid = 'pg_attrdef'::regclass AND d.objid IN (SELECT oid FROM pg_attrdef WHERE adrelid = #{table}))
        OR (d.classid = 'pg_constraint'::regclass AND d.objid IN (SELECT oid FROM pg_constraint WHERE conrelid = #{table}))
        OR (d.classid = 'pg_class'::regclass AND d.objid IN (SELECT indexrelid FROM pg_index WHERE indrelid = #{table}))
        OR (d.classid = 'pg_trigger'::regclass AND d.objid IN (SELECT oid FROM pg_trigger WHERE tgrelid = #{table}))
        OR (d.classid = 'pg_policy'::regclass AND d.objid IN (SELECT oid FROM pg_policy WHERE polrelid = #{table}))
        OR (d.classid = 'pg_rewrite'::regclass AND d.objid IN (SELECT oid FROM pg_rewrite WHERE ev_class = #{table})))
    """
  end

  defp app_reasons(_runner, %{app_super: nil}, _app, _owner), do: [:app_role_missing]
  defp app_reasons(_runner, %{app_super: true}, _app, _owner), do: [:app_role_is_superuser]

  defp app_reasons(runner, facts, app, owner) do
    role = quote_literal(app)

    # pg_has_role raises for a role that does not exist, so membership is only
    # checked when the owner role is there to be a member of.
    member_check =
      if facts.owner_oid,
        do: "pg_has_role(#{role}, #{quote_literal(owner)}, 'MEMBER')",
        else: "false"

    [[member?, insert?, select?, extra?, sequence?, schema_owner?]] =
      runner.("""
      SELECT
        #{member_check},
        has_table_privilege(#{role}, '#{@table}', 'INSERT'),
        has_table_privilege(#{role}, '#{@table}', 'SELECT'),
        has_table_privilege(#{role}, '#{@table}', '#{@extra_table_rights}')
          OR has_any_column_privilege(#{role}, '#{@table}', 'UPDATE, REFERENCES'),
        has_sequence_privilege(#{role}, pg_get_serial_sequence('#{@table}', 'id'), 'USAGE'),
        EXISTS (SELECT 1 FROM pg_namespace WHERE #{schema_filter()}
                AND pg_has_role(#{role}, nspowner, 'MEMBER'))
      """).rows

    collect([
      {member?, :app_role_member_of_owner_role},
      {not insert?, :app_role_missing_insert},
      {not select?, :app_role_missing_select},
      {not sequence?, :app_role_missing_sequence_usage},
      {extra?, :app_role_has_extra_table_rights},
      {schema_owner?, :app_role_owns_schema},
      {facts.app_createrole, :app_role_can_create_roles}
    ])
  end

  defp collect(checks), do: for({true, reason} <- checks, do: reason)

  # --- helpers ---------------------------------------------------------------

  defp scalar(runner, sql) do
    case runner.(sql).rows do
      [[value]] -> value
      [] -> nil
    end
  end

  # Reasons are code-defined atoms, so they are safe in the message.
  defp degrade(reasons) do
    Logger.warning("security_audit_hardening_degraded reason=#{Enum.join(reasons, ",")}")
    {:degraded, reasons}
  end

  defp quote_literal(name) do
    "'" <> (name |> validate_role_name!() |> String.replace("'", "''")) <> "'"
  end

  defp validate_role_name!(name)
       when is_binary(name) and byte_size(name) in 1..@max_role_name_bytes do
    if String.contains?(name, ["\0", "$"]),
      do: raise(ArgumentError, "invalid role name"),
      else: name
  end

  defp validate_role_name!(_name), do: raise(ArgumentError, "invalid role name")
end
