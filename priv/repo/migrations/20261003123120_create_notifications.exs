defmodule Kanban.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: true
      add :task_id, references(:tasks, on_delete: :delete_all), null: true
      add :event_type, :string, null: false
      add :title, :string, null: false
      add :body, :text
      add :url_path, :string
      add :actor_name, :string
      add :metadata, :map, null: false, default: %{}
      add :dedupe_key, :string
      add :read_at, :utc_datetime_usec
      add :emailed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # A notification that names a task must name its board too, so a
    # board-less (always visible) row can never carry task data.
    create constraint(:notifications, :notifications_task_requires_board,
             check: "task_id IS NULL OR board_id IS NOT NULL"
           )

    create index(:notifications, [:user_id, :read_at, :inserted_at])
    create index(:notifications, [:board_id])
    create index(:notifications, [:task_id])
    create unique_index(:notifications, [:user_id, :dedupe_key])

    create table(:notification_preferences) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :in_app, :boolean, null: false, default: true
      add :email, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_preferences, [:user_id, :event_type])
  end
end
