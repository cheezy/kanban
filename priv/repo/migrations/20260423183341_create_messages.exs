defmodule Kanban.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :title, :string, null: false
      add :body, :text, null: false
      add :sender_id, references(:users, on_delete: :nilify_all), null: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:sender_id])

    create table(:message_dismissals) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :dismissed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:message_dismissals, [:message_id])
    create index(:message_dismissals, [:user_id])
    create unique_index(:message_dismissals, [:message_id, :user_id])
  end
end
