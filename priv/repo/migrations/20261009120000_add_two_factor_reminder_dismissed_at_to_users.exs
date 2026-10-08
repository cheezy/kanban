defmodule Kanban.Repo.Migrations.AddTwoFactorReminderDismissedAtToUsers do
  @moduledoc """
  When the user last chose "Not now" on the two-factor setup reminder (W2347).

  `nil` means they never dismissed it. The reminder stays hidden for 10 days
  after this time (`Kanban.Accounts.TwoFactor.show_reminder?/2`). Stored on the
  user rather than in the session so the snooze holds on every device.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :two_factor_reminder_dismissed_at, :utc_datetime
    end
  end
end
