defmodule Kanban.SSO.DomainRecheckWorker do
  @moduledoc """
  Daily cron job (`Oban.Plugins.Cron`, every day at 04:11 UTC, on the
  `:maintenance` queue) that checks every verified email domain's DNS TXT
  record again through `Kanban.SSO.DomainRecheck.run/2`, so a domain whose
  record has been gone for three daily checks in a row stops being verified.
  Logs how many domains were checked, passed, are failing and were
  unverified; each unverified domain is also recorded as
  `:organization_domain_unverified`.
  """

  # A run that fails is simply re-run by the next day's cron tick; a missed
  # day only delays an unverify, it never causes one.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Kanban.SSO.DomainRecheck

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    summary = DomainRecheck.run(DateTime.utc_now())

    Logger.info(
      "Domain re-check: #{summary.checked} checked, #{summary.passed} passed, " <>
        "#{summary.failing} failing, #{summary.unverified} unverified"
    )

    :ok
  end
end
