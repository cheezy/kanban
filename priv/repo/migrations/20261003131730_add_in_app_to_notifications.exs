defmodule Kanban.Repo.Migrations.AddInAppToNotifications do
  use Ecto.Migration

  # In-app and email preferences are independent: a recipient who turned
  # in-app off but kept email on still gets a row (so the email worker has
  # something to send), stored with in_app = false and hidden from the inbox.
  def change do
    alter table(:notifications) do
      add :in_app, :boolean, null: false, default: true
    end
  end
end
