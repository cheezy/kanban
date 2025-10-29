defmodule Kanban.Repo.Migrations.CreateColumns do
  use Ecto.Migration

  def change do
    create table(:columns) do
      add :name, :string, null: false
      add :position, :integer, null: false
      add :wip_limit, :integer, default: 0, null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:columns, [:board_id])
    create unique_index(:columns, [:board_id, :position])

    # Check constraint to ensure wip_limit is non-negative
    create constraint(:columns, :wip_limit_must_be_non_negative, check: "wip_limit >= 0")
  end
end
