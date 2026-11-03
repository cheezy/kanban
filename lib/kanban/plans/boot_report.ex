defmodule Kanban.Plans.BootReport do
  @moduledoc """
  Says once at boot whether paid-plan enforcement is on.

  Enforcement turns on only for `STRIDE_PLANS_ENFORCED=true` exactly
  (`config/runtime.exs`), so a near-miss value such as `TRUE` or `1` leaves
  every paid feature unlocked without failing anything. `config/runtime.exs`
  warns about such a value; this line states the outcome, so an operator can
  confirm it in the boot log after launch or a rollback.
  `Kanban.Application.start/2` calls `log_enforcement/0` before the
  supervision tree starts.
  """

  require Logger

  @doc "Logs, at info level, whether `Kanban.Plans.enforced?/0` is true."
  @spec log_enforcement() :: :ok
  def log_enforcement do
    if Kanban.Plans.enforced?() do
      Logger.info("Paid-plan enforcement is on: free boards get only the free plan's features.")
    else
      Logger.info("Paid-plan enforcement is off: every feature is unlocked on every board.")
    end
  end
end
