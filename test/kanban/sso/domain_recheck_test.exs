defmodule Kanban.SSO.DomainRecheckTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.SSO
  alias Kanban.SSO.DomainRecheck
  alias Kanban.SSO.DomainRecheckWorker
  alias Kanban.SSO.OrganizationDomain

  defmodule Missing do
    @moduledoc "A resolver that finds no TXT records."
    @behaviour Kanban.SSO.TxtResolver
    @impl true
    def lookup_txt(_name), do: {:ok, []}
  end

  @missing [resolver: Missing]
  @found [resolver: Kanban.SSOFixtures.TxtResolver]

  setup do
    organization = organization_fixture()
    %{organization: organization, domain: verified_domain_fixture(organization)}
  end

  defp day(n), do: DateTime.add(~U[2026-10-21 04:11:00Z], n * 86_400, :second)

  test "a found record keeps the domain verified and resets a miss", ctx do
    assert DomainRecheck.recheck(ctx.domain, day(0), @missing) == :failing
    domain = Repo.reload(ctx.domain)
    assert domain.failed_checks == 1
    assert domain.failing_since == day(0)

    assert DomainRecheck.recheck(domain, day(1), @found) == :passed
    domain = Repo.reload(domain)
    assert domain.verified_at
    assert domain.failed_checks == 0
    assert domain.failing_since == nil
    assert domain.last_checked_at == day(1)
  end

  test "three misses in a row unverify the domain and record it", ctx do
    assert DomainRecheck.recheck(ctx.domain, day(0), @missing) == :failing
    assert ctx.domain |> Repo.reload() |> DomainRecheck.recheck(day(1), @missing) == :failing

    domain = Repo.reload(ctx.domain)
    assert domain.failed_checks == 2
    assert domain.failing_since == day(0), "the first miss's date is kept"
    assert SSO.domain_verified_by?(ctx.organization.id, domain.domain)

    assert DomainRecheck.recheck(domain, day(2), @missing) == :unverified

    domain = Repo.reload(domain)
    assert domain.verified_at == nil
    assert domain.failed_checks == 0
    assert domain.verification_token == ctx.domain.verification_token
    refute SSO.domain_verified_by?(ctx.organization.id, domain.domain)

    assert [event] = AuditLog.list_events(action: "organization_domain_unverified")
    assert event.organization_id == ctx.organization.id
    assert event.metadata["domain"] == domain.domain
  end

  test "an unverified domain can be verified again, and another Organization may verify it",
       ctx do
    domain = %{ctx.domain | failed_checks: DomainRecheck.misses_before_unverify() - 1}

    from(d in OrganizationDomain, where: d.id == ^domain.id)
    |> Repo.update_all(set: [failed_checks: domain.failed_checks])

    assert DomainRecheck.recheck(domain, day(0), @missing) == :unverified

    other = organization_fixture()
    claimed = domain_fixture(other, domain.domain)

    assert {:ok, %{verified_at: %DateTime{}}} =
             claimed |> OrganizationDomain.verify_changeset(day(1)) |> Repo.update()
  end

  test "a domain removed or changed while it is checked is skipped", ctx do
    stale = ctx.domain

    from(d in OrganizationDomain, where: d.id == ^stale.id)
    |> Repo.update_all(inc: [failed_checks: 1])

    assert DomainRecheck.recheck(stale, day(0), @missing) == :skipped
    assert Repo.reload(stale).failed_checks == 1

    Repo.delete!(stale)
    assert DomainRecheck.recheck(stale, day(0), @missing) == :skipped
    assert AuditLog.list_events(action: "organization_domain_unverified") == []
  end

  test "run/2 checks only verified domains and counts the outcomes", ctx do
    unverified = domain_fixture(ctx.organization)
    second = verified_domain_fixture(organization_fixture())

    {first_run, second_run} = {day(0), day(1)}

    assert DomainRecheck.run(first_run, @found) ==
             %{checked: 2, passed: 2, failing: 0, unverified: 0}

    assert unverified |> Repo.reload() |> Map.fetch!(:last_checked_at) == nil
    assert second |> Repo.reload() |> Map.fetch!(:last_checked_at) == first_run

    assert DomainRecheck.run(second_run, @missing) ==
             %{checked: 2, passed: 0, failing: 2, unverified: 0}
  end

  test "an org-admin verifying the domain again clears the misses", ctx do
    assert DomainRecheck.recheck(ctx.domain, day(0), @missing) == :failing

    domain =
      ctx.domain
      |> Repo.reload()
      |> OrganizationDomain.verify_changeset(day(1))
      |> Repo.update!()

    assert domain.failed_checks == 0
    assert domain.failing_since == nil
  end

  test "the worker re-checks with the configured resolver", ctx do
    assert :ok = perform_job(DomainRecheckWorker, %{})
    assert Repo.reload(ctx.domain).last_checked_at
  end
end
