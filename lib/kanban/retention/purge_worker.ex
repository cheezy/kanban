defmodule Kanban.Retention.PurgeWorker do
  @moduledoc """
  Daily cron job (`Oban.Plugins.Cron`, every day at 03:47 UTC, on the
  `:maintenance` queue) that applies the data retention settings:

    1. **Organization audit events.** For each Organization whose security
       policy sets `audit_retention_days`
       (`Kanban.Organizations.SecurityPolicies.list_audit_retention/0`), removes
       its audit events older than that through
       `Kanban.AuditLog.purge_organization_before/3`. Organizations without a
       retention period keep everything.
    2. **Site-level audit events** (rows with no Organization), only when
       `site_audit_retention_days` is set. `config/config.exs` sets 90, the
       period `/privacy` promises; unset keeps them all.
    3. **Archived tasks**, only when `archived_task_retention_days` is set,
       through `Kanban.Archives.purge_archived_before/2`. Unset, the default,
       keeps them all.
    4. **Expired SAML sign-in state** (W2246), always: SAML requests and
       replay-cache assertion IDs whose `expires_at` has passed, through
       `Kanban.SSO.SAMLLogin.purge_expired/2`. An assertion ID is kept until
       its assertion has expired, so removing it cannot re-open a replay.

  Settings are read at run time from

      config :kanban, Kanban.Retention.PurgeWorker,
        site_audit_retention_days: 90,
        archived_task_retention_days: nil,
        batch_size: 1_000

  An audit retention below the 90-day floor, or a setting that is not a
  positive whole number of days, removes nothing for that step and logs a
  warning, so a mistake can never empty a table; the database purge function
  refuses a cutoff inside the floor as well. Audit cutoffs are taken a few
  minutes further back than the retention period, so a retention of exactly
  the floor is not refused when the app's clock runs ahead of the database's. Every purge removes `batch_size`
  rows per statement and loops until a batch comes back short, so it never
  holds one long lock. Running the job twice removes nothing the second time.

  A step that fails (for example, an Organization purge function the database
  refuses because hardening has not been re-run since it was installed) is
  logged and named in `failed_steps`, and the remaining steps still run.

  Each run records one `retention_purge` audit event with the rows removed per
  Organization, for site-level events, for archived tasks and for SAML
  sign-in state (`saml_count`).
  """

  # A run that fails is simply re-run by the next day's cron tick.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Kanban.Archives
  alias Kanban.AuditLog
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.SSO.SAMLLogin

  require Logger

  @default_batch_size 1_000
  @seconds_per_day 24 * 60 * 60
  # How far an audit cutoff is moved back, so clock skew between the app and
  # the database cannot put a cutoff at the 90-day floor inside it.
  @clock_skew_allowance_seconds 5 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    settings = Application.get_env(:kanban, __MODULE__, [])
    now = run_time(args)
    batch_size = batch_size(settings)

    settings
    |> run_steps(now, batch_size)
    |> Enum.reduce(%{failed_steps: []}, &summarize_step/2)
    |> report()

    :ok
  end

  defp run_steps(settings, now, batch_size) do
    [
      organization_counts: purge_organizations(now, batch_size),
      site_count: purge_site(settings, now, batch_size),
      archived_task_count: purge_archived(settings, now, batch_size),
      saml_count: purge_saml(now, batch_size)
    ]
  end

  defp summarize_step({key, {count, failures}}, summary) do
    summary |> Map.put(key, count) |> Map.update!(:failed_steps, &(&1 ++ failures))
  end

  # --- steps -----------------------------------------------------------------

  defp purge_organizations(now, batch_size) do
    Enum.reduce(SecurityPolicies.list_audit_retention(), {%{}, []}, fn policy, acc ->
      policy |> purge_organization(now, batch_size) |> collect_organization(policy, acc)
    end)
  end

  defp purge_organization(%{organization_id: id, audit_retention_days: days}, now, batch_size) do
    case audit_days(days) do
      {:ok, days} ->
        run_step({:organization, id}, fn ->
          purge_audit(id, audit_cutoff(now, days), batch_size)
        end)

      :error ->
        warn_invalid("audit_retention_days for organization #{id}", days)
        :skipped
    end
  end

  defp collect_organization({:ok, removed}, %{organization_id: id}, {counts, failures}),
    do: {Map.put(counts, to_string(id), removed), failures}

  defp collect_organization(:error, %{organization_id: id}, {counts, failures}),
    do: {counts, failures ++ ["organization:#{id}"]}

  defp collect_organization(:skipped, _policy, acc), do: acc

  defp purge_site(settings, now, batch_size) do
    case Keyword.get(settings, :site_audit_retention_days) do
      nil -> {nil, []}
      value -> purge_site_days(audit_days(value), value, now, batch_size)
    end
  end

  defp purge_site_days({:ok, days}, _value, now, batch_size) do
    case run_step(:site, fn -> purge_audit(nil, audit_cutoff(now, days), batch_size) end) do
      {:ok, removed} -> {removed, []}
      :error -> {nil, ["site"]}
    end
  end

  defp purge_site_days(:error, value, _now, _batch_size) do
    warn_invalid("site_audit_retention_days", value)
    {nil, []}
  end

  defp purge_archived(settings, now, batch_size) do
    case Keyword.get(settings, :archived_task_retention_days) do
      nil ->
        {nil, []}

      days when is_integer(days) and days > 0 ->
        purge_archived_days(days, now, batch_size)

      invalid ->
        warn_invalid("archived_task_retention_days", invalid)
        {nil, []}
    end
  end

  defp purge_archived_days(days, now, batch_size) do
    case run_step(:archived_tasks, fn -> purge_tasks(cutoff(now, days), batch_size) end) do
      {:ok, removed} -> {removed, []}
      :error -> {nil, ["archived_tasks"]}
    end
  end

  defp purge_saml(now, batch_size) do
    case run_step(:saml, fn -> {:ok, SAMLLogin.purge_expired(now, batch_size)} end) do
      {:ok, removed} -> {removed, []}
      :error -> {nil, ["saml"]}
    end
  end

  defp purge_audit(organization_id, cutoff, batch_size, removed \\ 0) do
    case AuditLog.purge_organization_before(organization_id, cutoff, batch_size) do
      {:ok, count} when count < batch_size -> {:ok, removed + count}
      {:ok, count} -> purge_audit(organization_id, cutoff, batch_size, removed + count)
      {:error, :cutoff_too_recent} -> refused(organization_id, removed)
    end
  end

  # The database measures the floor from its own clock. audit_cutoff/2 leaves
  # room for clock skew; a refusal beyond that removes nothing, which is safe,
  # and the warning makes it visible.
  defp refused(organization_id, removed) do
    Logger.warning(
      "retention purge refused a cutoff inside the floor organization_id=#{inspect(organization_id)}"
    )

    {:ok, removed}
  end

  defp purge_tasks(cutoff, batch_size) do
    {removed, _batches} = Archives.purge_archived_before(cutoff, batch_size)
    {:ok, removed}
  end

  # The exception type and SQLSTATE are code-defined, never row data, so they
  # are safe to log.
  defp run_step(step, fun) do
    fun.()
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("retention purge failed step=#{inspect(step)} reason=#{failure_reason(error)}")
      :error
  end

  defp failure_reason(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp failure_reason(%module{}), do: inspect(module)

  # --- settings --------------------------------------------------------------

  defp audit_days(days) when is_integer(days) do
    if days >= Purge.retention_floor_days(), do: {:ok, days}, else: :error
  end

  defp audit_days(_days), do: :error

  defp cutoff(now, days), do: DateTime.add(now, -days * @seconds_per_day, :second)

  defp audit_cutoff(now, days),
    do: now |> cutoff(days) |> DateTime.add(-@clock_skew_allowance_seconds, :second)

  defp batch_size(settings) do
    case Keyword.get(settings, :batch_size) do
      size when is_integer(size) and size > 0 -> size
      _other -> @default_batch_size
    end
  end

  defp warn_invalid(setting, value) do
    Logger.warning(
      "retention purge skipped: #{setting} must be a whole number of days " <>
        "(at least #{Purge.retention_floor_days()} for audit events), got #{inspect(value)}"
    )
  end

  # "now" (ISO 8601) is a test seam; cron jobs carry empty args.
  defp run_time(%{"now" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      _error -> DateTime.utc_now()
    end
  end

  defp run_time(_args), do: DateTime.utc_now()

  defp report(result) do
    AuditLog.event(:retention_purge, Map.to_list(result))

    Logger.info(
      "retention purge: organizations=#{map_size(result.organization_counts)} " <>
        "site=#{inspect(result.site_count)} archived_tasks=#{inspect(result.archived_task_count)} " <>
        "saml=#{inspect(result.saml_count)} " <>
        "failed=#{length(result.failed_steps)}"
    )
  end
end
