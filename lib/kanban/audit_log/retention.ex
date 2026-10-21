defmodule Kanban.AuditLog.Retention do
  @moduledoc """
  The Organization-scoped audit purge behind
  `Kanban.AuditLog.purge_organization_before/3`.

  It calls the database function `audit_events_purge_organization` (see
  `Kanban.AuditLog.Hardening.OrganizationPurge`), which removes at most one
  batch of rows inserted strictly before the cutoff for one Organization, or,
  for `nil`, only rows that have no Organization, and refuses a cutoff inside
  the 90-day floor. `Kanban.AuditLog.purge_before/1` and its function are left
  as they are.
  """

  alias Kanban.AuditLog.Hardening.OrganizationPurge
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.Repo

  @purge_refused_code Purge.cutoff_too_recent_code()

  @doc """
  Removes up to `batch_limit` events of Organization `organization_id` (or,
  for `nil`, events with no Organization) inserted strictly before `cutoff`,
  returning `{:ok, removed_count}`. A caller wanting everything older than the
  cutoff calls again until fewer than `batch_limit` rows come back.

  Returns `{:error, :cutoff_too_recent}` when the database refuses a cutoff
  newer than the 90-day floor. Every argument is a bound parameter. Any other
  failure raises, as `Kanban.AuditLog.purge_before/1` does. Inside an open
  transaction the call runs under a savepoint, so a refusal does not abort the
  caller's transaction.
  """
  @spec purge_organization_before(pos_integer() | nil, DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :cutoff_too_recent}
  def purge_organization_before(organization_id, %DateTime{} = cutoff, batch_limit)
      when (is_nil(organization_id) or (is_integer(organization_id) and organization_id > 0)) and
             is_integer(batch_limit) and batch_limit > 0 do
    sql =
      "SELECT #{OrganizationPurge.function_name()}" <>
        "($1::bigint, $2::timestamptz, $3::integer)"

    case Repo.query(sql, [organization_id, cutoff, batch_limit], statement_opts()) do
      {:ok, %{rows: [[removed]]}} ->
        {:ok, removed}

      {:error, %Postgrex.Error{postgres: %{pg_code: @purge_refused_code}}} ->
        {:error, :cutoff_too_recent}

      {:error, error} ->
        raise error
    end
  end

  defp statement_opts do
    if Repo.in_transaction?(), do: [mode: :savepoint], else: []
  end
end
