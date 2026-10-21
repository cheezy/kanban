defmodule Kanban.SSO.DomainRecheck do
  @moduledoc """
  Checks every verified email domain's DNS TXT record again (decided
  2026-10-21), run once a day by `Kanban.SSO.DomainRecheckWorker`.

  A domain is verified once, when an org-admin publishes its TXT record; the
  domain can later lapse or change hands while the Organization keeps
  signing in and provisioning people on it. So each verified domain is
  looked up again (`Kanban.SSO.DomainVerification.check/2`):

    * the record is found: the miss count is reset;
    * it is not found: the miss is counted (`failed_checks`, with
      `failing_since` set on the first), and the single sign-on page warns
      the Organization's org-admins;
    * it is not found for the `misses_before_unverify/0`th check in a row:
      the domain stops being verified (`verified_at` is cleared, the row and
      its token are kept so it can be verified again), and
      `:organization_domain_unverified` is recorded. Single sign-on and SCIM
      then stop accepting addresses on it, and another Organization may
      verify it.

  A resolver error counts as a miss, the same as on the page, so a resolver
  outage on Stride's side has to last for three daily runs before anything
  is unverified. Each update is conditional on the row still being verified
  with the miss count that was read, so an org-admin removing or verifying
  the domain while the check runs wins.
  """

  import Ecto.Query, warn: false

  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.SSO.DomainVerification
  alias Kanban.SSO.OrganizationDomain

  @misses_before_unverify 3
  @batch_size 200

  @type summary :: %{
          checked: non_neg_integer(),
          passed: non_neg_integer(),
          failing: non_neg_integer(),
          unverified: non_neg_integer()
        }

  @doc "How many consecutive daily checks must miss the record before a domain is unverified."
  @spec misses_before_unverify() :: pos_integer()
  def misses_before_unverify, do: @misses_before_unverify

  @doc """
  Checks every verified domain at `now`. `opts` is passed to
  `Kanban.SSO.DomainVerification.check/2` (its `:resolver`). Returns how many
  were checked, passed, are failing and were unverified.
  """
  @spec run(DateTime.t(), keyword()) :: summary()
  def run(%DateTime{} = now, opts \\ []) do
    now = DateTime.truncate(now, :second)
    run_batches(now, opts, 0, %{checked: 0, passed: 0, failing: 0, unverified: 0})
  end

  defp run_batches(now, opts, after_id, summary) do
    case verified_batch(after_id) do
      [] ->
        summary

      domains ->
        summary = Enum.reduce(domains, summary, &tally(&2, recheck(&1, now, opts)))
        run_batches(now, opts, List.last(domains).id, summary)
    end
  end

  defp verified_batch(after_id) do
    from(d in OrganizationDomain,
      where: not is_nil(d.verified_at) and d.id > ^after_id,
      order_by: d.id,
      limit: @batch_size
    )
    |> Repo.all()
  end

  defp tally(summary, :skipped), do: summary

  defp tally(summary, outcome) do
    summary
    |> Map.update!(:checked, &(&1 + 1))
    |> Map.update!(outcome, &(&1 + 1))
  end

  @doc """
  Checks one verified domain at `now` and records the result. Returns
  `:passed`, `:failing`, `:unverified`, or `:skipped` when the row changed
  while it was being checked.
  """
  @spec recheck(OrganizationDomain.t(), DateTime.t(), keyword()) ::
          :passed | :failing | :unverified | :skipped
  def recheck(%OrganizationDomain{} = domain, %DateTime{} = now, opts \\ []) do
    now = DateTime.truncate(now, :second)

    case DomainVerification.check(domain, opts) do
      :ok -> record(domain, :passed, now)
      {:error, :record_not_found} -> record(domain, miss_outcome(domain), now)
    end
  end

  defp miss_outcome(%OrganizationDomain{failed_checks: failed}),
    do: if(failed + 1 >= @misses_before_unverify, do: :unverified, else: :failing)

  defp record(domain, outcome, now) do
    case domain |> unchanged() |> Repo.update_all(set: changes(outcome, domain, now)) do
      {1, _rows} -> recorded(outcome, domain)
      {_changed, _rows} -> :skipped
    end
  end

  defp unchanged(%OrganizationDomain{id: id, failed_checks: failed}) do
    from(d in OrganizationDomain,
      where: d.id == ^id and not is_nil(d.verified_at) and d.failed_checks == ^failed
    )
  end

  defp changes(:passed, _domain, now),
    do: [last_checked_at: now, failed_checks: 0, failing_since: nil, updated_at: now]

  defp changes(:failing, domain, now) do
    [
      last_checked_at: now,
      failed_checks: domain.failed_checks + 1,
      failing_since: domain.failing_since || now,
      updated_at: now
    ]
  end

  defp changes(:unverified, _domain, now) do
    [
      verified_at: nil,
      last_checked_at: now,
      failed_checks: 0,
      failing_since: nil,
      updated_at: now
    ]
  end

  # The audit call names its action literally so the telemetry source scan
  # (test/kanban/telemetry/emit_sites_test.exs) finds it.
  defp recorded(:unverified, domain) do
    AuditLog.event(:organization_domain_unverified,
      organization_id: domain.organization_id,
      domain: domain.domain
    )

    :unverified
  end

  defp recorded(outcome, _domain), do: outcome
end
