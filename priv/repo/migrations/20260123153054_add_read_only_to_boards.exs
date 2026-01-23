defmodule Kanban.Repo.Migrations.AddReadOnlyToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :read_only, :boolean, default: false, null: false
    end
  end
end
