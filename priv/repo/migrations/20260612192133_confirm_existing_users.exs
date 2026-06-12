defmodule Kanban.Repo.Migrations.ConfirmExistingUsers do
  use Ecto.Migration

  # The 2026-06-12 release (W1098) made email confirmation mandatory for
  # login and authenticated access. Accounts created before that deploy were
  # never required to confirm, so without this backfill every pre-existing
  # unconfirmed account is locked out the moment the gate ships. Grandfather
  # them by stamping confirmed_at with the account's own inserted_at.
  #
  # Accounts created after the gate deploy are left untouched — they go
  # through the normal email-confirmation flow.
  @gate_deployed_at "2026-06-12 19:21:37"

  def up do
    execute("""
    UPDATE users
    SET confirmed_at = inserted_at
    WHERE confirmed_at IS NULL
      AND inserted_at < '#{@gate_deployed_at}'
    """)
  end

  # One-way data backfill: once stamped, grandfathered rows are
  # indistinguishable from organically confirmed ones, so down is a no-op.
  def down, do: :ok
end
