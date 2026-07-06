defmodule Kanban.Repo.Migrations.CreateDeliveryTargets do
  use Ecto.Migration

  def change do
    create table(:delivery_targets) do
      add :name, :string, null: false
      add :target_date, :date, null: false
      add :description, :text
      add :owner_id, references(:users, on_delete: :nilify_all), null: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:delivery_targets, [:owner_id])

    # A goal may belong to a delivery target. Nullable (goals without a target
    # are the common case), indexed, and nullified when the target is removed.
    alter table(:tasks) do
      add :target_id, references(:delivery_targets, on_delete: :nilify_all)
    end

    create index(:tasks, [:target_id])
  end
end
